// A Preview, host-side: the agent asks, this process spawns.
//
// A **Preview** is a second varnick launched from a **Worktree** so a Core
// change can be run before it is merged (CONTEXT.md). The agent cannot launch
// one itself — srt gates mach lookups by service name and varnick's policy names
// none, so `com.apple.windowserver.active` is unreachable and no confined
// process can open a window. It asks through the `launch_preview` **Custom
// Tool**, whose request arrives here on the agent's stdout and is answered on
// its stdin (see agent.rs).
//
// ## The one thing this file is for
//
// **The tool takes a worktree name. Never a command, and never a path.**
//
// This is a host-side process spawn driven by agent input, which is a shell out
// of the Sandbox if it is shaped carelessly. So the name is never joined onto
// anything, never passed to a shell, and never handed to `git` as an argument.
// It is looked up in a table built out of what `git worktree list --porcelain`
// itself reported, and a name that is not a key in that table launches nothing.
// `../..`, `/etc`, `a/b` and `not-a-worktree` are all the same answer, arrived at
// the same way: they are not keys.
//
// The refusals are the tests that matter. A passing happy path proves nothing
// here, and `#[cfg(test)]` below is written the other way round on purpose.
//
// ## And the one case that raises a dialog
//
// A Preview runs unconfined, because it reads the Keychain to resolve a
// Credential. So there is a three-step path from confined to unconfined: the
// agent edits `sandbox.ts` in a worktree, calls this tool, and the host spawns a
// varnick whose **Fence** the agent wrote, whose own agent then runs under it.
//
// The dialog stands in that path and in nothing else. It raises for a worktree
// that touches `packages/harness/**`, `src-tauri/**` or
// `sandbox-policy.baseline.json`, and for nothing else — `packages/core/**`,
// `vite.config.*` and `package.json` are Core and launch silently, because a
// dialog on every Core preview is a dialog nobody reads by the second week.
// See docs/adr/0014-core-is-authored-in-a-worktree.md.
//
// Which changed paths are Fence is decided in
// packages/harness/src/preview.ts, by the Harness runtime — the process with a
// filesystem. This module decides *whether there were any* and draws the
// dialog, because a native dialog is the whole point: Userspace renders in the
// same window and the agent writes Userspace, so a Surface could draw a
// convincing fake and train the developer to click through. Userspace cannot
// draw an `NSAlert` at all.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

/// Where a Worktree lives, relative to the clone.
///
/// Claude Code's own default, which is the point — `EnterWorktree` and subagent
/// worktree isolation work unmodified (ADR-0014). It is also what makes a
/// worktree *name* a well-defined thing: one path component under one directory,
/// so the name and the last component of the path are the same string and
/// neither has to be derived from the other.
pub const WORKTREE_BASE: &str = ".claude/worktrees";

/// How the agent asks. One line on its stdout, told apart from a Turn event by
/// naming a request rather than a Turn — see `agent_event_of`.
pub const LAUNCH_PREVIEW_KIND: &str = "launch-preview";

/// How the host answers. One control line on the agent's stdin.
pub const PREVIEW_ANSWER_KIND: &str = "preview-answer";

/// What happened to a request for a Preview.
///
/// **Tags, not sentences**, and for the reason `TurnFailure` is: the prose is
/// authored once, on the far side, in packages/harness/src/preview.ts. Nothing
/// this process observed — a path, an OS error, an environment — can become a
/// string the confined agent reads. That is the same rule
/// `turnFailureMessage` follows, and here it is load-bearing rather than
/// stylistic: the process this host spawns things from is the one holding the
/// Credential.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreviewOutcome {
    /// A window is opening.
    Launched,
    /// The dialog was raised and the developer said no. Nothing was spawned.
    Declined,
    /// The name is not one git reports under `.claude/worktrees/`.
    UnknownWorktree,
    /// git could not be asked, so nothing could be validated against anything.
    NoWorktrees,
    /// There was a worktree and the launch itself failed.
    NoLaunch,
}

impl PreviewOutcome {
    /// The tag, as it crosses the wire.
    pub fn tag(self) -> &'static str {
        match self {
            PreviewOutcome::Launched => "launched",
            PreviewOutcome::Declined => "declined",
            PreviewOutcome::UnknownWorktree => "unknown-worktree",
            PreviewOutcome::NoWorktrees => "no-worktrees",
            PreviewOutcome::NoLaunch => "no-launch",
        }
    }
}

/// One request for a Preview, as the agent host wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewRequest {
    /// Which call this answers. Chosen by the agent host, opaque here.
    pub request_id: String,
    /// What the agent asked for. **Not yet a path, and not yet trusted.**
    pub worktree: String,
}

/// A line the agent host wrote, if it is a request for a Preview.
///
/// The second shape on a pipe that carries Turn events, told apart the way
/// `read-plan-usage` answers once were: by which id it names. A Turn event names
/// a `turnId`; this names a `requestId` and never a Turn, so `agent_event_of`
/// drops it and this drops every Turn event.
///
/// Rebuilt out of two strings, like every other parse on this wire. A request
/// carrying a `command`, an `argv` or a `path` alongside loses them here, which
/// is what makes "this tool takes a name" a property of the parse rather than a
/// rule someone upstream keeps.
pub fn preview_request_of(line: &str) -> Option<PreviewRequest> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    if value.get("kind").and_then(Value::as_str)? != LAUNCH_PREVIEW_KIND {
        return None;
    }
    let request_id = value.get("requestId").and_then(Value::as_str)?;
    let worktree = value.get("worktree").and_then(Value::as_str)?;
    if request_id.is_empty() {
        return None;
    }
    Some(PreviewRequest {
        request_id: request_id.to_string(),
        worktree: worktree.to_string(),
    })
}

/// The answer, as one control line for the agent host's stdin.
///
/// `serde_json` escapes newlines, so nothing here can split a control request
/// across two lines — the same framing every other line on this pipe uses.
pub fn preview_answer_line(request_id: &str, outcome: PreviewOutcome) -> String {
    let answer = serde_json::json!({
        "kind": PREVIEW_ANSWER_KIND,
        "requestId": request_id,
        "outcome": outcome.tag(),
    });
    format!("{answer}\n")
}

/// Is this a bare name, rather than a path or a flag?
///
/// The cheap half of the check, and it is deliberately not the whole of it:
/// {@link resolve_worktree} answers from a table git built, so a name that got
/// past this and is not a worktree still launches nothing. This exists so the
/// three shapes the ticket names — `../..`, an absolute path, and a name with a
/// separator in it — are refused *by shape* as well as by absence, and so that
/// the refusal does not depend on a directory listing happening to disagree.
///
/// A leading `-` is refused for a reason that does not apply today and is one
/// edit away from applying: nothing here passes the name to a command, and a
/// name that could be read as a flag if anything ever did is not worth keeping
/// around.
pub fn is_plain_worktree_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 100
        && name != "."
        && name != ".."
        && !name.starts_with('-')
        && !name.starts_with('.')
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
}

/// Every Worktree git reports for this clone, by name.
///
/// Built from `git worktree list --porcelain`, which writes one `worktree <abs
/// path>` line per entry. Two things are dropped: the main worktree, because the
/// live tree is what a Preview exists to run *beside*; and anything outside
/// `<clone>/.claude/worktrees/`, because that is where Core is authored
/// (ADR-0014) and because it is what makes a name one path component rather
/// than an arbitrary string.
///
/// A duplicate name is dropped rather than resolved. Two worktrees cannot share
/// a directory, so this cannot happen from a well-formed listing — and if it
/// somehow does, the honest answer to "which one did you mean" is to refuse.
pub fn worktrees_of(porcelain: &str, clone_root: &Path) -> BTreeMap<String, PathBuf> {
    let base = clone_root.join(WORKTREE_BASE);
    let mut found: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut duplicated: Vec<String> = Vec::new();

    for line in porcelain.lines() {
        let Some(path) = line.strip_prefix("worktree ") else {
            continue;
        };
        let path = PathBuf::from(path.trim());
        // The name is the last component *and* the path is the base joined onto
        // it. Checked in that direction rather than by string prefix, so a path
        // like `<base>/a/b` — which has a separator in the part that would be
        // the name — has no name at all rather than the name `b`.
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if path != base.join(name) {
            continue;
        }
        if !is_plain_worktree_name(name) {
            continue;
        }
        let name = name.to_string();
        if found.insert(name.clone(), path).is_some() {
            duplicated.push(name);
        }
    }

    for name in duplicated {
        found.remove(&name);
    }
    found
}

/// The Worktree the agent named, or why there is none.
///
/// **This is the whole of the boundary.** The answer is a value out of a table
/// git wrote; the agent's string is only ever used as a key. There is no path
/// join, no canonicalisation and no "is it inside" test on anything the agent
/// sent, because none of those is needed when the candidate set was enumerated
/// rather than constructed.
pub fn resolve_worktree(
    name: &str,
    porcelain: &str,
    clone_root: &Path,
) -> Result<PathBuf, PreviewOutcome> {
    if !is_plain_worktree_name(name) {
        return Err(PreviewOutcome::UnknownWorktree);
    }
    worktrees_of(porcelain, clone_root)
        .remove(name)
        .ok_or(PreviewOutcome::UnknownWorktree)
}

/// What `git worktree list` is asked, and the whole of what it is asked.
///
/// A constant argv with no hole in it, for the reason `MINT_ARGV` in mint.rs is
/// one: a command with a field in it would be a way to run something else as
/// varnick, on the host, outside the Sandbox. The agent's string reaches this
/// process and never reaches this command.
pub const WORKTREE_LIST_ARGV: [&str; 3] = ["worktree", "list", "--porcelain"];

/// Ask git what worktrees this clone has.
///
/// Run in the clone root, which is the only directory this takes, and it comes
/// from `VARNICK_CLONE_ROOT` or the build path rather than from the request.
pub fn worktree_listing(clone_root: &Path) -> Option<String> {
    let output = Command::new("git")
        .args(WORKTREE_LIST_ARGV)
        .current_dir(clone_root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout).ok()
}

/// What it takes to start a second varnick from a Worktree.
///
/// Split out from the spawn so a test can read exactly what would run without a
/// test ever running one — the same split `build_command` in agent.rs makes, and
/// for a sharper reason: this argv is produced because an agent asked for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewLaunch {
    pub program: String,
    pub args: Vec<String>,
    /// Added to this process's environment, never a replacement for it.
    pub env: BTreeMap<String, String>,
    pub cwd: PathBuf,
}

/// What varnick's own launcher is called, and what it takes.
///
/// `bun run dev:app --port <n>` — packages/core/scripts/dev.ts, ticket 46. A
/// Preview is started the same way a developer starts a second varnick by hand,
/// which is why there is no second launcher and no bespoke argv: the port is an
/// input already, and `dev.ts` is where `bun install` for a fresh worktree
/// happens.
pub const PREVIEW_PROGRAM: &str = "bun";

/// The clone root the spawned varnick works in.
///
/// Mirrored from `CLONE_ROOT_VAR` in bridge.rs, which is the same variable this
/// process reads to find its own. **The Preview is launched *in* its worktree**,
/// so its build root and its clone root are the same directory and ticket 30's
/// second-root case does not arise. Nothing here routes through a second root.
pub const PREVIEW_CLONE_ROOT_VAR: &str = crate::bridge::CLONE_ROOT_VAR;

/// The spawn, as data.
///
/// Two things are true of this and both are asserted below. The worktree
/// **path** appears, twice — as the working directory and as the clone root —
/// and it is a value out of git's own listing. The worktree **name** appears
/// nowhere: nothing the agent typed is in the argv, in the environment, or in
/// the directory.
pub fn preview_launch(worktree: &Path, port: u16) -> PreviewLaunch {
    let mut env = BTreeMap::new();
    env.insert(
        PREVIEW_CLONE_ROOT_VAR.to_string(),
        worktree.display().to_string(),
    );
    PreviewLaunch {
        program: PREVIEW_PROGRAM.to_string(),
        args: vec![
            "run".to_string(),
            "dev:app".to_string(),
            "--port".to_string(),
            port.to_string(),
        ],
        env,
        cwd: worktree.to_path_buf(),
    }
}

/// The first port from `from` upwards that nothing is listening on.
///
/// A Preview that cannot take its own port collides with the varnick that
/// launched it — ticket 46 made the port an input, and this is what chooses one.
/// Started above the default rather than at it, because 1420 is the varnick
/// doing the launching.
///
/// `free` is injected so this is decided without binding anything in a test.
pub fn first_free_port(from: u16, free: impl Fn(u16) -> bool) -> Option<u16> {
    (from..=from.saturating_add(40)).find(|port| free(*port))
}

/// Where a Preview's port search starts. One above `DEFAULT_DEV_PORT`.
pub const FIRST_PREVIEW_PORT: u16 = 1421;

/// Is nothing listening on this port?
pub fn port_is_free(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// Does this Preview need to be asked about?
///
/// One condition, on the same line `denyWrite` already draws. Empty hunks mean
/// the worktree's Fence is the Fence already running, and that launches without
/// asking.
pub fn should_ask(fence_hunks: &str) -> bool {
    !fence_hunks.trim().is_empty()
}

/// What the dialog says above the hunks.
///
/// Deliberately short, and deliberately not a rationale. ADR-0005 found this and
/// it survives its own supersession: approving a request means approving a
/// sentence the agent wrote, and that sentence is exactly what prompt injection
/// produces. The hunks are the accessory view; this is the label on it.
pub fn dialog_message(worktree: &str) -> String {
    format!("Launch a preview of {worktree}?")
}

/// The line under it, which is the whole of the argument for reading the hunks.
pub const DIALOG_INFORMATIVE: &str = "This worktree changes the code that decides what the agent may do — the sandbox policy generator, the Tauri host, or the recorded baseline. A preview runs unconfined and reads the keychain, so it will run under the fence below. Read the diff.";

/// How much of a diff a person will be shown.
///
/// Bounded because the alert has to fit on a screen and because a diff is
/// agent-produced text of no fixed size. A truncated diff says so — see
/// {@link dialog_hunks} — because a dialog that silently showed half the change
/// would be worse than one that showed none.
pub const DIALOG_HUNK_LIMIT: usize = 20_000;

/// The hunks, capped, saying so when they were.
pub fn dialog_hunks(fence_hunks: &str) -> String {
    if fence_hunks.len() <= DIALOG_HUNK_LIMIT {
        return fence_hunks.to_string();
    }
    // On a character boundary, because this is UTF-8 and a diff is arbitrary
    // file content.
    let mut cut = DIALOG_HUNK_LIMIT;
    while cut > 0 && !fence_hunks.is_char_boundary(cut) {
        cut -= 1;
    }
    format!(
        "{}\n\n… this diff is longer than the dialog shows. {} of {} characters are above; the rest is in the worktree.\n",
        &fence_hunks[..cut],
        cut,
        fence_hunks.len()
    )
}

// ---------------------------------------------------------------------------
// The dialog, and the spawn behind it
// ---------------------------------------------------------------------------

/// Ask the developer, on the main thread, and answer what they said.
///
/// **An `NSAlert` drawn by this process**, which is the whole point. Userspace
/// renders in the same window and the agent writes Userspace freely, so a
/// Surface could paint a convincing approval dialog and train the developer to
/// click through the real one. Userspace cannot draw an `NSAlert` at all, which
/// removes the class rather than mitigating it.
///
/// The hunks go in a scrolling accessory view in a fixed-pitch font, because
/// `informativeText` truncates and a diff is the thing being approved. Nothing
/// here summarises: what is shown is what git wrote.
///
/// **No test calls this.** A test that did would open a window on whoever ran
/// the suite and then wait for them. Everything about the decision that can be
/// decided from text — whether to ask, what the label says, how a long diff is
/// capped — is above, and is what `#[cfg(test)]` covers.
#[cfg(target_os = "macos")]
fn ask_developer(app: &tauri::AppHandle, worktree: &str, fence_hunks: &str) -> bool {
    use objc2::{MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSAlert, NSAlertFirstButtonReturn, NSAlertStyle, NSBorderType, NSFont, NSScrollView,
        NSTextView, NSView,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};

    let message = dialog_message(worktree);
    let hunks = dialog_hunks(fence_hunks);

    let (answered, wait) = std::sync::mpsc::channel::<bool>();
    let asked = app.run_on_main_thread(move || {
        // Some only on the main thread, which is where this closure runs.
        let Some(mtm) = MainThreadMarker::new() else {
            let _ = answered.send(false);
            return;
        };

        let frame = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(560.0, 320.0));
        let text = NSTextView::initWithFrame(NSTextView::alloc(mtm), frame);
        text.setEditable(false);
        text.setRichText(false);
        text.setString(&NSString::from_str(&hunks));
        if let Some(font) = NSFont::userFixedPitchFontOfSize(11.0) {
            text.setFont(Some(&font));
        }

        let scroll = NSScrollView::initWithFrame(NSScrollView::alloc(mtm), frame);
        scroll.setHasVerticalScroller(true);
        scroll.setBorderType(NSBorderType::BezelBorder);
        scroll.setDocumentView(Some(&text));

        let alert = NSAlert::new(mtm);
        alert.setAlertStyle(NSAlertStyle::Critical);
        alert.setMessageText(&NSString::from_str(&message));
        alert.setInformativeText(&NSString::from_str(DIALOG_INFORMATIVE));
        // The refusal is the default. The first button is the one Return
        // activates, so the safe answer is the one a distracted developer gives.
        alert.addButtonWithTitle(&NSString::from_str("Don’t launch"));
        alert.addButtonWithTitle(&NSString::from_str("Launch preview"));
        alert.setAccessoryView(Some(scroll.as_ref() as &NSView));

        let response = alert.runModal();
        let _ = answered.send(response != NSAlertFirstButtonReturn);
    });

    // A dialog that could not be put on the main thread, or a main thread that
    // never answered, is not consent. There is no timeout: the developer takes
    // as long as reading a diff takes, and the tool call waiting on this is one
    // the agent asked for.
    if asked.is_err() {
        return false;
    }
    wait.recv().unwrap_or(false)
}

#[cfg(not(target_os = "macos"))]
fn ask_developer(_app: &tauri::AppHandle, _worktree: &str, _fence_hunks: &str) -> bool {
    // varnick is macOS-only until proven otherwise, and this is the one place
    // where "unmeasured" has to mean "no" rather than "probably fine": there is
    // no dialog to draw, so there is no approval to have been given.
    false
}

/// Start the second varnick, and say only whether it started.
///
/// Detached: this host does not wait for it, does not read its output and does
/// not adopt it. A Preview is a varnick, not a child job — it holds its own
/// Session, its own Sandbox and its own agent, and the one that launched it has
/// no business in any of them.
fn spawn_preview(launch: &PreviewLaunch) -> bool {
    Command::new(&launch.program)
        .args(&launch.args)
        .envs(&launch.env)
        .current_dir(&launch.cwd)
        // Inherited, so a developer watching the terminal varnick was started
        // from sees the Preview's own output — including the `bun install` a
        // fresh worktree needs, which is the slowest part of a first launch.
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .is_ok()
}

/// The whole of what happens when the agent asks for a Preview.
///
/// Five steps, in this order, and the order is the design: the name is resolved
/// against git before anything else happens, the Fence is read before anything
/// is spawned, and the developer is asked before anything is spawned. Nothing
/// downstream of a refusal runs.
///
/// The clone root is this process's own — `VARNICK_CLONE_ROOT` or the build path
/// — and never anything the agent sent. The Preview's clone root is the
/// worktree, which is where it is launched, so its build root and its clone root
/// are one directory and ticket 30's second-root case does not arise.
pub fn answer_preview(app: &tauri::AppHandle, worktree: &str) -> PreviewOutcome {
    use tauri::Manager;

    let clone_root = crate::bridge::clone_root(std::env::var(crate::bridge::CLONE_ROOT_VAR).ok());

    let Some(listing) = worktree_listing(&clone_root) else {
        return PreviewOutcome::NoWorktrees;
    };
    let path = match resolve_worktree(worktree, &listing, &clone_root) {
        Ok(path) => path,
        Err(outcome) => return outcome,
    };

    /*
      The Fence, as hunks, from the Harness runtime — the process with a
      filesystem and the one holding `isFencePath`, which three separate
      mechanisms key off. A runtime that will not answer leaves this empty, and
      an empty answer launches without asking.

      That is a failure in the unsafe direction and it is deliberate rather than
      overlooked. The alternative is a dialog with nothing in it, which asks the
      developer to approve bytes it cannot show them — and approving bytes is
      the entire mechanism. See `fenceDiffOf` in packages/harness/src/runtime.ts,
      which makes the same trade one process further down.
    */
    let hunks = app
        .state::<crate::bridge::HarnessRuntime>()
        .fence_diff(&path.display().to_string())
        .unwrap_or_default();

    if should_ask(&hunks) && !ask_developer(app, worktree, &hunks) {
        return PreviewOutcome::Declined;
    }

    let Some(port) = first_free_port(FIRST_PREVIEW_PORT, port_is_free) else {
        return PreviewOutcome::NoLaunch;
    };

    if spawn_preview(&preview_launch(&path, port)) {
        PreviewOutcome::Launched
    } else {
        PreviewOutcome::NoLaunch
    }
}

#[cfg(test)]
mod tests {
    use super::{
        dialog_hunks, dialog_message, first_free_port, is_plain_worktree_name, preview_answer_line,
        preview_launch, preview_request_of, resolve_worktree, should_ask, worktrees_of,
        PreviewOutcome, PreviewRequest, DIALOG_HUNK_LIMIT, PREVIEW_CLONE_ROOT_VAR, WORKTREE_BASE,
    };
    use std::path::{Path, PathBuf};

    fn clone_root() -> PathBuf {
        PathBuf::from("/Users/dev/varnick")
    }

    /// What git says about a clone with two worktrees in the usual place.
    fn listing() -> String {
        [
            "worktree /Users/dev/varnick",
            "HEAD 45354d1a6ab89de0c49e06b656bcc7b377f75dfa",
            "branch refs/heads/main",
            "",
            "worktree /Users/dev/varnick/.claude/worktrees/agent-one",
            "HEAD ec1ae4916526b5c81c7518f2df4ebecc790a6328",
            "branch refs/heads/ticket/48",
            "",
            "worktree /Users/dev/varnick/.claude/worktrees/agent-two",
            "HEAD a0de1b42cbe1771810dfcbc2f83b3546837ff048",
            "branch refs/heads/ticket/49",
            "locked claude agent agent-two (pid 28245 start Sat Aug  8 04:56:59 2026)",
            "",
        ]
        .join("\n")
    }

    // -----------------------------------------------------------------------
    // The refusals. These are the tests that matter; the happy path below is
    // here to keep them honest, not the other way round.
    // -----------------------------------------------------------------------

    #[test]
    fn a_worktree_name_that_climbs_out_of_the_worktrees_directory_is_refused() {
        // The shape the ticket names first, and the one a careless
        // implementation joins onto a base directory and spawns from.
        for climbing in ["..", "../..", "../../..", "../../etc", "agent-one/.."] {
            assert_eq!(
                resolve_worktree(climbing, &listing(), &clone_root()),
                Err(PreviewOutcome::UnknownWorktree),
                "{climbing} must not resolve to anything"
            );
        }
    }

    #[test]
    fn an_absolute_path_is_not_a_worktree_name() {
        for absolute in [
            "/etc",
            "/Users/dev/varnick",
            "/Users/dev/varnick/.claude/worktrees/agent-one",
            "/tmp",
        ] {
            assert_eq!(
                resolve_worktree(absolute, &listing(), &clone_root()),
                Err(PreviewOutcome::UnknownWorktree),
                "{absolute} must not resolve to anything"
            );
        }
        // Including the path of a worktree that really is there. The tool takes
        // a name; a path that happens to be right is still not a name, and
        // accepting one would be accepting the *shape* rather than the value.
    }

    #[test]
    fn a_name_with_a_separator_in_it_is_refused() {
        for separated in [
            "agent-one/agent-two",
            "a/b",
            "agent-one/",
            "sub/agent-one",
            "agent\\one",
        ] {
            assert_eq!(
                resolve_worktree(separated, &listing(), &clone_root()),
                Err(PreviewOutcome::UnknownWorktree),
                "{separated} must not resolve to anything"
            );
        }
    }

    #[test]
    fn a_name_git_does_not_report_is_refused_however_ordinary_it_looks() {
        // The one that has nothing wrong with its shape. `agent-three` is a
        // perfectly good directory name and there is no worktree by it, which is
        // the only thing that decides the answer.
        assert_eq!(
            resolve_worktree("agent-three", &listing(), &clone_root()),
            Err(PreviewOutcome::UnknownWorktree)
        );
        assert_eq!(
            resolve_worktree("agent-one", "", &clone_root()),
            Err(PreviewOutcome::UnknownWorktree),
            "git reporting nothing means nothing resolves"
        );
    }

    #[test]
    fn the_live_tree_is_not_a_worktree_anyone_can_preview() {
        /*
          A Preview exists to run a change *beside* the varnick that is running,
          and the live tree is that varnick. It is on git's list, so it has to be
          taken off this one — and the name it would go on under is the clone
          directory's own, which is exactly the string somebody would try.
        */
        assert_eq!(
            resolve_worktree("varnick", &listing(), &clone_root()),
            Err(PreviewOutcome::UnknownWorktree)
        );
    }

    #[test]
    fn a_worktree_outside_the_worktrees_directory_is_not_previewable() {
        /*
          The agent can write the OS temp directory and can run git, so
          `git worktree add $TMPDIR/x` is within reach. Such a worktree is real
          and git reports it; it is still not where Core is authored (ADR-0014),
          and admitting it would make "the name is one path component under one
          directory" untrue — which is what the whole lookup rests on.
        */
        let elsewhere = [
            "worktree /Users/dev/varnick",
            "",
            "worktree /private/tmp/planted",
            "",
            "worktree /Users/dev/varnick/.claude/worktrees/nested/deeper",
            "",
        ]
        .join("\n");
        assert_eq!(
            resolve_worktree("planted", &elsewhere, &clone_root()),
            Err(PreviewOutcome::UnknownWorktree)
        );
        assert_eq!(
            resolve_worktree("deeper", &elsewhere, &clone_root()),
            Err(PreviewOutcome::UnknownWorktree)
        );
    }

    #[test]
    fn a_name_that_is_not_a_name_at_all_is_refused_before_anything_is_looked_up() {
        for shapeless in ["", ".", "..", "-p", "--config", ".git", "a b", "a\0b", "a\nb"] {
            assert!(
                !is_plain_worktree_name(shapeless),
                "{shapeless:?} is not a worktree name"
            );
            assert_eq!(
                resolve_worktree(shapeless, &listing(), &clone_root()),
                Err(PreviewOutcome::UnknownWorktree)
            );
        }
        // Two hundred characters of nothing. A name is a directory, and one this
        // long is somebody probing rather than somebody working.
        assert!(!is_plain_worktree_name(&"a".repeat(200)));
    }

    #[test]
    fn a_listing_naming_one_directory_twice_resolves_to_neither() {
        let doubled = [
            "worktree /Users/dev/varnick",
            "",
            "worktree /Users/dev/varnick/.claude/worktrees/agent-one",
            "",
            "worktree /Users/dev/varnick/.claude/worktrees/agent-one",
            "",
        ]
        .join("\n");
        assert_eq!(
            resolve_worktree("agent-one", &doubled, &clone_root()),
            Err(PreviewOutcome::UnknownWorktree)
        );
    }

    // -----------------------------------------------------------------------
    // What is left after the refusals
    // -----------------------------------------------------------------------

    #[test]
    fn a_worktree_git_reports_resolves_to_the_path_git_reported() {
        // The value is git's, not one built by joining the agent's string onto
        // a base. That is the difference the whole module rests on.
        assert_eq!(
            resolve_worktree("agent-one", &listing(), &clone_root()),
            Ok(PathBuf::from(
                "/Users/dev/varnick/.claude/worktrees/agent-one"
            ))
        );
        assert_eq!(
            resolve_worktree("agent-two", &listing(), &clone_root()),
            Ok(PathBuf::from(
                "/Users/dev/varnick/.claude/worktrees/agent-two"
            ))
        );
    }

    #[test]
    fn the_worktrees_are_the_ones_under_the_directory_core_is_authored_in() {
        let found = worktrees_of(&listing(), &clone_root());
        assert_eq!(
            found.keys().cloned().collect::<Vec<_>>(),
            vec!["agent-one".to_string(), "agent-two".to_string()]
        );
        assert!(WORKTREE_BASE.ends_with("worktrees"));
    }

    #[test]
    fn a_second_root_has_its_own_worktrees_and_shares_none_of_them() {
        // The same listing read against a different clone root resolves nothing,
        // because every path in it belongs to the first. ADR-0012: a Workspace
        // is per clone, and so is everything keyed by one.
        assert!(worktrees_of(&listing(), Path::new("/opt/other/varnick")).is_empty());
    }

    // -----------------------------------------------------------------------
    // The spawn's argument shape
    // -----------------------------------------------------------------------

    #[test]
    fn the_spawn_carries_a_path_git_reported_and_nothing_the_agent_typed() {
        let worktree = resolve_worktree("agent-one", &listing(), &clone_root()).unwrap();
        let launch = preview_launch(&worktree, 1421);

        assert_eq!(launch.program, "bun");
        assert_eq!(launch.args, vec!["run", "dev:app", "--port", "1421"]);
        assert_eq!(launch.cwd, worktree);
        assert_eq!(
            launch.env.get(PREVIEW_CLONE_ROOT_VAR).map(String::as_str),
            Some("/Users/dev/varnick/.claude/worktrees/agent-one")
        );
    }

    #[test]
    fn the_preview_is_launched_in_its_worktree_so_there_is_no_second_root() {
        /*
          Build root == clone root, which is why ticket 30 does not apply and why
          this is not routed through a second root. The launcher runs in the
          worktree and the clone root names the same directory, so the Sandbox,
          the write boundary and the Session mirror are all about the tree the
          window is showing.
        */
        let worktree = PathBuf::from("/Users/dev/varnick/.claude/worktrees/agent-one");
        let launch = preview_launch(&worktree, 1421);
        assert_eq!(
            launch.env.get(PREVIEW_CLONE_ROOT_VAR).map(PathBuf::from),
            Some(launch.cwd.clone())
        );
    }

    #[test]
    fn the_spawn_has_no_field_a_command_could_arrive_in() {
        /*
          The whole argv is decided here and the only thing that varies is a
          port. A request that tried to bring a command with it — the failure
          this ticket exists to prevent — has nowhere to put it: `preview_launch`
          takes a path and a number, and neither of those is the agent's string.
        */
        let launch = preview_launch(Path::new("/Users/dev/varnick/.claude/worktrees/x"), 1421);
        assert!(launch
            .args
            .iter()
            .all(|arg| !arg.contains(';') && !arg.contains('&') && !arg.contains('|')));
        assert_eq!(launch.env.len(), 1, "one variable, and it is the clone root");
    }

    #[test]
    fn a_preview_takes_a_port_the_varnick_that_launched_it_is_not_on() {
        // Ticket 46 made the port an input; this is what fills it in. Never
        // 1420, which is the varnick doing the asking.
        assert_eq!(first_free_port(1421, |_| true), Some(1421));
        assert_eq!(first_free_port(1421, |port| port >= 1424), Some(1424));
        assert_eq!(first_free_port(1421, |_| false), None);
    }

    // -----------------------------------------------------------------------
    // The wire
    // -----------------------------------------------------------------------

    #[test]
    fn a_request_for_a_preview_is_two_strings_and_nothing_else() {
        let request = preview_request_of(
            r#"{"kind":"launch-preview","requestId":"p1","worktree":"agent-one","command":"rm -rf /","argv":["sh"]}"#,
        );
        assert_eq!(
            request,
            Some(PreviewRequest {
                request_id: "p1".to_string(),
                worktree: "agent-one".to_string(),
            }),
            "a command sent alongside is a field that was never read"
        );
    }

    #[test]
    fn a_turn_event_is_not_a_request_for_a_preview_and_the_reverse() {
        // Two shapes on one pipe, told apart by which id each names. A Turn
        // event names a Turn; a preview request names a request.
        assert_eq!(
            preview_request_of(r#"{"kind":"delta","turnId":"t1","text":"hello"}"#),
            None
        );
        assert_eq!(
            crate::agent::agent_event_of(
                r#"{"kind":"launch-preview","requestId":"p1","worktree":"agent-one"}"#
            ),
            None,
            "a preview request must not be delivered to a Turn"
        );
    }

    #[test]
    fn a_request_missing_either_half_is_not_a_request() {
        assert_eq!(preview_request_of(r#"{"kind":"launch-preview"}"#), None);
        assert_eq!(
            preview_request_of(r#"{"kind":"launch-preview","requestId":"p1"}"#),
            None
        );
        assert_eq!(
            preview_request_of(r#"{"kind":"launch-preview","worktree":"agent-one"}"#),
            None
        );
        assert_eq!(
            preview_request_of(r#"{"kind":"launch-preview","requestId":"","worktree":"a"}"#),
            None
        );
        assert_eq!(preview_request_of("not json"), None);
        assert_eq!(preview_request_of(r#"{"ready":true}"#), None);
    }

    #[test]
    fn an_answer_is_exactly_one_line_and_carries_a_tag_rather_than_a_sentence() {
        let line = preview_answer_line("p1", PreviewOutcome::Declined);
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(
            parsed,
            serde_json::json!({
                "kind": "preview-answer",
                "requestId": "p1",
                "outcome": "declined",
            })
        );
    }

    #[test]
    fn every_outcome_crosses_as_its_own_tag() {
        let tags: Vec<&str> = [
            PreviewOutcome::Launched,
            PreviewOutcome::Declined,
            PreviewOutcome::UnknownWorktree,
            PreviewOutcome::NoWorktrees,
            PreviewOutcome::NoLaunch,
        ]
        .iter()
        .map(|outcome| outcome.tag())
        .collect();
        assert_eq!(
            tags,
            vec![
                "launched",
                "declined",
                "unknown-worktree",
                "no-worktrees",
                "no-launch"
            ]
        );
        // No two the same, or the agent could not tell a refusal from a launch.
        let mut sorted = tags.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), tags.len());
    }

    // -----------------------------------------------------------------------
    // The dialog, decided without one being opened
    // -----------------------------------------------------------------------

    #[test]
    fn a_worktree_that_changes_no_fence_code_launches_without_asking() {
        assert!(!should_ask(""));
        assert!(!should_ask("   \n  "));
    }

    #[test]
    fn a_worktree_that_changes_fence_code_is_asked_about() {
        assert!(should_ask("diff --git a/packages/harness/src/sandbox.ts b/…"));
    }

    #[test]
    fn the_dialog_shows_the_hunks_rather_than_a_summary() {
        let hunks = "diff --git a/src-tauri/src/credential.rs b/src-tauri/src/credential.rs\n@@ -1 +1 @@\n-safe\n+not\n";
        assert_eq!(dialog_hunks(hunks), hunks);
        assert!(dialog_message("agent-one").contains("agent-one"));
    }

    #[test]
    fn a_diff_too_long_for_the_dialog_says_so_rather_than_being_cut_silently() {
        // A dialog that quietly showed half a change would be worse than one
        // that showed none: the developer would believe they had read it.
        let long = "+".repeat(DIALOG_HUNK_LIMIT + 500);
        let shown = dialog_hunks(&long);
        assert!(shown.contains("longer than the dialog shows"));
        assert!(shown.len() < long.len() + 300);
    }
}
