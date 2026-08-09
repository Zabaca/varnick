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

use std::collections::{BTreeMap, VecDeque};
use std::io::{self, BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde::Deserialize;
use serde_json::Value;

use crate::bridge::Failure;
use crate::credential::{credential_env, CredentialStore};

/// How long a wait for the next Turn event lasts before answering "nothing yet".
///
/// Long, because a Turn that is thinking is a working Turn and a short limit
/// would turn a wait into a poll. Bounded at all, because a wait nobody is
/// listening to any more — an interrupted Turn's — would otherwise hold a host
/// thread until the agent said something, which it may never do.
const EVENT_WAIT: Duration = Duration::from_secs(15);

/// How long a wait for the agent to exit lasts before answering "still running".
///
/// **Bounded for the reason `EVENT_WAIT` is, arrived at the hard way.** This
/// wait was unbounded, and one is issued on every entry to `agent.running` — so
/// each agent restart and each page load left another host thread parked for the
/// life of a process that may run all day. Eleven of them were measured on a
/// developer's machine, and while they were parked on the *worker* pool the app
/// eventually had no thread left to answer anything at all.
///
/// The blocking pool the bridge now uses makes that far harder to reach. This
/// makes it unreachable: a waiter belongs to whoever is still asking, and one
/// nobody re-asks for goes away on its own within the minute.
const EXIT_WAIT: Duration = Duration::from_secs(30);

/// What `await-agent-exit` answers while the agent is still running.
///
/// A tag rather than prose, and deliberately not a failure: the actor re-asks,
/// the same shape as `next-turn-event`'s `null`. The machine only leaves
/// `agent.running` when a real reason arrives.
pub const STILL_RUNNING: &str = "still-running";

/// What to say when there is no agent to be told which secrets exist.
///
/// Its own sentence since ticket 31. It used to borrow `NO_SESSION_TO_ASK`,
/// which was written for a plan-usage read and said so — a describe that
/// refused explained itself by talking about figures from a plan. Nobody ever
/// read it, because `describe_secrets` is best-effort and its caller drops the
/// refusal, which is exactly how a wrong sentence survives.
const NO_AGENT_TO_TELL: &str =
    "There is no agent running, so there is nothing to tell which secrets exist. \
     The names are sent again before the next Turn.";


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

/// One control request to the agent host, as one line, or nothing.
///
/// Rebuilt field by field rather than forwarded. The agent host runs inside srt
/// holding a live Claude Code session, so its control channel is the one place
/// where "pass the request through and let the other end sort it out" would mean
/// handing the renderer a way to say things to a confined agent that nobody
/// agreed it could say.
///
/// `serde_json` escapes newlines, so a prompt with one in it cannot split a
/// request across two lines — the same framing the runtime channel uses.
pub fn control_line_for(request: &Value) -> Option<String> {
    let field = |name: &str| request.get(name).and_then(Value::as_str);
    // Per kind rather than up front: a read names a `requestId` and has no Turn
    // to name, and requiring one of both would be requiring the wrong field.
    let turn_id = || field("turnId");

    let control = match request.get("kind").and_then(Value::as_str)? {
        "run-turn" => serde_json::json!({
            "kind": "run-turn",
            "turnId": turn_id()?,
            "prompt": field("prompt")?,
            "model": field("model")?,
            "effort": field("effort")?,
        }),
        // The renderer's word is `interrupt-turn`, because on that side of the
        // bridge a Turn is the thing being interrupted. Inside the agent host
        // there is only one Turn, so it is just `interrupt`.
        "interrupt-turn" => serde_json::json!({ "kind": "interrupt", "turnId": turn_id()? }),
        // Likewise `compact-session` outside, `compact` inside — one Session,
        // so there is nothing to name. It carries a Turn id and nothing else:
        // what the confined process is actually told to run is a constant in
        // packages/harness/src/turn.ts, so no prompt crosses this boundary and
        // there is no field a request could put one in.
        "compact-session" => serde_json::json!({ "kind": "compact", "turnId": turn_id()? }),
        // `clear-session` outside, `clear` inside, and the emptiest request on
        // the channel: no Turn id, because a clear is not part of one, and no
        // prompt, because what the confined process runs is a constant in
        // packages/harness/src/turn.ts. Nothing crosses here at all except the
        // instruction to forget.
        "clear-session" => serde_json::json!({ "kind": "clear" }),
        // The one request on this channel that tells the confined process
        // something instead of asking it to do something: which secrets exist,
        // by name, so the agent can write `process.env.STRIPE_KEY` in the
        // Userspace it builds (ADR-0006).
        //
        // **Rebuilt to `kind` and `names`, and every entry has to be a string.**
        // That is what makes "no value crosses here" a property of this function
        // rather than a promise made by whoever calls it: a request carrying a
        // `values` field alongside loses it, in the same way a `prompt` sent
        // beside a compaction is a field that was never read. The names
        // themselves come from the Harness runtime, off `SecretsStore.names()`
        // — see `HarnessRuntime::secret_names` — and this process never learns
        // what any of them stand for.
        "describe-secrets" => {
            let names = request.get("names").and_then(Value::as_array)?;
            if !names.iter().all(Value::is_string) {
                return None;
            }
            serde_json::json!({ "kind": "describe-secrets", "names": names })
        }
        _ => return None,
    };

    Some(format!("{control}\n"))
}

// `usage_answer_of` was here, reading `plan-usage` answer lines off the agent's
// stdout and telling them apart from Turn events by which id they named. The
// kind it decoded is gone (ticket 31): no credential varnick can hold reports
// plan usage, so nothing ever wrote one of those lines with a figure in it.
//
// The two-shapes-on-one-pipe discipline it demonstrated still holds; there is
// simply one shape on the pipe again, and `agent_event_of` is it.

/// A line the agent host wrote, if it is a Turn event.
///
/// Anything else on stdout is diagnostics — the agent host announces itself
/// with `{"ready":true}` — and is dropped. The event is not interpreted here:
/// packages/harness/src/bridge.ts rebuilds it field by field on the way into
/// Core, and authoring the sentence a developer reads is that side's job.
pub fn agent_event_of(line: &str) -> Option<Value> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    value.get("turnId").and_then(Value::as_str)?;
    value.get("kind").and_then(Value::as_str)?;
    Some(value)
}

/// What the agent has said that nobody has read yet.
///
/// Its own type so it can be tested without a process. Generation-stamped for
/// the same reason the exit is: a delta written by an agent that has since been
/// replaced would arrive as the previous conversation's words in this one's
/// transcript.
#[derive(Default)]
pub struct EventQueue {
    inner: Arc<EventQueueInner>,
}

#[derive(Default)]
struct EventQueueInner {
    state: Mutex<EventQueueState>,
    arrived: Condvar,
}

#[derive(Default)]
struct EventQueueState {
    generation: u64,
    events: VecDeque<Value>,
}

impl EventQueue {
    /// Start a generation, discarding everything the last one had to say.
    pub fn restart(&self) -> u64 {
        let mut state = match self.inner.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        };
        state.generation += 1;
        state.events.clear();
        state.generation
    }

    /// Queue an event, if the generation that produced it is still current.
    pub fn push(&self, generation: u64, event: Value) {
        if let Ok(mut state) = self.inner.state.lock() {
            if state.generation == generation {
                state.events.push_back(event);
            }
        }
        self.inner.arrived.notify_all();
    }

    /// The next event, waiting up to `limit` for one.
    ///
    /// `None` means nothing was said in that time, which is not a failure: a
    /// Turn that is thinking is a working Turn.
    pub fn next(&self, limit: Duration) -> Option<Value> {
        let mut state = self.inner.state.lock().ok()?;
        let deadline = std::time::Instant::now() + limit;
        loop {
            if let Some(event) = state.events.pop_front() {
                return Some(event);
            }
            let remaining = deadline.checked_duration_since(std::time::Instant::now())?;
            let (guard, timed_out) = self.inner.arrived.wait_timeout(state, remaining).ok()?;
            state = guard;
            if timed_out.timed_out() && state.events.is_empty() {
                return None;
            }
        }
    }

    /// A second handle on the same queue, for the thread reading the agent.
    pub fn clone_handle(&self) -> EventQueue {
        EventQueue {
            inner: Arc::clone(&self.inner),
        }
    }
}

// A `PlanUsageAnswers` slot was here: one generation-stamped answer, a condvar,
// and a `take` that refused to hand a figure to a read that did not ask for it.
//
// The care was warranted and the thing it was careful about never existed. No
// credential varnick can hold reports plan usage, so no answer ever arrived to
// be matched to a read. Removed with the rest in ticket 31; `EventQueue` above
// keeps the generation stamping, which does guard something real — a delta from
// a previous agent landing in this one's Turn.

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
    /// The agent host's control channel. `Some` while the process is believed
    /// alive — a Turn with nowhere to send its prompt is a refusal, never a
    /// second process started to have somewhere to send it.
    stdin: Option<ChildStdin>,
    /// The Turn this host last started, so an agent that dies mid-Turn can be
    /// reported against the Turn it killed rather than silently.
    turn: Option<String>,
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
    /// What the agent has said about the Turn in flight, waiting to be read.
    events: EventQueue,
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
        let Some(injection) = credential_env(credentials) else {
            // A tag, not a message. Nothing about a credential is described in
            // a string this process builds — see credential.rs.
            return Err(Failure::refused("nothing-stored"));
        };

        let mut child = build_command(wrapping)
            .env(injection.variable, injection.value)
            // The other authentication variable, taken away rather than left
            // to be inherited. This process was launched from a developer's
            // terminal and may itself hold an exported ANTHROPIC_API_KEY; an
            // agent handed that beside an injected subscription token would
            // authenticate as an account varnick never resolved. Exactly one
            // credential reaches the child, and it is the resolved one.
            .env_remove(injection.cleared)
            .spawn()
            // Nothing the spawn said is forwarded. The environment it failed
            // with holds the credential, and an OS error can quote it.
            .map_err(|_: io::Error| Failure::of("no-runtime"))?;

        let pid = child.id();
        // Both pipes, or neither. A Turn with nowhere to send its prompt is a
        // refusal; there is no branch here that starts a second process to have
        // somewhere to send it.
        let stdin = child.stdin.take().ok_or_else(|| Failure::of("no-runtime"))?;
        let stdout = child.stdout.take().ok_or_else(|| Failure::of("no-runtime"))?;

        // Before the watchers, so the two threads below are the only ones whose
        // generation matches. The queue restarts here too: a delta from the
        // agent being replaced must not arrive in the new one's transcript.
        let generation = {
            let mut state = self
                .shared
                .state
                .lock()
                .map_err(|_| Failure::of("runtime-lost"))?;
            kill_group(state.group.take());
            state.generation += 1;
            state.exit = None;
            state.turn = None;
            state.stdin = Some(stdin);
            // The child leads its own process group (see build_command), so its
            // pid is its pgid — and killing the group kills the tree, which is
            // what the wrapper's bash, sandbox-exec and Claude Code all live in.
            state.group = Some(pid as i32);
            state.generation
        };
        self.events.restart();
        let queue_generation = generation;

        /*
          One thread reading the agent's stdout, for the life of this process.

          This is the only thing this host reads out of the agent, and it reads
          it as data rather than as prose: `agent_event_of` keeps the lines that
          name a Turn and drops the rest. Nothing here authors a sentence — the
          renderer does that, from the tag the event carries, so a failure this
          host has never seen cannot be described by a string it built.
        */
        let queue = self.events.clone_handle();
        let shared = Arc::clone(&self.shared);
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(event) = agent_event_of(&line) {
                    queue.push(queue_generation, event);
                }
            }
            // End of stream: the agent is gone. A Turn that was running has to
            // be told, or it streams for ever against a process that stopped
            // answering.
            let turn = shared
                .state
                .lock()
                .ok()
                .and_then(|mut state| {
                    if state.generation == queue_generation {
                        state.turn.take()
                    } else {
                        None
                    }
                });
            if let Some(turn_id) = turn {
                queue.push(
                    queue_generation,
                    serde_json::json!({
                        "kind": "failed",
                        "turnId": turn_id,
                        "failure": "agent-ended",
                    }),
                );
            }
        });

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

    /// Put one control request on the Session the agent process is holding.
    ///
    /// Three kinds arrive here, because from this side they are the same act:
    /// starting a Turn, interrupting one, and compacting the Session. Which
    /// line goes out is {@link control_line_for}'s decision; what differs after
    /// the write is only whether the request names a Turn this process should
    /// remember, so that an agent dying mid-answer is reported against it.
    ///
    /// Writes one control line and returns. Every answer arrives through
    /// {@link AgentProcess::next_event}, which is what lets a developer read it
    /// as it comes rather than when it is over.
    ///
    /// There is no path from here to a Claude Code process: this writes to a
    /// pipe, and a Turn with no pipe to write to is a refusal. Opening a session
    /// to answer a Turn would be the second session ADR-0003 forbids.
    pub fn run_turn(&self, request: &Value) -> Result<(), Failure> {
        let Some(line) = control_line_for(request) else {
            return Err(Failure::of("malformed"));
        };
        let turn_id = request
            .get("turnId")
            .and_then(Value::as_str)
            .map(str::to_string);

        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;

        let Some(stdin) = state.stdin.as_mut() else {
            return Err(Failure::refused(
                "There is no agent running, so there is nothing to run a turn on. Start the agent first.",
            ));
        };

        stdin
            .write_all(line.as_bytes())
            .and_then(|()| stdin.flush())
            // Nothing the write said is forwarded: this process holds the
            // credential, and an OS error can quote the environment.
            .map_err(|_| Failure::of("runtime-lost"))?;

        // Both are Turns from this host's point of view: an agent that dies
        // mid-compaction has to be reported against the compaction it killed,
        // or `turn.compacting` waits on a process that has stopped answering.
        if matches!(
            request.get("kind").and_then(Value::as_str),
            Some("run-turn") | Some("compact-session")
        ) {
            state.turn = turn_id;
        }
        Ok(())
    }

    /// Tell the agent which secrets exist, by name.
    ///
    /// One line onto the same pipe a Turn rides, sent immediately before one so
    /// that the brief the agent is given describes the store as it is *now* —
    /// not as it was when varnick launched. That is the whole reason this is a
    /// control line rather than a variable in the spawn environment: a
    /// developer who runs `bun run secret add` in another terminal should be
    /// able to say "use it" in the next message, and the SDK gives no way to
    /// change a system prompt once a session is open.
    ///
    /// **Best effort, and it must stay that way.** A Turn is the thing the
    /// developer asked for; being unable to name the secrets is a poorer answer,
    /// not a failed one, so this returns a refusal that the caller drops. With
    /// no agent running there is nothing to tell and nothing to fail — the Turn
    /// that follows refuses on its own account, with the sentence that fits.
    ///
    /// Names, never values. There is no argument here a value could arrive in,
    /// and `control_line_for` would not carry one if there were.
    pub fn describe_secrets(&self, names: &[String]) -> Result<(), Failure> {
        let Some(line) = control_line_for(&serde_json::json!({
            "kind": "describe-secrets",
            "names": names,
        })) else {
            return Err(Failure::of("malformed"));
        };

        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;

        let Some(stdin) = state.stdin.as_mut() else {
            return Err(Failure::refused(NO_AGENT_TO_TELL));
        };

        stdin
            .write_all(line.as_bytes())
            .and_then(|()| stdin.flush())
            // Nothing the write said is forwarded, for the same reason as
            // everywhere else here: this process holds the credential, and an
            // OS error can quote the environment.
            .map_err(|_| Failure::of("runtime-lost"))
    }

    /// The next thing the running Turn had to say, or nothing yet.
    pub fn next_event(&self) -> Option<Value> {
        self.events.next(EVENT_WAIT)
    }

    /// Wait for the agent to exit and say why, or say it is still running.
    ///
    /// Returns immediately if it has already exited — the exit is *state*, not a
    /// signal, precisely because the renderer asks after the machine reaches
    /// `agent.running`, which can be after a process that died instantly.
    ///
    /// Bounded by {@link EXIT_WAIT}, answering {@link STILL_RUNNING} when it
    /// expires. The caller re-asks; see `liveAgentExit`. A wait for a process
    /// that runs all day used to hold a host thread for the whole of it, one per
    /// page load, and the app went silent when they outnumbered the pool.
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
        let deadline = std::time::Instant::now() + EXIT_WAIT;
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
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            if left.is_zero() {
                return Ok(STILL_RUNNING.to_string());
            }
            // The deadline is against the wall clock rather than per-wait, so a
            // spurious wake-up cannot extend it indefinitely.
            let (next, _) = self
                .shared
                .ended
                .wait_timeout(state, left)
                .map_err(|_| Failure::of("runtime-lost"))?;
            state = next;
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
        // Dropped with the process. A control channel to a tree that has been
        // killed is a pipe a later Turn would write into and never hear from.
        state.stdin = None;
        state.turn = None;
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
        /*
          Both pipes, because a Turn rides this process.

          stdin carries control requests — a prompt, an interrupt — and stdout
          carries what the Turn says back. That is what makes ADR-0003's last
          consequence implementable rather than merely stated: there is a way to
          ask the confined session a question, so nothing needs to open a second
          one to ask it.

          Only lines that name a Turn are read back (`agent_event_of`), and even
          those are rebuilt on the far side of the bridge. stderr stays on the
          terminal varnick was launched from, uncaptured, so nothing the agent
          printed can be forwarded into a reply.
        */
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
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
    use super::{
        agent_event_of, build_command, control_line_for, exit_reason, wrapping_of, AgentProcess,
        EventQueue, Wrapping,
    };
    use crate::bridge::Failure;
    use serde_json::json;
    use std::collections::BTreeMap;
    use std::time::Duration;

    /// A value shaped like a real key, used to prove it never gets through.
    // Assembled at run time, for the same reason its TypeScript counterparts are:
    // the value is invented, but its shape is one every secret scanner flags,
    // and a literal of that shape blocks pushing for this repository and for
    // every fork of it.
    fn looks_like_a_key() -> String {
        format!("{}{}", "sk-", "ant-api03-NEVER-LET-THIS-OUT")
    }

    #[test]
    fn a_turn_reaches_the_agent_as_one_line() {
        let line = control_line_for(&json!({
            "kind": "run-turn",
            "turnId": "t1",
            "prompt": "hello\nthere",
            "model": "claude-opus-5",
            "effort": "xhigh",
        }))
        .expect("a run-turn is a control request");
        assert!(line.ends_with('\n'));
        // The prompt has a newline in it and the framing is one request per
        // line, so escaping is what keeps the channel in step.
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn the_control_request_is_rebuilt_rather_than_forwarded() {
        // The agent host runs inside srt holding a live Claude Code session.
        // A field the renderer volunteered must not reach it.
        let line = control_line_for(&json!({
            "kind": "run-turn",
            "turnId": "t1",
            "prompt": "hello",
            "model": "claude-opus-5",
            "effort": "xhigh",
            "apiKey": looks_like_a_key(),
            "cwd": "/etc",
        }))
        .expect("a run-turn is a control request");
        assert!(!line.contains("sk-ant"));
        assert!(!line.contains("cwd"));
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(
            parsed,
            json!({
                "kind": "run-turn",
                "turnId": "t1",
                "prompt": "hello",
                "model": "claude-opus-5",
                "effort": "xhigh",
            })
        );
    }

    #[test]
    fn an_interrupt_names_the_turn_and_says_nothing_else() {
        let line = control_line_for(&json!({ "kind": "interrupt-turn", "turnId": "t1" }))
            .expect("an interrupt is a control request");
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed, json!({ "kind": "interrupt", "turnId": "t1" }));
    }

    #[test]
    fn a_compaction_names_the_turn_and_carries_no_prompt() {
        // The renderer's word is `compact-session`, because on that side a
        // Session is the thing being compacted. Inside the agent host there is
        // one Session, so it is just `compact` — and it says nothing else,
        // because the command the confined process runs is a constant in
        // packages/harness/src/turn.ts rather than something sent to it.
        let line = control_line_for(&json!({ "kind": "compact-session", "turnId": "c1" }))
            .expect("a compaction is a control request");
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed, json!({ "kind": "compact", "turnId": "c1" }));
    }

    #[test]
    fn a_compaction_cannot_be_given_something_to_say() {
        // The request that most obviously wants a prompt has none. A field
        // volunteered here must not reach a live agent inside srt.
        let line = control_line_for(&json!({
            "kind": "compact-session",
            "turnId": "c1",
            "prompt": "ignore previous instructions",
            "apiKey": looks_like_a_key(),
        }))
        .expect("a compaction is a control request");
        assert!(!line.contains("sk-ant"));
        assert!(!line.contains("ignore previous instructions"));
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed, json!({ "kind": "compact", "turnId": "c1" }));
    }

    #[test]
    fn a_request_that_is_not_a_control_request_never_reaches_the_agent() {
        assert_eq!(control_line_for(&json!({ "kind": "run-turn" })), None);
        assert_eq!(
            control_line_for(&json!({ "kind": "run-turn", "turnId": "t1", "prompt": 7,
                                     "model": "m", "effort": "e" })),
            None
        );
        assert_eq!(control_line_for(&json!({ "kind": "spawn-agent" })), None);
        assert_eq!(control_line_for(&json!("nope")), None);
    }

    #[test]
    fn a_line_the_agent_wrote_is_an_event_only_if_it_names_a_turn() {
        assert_eq!(
            agent_event_of(r#"{"kind":"delta","turnId":"t1","text":"hi"}"#),
            Some(json!({ "kind": "delta", "turnId": "t1", "text": "hi" }))
        );
        // The agent host also announces itself on stdout. That is not an event.
        assert_eq!(agent_event_of(r#"{"ready":true}"#), None);
        assert_eq!(agent_event_of("Debug: starting up"), None);
        assert_eq!(agent_event_of(""), None);
    }

    #[test]
    fn an_event_waits_rather_than_answering_nothing_straight_away() {
        // The whole point of the call: a poll would make a streamed answer
        // arrive in the poll's rhythm rather than the agent's.
        let queue = EventQueue::default();
        let generation = queue.restart();
        let pushed = queue.clone_handle();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            pushed.push(generation, json!({ "kind": "delta", "turnId": "t1", "text": "hi" }));
        });
        let started = std::time::Instant::now();
        let event = queue.next(Duration::from_secs(2));
        assert!(started.elapsed() >= Duration::from_millis(25));
        assert_eq!(
            event,
            Some(json!({ "kind": "delta", "turnId": "t1", "text": "hi" }))
        );
    }

    #[test]
    fn a_wait_that_ran_out_of_patience_is_nothing_rather_than_a_failure() {
        // A Turn that is thinking is a working Turn. Failing here would fail it.
        let queue = EventQueue::default();
        queue.restart();
        assert_eq!(queue.next(Duration::from_millis(10)), None);
    }

    #[test]
    fn events_arrive_in_the_order_the_agent_wrote_them() {
        let queue = EventQueue::default();
        let generation = queue.restart();
        queue.push(generation, json!({ "kind": "delta", "turnId": "t1", "text": "one" }));
        queue.push(generation, json!({ "kind": "delta", "turnId": "t1", "text": "two" }));
        assert_eq!(
            queue.next(Duration::from_millis(10)),
            Some(json!({ "kind": "delta", "turnId": "t1", "text": "one" }))
        );
        assert_eq!(
            queue.next(Duration::from_millis(10)),
            Some(json!({ "kind": "delta", "turnId": "t1", "text": "two" }))
        );
    }

    #[test]
    fn a_restart_leaves_no_event_from_the_process_that_was_replaced() {
        // A delta from a dead agent delivered into a fresh one's Turn would be
        // the previous conversation's words in this one's transcript.
        let queue = EventQueue::default();
        let old = queue.restart();
        queue.push(old, json!({ "kind": "delta", "turnId": "t1", "text": "stale" }));
        queue.restart();
        assert_eq!(queue.next(Duration::from_millis(10)), None);
    }

    #[test]
    fn an_event_from_a_replaced_generation_is_dropped_rather_than_queued() {
        let queue = EventQueue::default();
        let old = queue.restart();
        let new = queue.restart();
        queue.push(old, json!({ "kind": "delta", "turnId": "t1", "text": "stale" }));
        queue.push(new, json!({ "kind": "delta", "turnId": "t2", "text": "fresh" }));
        assert_eq!(
            queue.next(Duration::from_millis(10)),
            Some(json!({ "kind": "delta", "turnId": "t2", "text": "fresh" }))
        );
        assert_eq!(queue.next(Duration::from_millis(10)), None);
    }

    /*
      A "Plan usage, on the same channel" section stood here. Its three tests
      checked that a `read-plan-usage` request reached the agent as one line,
      was rebuilt rather than forwarded, and was refused without a `requestId`.

      The kind is gone (ticket 31) and the property they were really guarding —
      that this function rebuilds rather than forwards, so nothing rides along —
      is asserted below over `describe-secrets` and above over a Turn. What
      follows is the one assertion the removal adds: a kind this host no longer
      carries reaches the agent as nothing at all.
    */

    #[test]
    fn a_kind_this_host_no_longer_carries_never_reaches_the_agent() {
        assert_eq!(
            control_line_for(&json!({ "kind": "read-plan-usage", "requestId": "u1" })),
            None
        );
    }

    // -----------------------------------------------------------------------
    // The names of the stored secrets, on the same channel
    // -----------------------------------------------------------------------

    /*
      ADR-0006's naming end, as this process sees it: a list of names arriving
      from the Harness runtime and going onto the pipe the agent is listening on.

      This process never learns what any of them stand for, and these tests are
      where that is checked rather than assumed. The rebuild is the mechanism —
      `control_line_for` writes `kind` and `names` and reads nothing else — so a
      value cannot cross however it is labelled on the way in.
    */

    #[test]
    fn the_secret_names_reach_the_agent_as_one_line() {
        let line = control_line_for(&json!({
            "kind": "describe-secrets",
            "names": ["STRIPE_KEY", "BILLING_TOKEN"],
        }))
        .expect("describing the secrets is a control request");
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(
            parsed,
            json!({ "kind": "describe-secrets", "names": ["STRIPE_KEY", "BILLING_TOKEN"] })
        );
    }

    #[test]
    fn no_secret_value_crosses_with_the_names_however_it_is_labelled() {
        // The assertion the naming end turns on. A request carrying values
        // alongside the names loses them here, in the same way a `prompt` sent
        // beside a compaction is a field that was never read.
        let line = control_line_for(&json!({
            "kind": "describe-secrets",
            "names": ["STRIPE_KEY"],
            "values": [looks_like_a_key()],
            "STRIPE_KEY": looks_like_a_key(),
            "secrets": { "STRIPE_KEY": looks_like_a_key() },
        }))
        .expect("describing the secrets is a control request");
        assert!(!line.contains("sk-ant"));
        assert!(!line.contains("values"));
        // Exactly two fields, checked as a whole rather than by absence: an
        // assertion that lists the things a value must not be called is an
        // assertion that is wrong the first time someone thinks of a new name
        // for one.
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(
            parsed,
            json!({ "kind": "describe-secrets", "names": ["STRIPE_KEY"] })
        );
    }

    #[test]
    fn an_empty_list_of_names_is_still_a_line_worth_sending() {
        // "The store was read and holds nothing" is worth telling the agent, and
        // is a different thing from never having been told.
        let line = control_line_for(&json!({ "kind": "describe-secrets", "names": [] }))
            .expect("an empty list is an answer");
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed, json!({ "kind": "describe-secrets", "names": [] }));
    }

    #[test]
    fn a_list_that_is_not_wholly_names_never_reaches_the_agent() {
        // Refused whole rather than partly sent. An agent told about some of the
        // secrets writes code against those and has no way to tell it was told
        // about fewer than the store holds.
        assert_eq!(
            control_line_for(&json!({ "kind": "describe-secrets", "names": ["A", 7] })),
            None
        );
        assert_eq!(
            control_line_for(&json!({ "kind": "describe-secrets", "names": "STRIPE_KEY" })),
            None
        );
        assert_eq!(control_line_for(&json!({ "kind": "describe-secrets" })), None);
    }

    #[test]
    fn describing_the_secrets_with_no_agent_running_refuses_rather_than_starting_one() {
        // The same shape as a Turn: with no pipe to write to, this refuses.
        // There is no branch here that starts a process to have somewhere to
        // send the names. Since ticket 31 this is the assertion holding
        // ADR-0003's corollary shut on this host — the plan-usage read that
        // used to carry it is gone.
        let agent = AgentProcess::default();
        assert!(agent.describe_secrets(&["STRIPE_KEY".to_string()]).is_err());
    }

    /*
      Eight tests stood here over the plan-usage answer path: that a line was
      read as an answer only if it named its read, that an answer and a Turn
      event were never mistaken for each other, that a read with no agent
      refused rather than starting one, and that the answer slot dropped a
      figure from a replaced generation.

      The ADR-0003 property the third of those guarded is still guarded, by
      `describing_the_secrets_with_no_agent_running_refuses_rather_than_starting_one`
      above and by the Turn path: no function on this host starts a process to
      have somewhere to send a request. What is gone is the read itself, which
      could not return a figure under any credential varnick can hold — ticket
      31.
    */

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
    fn no_credential_is_in_the_command_before_the_spawn_adds_one() {
        // The value is attached at the spawn and nowhere else, so nothing that
        // inspects a command can find it. Both variables now, because a
        // credential has a kind and either one may be the one injected.
        let command = build_command(&wrapping());
        for (name, _) in command.get_envs() {
            assert_ne!(
                name,
                std::ffi::OsStr::new(crate::credential::API_KEY_ENV_VAR)
            );
            assert_ne!(
                name,
                std::ffi::OsStr::new(crate::credential::SUBSCRIPTION_ENV_VAR)
            );
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
