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
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::Value;

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
        // A Compaction is here for that same second reason: it is a model call
        // on the Session the agent process is already holding, and answering it
        // in the runtime — the process with a filesystem, and the obvious home
        // for "do some work" — would mean opening a session there.
        //
        // A `read-plan-usage` was on this list for the same reason and is gone
        // with the read (ticket 31). The trap it illustrated is worth keeping in
        // mind for whatever is added next: it looked like a question the runtime
        // could answer, since it needed no credential and returned two numbers,
        // and it belonged here anyway because the figures came from a control
        // request riding a live Session.
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
        //
        // `restart-varnick` is here for a reason unlike any of the others: it is
        // not a question at all. It replaces *this* process, so it can only be
        // answered by the process being replaced — and it runs the same teardown
        // the View menu's Restart runs, because anything still alive when the
        // image is replaced is orphaned by it. See lib.rs.
        "read-credential" | "store-credential" | "mint-subscription-token"
        | "next-mint-event" | "spawn-agent" | "stop-agent" | "await-agent-exit"
        | "run-turn" | "next-turn-event" | "next-unprompted-event" | "interrupt-turn"
        | "restart-varnick" => Some(Route::Host),
        // `read-commands` is the runtime's because it is a file read, and the
        // runtime is the process with a filesystem. It answers what the *agent*
        // last reported — written by the agent host, read back for a window
        // that has not run a Turn yet and so has never been told.
        //
        // `list-worktrees` is the runtime's for the same reason one step along:
        // it runs git in the clone, which needs a filesystem and a subprocess.
        // It carries no credential and asks for none, so there is nothing about
        // it that belongs on this side — and it must never be answered by
        // anything the agent writes, because the list is what shows what the
        // agent changed. See packages/harness/src/worktrees.ts.
        //
        // `read-worktree-diff` is the hunks behind one row of that list, and it
        // is here for those reasons and one of its own. It is the only call on
        // the review path that carries a field, and the field is a *selector*:
        // the path is compared against git's own listing where git runs, and the
        // ref that reaches argv is the one git printed. This host forwards it —
        // it holds no listing to check a path against, and a validation written
        // twice is a validation that drifts.
        //
        // `merge-worktree` is the runtime's for those same reasons — it is git,
        // in the clone, with a filesystem — and it is the one call on this whole
        // bridge that *writes* that clone. That is not a widening: the merge is
        // the gate ADR-0014 rests on, and what reaches the runtime here is a
        // human having clicked a control in a surface the agent cannot write
        // (ADR-0002). Nothing the agent says can produce this call. The path is
        // a selector, checked against git's own listing where git runs, exactly
        // as the diff's is.
        //
        // `reap-worktree` is the same call one moment later. It removes a
        // directory and force-deletes a branch, and it is here for exactly the
        // reasons above: it runs where git runs, the path is a selector against
        // git's own listing, and the control that sends it lives in a surface
        // `denyWrite` refuses the agent. What makes the deletion safe is asked
        // in TypeScript, not here — the branch's content has to already be in
        // the live tree.
        "check-sandbox" | "persist-session" | "read-session" | "read-commands"
        | "list-worktrees" | "read-worktree-diff" | "merge-worktree" | "reap-worktree" => {
            Some(Route::Runtime)
        }
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

/// How long the runtime gets to answer one request before it counts as gone.
///
/// Generous, because the slowest legitimate answer here is `check-sandbox`,
/// which establishes srt and its proxies. The point is not to police latency —
/// it is that "for ever" must not be one of the options. A runtime that has
/// stopped answering used to hold the channel lock permanently and take every
/// later call with it, which is a dead app rather than a failed call.
const RUNTIME_WAIT: std::time::Duration = std::time::Duration::from_secs(90);

/// The runtime process and the two pipes that reach it.
///
/// The read half is a thread rather than a `BufReader` this side of the lock,
/// and that is the whole of what makes {@link RUNTIME_WAIT} possible: a
/// blocking `read_line` on a pipe cannot be given a deadline, and there is no
/// portable way to interrupt one. A thread that owns the pipe and posts whole
/// lines to a channel can be waited on with a timeout, and — if it never
/// answers — abandoned. It dies on its own when the child is killed and the
/// pipe closes.
struct Channel {
    child: Child,
    stdin: ChildStdin,
    lines: std::sync::mpsc::Receiver<String>,
}

impl Drop for Channel {
    /// A runtime holds a Sandbox and, later, an agent process tree. Leaving one
    /// behind when varnick exits — or when a call desynchronises the pipe and
    /// the channel is dropped — would leave that tree running with nothing
    /// attached to it.
    ///
    /// **This runs on a desync and on an explicit teardown, and not on exit.**
    /// macOS ends the event loop in `process::exit`, which unwinds nothing, so
    /// managed state is never dropped — see the run callback in lib.rs, which is
    /// what actually closes this down when varnick quits.
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
    /// End the runtime process, now, and leave nothing able to restart it.
    ///
    /// Called from the exit path in lib.rs rather than left to `Drop`, because
    /// `Drop` is not on the exit path: macOS ends the event loop in
    /// `process::exit`, which unwinds nothing, so managed state is never
    /// dropped. Taking the channel out of the slot runs `Channel::drop` here,
    /// where it does happen.
    ///
    /// A poisoned lock is not a reason to leave a process behind — but it is a
    /// reason not to touch the pipes, so the failure is silent and the child is
    /// left to the operating system.
    pub fn shut_down(&self) {
        if let Ok(mut slot) = self.channel.lock() {
            slot.take();
        }
    }

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

    /// Ask the runtime what a Worktree changes about the **Fence**.
    ///
    /// Host-internal like `agent_wrapping` and `secret_names`, and absent from
    /// `route_of` for the same reason: it is a step inside answering a Preview,
    /// not a capability the renderer has. Keeping it off that list also keeps
    /// the webview — which the agent writes Surfaces for — from being able to
    /// ask what a diff of the fence looks like, or to be told one that is not
    /// the truth.
    ///
    /// The worktree is an absolute path this process resolved out of
    /// `git worktree list`. Nothing the agent typed reaches here.
    ///
    /// Hunks, and there is no shape on this answer that could carry anything
    /// else: the runtime rebuilds the reply to one string, and this reads one
    /// string back out of it.
    pub fn fence_diff(&self, worktree: &str) -> Result<String, Failure> {
        let answer = self.call(&serde_json::json!({
            "kind": "read-fence-diff",
            "worktree": worktree,
        }))?;
        match answer.get("hunks").and_then(Value::as_str) {
            Some(hunks) => Ok(hunks.to_string()),
            None => Err(Failure::of("malformed")),
        }
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

/// One request, and the answer to it or a reason there was none.
///
/// **The wait is bounded now, and that is the point of the reader thread.** The
/// runtime answers one request at a time, and some of its handlers can hang for
/// ever rather than fail: `read-session` opens the Secrets Store, which shells
/// out to `/usr/bin/security` with no timeout and no kill, so a locked keychain
/// or an access prompt nobody answers used to stall this pipe permanently —
/// with the channel lock held, which took every later call with it. The app
/// stopped, and nothing anywhere said why.
///
/// A timeout answers `runtime-lost`, which the caller already handles by
/// dropping the channel: the process is killed and the next call starts a fresh
/// one. That is the right treatment, because a runtime that overran its answer
/// cannot be trusted to be at the start of the next line.
fn exchange(channel: &mut Channel, id: u64, request: &Value) -> Result<Value, Failure> {
    let call = encode_call(id, request);
    channel
        .stdin
        .write_all(call.as_bytes())
        .and_then(|()| channel.stdin.flush())
        .map_err(|_| Failure::of("runtime-lost"))?;

    match channel.lines.recv_timeout(RUNTIME_WAIT) {
        Ok(reply) => decode_reply(id, &reply),
        // Timed out, or the reader thread ended because the pipe closed. Both
        // mean the same thing to the caller: this runtime is not going to
        // answer, and the channel it was reached through is finished.
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

    /*
      One thread per runtime, owning the read half and posting whole lines.

      Unbounded, and it does not need to be otherwise: the runtime answers one
      request at a time (see readLines in packages/harness/src/framing.ts), so
      at most one unread line can be waiting — and if a call has timed out and
      abandoned its answer, the line arriving late is exactly the thing the
      generation check below has to be able to see and skip.

      The thread ends when the pipe closes, which is when the child is killed.
      Nothing has to join it.
    */
    let (posted, lines) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    if posted.send(line).is_err() {
                        return;
                    }
                }
            }
        }
    });

    Ok(Channel {
        child,
        stdin,
        lines,
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
#[tauri::command]
pub async fn harness_call(request: Value, app: tauri::AppHandle) -> Result<Value, Failure> {
    /*
      The blocking body runs on the blocking pool, and that is load-bearing
      rather than tidy.

      It was `#[tauri::command(async)]` on a *synchronous* function, which reads
      like "run this off the main thread" and is not what it does: tauri hands a
      sync body to `async_runtime::spawn`, which is `tokio::spawn` on the
      multi-thread runtime, so every blocking call occupied one of
      `num_cpus` **worker** threads. Three call kinds block for a long time or
      for ever — `await-agent-exit` for the life of the agent, `next-turn-event`
      for its poll, and every runtime call for a pipe round trip — and the
      renderer issues a fresh `await-agent-exit` on each entry to
      `agent.running`. They accumulate, and when they reach the worker count the
      runtime has no thread left to poll *any* task: the whole IPC surface goes
      silent with nothing logged and nothing failed.

      That is what the developer saw as a window stuck for ever on "Reading the
      conversation…" — the first call the app makes. `sample` showed eleven
      threads parked in `await_exit` and not one executing the read.

      `spawn_blocking` is the pool meant for this: 512 slots, and blocking in it
      is the contract rather than an accident. The bound on `await_exit` below
      is the other half — the pool makes starvation take 512 waiters instead of
      ten, and the bound means they stop accumulating at all.

      `AppHandle` rather than `State` arguments, because a `State` borrows the
      invocation and cannot cross into a blocking closure. The handle is cheap
      to clone and resolves the same managed values.
    */
    tauri::async_runtime::spawn_blocking(move || answer(request, &app))
        .await
        // The pool refused the work or the task panicked. Neither is a refusal
        // by the Harness, and both leave this call with nothing to report.
        .unwrap_or_else(|_| Err(Failure::of("runtime-lost")))
}

/// The whole of the bridge, on a thread that is allowed to block.
fn answer(request: Value, app: &tauri::AppHandle) -> Result<Value, Failure> {
    use tauri::Manager;

    let credentials = app.state::<CredentialStore>();
    let runtime = app.state::<HarnessRuntime>();
    let agent = app.state::<AgentProcess>();
    let mint = app.state::<Minting>();

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
                let pid = agent.spawn(&wrapping, &credentials, app)?;
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
            // A prompt and an interrupt are the same act from here: one control
            // line onto the pipe the agent process is listening on. Neither
            // answer comes back through this call.
            "run-turn" | "interrupt-turn" => {
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
                  agent for nothing. It would pay a round-trip to the runtime
                  for a brief nothing is going to read, which is the exact delay
                  interrupting exists to avoid.

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
            // Read by a pump that outlives every Turn, so an answer nobody
            // asked for arrives when it happens. A separate queue rather than a
            // filter on the one above — see `is_unprompted` for why the two
            // readers must never contend.
            "next-unprompted-event" => {
                Ok(serde_json::json!({ "event": agent.next_unprompted_event() }))
            }
            /*
              Everything, from the top — the same act as **Restart varnick** on
              the View menu, asked for from the window instead of the menu bar.

              It is on the bridge because the moment a restart is *owed* is a
              moment varnick knows about and a developer would otherwise have to
              remember: a merge has just landed, so the window is running the
              code from before the change it accepted. A menu item is the right
              place for "something is stuck"; it is the wrong place for
              "something specific just happened".

              The teardown runs first, and that ordering is the whole of it:
              `restart` replaces this process image, and the agent and the
              runtime are children of *this* process — anything still alive at
              that moment is orphaned by it, which is exactly the process tree
              ADR-0003 exists to prevent.

              The `Ok` below is not reached in the ordinary case. `restart`
              replaces the image and does not return, so the only way the
              renderer ever sees an answer to this call is a restart that did
              not happen — which is why there is an answer at all rather than a
              silence for the window to hang on.
            */
            "restart-varnick" => {
                crate::shut_down(app);
                app.restart();
                #[allow(unreachable_code)]
                Ok(serde_json::json!({ "ok": true }))
            }
            // Unreachable while `route_of` and this match agree, and a closed
            // default rather than a forward if they ever stop agreeing.
            _ => Err(Failure::of("malformed")),
        },
        /*
          Forwarded, with one thing done on the way back.

          A merge is the runtime's — git, a filesystem, no credential — but the
          agent that wrote the branch lives in *this* process, on a pipe the
          runtime cannot reach. So the reply is read for the sentence the merge
          composed for it, and that sentence is copied onto the control channel.
          Nothing is written here: the words were composed where the merge
          happened, which is the same division `describe-secrets` has.

          Best effort, and the ordering says why. The merge has already happened
          by the time this runs, so a failure to tell the agent must not turn a
          merge that landed into a call that failed — the developer would be
          told nothing happened to a tree that has changed.

          The briefing does not go on to the renderer. `mergeAnswer` in
          packages/harness/src/bridge.ts rebuilds the report field by field and
          this is not one of them, which is the ordinary rule working in
          varnick's favour: the window has no use for a brief addressed to the
          agent.
        */
        Some(Route::Runtime) if kind == "merge-worktree" => {
            let reply = runtime.call(&request)?;
            if let Some(briefing) = reply.get("briefing").and_then(Value::as_str) {
                // Relayed, never composed. Both strings were written in
                // TypeScript where the merge happened; this picks neither.
                let while_running = reply.get("whileRunning").and_then(Value::as_str);
                let _ = agent.report_merge(briefing, while_running);
            }
            Ok(reply)
        }
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
    fn the_pending_worktrees_are_listed_by_the_runtime() {
        /*
          The review list is git's answer, not the agent's, and not this
          process's either.

          It goes to the runtime for the same reason the mirror does: it needs a
          filesystem and a subprocess, and this host has neither reason to grow
          one. It carries no credential, touches none, and names no worktree —
          the renderer asks what is pending and does not get to say what the
          answer should be about, which is what keeps agent input out of a
          host-side spawn (that is ticket 48's problem, and it is a different
          call).

          What must never happen is this being answered by anything the agent
          writes: the whole point of the list is that it shows what the agent
          changed, and a listing the agent composed is a listing the agent can
          shade.
        */
        assert_eq!(route_of("list-worktrees"), Some(Route::Runtime));
    }

    #[test]
    fn the_diff_of_one_worktree_is_read_by_the_runtime_too() {
        /*
          The hunks behind one row of that list, and the only call on the review
          path carrying a field.

          It is the runtime's for the same reasons the list is — a subprocess and
          a filesystem, no credential — and it must not be answered by anything
          the agent writes for a sharper version of the same reason: a listing
          the agent could shade hides a branch, and a diff the agent could shade
          hides a widening inside a branch somebody is about to merge.

          What the field can name is decided where git runs, in
          packages/harness/src/worktrees.ts: the path is compared against git's
          own listing and the ref that reaches argv is the one git printed. This
          host forwards; it does not validate a path it has no listing to check
          against.
        */
        assert_eq!(route_of("read-worktree-diff"), Some(Route::Runtime));
    }

    #[test]
    fn a_worktree_diff_is_never_answered_where_the_credential_is() {
        // The other direction, stated on its own: this call is not the Host's.
        // Answering it here would put a git subprocess in the process holding
        // the credential, for a question that needs neither.
        assert_ne!(route_of("read-worktree-diff"), Some(Route::Host));
    }

    #[test]
    fn the_one_call_that_writes_the_clone_goes_where_git_is() {
        /*
          The merge, and it is the only request on this bridge that changes the
          developer's tree.

          It is the runtime's for the reasons the two reads above are — git, a
          filesystem, no credential — and putting it there rather than here also
          keeps the selector rule in one place: the path is compared against
          git's own listing where git runs, so a merge cannot be pointed at a
          tree by anything that composed a name.

          What makes it *safe* is not the route. It is that nothing the agent
          says can produce this call: the control that sends it lives under
          `packages/core`, which `denyWrite` refuses the agent in the live tree,
          and the agent has no way to send an event to the renderer at all. The
          merge is still the gate ADR-0014 rests on — a human clicks it, with the
          diff on screen.

          The path is written without its glob on purpose. Rust nests block
          comments, so a `core` followed by the two characters a glob starts with
          opens one inside this and the closing marker below shuts that instead
          — which is exactly what happened here, and it took the whole crate
          out. It compiled nowhere and said `unterminated block comment` about a
          comment that is plainly terminated.
        */
        assert_eq!(route_of("merge-worktree"), Some(Route::Runtime));
        assert_ne!(route_of("merge-worktree"), Some(Route::Host));
        // The reap is the same call one moment later, and it removes a
        // directory. It answers where git runs, like everything else that
        // touches the clone.
        assert_eq!(route_of("reap-worktree"), Some(Route::Runtime));
        assert_ne!(route_of("reap-worktree"), Some(Route::Host));
    }

    #[test]
    fn a_restart_can_only_be_answered_by_the_process_being_restarted() {
        // Not a question, and not forwardable: it replaces *this* image. The
        // runtime and the agent are this process's children, so the teardown
        // has to run here — anything alive when the image goes is orphaned by
        // it, which is the tree ADR-0003 exists to prevent.
        assert_eq!(route_of("restart-varnick"), Some(Route::Host));
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
        assert_eq!(route_of("next-unprompted-event"), Some(Route::Host));
        assert_eq!(route_of("interrupt-turn"), Some(Route::Host));
    }

    #[test]
    fn the_renderer_cannot_ask_for_a_preview_or_for_what_one_would_show() {
        /*
          Neither half of a Preview is on this bridge, and both are absent for
          their own reason.

          `launch-preview` is not a call at all — it arrives on the agent's own
          stdout, from inside the Sandbox, because the agent is who asks. A
          renderer that could send one would be a Surface — Userspace, which the
          agent writes freely — able to start an unconfined varnick from a
          worktree the agent also wrote, with no dialog and no agent in the loop.
          That is the whole escalation path with its one gate removed.

          `read-fence-diff` is the runtime's, but — like `wrap-agent-command`
          and `read-secret-names` — only when this process asks, as a step inside
          answering a Preview. The window has no reason to hold a diff of the
          fence, and a window that could ask for one is a window that could be
          answered with a different one.
        */
        assert_eq!(route_of("launch-preview"), None);
        assert_eq!(route_of("preview-answer"), None);
        assert_eq!(route_of("read-fence-diff"), None);
    }

    #[test]
    fn a_kind_the_bridge_no_longer_carries_is_routed_nowhere() {
        // `read-plan-usage` was routed to the host, for the same reason a Turn
        // is. The read is gone (ticket 31) and an unknown kind must fall through
        // to `None` rather than to a route — a bridge that guessed would be a
        // renderer able to ask for something no half of this build agreed to.
        assert_eq!(route_of("read-plan-usage"), None);
    }

    #[test]
    fn a_compaction_is_no_longer_a_kind_this_bridge_carries() {
        // It used to route to the host, because summarising is a model call on
        // the Session the agent already holds and opening one in the runtime
        // would be the second Claude Code process ADR-0003 forbids. varnick
        // does not ask for a compaction at all now — it hears about the one the
        // Session performed — so the kind falls through to the closed default,
        // the same place `read-plan-usage` went.
        assert_eq!(route_of("compact-session"), None);
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
