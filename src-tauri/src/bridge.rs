// The bridge, host-side.
//
// One Tauri command, `harness_call`, and two places an answer can come from.
// The renderer's half is packages/harness/src/bridge.ts; this is the other end
// of the same wire.
//
// ## Where the Harness runs
//
// The Harness is TypeScript against @anthropic-ai/sandbox-runtime and the Claude
// Agent SDK. It runs as one long-lived Node process this host starts and keeps,
// spoken to over stdio. Long-lived rather than one process per call because
// srt's proxies live in the process that called `initialize()`, because
// containment has to wrap the agent's whole process tree and the agent must
// therefore be a child of that process (ADR-0003), and because the Session
// mirror serialises its saves through a queue a fresh process would not have.
//
// Two alternatives were rejected. A Node process per call cannot hold a Sandbox
// between calls, so `check-sandbox` would answer `ok` about a sandbox that no
// longer exists. Reimplementing the capabilities in Rust means a second
// implementation of srt policy generation and of the Agent SDK — the product's
// only real claim, written twice.
//
// The runtime is a Node process, not a Claude Code process, and it is not what
// starts one. It computes the wrapping — argv, an environment overlay and a
// working directory — and this host performs the spawn. See agent.rs.
//
// ## Except the credential, and everything downstream of it
//
// `read-credential` is answered here, in Rust, and never forwarded. The value
// must exist in exactly one process, and it has to be the process that spawns
// the agent subprocess and injects the value into its environment — so starting,
// stopping and watching that process are answered here too. `route_of` is where
// that is decided, and it is a unit test rather than a convention.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;
use tauri::State;

use crate::agent::AgentProcess;
use crate::credential::CredentialStore;
use crate::mint::Minting;

/// The environment variable that points at the runtime entry, for a build that
/// does not sit beside the repository.
pub const ENTRY_VAR: &str = "VARNICK_HARNESS_ENTRY";

/// The environment variable that names the runner. `bun` unless told otherwise.
pub const RUNNER_VAR: &str = "VARNICK_HARNESS_RUNNER";

/// The environment variable that chooses the clone the agent works in.
///
/// The third of the three, and the one that was missing. `VARNICK_HARNESS_ENTRY`
/// says which script the runtime runs and `VARNICK_HARNESS_RUNNER` says what
/// runs it; until ticket 28 nothing said which tree the agent works in, because
/// nothing had ever chosen it — see {@link clone_root}.
///
/// Read here and nowhere else. This process resolves it once, validates it, and
/// hands the answer to the runtime as an argument; the runtime does not read the
/// variable a second time. Two readers of one variable are two answers waiting
/// to disagree, and the Sandbox and the Session mirror have to be about the same
/// directory. Mirrored as `CLONE_ROOT_ENV_VAR` in
/// packages/harness/src/clone-root.ts, where it is a literal because TypeScript
/// cannot read this one.
pub const CLONE_ROOT_VAR: &str = "VARNICK_CLONE_ROOT";

/// Why a call produced no answer.
///
/// Mirrored as `HarnessFailure` in packages/harness/src/bridge.ts. A tag, not a
/// message: the prose a developer reads is authored once, on the TypeScript
/// side, so the two halves cannot drift into two different instructions.
///
/// `detail` is the one string that crosses, and only on `refused` — the
/// Harness's own reason for saying no. The credential route cannot produce one
/// that is not a literal: every failure in credential.rs is a `&'static str`.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Failure {
    pub failure: &'static str,
    pub detail: Option<String>,
}

impl Failure {
    pub fn of(failure: &'static str) -> Self {
        Failure {
            failure,
            detail: None,
        }
    }

    pub fn refused(detail: impl Into<String>) -> Self {
        Failure {
            failure: "refused",
            detail: Some(detail.into()),
        }
    }
}

/// Which half of the host answers a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// This process. The credential, and everything downstream of it — the
    /// agent process the value is injected into, and the calls that ride the
    /// Session that process holds. `route_of` below lists them, with the
    /// reason each one is on this side rather than the other.
    Host,
    /// The Harness runtime — the Node process that holds the Sandbox.
    Runtime,
}

/// Where a request goes. `None` for a kind this host does not know.
///
/// Exhaustive on purpose rather than a default arm that forwards: a kind neither
/// half has agreed to answer is a renderer and a host that are not the same
/// build, and forwarding it would turn that into a timeout.
pub fn route_of(kind: &str) -> Option<Route> {
    match kind {
        // The credential, and every call that needs it or the process it was
        // injected into. All of them are this process's, because this is where
        // the value is — see agent.rs.
        //
        // A Turn is on this list for the second reason rather than the first.
        // It carries no secret, but it rides the Session the agent process is
        // already holding, and this is the process that spawned it. Answering a
        // Turn anywhere else would mean a second Claude Code session, which is
        // ADR-0003's last consequence and the rule most likely to be broken by
        // accident.
        //
        // A plan-usage read is here for exactly that second reason and nothing
        // else. It looks like a question the runtime could answer — it needs no
        // credential and returns two numbers — and that is the trap: the figures
        // come from an SDK control request, which rides a live Session, and
        // asking for one anywhere but here means opening one.
        //
        // A Compaction is here for the same reason as a plan-usage read: it is a
        // model call on the Session the agent process is already holding, and
        // answering it in the runtime — the process with a filesystem, and the
        // obvious home for "do some work" — would mean opening a session there.
        //
        // Storing one is here for the first reason, in the other direction and
        // more sharply than any of the rest: it is the one call that carries a
        // value *into* the host, from the window a developer pasted it into.
        // Forwarding it would put a credential on the pipe to the Node runtime,
        // which is a second process holding one.
        //
        // Minting one is here for the first reason too, and it is the sharpest
        // case of it: the value does not come from the window at all, it is
        // *created* in this process by a command this process runs, and it goes
        // into the keychain without ever being anywhere else. Forwarding either
        // half of it would put the pty — and therefore the token — in the Node
        // runtime. See mint.rs.
        "read-credential" | "store-credential" | "mint-subscription-token"
        | "next-mint-event" | "spawn-agent" | "stop-agent" | "await-agent-exit"
        | "run-turn" | "next-turn-event" | "interrupt-turn" | "read-plan-usage"
        | "compact-session" => Some(Route::Host),
        "check-sandbox" | "persist-session" | "read-session" => Some(Route::Runtime),
        // `wrap-agent-command` is absent on purpose. The runtime answers it, but
        // only when *this* process asks: it is a step inside a spawn, not a
        // capability the renderer has.
        _ => None,
    }
}

/// One call, as one line.
///
/// `serde_json` escapes newlines, so nothing inside a request can split a call
/// across two lines. That is what makes "one call per line" a framing rather
/// than a hope.
pub fn encode_call(id: u64, request: &Value) -> String {
    // The value is two owned pieces of JSON; serialising it cannot fail.
    let call = serde_json::json!({ "id": id, "request": request });
    format!("{call}\n")
}

/// One reply, as one line.
///
/// An id that is not the one asked for means the pipe has lost its place, and
/// that is not recoverable — the next reply would answer the previous call. The
/// caller drops the runtime rather than reading on.
pub fn decode_reply(id: u64, line: &str) -> Result<Value, Failure> {
    let Ok(reply) = serde_json::from_str::<Value>(line.trim()) else {
        return Err(Failure::of("runtime-lost"));
    };

    if reply.get("id").and_then(Value::as_u64) != Some(id) {
        return Err(Failure::of("runtime-lost"));
    }

    if let Some(answer) = reply.get("ok") {
        return Ok(answer.clone());
    }

    match reply.get("error").and_then(Value::as_str) {
        Some(reason) => Err(Failure::refused(reason)),
        // Neither an answer nor a reason: a reply this host cannot read at all,
        // which is the same problem as a line that did not parse.
        None => Err(Failure::of("runtime-lost")),
    }
}

/// The runner that starts the runtime.
pub fn runtime_runner(override_: Option<String>) -> String {
    override_.unwrap_or_else(|| "bun".to_string())
}

/// The runtime's entry script.
///
/// The default is the repository's own `serve.ts`, resolved from where this
/// crate was compiled. That is right for `bun tauri dev`, which is the only way
/// varnick runs today, and wrong for a bundled `.app` — packaging the runtime as
/// a Tauri sidecar is open work this ticket does not do. {@link ENTRY_VAR} is
/// how a build that is not beside the repository says where it went.
pub fn runtime_entry(override_: Option<String>) -> PathBuf {
    match override_ {
        Some(path) => PathBuf::from(path),
        None => project_root().join("packages/harness/src/serve.ts"),
    }
}

/// The repository root, as it was when this crate was compiled.
///
/// `env!` is a compile-time macro, so this is a literal frozen into the binary
/// when `cargo build` ran — it appears twice in `target/debug/varnick`. It is
/// **not** where the process is run: launch the binary from anywhere and it
/// still names the machine it was built on. The two coincide in development only
/// because `bun tauri dev` is `cargo run`, which recompiles in the checkout
/// every time.
///
/// That is right for varnick's *own* code, which is what {@link runtime_entry}
/// uses it for and what ADR-0008 records as unsolved for packaging. It was
/// wrong for the clone the agent works in, which is a separate question with a
/// separate answer — see {@link clone_root}.
fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// The clone the agent works in.
///
/// The one function that says where the agent works and why. Until ticket 28
/// there was none: this host spawned the runtime with
/// `.current_dir(project_root())`, `runtime.ts` called `establishSandbox()` with
/// no argument, and `sandbox.ts` fell back to `process.cwd()` — four hops, no
/// name, and the answer was a path baked into the binary rather than one anybody
/// chose. See docs/adr/0012-the-clone-root-is-an-input.md.
///
/// The compile-time constant stays the default, deliberately. A developer
/// running `bun tauri dev` in a checkout gets exactly what they got before, and
/// {@link CLONE_ROOT_VAR} is how somebody says otherwise.
pub fn clone_root(override_: Option<String>) -> PathBuf {
    match override_ {
        Some(path) => PathBuf::from(path),
        None => project_root(),
    }
}

/// The root, checked, or the sentence a developer needs instead.
///
/// Checked *here*, before the spawn, and again in the runtime before a Sandbox
/// is established. Not redundant: they guard different things. `Command` with a
/// `current_dir` that does not exist fails with a bare io error this host can
/// only report as `no-runtime`, which names nothing — and the runtime's own
/// check is the one that keeps `establishSandbox` honest when it is called from
/// a test or by hand, where this host is not involved at all.
///
/// A `refused` rather than a tag, because this is the one host-side failure
/// whose detail is worth reading: the fix is a path, and the message has to
/// carry it. Nothing secret can be in it — it is a directory a developer typed
/// into {@link CLONE_ROOT_VAR}, or the build path of this binary.
fn checked_clone_root(root: PathBuf) -> Result<PathBuf, Failure> {
    if root.is_dir() {
        return Ok(root);
    }

    Err(Failure::refused(format!(
        "There is no directory at {}, so there is nothing for the agent to work in. \
         Set {} to the clone varnick should work in, or — if it is unset — check that \
         the clone this build came from has not been moved or deleted.",
        root.display(),
        CLONE_ROOT_VAR
    )))
}

/// The runtime process and the two pipes that reach it.
struct Channel {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Drop for Channel {
    /// A runtime holds a Sandbox and, later, an agent process tree. Leaving one
    /// behind when varnick exits — or when a call desynchronises the pipe and
    /// the channel is dropped — would leave that tree running with nothing
    /// attached to it.
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The Harness runtime, started on first use and kept. Tauri managed state.
#[derive(Default)]
pub struct HarnessRuntime {
    channel: Mutex<Option<Channel>>,
    next_id: AtomicU64,
}

impl HarnessRuntime {
    /// Ask the runtime for the wrapping that starts an agent.
    ///
    /// The only caller is the spawn in this module. It is not reachable from
    /// `route_of`, so the renderer cannot ask for it — and the answer is the
    /// single gate on starting an agent: a runtime with no Sandbox established
    /// refuses, and this returns that refusal rather than spawning.
    pub fn agent_wrapping(&self) -> Result<crate::agent::Wrapping, Failure> {
        let answer = self.call(&serde_json::json!({ "kind": "wrap-agent-command" }))?;
        crate::agent::wrapping_of(&answer)
    }

    /// Ask the runtime which secrets are stored, by name.
    ///
    /// Host-internal like `agent_wrapping`, and absent from `route_of` for the
    /// same reason: it is a step inside running a Turn, not a capability the
    /// renderer has. Keeping it off that list also keeps the webview unable to
    /// ask what a developer's keys are called, which is not a secret but is
    /// nobody's business in a process that talks HTTP.
    ///
    /// The runtime is the only process that can answer it — the Secrets Store
    /// is a keychain under `$HOME`, and both this process and the agent host
    /// are the wrong side of that. Names only: `read-secret-names` is answered
    /// from `SecretsStore.names()`, and nothing on that path can reach a value.
    ///
    /// A name that is not a string is dropped rather than failing the read. The
    /// store cannot produce one, so this is a runtime that does not match this
    /// build, and the useful behaviour then is to name the secrets it did agree
    /// about rather than to leave the agent knowing nothing.
    pub fn secret_names(&self) -> Result<Vec<String>, Failure> {
        let answer = self.call(&serde_json::json!({ "kind": "read-secret-names" }))?;
        let Some(names) = answer.get("names").and_then(Value::as_array) else {
            return Err(Failure::of("malformed"));
        };
        Ok(names
            .iter()
            .filter_map(|name| name.as_str().map(str::to_string))
            .collect())
    }

    /// Ask the runtime to do one thing.
    ///
    /// Calls are serialised by the lock. That is not a limitation worked around:
    /// there is one runtime holding one Sandbox, and two callers racing to
    /// establish it would be two answers about the same kernel state.
    fn call(&self, request: &Value) -> Result<Value, Failure> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;

        // A poisoned lock means a previous call panicked holding the pipes, so
        // nothing can vouch for where the runtime is in the conversation.
        let mut slot = self
            .channel
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;

        if slot.is_none() {
            // Started lazily: a run that never goes live never pays for a Node
            // process, and a runtime that will not start fails at the actor that
            // needed it rather than at launch, where nothing is listening.
            *slot = Some(start_runtime()?);
        }

        let channel = slot.as_mut().expect("the channel was just established");
        let outcome = exchange(channel, id, request);

        // A refusal is the runtime working. Anything else is the pipe, and a
        // pipe that has lost its place cannot be read back into step — drop it,
        // which kills the process, and let the next call start a fresh one.
        if matches!(&outcome, Err(failure) if failure.failure != "refused") {
            slot.take();
        }

        outcome
    }
}

fn exchange(channel: &mut Channel, id: u64, request: &Value) -> Result<Value, Failure> {
    let call = encode_call(id, request);
    channel
        .stdin
        .write_all(call.as_bytes())
        .and_then(|()| channel.stdin.flush())
        .map_err(|_| Failure::of("runtime-lost"))?;

    let mut reply = String::new();
    match channel.stdout.read_line(&mut reply) {
        // End of stream: the runtime exited rather than answering.
        Ok(0) => Err(Failure::of("runtime-lost")),
        Ok(_) => decode_reply(id, &reply),
        Err(_) => Err(Failure::of("runtime-lost")),
    }
}

fn start_runtime() -> Result<Channel, Failure> {
    // Resolved and checked before anything is spawned. A root that is not there
    // used to become a Sandbox established for a directory that no longer
    // existed; now it is a refusal naming the path.
    let root = checked_clone_root(clone_root(std::env::var(CLONE_ROOT_VAR).ok()))?;

    let mut child = Command::new(runtime_runner(std::env::var(RUNNER_VAR).ok()))
        // Two paths, and they are two different questions. The entry is where
        // varnick's own code is — the build path, which ADR-0008 records as
        // unsolved for packaging. The argument after it is the clone the agent
        // works in, which is now a choice.
        .arg(runtime_entry(std::env::var(ENTRY_VAR).ok()))
        .arg(&root)
        // Still set, and no longer load-bearing. The runtime reads its root from
        // the argument above; this only keeps relative resolution inside the
        // runtime agreeing with it. Nothing downstream infers the clone from it
        // any more — that inference was ticket 28.
        .current_dir(&root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // stdout is the wire. Diagnostics go to the terminal varnick was
        // launched from, where a developer can see them.
        .stderr(Stdio::inherit())
        .spawn()
        // Nothing the spawn said is forwarded. `no-runtime` is a tag and the
        // renderer authors the sentence, so a PATH that happens to hold a
        // credential cannot arrive in the transcript by way of an error.
        .map_err(|_| Failure::of("no-runtime"))?;

    let stdin = child.stdin.take().ok_or_else(|| Failure::of("no-runtime"))?;
    let stdout = child.stdout.take().ok_or_else(|| Failure::of("no-runtime"))?;

    Ok(Channel {
        child,
        stdin,
        stdout: BufReader::new(stdout),
    })
}

/// The one way Core reaches the Harness.
///
/// Answers with a value or a {@link Failure} tag. Every live actor's call comes
/// through here, so a call that cannot be delivered reaches that actor's own
/// failure state carrying the reason, rather than rejecting unhandled.
///
/// Marked `async` so Tauri runs it off the main thread.
///
/// Not a detail: `await-agent-exit` blocks until the agent process ends, and a
/// synchronous command runs on the main thread, where blocking would freeze the
/// window for the life of the agent. Every runtime call blocks on a pipe too, so
/// this is the right thread for all of them.
#[tauri::command(async)]
pub fn harness_call(
    request: Value,
    credentials: State<'_, CredentialStore>,
    runtime: State<'_, HarnessRuntime>,
    agent: State<'_, AgentProcess>,
    mint: State<'_, Minting>,
) -> Result<Value, Failure> {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or("");

    match route_of(kind) {
        Some(Route::Host) => match kind {
            // The credential, read and held in this process. `Reading`
            // serialises to `{ source }` and `Secret` has no `Serialize` at all,
            // so the value has no way through even if this line were wrong.
            "read-credential" => {
                let reading =
                    crate::credential::read_credential(&credentials).map_err(Failure::refused)?;
                serde_json::to_value(reading).map_err(|_| Failure::of("malformed"))
            }
            /*
              The credential written, in the one process allowed to hold one.

              This is the only request on the bridge with a secret in it, and it
              travels in one direction: the value goes into `Secret` before
              anything else is done with it, `store_credential` answers `Ok(())`
              or a `&'static str` tag, and the reply below is a constant. There
              is no shape on either path a value could come back in, and nothing
              between here and the keychain prints one — see credential.rs.

              Which item is written is the developer's choice, made in the
              window. Which credential is *resolved* is still the host's, decided
              by what it finds on the next read: nothing here records a
              preference, and ADR-0011 is unchanged.
            */
            "store-credential" => {
                let Some(kind) = request
                    .get("credentialKind")
                    .and_then(Value::as_str)
                    .and_then(crate::credential::kind_of)
                else {
                    return Err(Failure::of("malformed"));
                };
                let Some(value) = request.get("value").and_then(Value::as_str) else {
                    return Err(Failure::of("malformed"));
                };
                crate::credential::store_credential(
                    &crate::credential::SystemSecurity,
                    kind,
                    crate::credential::Secret::new(value.to_string()),
                )
                .map_err(Failure::refused)?;
                Ok(serde_json::json!({ "ok": true }))
            }
            /*
              The credential minted, in the one process allowed to hold one.

              Two calls with the same shape a Turn has, and for the same reason:
              a mint takes as long as a person takes to sign in to a website, so
              starting it and hearing from it have to be separate or the window
              would freeze for the length of an authentication.

              What comes back is an authorize URL and an outcome. Never the
              token: it goes from the pty into `Secret` and from there into the
              keychain, inside this process, and every failure is a tag chosen
              by a match arm — see mint.rs.
            */
            "mint-subscription-token" => {
                mint.start()?;
                Ok(serde_json::json!({ "ok": true }))
            }
            "next-mint-event" => Ok(serde_json::json!({ "event": mint.next_event() })),
            // Two steps, in this order, with no third: ask the runtime how to
            // run the agent under the Sandbox it established, then run that with
            // the credential added. A runtime that refuses the first step ends
            // the call — there is no path from here to an unwrapped process.
            "spawn-agent" => {
                let wrapping = runtime.agent_wrapping()?;
                let pid = agent.spawn(&wrapping, &credentials)?;
                Ok(serde_json::json!({ "pid": pid }))
            }
            "stop-agent" => {
                agent.stop()?;
                Ok(serde_json::json!({ "ok": true }))
            }
            "await-agent-exit" => {
                let reason = agent.await_exit()?;
                Ok(serde_json::json!({ "reason": reason }))
            }
            // A prompt, an interrupt and a compaction are the same act from
            // here: one control line onto the pipe the agent process is
            // listening on. None of their answers comes back through this call.
            "run-turn" | "interrupt-turn" | "compact-session" => {
                /*
                  A Turn, and only a Turn, is preceded by the names of the
                  stored secrets — ADR-0006's naming end.

                  Here rather than at spawn because the list changes while the
                  agent runs: `bun run secret add` is a different process, and a
                  developer who adds a key should be able to use it in the next
                  message rather than after a relaunch. Ticket 06 answered the
                  same problem on the mirror's side the same way, by re-reading
                  the store before every save instead of trusting the snapshot
                  taken at start-up.

                  Not before an interrupt, which stops an answer and asks the
                  agent for nothing, and not before a compaction, which
                  summarises what has already been said. Both would pay a
                  round-trip to the runtime for a brief nothing is going to read,
                  and an interrupt paying for one is the exact delay interrupting
                  exists to avoid.

                  Both steps are deliberately unchecked. A runtime that will not
                  answer, or an agent that is not running, leaves the agent
                  knowing whatever it last knew — and the Turn below still
                  succeeds or refuses on its own account, with the sentence that
                  fits. A Turn is what the developer asked for; an unnameable
                  secret makes it a poorer answer, never a failed one.
                */
                if request.get("kind").and_then(Value::as_str) == Some("run-turn") {
                    if let Ok(names) = runtime.secret_names() {
                        let _ = agent.describe_secrets(&names);
                    }
                }
                agent.run_turn(&request)?;
                Ok(serde_json::json!({ "ok": true }))
            }
            // Waits, like `await-agent-exit`, and for the same reason: a
            // request/response seam cannot push, and a poll would deliver a
            // streamed answer in the poll's rhythm rather than the agent's.
            // `null` is "nothing yet", which is a working Turn rather than a
            // failed one.
            "next-turn-event" => Ok(serde_json::json!({ "event": agent.next_event() })),
            // Waits too, and unlike the one above a wait that runs out is a
            // failed read rather than "nothing yet". With no agent running it
            // refuses at once: there is no session to ask, and the answer to
            // that is to say so — never to start one to have something to ask.
            "read-plan-usage" => agent.read_plan_usage(&request),
            // Unreachable while `route_of` and this match agree, and a closed
            // default rather than a forward if they ever stop agreeing.
            _ => Err(Failure::of("malformed")),
        },
        Some(Route::Runtime) => runtime.call(&request),
        None => Err(Failure::of("malformed")),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        checked_clone_root, clone_root, decode_reply, encode_call, route_of, runtime_entry,
        runtime_runner, Failure, PathBuf, Route, CLONE_ROOT_VAR,
    };
    use serde_json::json;

    #[test]
    fn the_credential_is_answered_by_this_process_and_never_forwarded() {
        assert_eq!(route_of("read-credential"), Some(Route::Host));
    }

    #[test]
    fn storing_a_credential_is_answered_by_this_process_and_never_forwarded() {
        /*
          The one call that carries a secret *into* the host, and the only route
          it may take. Forwarding it would put the value on the pipe to the
          Harness runtime — a second process holding a credential, which is
          exactly what ADR-0008 exists to prevent, and it would be one line in
          `route_of` away at all times.

          This is why `route_of` is a unit test rather than a convention: a
          `cargo build` once found two arms for the same kind that fifty-nine
          passing tests could not see.
        */
        assert_eq!(route_of("store-credential"), Some(Route::Host));
    }

    #[test]
    fn minting_a_credential_is_answered_by_this_process_and_never_forwarded() {
        /*
          The sharpest case of the same rule. A store carries a value the
          developer already had; a mint *creates* one, on a pty this process
          owns, and the whole of what it produces is a credential. Forwarding
          either half would put the terminal — and therefore the token — in the
          Harness runtime, which is a second process holding one.

          Both halves, because the polling call is the one that would look
          harmless enough to move: it carries a URL and an outcome, and it is
          reading the same buffer the token is in.
        */
        assert_eq!(route_of("mint-subscription-token"), Some(Route::Host));
        assert_eq!(route_of("next-mint-event"), Some(Route::Host));
    }

    #[test]
    fn the_sandbox_and_the_mirror_are_answered_by_the_runtime() {
        assert_eq!(route_of("check-sandbox"), Some(Route::Runtime));
        assert_eq!(route_of("persist-session"), Some(Route::Runtime));
        // Both directions of the mirror go the same way. The runtime is the
        // process with a filesystem, and resume reads the mirror rather than
        // the Agent SDK's own store — docs/adr/0009-resume-reads-the-mirror.md.
        assert_eq!(route_of("read-session"), Some(Route::Runtime));
    }

    #[test]
    fn a_restored_transcript_comes_back_as_the_answer_rather_than_an_empty_ok() {
        // Every other call answers `ok: {}`. A restore is the one that carries
        // a payload, and it has to survive decoding intact or a relaunch shows
        // an empty conversation over a mirror that is not empty.
        let reply = decode_reply(
            4,
            r#"{"id":4,"ok":{"messages":[{"id":"m1","role":"user","text":"one"}],"redacted":true}}"#,
        );
        assert_eq!(
            reply,
            Ok(json!({
                "messages": [{ "id": "m1", "role": "user", "text": "one" }],
                "redacted": true
            }))
        );
    }

    #[test]
    fn starting_stopping_and_watching_the_agent_are_answered_where_the_credential_is() {
        // The spawn has to happen in the process holding the credential, so the
        // three calls about the agent process are this process's — ADR-0008.
        assert_eq!(route_of("spawn-agent"), Some(Route::Host));
        assert_eq!(route_of("stop-agent"), Some(Route::Host));
        assert_eq!(route_of("await-agent-exit"), Some(Route::Host));
    }

    #[test]
    fn the_renderer_cannot_ask_for_the_agent_wrapping_itself() {
        // The runtime answers `wrap-agent-command`, but only to this process,
        // as a step inside a spawn. It is not a capability Core has.
        assert_eq!(route_of("wrap-agent-command"), None);
    }

    #[test]
    fn the_renderer_cannot_ask_about_the_secrets_at_all() {
        /*
          Neither half of ADR-0006's naming end is on this bridge, and both are
          absent for their own reason.

          `read-secret-names` is answered by the runtime, but — like
          `wrap-agent-command` — only when this process asks, as a step inside
          running a Turn. Names are not secret, so a renderer holding them would
          not be a containment failure; it would be the webview knowing what a
          developer's keys are called, in a process that talks HTTP, for no
          reason anything needs.

          `describe-secrets` is sharper. It is the line that decides what the
          confined agent believes about the store, and a renderer that could
          send one could tell the agent that a secret exists which does not, or
          conceal one that does. It is written by this process, from what the
          runtime answered, and there is no route to it from anywhere else.
        */
        assert_eq!(route_of("read-secret-names"), None);
        assert_eq!(route_of("describe-secrets"), None);
    }

    #[test]
    fn a_turn_is_answered_where_the_agent_process_is() {
        // A Turn rides the Session the agent process is already holding, and
        // this host is the process that spawned it — so the three calls about a
        // Turn go the same way as the three about the process. The alternative
        // is a second Claude Code session, which ADR-0003 forbids.
        assert_eq!(route_of("run-turn"), Some(Route::Host));
        assert_eq!(route_of("next-turn-event"), Some(Route::Host));
        assert_eq!(route_of("interrupt-turn"), Some(Route::Host));
    }

    #[test]
    fn a_plan_usage_read_is_answered_where_the_agent_process_is() {
        // For the same reason a Turn is, and it is the reason ADR-0003's last
        // consequence was amended: the figures come from a control request on a
        // live Session, and the only Session varnick has is the confined one
        // this process spawned. Anywhere else would mean opening a second.
        assert_eq!(route_of("read-plan-usage"), Some(Route::Host));
    }

    #[test]
    fn a_compaction_is_answered_where_the_agent_process_is() {
        // Summarising is a model call on the Session the agent already holds.
        // Routing it to the runtime — the process that has a filesystem, and
        // the obvious home for "do some work" — would mean opening a session
        // there, which is the second Claude Code process ADR-0003 forbids.
        assert_eq!(route_of("compact-session"), Some(Route::Host));
    }

    #[test]
    fn a_kind_this_host_does_not_know_is_routed_nowhere() {
        assert_eq!(route_of("summarise"), None);
        assert_eq!(route_of(""), None);
    }

    #[test]
    fn a_call_is_exactly_one_line() {
        let line = encode_call(7, &json!({ "kind": "check-sandbox" }));
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn a_call_carries_its_id_and_the_request_unchanged() {
        let request = json!({ "kind": "persist-session", "sessionId": "abc", "messages": [] });
        let line = encode_call(7, &request);
        let parsed: serde_json::Value = serde_json::from_str(line.trim_end()).unwrap();
        assert_eq!(parsed, json!({ "id": 7, "request": request }));
    }

    #[test]
    fn text_with_a_newline_in_it_cannot_split_a_call_in_two() {
        let line = encode_call(1, &json!({ "kind": "persist-session", "text": "one\ntwo" }));
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn an_answer_to_this_call_is_the_answer() {
        let reply = decode_reply(3, r#"{"id":3,"ok":{}}"#);
        assert_eq!(reply, Ok(json!({})));
    }

    #[test]
    fn an_answer_to_a_different_call_means_the_pipe_lost_its_place() {
        // Not recoverable: the next reply would answer the previous call. The
        // caller drops the runtime on this, rather than reading on and
        // returning one call's answer to another.
        assert_eq!(
            decode_reply(3, r#"{"id":2,"ok":{}}"#),
            Err(Failure::of("runtime-lost"))
        );
    }

    #[test]
    fn a_line_that_is_not_a_reply_means_the_pipe_lost_its_place() {
        assert_eq!(decode_reply(3, "not json"), Err(Failure::of("runtime-lost")));
        assert_eq!(
            decode_reply(3, r#"{"id":3}"#),
            Err(Failure::of("runtime-lost"))
        );
    }

    #[test]
    fn a_runtime_that_said_no_is_a_refusal_carrying_its_reason() {
        assert_eq!(
            decode_reply(3, r#"{"id":3,"error":"sandbox-runtime does not support win32."}"#),
            Err(Failure::refused("sandbox-runtime does not support win32."))
        );
    }

    #[test]
    fn a_failure_serialises_into_the_shape_the_renderer_reads() {
        let refused = serde_json::to_value(Failure::refused("nothing-stored")).unwrap();
        assert_eq!(
            refused,
            json!({ "failure": "refused", "detail": "nothing-stored" })
        );
        let lost = serde_json::to_value(Failure::of("runtime-lost")).unwrap();
        assert_eq!(lost, json!({ "failure": "runtime-lost", "detail": null }));
    }

    #[test]
    fn the_runner_is_bun_unless_the_environment_names_another() {
        assert_eq!(runtime_runner(None), "bun");
        assert_eq!(runtime_runner(Some("/opt/bun".into())), "/opt/bun");
    }

    #[test]
    fn the_entry_is_the_repositorys_serve_script_unless_overridden() {
        let default = runtime_entry(None);
        assert!(default.ends_with("packages/harness/src/serve.ts"));
        assert_eq!(
            runtime_entry(Some("/elsewhere/serve.ts".into())),
            std::path::Path::new("/elsewhere/serve.ts")
        );
    }

    #[test]
    fn the_clone_root_is_the_build_path_unless_the_environment_names_another() {
        /*
          Ticket 28. The default has to stay exactly what it was — a developer
          running `bun tauri dev` in a checkout sees no change — and there has to
          be a way to say otherwise, which there was not.

          The default is asserted against `runtime_entry(None)` rather than
          against a literal, because both come from the same compile-time
          constant and the point of the test is that they still do.
        */
        assert!(runtime_entry(None).starts_with(clone_root(None)));
        assert_eq!(
            clone_root(Some("/opt/work/varnick".into())),
            std::path::Path::new("/opt/work/varnick")
        );
    }

    #[test]
    fn a_clone_root_that_is_not_there_is_refused_by_name() {
        /*
          The ticket's own criterion, and the failure it replaces. Moving a
          checkout after building used to produce a Sandbox established for a
          directory that no longer existed; the runtime's own error named
          `sandbox-policy.json` inside it, which is a file nobody created in a
          directory nobody has.

          A `refused` carrying the path, not a tag: the fix *is* the path.
        */
        let refusal = checked_clone_root(PathBuf::from("/Users/dev/moved-away-1234"))
            .expect_err("a root that is not there cannot be used");
        assert_eq!(refusal.failure, "refused");
        let detail = refusal.detail.expect("the refusal names the path");
        assert!(detail.contains("/Users/dev/moved-away-1234"));
        assert!(detail.contains(CLONE_ROOT_VAR));
    }

    #[test]
    fn a_file_is_not_a_clone_root() {
        // A path that exists is not enough. `Command::current_dir` on a file
        // fails inside the spawn, where the only thing this host can say is
        // `no-runtime`.
        let file = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml");
        assert!(file.is_file(), "the fixture has to be a real file");
        assert!(checked_clone_root(file).is_err());
    }

    #[test]
    fn the_root_this_build_defaults_to_is_a_directory_that_is_there() {
        // The default path has to survive its own check, or every launch of a
        // fresh build would refuse. This is also the regression guard on
        // `project_root()` losing its `.parent()`.
        assert!(checked_clone_root(clone_root(None)).is_ok());
    }
}
