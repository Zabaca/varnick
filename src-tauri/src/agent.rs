// The agent process, host-side.
//
// This is the process that performs the spawn, and it is deliberately not the
// process that holds the Sandbox.
//
// ## Why the split is this way round
//
// The Harness runtime holds the Sandbox, so the obvious reading is that it
// should also start the agent. It would then need the credential, which would
// mean sending the value across the bridge — the one thing that may never
// happen. So the work is divided along the secret rather than along the fence
// (ADR-0008):
//
//   * the runtime answers `wrap-agent-command` with argv, an environment
//     overlay and a working directory. That answer contains no secret, and it
//     is computed from the Sandbox that process actually established.
//   * this module spawns that argv and adds the credential to the child's
//     environment, because the credential is already here. `credential_env` is
//     the one way the value leaves credential.rs, and it goes into a child's
//     environment — never into a string this process keeps, never into a log,
//     never into the reply.
//
// Containment still wraps the whole tree, because the wrapping is *in the
// argv*: on macOS it is `bash -c 'env … sandbox-exec -p … bash -c <agent>'`.
// The srt proxies the profile points at live in the runtime, which is why that
// process has to outlive the call that established them.
//
// ## No fallback, under any flag
//
// There is exactly one way to a spawn, and it runs through the runtime's
// wrapping. A runtime that has not established a Sandbox refuses to answer
// `wrap-agent-command`, and a refusal here returns rather than spawning. There
// is no branch that starts an unwrapped process, no environment variable that
// makes one, and no error path that degrades into one.

use std::collections::BTreeMap;
use std::io;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};

use serde::Deserialize;
use serde_json::Value;

use crate::bridge::Failure;
use crate::credential::{credential_env, CredentialStore};

/// The wrapping, as the runtime answered it.
///
/// Mirrored as `WrappedCommand` in packages/harness/src/sandbox.ts. `env` is an
/// overlay applied on top of this process's environment, not a replacement for
/// it — on macOS srt bakes the proxy variables into the command instead, so it
/// is usually empty and must still be applied.
#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct Wrapping {
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub cwd: String,
}

/// Read the runtime's answer, or say it could not be read.
///
/// An empty argv is rejected rather than defaulted: the only thing to default
/// to would be an unwrapped command.
pub fn wrapping_of(answer: &Value) -> Result<Wrapping, Failure> {
    let wrapping: Wrapping =
        serde_json::from_value(answer.clone()).map_err(|_| Failure::of("malformed"))?;
    if wrapping.argv.is_empty() {
        return Err(Failure::of("malformed"));
    }
    Ok(wrapping)
}

/// What to tell the machine about a process that ended.
///
/// Prose, because `agent.crashed` renders it and "the agent stopped" with no
/// reason is the state this exists to avoid. Nothing the child wrote is
/// included — only how it ended, which this process observed itself.
#[cfg(unix)]
pub fn exit_reason(status: &std::process::ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;

    if let Some(signal) = status.signal() {
        return format!("The agent process was killed by signal {signal}.");
    }
    match status.code() {
        Some(0) => "The agent process exited normally.".to_string(),
        Some(code) => format!("The agent process exited with code {code}."),
        None => "The agent process ended for a reason this host could not read.".to_string(),
    }
}

#[cfg(not(unix))]
pub fn exit_reason(status: &std::process::ExitStatus) -> String {
    match status.code() {
        Some(0) => "The agent process exited normally.".to_string(),
        Some(code) => format!("The agent process exited with code {code}."),
        None => "The agent process ended for a reason this host could not read.".to_string(),
    }
}

/// What this host knows about the agent right now.
#[derive(Default)]
struct AgentState {
    /// Bumped on every spawn, so a watcher for a process that has been replaced
    /// cannot report an exit for the one that replaced it.
    generation: u64,
    /// The process group to kill. `Some` while the process is believed alive.
    group: Option<i32>,
    /// Why the current generation ended, once it has.
    exit: Option<String>,
}

/// What the host and every watcher thread share.
#[derive(Default)]
struct Shared {
    state: Mutex<AgentState>,
    ended: Condvar,
}

impl Shared {
    /// Record how a generation ended, if it is still the current one.
    fn report(&self, generation: u64, reason: String) {
        if let Ok(mut state) = self.state.lock() {
            // A watcher for a replaced process says nothing. Otherwise a
            // restart would immediately look like a second crash.
            if state.generation == generation {
                state.exit = Some(reason);
                state.group = None;
            }
        }
        self.ended.notify_all();
    }
}

/// The agent process, and the one place its liveness is known. Tauri state.
#[derive(Default)]
pub struct AgentProcess {
    shared: Arc<Shared>,
}

impl AgentProcess {
    /// Start the agent, replacing whatever was running.
    ///
    /// `wrapping` comes from the runtime and `credentials` from this process.
    /// Neither is optional: a missing credential refuses rather than starting a
    /// process that would fail to authenticate a moment later, which is the
    /// stream of errors story 14 exists to prevent.
    pub fn spawn(
        &self,
        wrapping: &Wrapping,
        credentials: &CredentialStore,
    ) -> Result<u32, Failure> {
        let Some((variable, value)) = credential_env(credentials) else {
            // A tag, not a message. Nothing about a credential is described in
            // a string this process builds — see credential.rs.
            return Err(Failure::refused("nothing-stored"));
        };

        let mut child = build_command(wrapping)
            .env(variable, value)
            .spawn()
            // Nothing the spawn said is forwarded. The environment it failed
            // with holds the credential, and an OS error can quote it.
            .map_err(|_: io::Error| Failure::of("no-runtime"))?;

        let pid = child.id();

        // Replace before watching, so the watcher below is the only one whose
        // generation matches.
        let generation = {
            let mut state = self
                .shared
                .state
                .lock()
                .map_err(|_| Failure::of("runtime-lost"))?;
            kill_group(state.group.take());
            state.generation += 1;
            state.exit = None;
            // The child leads its own process group (see build_command), so its
            // pid is its pgid — and killing the group kills the tree, which is
            // what the wrapper's bash, sandbox-exec and Claude Code all live in.
            state.group = Some(pid as i32);
            state.generation
        };

        // One thread per spawn, owning the Child. `wait()` needs `&mut Child`,
        // and holding the state lock across it would deadlock every stop.
        let shared = Arc::clone(&self.shared);
        std::thread::spawn(move || {
            let reason = match child.wait() {
                Ok(status) => exit_reason(&status),
                Err(_) => "The agent process could not be waited on.".to_string(),
            };
            shared.report(generation, reason);
        });

        Ok(pid)
    }

    /// Wait for the agent to exit and say why.
    ///
    /// Returns immediately if it has already exited — the exit is *state*, not a
    /// signal, precisely because the renderer asks after the machine reaches
    /// `agent.running`, which can be after a process that died instantly.
    pub fn await_exit(&self) -> Result<String, Failure> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;
        if state.generation == 0 {
            return Err(Failure::refused(
                "No agent has been started, so none can exit.",
            ));
        }
        let waiting_for = state.generation;
        loop {
            if let Some(reason) = &state.exit {
                return Ok(reason.clone());
            }
            // A newer generation means a restart happened while this call was
            // waiting. Reporting the new process's future exit under the old
            // call would attach a reason to the wrong run.
            if state.generation != waiting_for {
                return Err(Failure::of("runtime-lost"));
            }
            state = self
                .shared
                .ended
                .wait(state)
                .map_err(|_| Failure::of("runtime-lost"))?;
        }
    }

    /// Stop the agent's whole process tree.
    ///
    /// Idempotent, and quiet when there is nothing running: STOP is a state the
    /// machine can reach without a process behind it.
    pub fn stop(&self) -> Result<(), Failure> {
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;
        kill_group(state.group.take());
        Ok(())
    }
}

impl Drop for AgentProcess {
    /// varnick exiting must not leave a sandboxed agent tree behind it.
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.state.lock() {
            kill_group(state.group.take());
        }
    }
}

/// The command, minus the credential.
///
/// Split out so a test can read exactly what is spawned without a test ever
/// spawning one.
fn build_command(wrapping: &Wrapping) -> Command {
    let mut command = Command::new(&wrapping.argv[0]);
    command
        .args(&wrapping.argv[1..])
        // The overlay is added to this process's environment, never used as a
        // replacement for it — see `Wrapping`.
        .envs(&wrapping.env)
        // The clone. Load-bearing: the policy denies the home directory and
        // reads only the clone back out, so a child started anywhere else has a
        // working directory it cannot read, and its interpreter fails at
        // startup with an error that names nothing.
        .current_dir(&wrapping.cwd)
        .stdin(Stdio::null())
        // Diagnostics go to the terminal varnick was launched from. Not
        // captured: this host does not read the agent's output, so it cannot
        // forward anything the agent printed into a reply.
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    lead_process_group(&mut command);
    command
}

/// Put the child in its own process group, so stopping it stops its tree.
#[cfg(unix)]
fn lead_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(not(unix))]
fn lead_process_group(_command: &mut Command) {}

/// Kill a whole process group, best effort.
#[cfg(unix)]
fn kill_group(group: Option<i32>) {
    let Some(group) = group else { return };
    // Negative pid means the group: the wrapper's bash, sandbox-exec, the agent
    // host and the Claude Code process it started. Killing only the leader
    // would leave a sandboxed tree with nothing attached to it.
    unsafe {
        libc::kill(-group, libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_group(_group: Option<i32>) {}

#[cfg(test)]
mod tests {
    use super::{build_command, exit_reason, wrapping_of, Wrapping};
    use crate::bridge::Failure;
    use serde_json::json;
    use std::collections::BTreeMap;

    fn wrapping() -> Wrapping {
        Wrapping {
            argv: vec!["/bin/bash".into(), "-c".into(), "sandbox-exec … agent".into()],
            env: BTreeMap::from([("SANDBOX_RUNTIME".to_string(), "1".to_string())]),
            cwd: "/Users/dev/code/varnick".into(),
        }
    }

    #[test]
    fn the_wrapping_is_read_as_the_runtime_wrote_it() {
        let answer = json!({
            "argv": ["/bin/bash", "-c", "sandbox-exec … agent"],
            "env": { "SANDBOX_RUNTIME": "1" },
            "cwd": "/Users/dev/code/varnick",
        });
        assert_eq!(wrapping_of(&answer), Ok(wrapping()));
    }

    #[test]
    fn an_empty_argv_is_not_a_command_to_run_unwrapped() {
        // The only thing an empty argv could fall back to is an unconfined
        // process, so it is a refusal rather than a default.
        let answer = json!({ "argv": [], "env": {}, "cwd": "/clone" });
        assert_eq!(wrapping_of(&answer), Err(Failure::of("malformed")));
    }

    #[test]
    fn an_answer_that_is_not_a_wrapping_is_malformed() {
        assert_eq!(wrapping_of(&json!({})), Err(Failure::of("malformed")));
        assert_eq!(
            wrapping_of(&json!({ "argv": ["/bin/bash"] })),
            Err(Failure::of("malformed"))
        );
        assert_eq!(wrapping_of(&json!("nope")), Err(Failure::of("malformed")));
    }

    #[test]
    fn the_command_runs_the_wrapped_argv_in_the_clone() {
        let command = build_command(&wrapping());
        assert_eq!(command.get_program(), "/bin/bash");
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(args, vec!["-c", "sandbox-exec … agent"]);
        assert_eq!(
            command.get_current_dir(),
            Some(std::path::Path::new("/Users/dev/code/varnick"))
        );
    }

    #[test]
    fn the_overlay_is_added_and_nothing_is_cleared() {
        // `env_clear` is never called: the overlay is an addition to this
        // process's environment, and on macOS it is empty because srt bakes the
        // proxy variables into the command instead.
        let command = build_command(&wrapping());
        let envs: Vec<_> = command.get_envs().collect();
        assert_eq!(
            envs,
            vec![(
                std::ffi::OsStr::new("SANDBOX_RUNTIME"),
                Some(std::ffi::OsStr::new("1"))
            )]
        );
    }

    #[test]
    fn the_credential_is_not_in_the_command_before_the_spawn_adds_it() {
        // The value is attached at the spawn and nowhere else, so nothing that
        // inspects a command can find it.
        let command = build_command(&wrapping());
        for (name, _) in command.get_envs() {
            assert_ne!(name, std::ffi::OsStr::new(crate::credential::ENV_VAR));
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_killed_process_says_it_was_killed() {
        use std::os::unix::process::ExitStatusExt;
        let status = std::process::ExitStatus::from_raw(9);
        assert_eq!(
            exit_reason(&status),
            "The agent process was killed by signal 9."
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_exit_code_is_reported_as_itself() {
        use std::os::unix::process::ExitStatusExt;
        // 71 is what every Bash command returns when the SDK's own sandbox is
        // left on inside srt — the reason ADR-0003 says it stays off.
        let status = std::process::ExitStatus::from_raw(71 << 8);
        assert_eq!(exit_reason(&status), "The agent process exited with code 71.");
    }

    #[cfg(unix)]
    #[test]
    fn a_clean_exit_still_carries_a_reason() {
        use std::os::unix::process::ExitStatusExt;
        // agent.crashed renders this, so there is no such thing as an exit with
        // nothing to say.
        let status = std::process::ExitStatus::from_raw(0);
        assert!(!exit_reason(&status).is_empty());
        assert_eq!(exit_reason(&status), "The agent process exited normally.");
    }
}
