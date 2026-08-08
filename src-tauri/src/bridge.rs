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
// The runtime is a Node process, not a Claude Code process. Nothing on this path
// spawns an agent; when one is spawned it will be spawned by the runtime, under
// the Sandbox the runtime established, which is what ADR-0003's last consequence
// requires.
//
// ## Except the credential
//
// `read-credential` is answered here, in Rust, and never forwarded. The value
// must exist in exactly one process, and it has to be the process that spawns
// the agent subprocess and injects the value into its environment. `route_of`
// is where that is decided, and it is a unit test rather than a convention.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;
use tauri::State;

use crate::credential::CredentialStore;

/// The environment variable that points at the runtime entry, for a build that
/// does not sit beside the repository.
pub const ENTRY_VAR: &str = "VARNICK_HARNESS_ENTRY";

/// The environment variable that names the runner. `bun` unless told otherwise.
pub const RUNNER_VAR: &str = "VARNICK_HARNESS_RUNNER";

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
    /// This process. The credential, and only the credential.
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
        "read-credential" => Some(Route::Host),
        "check-sandbox" | "persist-session" | "read-session" => Some(Route::Runtime),
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
fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
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
    let mut child = Command::new(runtime_runner(std::env::var(RUNNER_VAR).ok()))
        .arg(runtime_entry(std::env::var(ENTRY_VAR).ok()))
        // The Sandbox is generated for the clone the runtime runs in.
        .current_dir(project_root())
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
#[tauri::command]
pub fn harness_call(
    request: Value,
    credentials: State<'_, CredentialStore>,
    runtime: State<'_, HarnessRuntime>,
) -> Result<Value, Failure> {
    let kind = request.get("kind").and_then(Value::as_str).unwrap_or("");

    match route_of(kind) {
        Some(Route::Host) => {
            // The credential, read and held in this process. `Reading`
            // serialises to `{ source }` and `Secret` has no `Serialize` at all,
            // so the value has no way through even if this line were wrong.
            let reading = crate::credential::read_credential(&credentials).map_err(Failure::refused)?;
            serde_json::to_value(reading).map_err(|_| Failure::of("malformed"))
        }
        Some(Route::Runtime) => runtime.call(&request),
        None => Err(Failure::of("malformed")),
    }
}

#[cfg(test)]
mod tests {
    use super::{decode_reply, encode_call, route_of, runtime_entry, runtime_runner, Failure, Route};
    use serde_json::json;

    #[test]
    fn the_credential_is_answered_by_this_process_and_never_forwarded() {
        assert_eq!(route_of("read-credential"), Some(Route::Host));
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
    fn a_kind_this_host_does_not_know_is_routed_nowhere() {
        assert_eq!(route_of("spawn-agent"), None);
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
}
