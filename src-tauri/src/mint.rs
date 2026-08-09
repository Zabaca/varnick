// Minting a subscription token, host-side.
//
// One command — `claude setup-token` — run by this process, on a pty, with its
// output parsed for two things: the URL a developer signs in at, and the token
// the flow prints when they have. The token goes straight into the keychain
// through the write path credential.rs already owns. Nothing else sees it.
//
// ## Why this runs on the host, and why that is not a hole in ADR-0003
//
// ADR-0003's last consequence says varnick never spawns a Claude Code process
// outside `srt`. The reason it says that is specific and is written down there:
// the SDK's `query()` starts a session, and a session runs `SessionStart` hooks
// out of the clone's `.claude/settings.json`, which the agent can write. So a
// host-side session executes agent-authored code unconfined.
//
// This is a bounded exception, recorded in that ADR, and the hook concern is
// closed by construction rather than by promise:
//
//   * the argv is a constant — {@link MINT_ARGV} — with no field anywhere that
//     could add to it. It is not `query()`, it is not an SDK entry point, and it
//     opens no session.
//   * `CLAUDE_CONFIG_DIR` **and** the working directory point at a directory
//     varnick makes for this run and deletes afterwards, outside the clone. The
//     settings file the rule is about is in the clone; this process never looks
//     at the clone, so there are no agent-authored hooks to find.
//   * nothing about it is agent input. A person clicks a button; the argv is
//     already decided. `srt` exists to confine a nondeterministic actor, and
//     there is no actor here — this is the same class of work as reading the
//     keychain, which this process already does.
//
// ## The credential rule, which is stricter here than anywhere else
//
// The value this produces is a live credential from the byte it appears. It is
// never printed, never logged, never written to a file, and never crosses the
// bridge:
//
//   * what the pty produced is held in {@link Rendered}, which has no
//     `Serialize` and a hand-written `Debug` that refuses — the same two rules
//     `Secret` follows, because between the first byte of the token and the
//     keychain this is the type holding one.
//   * the parsed value is a `Secret` immediately and is handed to
//     `store_credential`, which is ticket 24's path and the only keychain writer
//     in this codebase.
//   * every failure is a `&'static str` tag chosen by a match arm. There is no
//     `String` on any path out of here for a value to be formatted into, and
//     nothing the command printed is ever forwarded.
//   * the one string that does cross the bridge is the authorize URL, which is
//     an OAuth request the developer's browser is about to make anyway. It is
//     read out of the same buffer the token is in, so `the_url_is_never_the_token`
//     asserts what that separation depends on.
//
// A pty rather than a pipe, because a plain pipe produces nothing at all: the
// token is rendered into a terminal UI. The window is opened deliberately wide
// so the values land on one line each; the parse still deletes whitespace,
// because the renderer wrapping a credential mid-string is the failure that
// silently truncates one.

use std::collections::VecDeque;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde_json::Value;

use crate::bridge::Failure;
use crate::credential::{
    store_credential, Kind, Secret, Security, SystemSecurity, API_KEY_ENV_VAR, SUBSCRIPTION_ENV_VAR,
};

/// The whole command, and there is no way to add to it.
///
/// A constant rather than a request field, for the same reason the Compaction
/// command is a constant inside the Sandbox: this is the one place varnick
/// starts a Claude Code process on the host, and a command with a hole in it is
/// a command something could be smuggled into.
pub const MINT_ARGV: [&str; 2] = ["claude", "setup-token"];

/// The variable that decides where the command reads and writes its own
/// configuration.
///
/// Pointed at a directory varnick owns for this run. That is what closes
/// ADR-0003's stated concern — see the module comment — and it is also the
/// answer to "what does it write, and where", which was open in ticket 25.
pub const CONFIG_DIR_VAR: &str = "CLAUDE_CONFIG_DIR";

/// The prefix every subscription token starts with.
///
/// Assembled by `concat!` so the literal does not appear in this file. The value
/// is a prefix and not a credential, but its shape is one every secret scanner
/// looks for, and a repository that cannot be pushed is a repository nobody can
/// fork.
const TOKEN_PREFIX: &str = concat!("sk-", "ant-oat01-");

/// What the flow says immediately after the token, in either wording seen.
///
/// The parse cuts here. A terminator that stops matching is the fragility this
/// whole path was warned about, and the consequence is designed to be loud: no
/// terminator means `unreadable-token`, never a value stored short.
const TOKEN_TERMINATORS: [&str; 2] = ["Store this token", "Use this token"];

/// What an authorize URL looks like, so the parse does not depend on the
/// sentence above it.
///
/// The prose around it — "Browser didn't open? Use the url below to sign in" —
/// is what a human reads and is the part most likely to be reworded. The
/// endpoint is the part that cannot move without the OAuth flow moving with it.
const AUTHORIZE_MARK: &str = "/oauth/authorize";

/// How long a mint may take before the process tree is killed.
///
/// Generous, because the developer is signing in to a website in the middle of
/// it. Bounded at all, because an abandoned mint would otherwise leave a Claude
/// Code process running with nobody watching it.
const MINT_LIMIT: Duration = Duration::from_secs(10 * 60);

/// How long a wait for the next mint event lasts before answering "nothing yet".
///
/// The same shape as a Turn event wait: a mint that is waiting on a person is a
/// working mint, so running out of patience is not a failure.
const EVENT_WAIT: Duration = Duration::from_secs(15);

/// How wide the pty is.
///
/// Wide on purpose. The renderer wraps to the terminal width, and a wrapped
/// credential is the failure mode this ticket exists to avoid — a naive parse
/// stores the first line and authentication fails days later, far from the
/// cause. The parse deletes whitespace anyway; this makes it unnecessary rather
/// than relying on it.
const PTY_COLUMNS: u16 = 512;
const PTY_ROWS: u16 = 200;

/// Everything the command has rendered so far.
///
/// Holds a live credential from the moment the token appears, so it follows the
/// two rules `Secret` follows: no `Serialize`, and a `Debug` that refuses. A
/// `{:?}` in a log line is the likeliest way a credential escapes, and a pty
/// capture landing in a transcript is how one escaped during measurement.
#[derive(Default)]
pub struct Rendered(String);

impl std::fmt::Debug for Rendered {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Rendered([redacted])")
    }
}

impl Rendered {
    /// Build one from text. The seam every test uses: a recorded shape with the
    /// token replaced, never a real run.
    ///
    /// Test-only, and that is enforced rather than intended. A way to construct
    /// a render out of a string, available to the rest of this process, is a way
    /// for something that is not a pty to be parsed as though it were one.
    #[cfg(test)]
    pub fn of(text: &str) -> Self {
        Rendered(text.to_string())
    }

    /// Append what the pty just produced.
    ///
    /// Lossy on purpose: a terminal UI emits bytes that are not valid UTF-8 at
    /// a chunk boundary, and failing the mint over a split code point would fail
    /// it for a reason that has nothing to do with the token.
    fn extend(&mut self, bytes: &[u8]) {
        self.0.push_str(&String::from_utf8_lossy(bytes));
    }

    /// The same text with terminal control sequences removed.
    ///
    /// The values are rendered into a UI, so they arrive beside cursor
    /// positioning and colour. Stripping is what makes "the token is the
    /// characters between these two markers" true of the text rather than of an
    /// idealised version of it.
    fn plain(&self) -> String {
        plain_text(&self.0)
    }
}

/// Strip ANSI escape sequences. CSI, OSC, and the two-character forms.
fn plain_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            // A carriage return is the renderer returning to the start of a
            // line, not part of any value.
            if c != '\r' {
                out.push(c);
            }
            continue;
        }
        match chars.next() {
            // CSI: parameters, then a final byte in @-~.
            Some('[') => {
                for next in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&next) {
                        break;
                    }
                }
            }
            // OSC: a string, ended by BEL or by ESC \.
            Some(']') => {
                while let Some(next) = chars.next() {
                    if next == '\u{7}' {
                        break;
                    }
                    if next == '\u{1b}' {
                        chars.next();
                        break;
                    }
                }
            }
            // Anything else is a two-character escape, already consumed.
            _ => {}
        }
    }
    out
}

/// The authorize URL the flow printed, if it has printed one yet.
///
/// The developer's browser is outside the Sandbox and always was, so this is a
/// fallback that costs nothing and rescues the case that would otherwise be
/// fatal: a browser that did not open. The flow completes over a local callback
/// and needs no paste, so surfacing this is the whole of what the window has to
/// do while the mint runs.
///
/// Never the token: a token has no scheme, and the run stops at whitespace.
pub fn authorize_url_of(rendered: &Rendered) -> Option<String> {
    let text = rendered.plain();
    let mut from = 0;
    while let Some(found) = text[from..].find("https://") {
        let start = from + found;
        let end = text[start..]
            .find(char::is_whitespace)
            .map(|offset| start + offset)
            .unwrap_or(text.len());
        let url = &text[start..end];
        if url.contains(AUTHORIZE_MARK) {
            return Some(url.to_string());
        }
        from = end.max(start + 1);
    }
    None
}

/// Whether what was captured looks like a token.
///
/// The check that stands between a rendering change and a truncated credential
/// in the keychain. A truncated token fails as an authentication error days
/// later, with nothing on screen pointing back here.
fn looks_like_a_token(candidate: &str) -> bool {
    let Some(body) = candidate.strip_prefix(TOKEN_PREFIX) else {
        return false;
    };
    !body.is_empty()
        && body
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Everything up to the first blank line.
///
/// The renderer wraps a long value across lines, so a single newline inside the
/// value has to be joined over. A *blank* line is the render moving on to the
/// next thing it has to say, and it is what stops the join running into prose
/// that happens to be made of token characters.
fn until_blank_line(text: &str) -> &str {
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }
        let mut next = index + 1;
        while next < bytes.len() && (bytes[next] == b' ' || bytes[next] == b'\t') {
            next += 1;
        }
        if next < bytes.len() && bytes[next] == b'\n' {
            // Cutting at an ASCII newline, so this is always a char boundary.
            return &text[..index];
        }
    }
    text
}

/// The token the flow printed, or why what it printed is not one.
///
/// `None` means it has not printed one yet, which is the ordinary state for
/// most of a mint. `Some(Err(_))` means the prefix appeared and what followed it
/// could not be read as a token — the loud failure this path is built around.
///
/// Two cuts and then a deletion, and each of the three is a guard against a
/// different way of storing the wrong bytes:
///
///   * up to the sentence that follows the value, so the sentence is not part
///     of it. No sentence means no token, not "take what there is".
///   * up to the first blank line, so a render that carries on talking cannot
///     have its words joined onto the end of a credential.
///   * whitespace deleted rather than trimmed, because the renderer wraps a
///     long value mid-string. A parse that stopped at the first newline would
///     take the first line of a credential and store it as the whole one, and
///     the symptom is authentication failing days later.
pub fn minted_token_of(rendered: &Rendered) -> Option<Result<Secret, &'static str>> {
    let text = rendered.plain();
    let start = text.find(TOKEN_PREFIX)?;
    let rest = &text[start..];

    // No terminator yet. Still arriving, or it never will — the caller decides
    // which by whether the command has ended. See {@link store_minted_token}.
    let end = TOKEN_TERMINATORS
        .iter()
        .filter_map(|marker| rest.find(marker))
        .min()?;

    let span = until_blank_line(&rest[..end]);
    let candidate: String = span.chars().filter(|c| !c.is_whitespace()).collect();
    if looks_like_a_token(&candidate) {
        Some(Ok(Secret::new(candidate)))
    } else {
        Some(Err("unreadable-token"))
    }
}

/// What a finished mint amounts to, and the one place a token is stored.
///
/// Split from the reader thread so it can be tested against a recorded shape
/// with the token replaced. `security` has no default, exactly as
/// `store_credential` has none: no test in this repository may reach a real
/// keychain, and that is a property of the signature rather than a rule.
///
/// A prefix with no terminator after the flow has ended is `unreadable-token`
/// rather than "take what there is". Storing a credential this code could not
/// finish reading is the one outcome worse than not storing one.
pub fn store_minted_token(
    security: &dyn Security,
    rendered: &Rendered,
) -> Result<(), &'static str> {
    match minted_token_of(rendered) {
        Some(Ok(secret)) => store_credential(security, Kind::Subscription, secret),
        Some(Err(problem)) => Err(problem),
        None if rendered.plain().contains(TOKEN_PREFIX) => Err("unreadable-token"),
        None => Err("no-token"),
    }
}

/// What the mint has said that nobody has read yet.
///
/// The same shape as the agent's event queue, and generation-stamped for the
/// same reason: a URL from a mint that has been replaced would send a developer
/// to an authorization that finishes into a process that is gone.
#[derive(Default)]
struct MintState {
    generation: u64,
    events: VecDeque<Value>,
    /// The process group to kill. `Some` while a mint is believed to be running.
    group: Option<i32>,
}

#[derive(Default)]
struct MintingInner {
    state: Mutex<MintState>,
    arrived: Condvar,
}

/// The mint, and the one place its liveness is known. Tauri managed state.
#[derive(Default)]
pub struct Minting {
    inner: Arc<MintingInner>,
}

impl Minting {
    /// Start the flow. Answers at once; everything else arrives as events.
    ///
    /// Refuses while one is already running rather than starting a second: two
    /// concurrent flows would race each other into the same keychain item, and
    /// the developer would have two browser tabs and no way to tell which one
    /// varnick was listening to.
    pub fn start(&self) -> Result<(), Failure> {
        let mut state = self
            .inner
            .state
            .lock()
            .map_err(|_| Failure::of("runtime-lost"))?;
        if state.group.is_some() {
            return Err(Failure::refused("already-minting"));
        }

        let directory = mint_directory();
        std::fs::create_dir_all(&directory).map_err(|_| Failure::refused("no-workspace"))?;

        let pty = Pty::open().map_err(|_| Failure::refused("no-terminal"))?;
        let child = spawn_mint(&pty, &directory);
        let mut child = match child {
            Ok(child) => child,
            Err(()) => {
                let _ = std::fs::remove_dir_all(&directory);
                // Nothing the spawn said is forwarded: this process holds a
                // credential and an OS error can quote the environment.
                return Err(Failure::refused("no-command"));
            }
        };
        state.generation += 1;
        state.events.clear();
        let generation = state.generation;
        let pid = child.id() as i32;
        // `setsid` in the spawn makes the child its own group leader, so its pid
        // is its pgid and killing the group kills the tree.
        state.group = Some(pid);
        drop(state);

        let inner = Arc::clone(&self.inner);
        let master = pty.into_master();
        std::thread::spawn(move || {
            let mut rendered = Rendered::default();
            let mut announced = false;
            let mut master = master;
            let mut buffer = [0u8; 4096];
            loop {
                match master.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => rendered.extend(&buffer[..read]),
                    // A signal arriving mid-read is not the end of anything, and
                    // treating it as one would end the capture in the middle of
                    // a credential — which is exactly the truncation the parse
                    // downstream exists to refuse, arriving one step earlier.
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    // Anything else is the far end gone: macOS ends a master
                    // read with 0 when the slave closes and other platforms
                    // raise EIO, and both mean the command has finished writing.
                    Err(_) => break,
                }
                if !announced {
                    if let Some(url) = authorize_url_of(&rendered) {
                        announced = true;
                        push(&inner, generation, serde_json::json!({
                            "kind": "authorize",
                            "url": url,
                        }));
                    }
                }
            }

            let _ = child.wait();
            let outcome = match store_minted_token(&SystemSecurity, &rendered) {
                Ok(()) => serde_json::json!({ "kind": "stored" }),
                // A tag chosen by a match arm, never anything the command
                // printed — which on this path is a credential.
                Err(tag) => serde_json::json!({ "kind": "failed", "failure": tag }),
            };
            // Dropped before the event, so the directory is gone by the time
            // anything reacts to the outcome.
            drop(rendered);
            let _ = std::fs::remove_dir_all(&directory);
            if let Ok(mut state) = inner.state.lock() {
                if state.generation == generation {
                    state.group = None;
                }
            }
            push(&inner, generation, outcome);
        });

        // The watchdog. A developer who closed the browser tab and walked away
        // must not leave a Claude Code process running on their machine.
        let inner = Arc::clone(&self.inner);
        std::thread::spawn(move || {
            std::thread::sleep(MINT_LIMIT);
            if let Ok(mut state) = inner.state.lock() {
                if state.generation == generation {
                    kill_group(state.group.take());
                }
            }
        });

        Ok(())
    }

    /// The next thing the running mint had to say, or nothing yet.
    pub fn next_event(&self) -> Option<Value> {
        let mut state = self.inner.state.lock().ok()?;
        let deadline = std::time::Instant::now() + EVENT_WAIT;
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
}

impl Drop for Minting {
    /// varnick exiting must not leave a mint running behind it.
    fn drop(&mut self) {
        if let Ok(mut state) = self.inner.state.lock() {
            kill_group(state.group.take());
        }
    }
}

fn push(inner: &Arc<MintingInner>, generation: u64, event: Value) {
    if let Ok(mut state) = inner.state.lock() {
        if state.generation == generation {
            state.events.push_back(event);
        }
    }
    inner.arrived.notify_all();
}

/// A directory varnick owns, for one mint, outside the clone.
fn mint_directory() -> PathBuf {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("varnick-mint-{}-{stamp}", std::process::id()))
}

/// The command, minus the terminal it runs on.
///
/// Split out so a test can read exactly what would be spawned without a test
/// ever spawning one. Three things are decided here and nothing else is:
///
///   * the argv, which is a constant.
///   * `CLAUDE_CONFIG_DIR` and the working directory, both pointing at a
///     directory varnick made for this run. That is what puts the command
///     outside the clone, which is what closes ADR-0003's hook concern.
///   * both authentication variables removed. This process may hold a
///     credential of its own and was launched from a terminal that may export
///     another; handing either to the command that is minting one would be
///     authenticating the mint with the thing the mint is for.
pub fn build_mint_command(directory: &std::path::Path) -> Command {
    let mut command = Command::new(MINT_ARGV[0]);
    command
        .args(&MINT_ARGV[1..])
        .env(CONFIG_DIR_VAR, directory)
        .current_dir(directory)
        .env_remove(API_KEY_ENV_VAR)
        .env_remove(SUBSCRIPTION_ENV_VAR);
    command
}

// ---------------------------------------------------------------------------
// The terminal
//
// A plain pipe produces nothing at all: the token is drawn into a terminal UI
// rather than written to stdout, so there has to be a terminal for it to be
// drawn into. `openpty` rather than shelling out to `script`, so the argv stays
// exactly the two words above and the window size is varnick's to choose.
// ---------------------------------------------------------------------------

#[cfg(unix)]
struct Pty {
    master: std::os::fd::OwnedFd,
    slave: Option<std::os::fd::OwnedFd>,
}

#[cfg(unix)]
impl Pty {
    fn open() -> Result<Pty, ()> {
        use std::os::fd::FromRawFd;

        let mut master = 0;
        let mut slave = 0;
        let mut size = libc::winsize {
            ws_row: PTY_ROWS,
            ws_col: PTY_COLUMNS,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: both descriptors are written by `openpty` on success and
        // taken ownership of immediately; the size is a local this call reads.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        };
        if opened != 0 {
            return Err(());
        }
        // SAFETY: `openpty` succeeded, so both are fresh descriptors this
        // process owns and nothing else holds.
        unsafe {
            Ok(Pty {
                master: std::os::fd::OwnedFd::from_raw_fd(master),
                slave: Some(std::os::fd::OwnedFd::from_raw_fd(slave)),
            })
        }
    }

    /// A handle on the far end, for one of the child's three descriptors.
    fn child_end(&self) -> Result<Stdio, ()> {
        let slave = self.slave.as_ref().ok_or(())?;
        slave.try_clone().map(Stdio::from).map_err(|_| ())
    }

    /// Keep the near end and let go of the far one.
    ///
    /// Letting go is the load-bearing half. The child has its own copies; while
    /// this process also holds one, the terminal never reaches end-of-file and
    /// the read below waits for ever on a command that has already exited.
    fn into_master(mut self) -> std::fs::File {
        drop(self.slave.take());
        std::fs::File::from(self.master)
    }
}

/// Start the command with all three of its descriptors on the terminal.
#[cfg(unix)]
fn spawn_mint(pty: &Pty, directory: &std::path::Path) -> Result<std::process::Child, ()> {
    use std::os::unix::process::CommandExt;

    let mut command = build_mint_command(directory);
    command
        .stdin(pty.child_end()?)
        .stdout(pty.child_end()?)
        // The command's own diagnostics go to the same terminal, where they are
        // read by the parse and by nothing else. Left on this process's stderr
        // they would reach the terminal varnick was launched from, which is a
        // place a credential must never be printed.
        .stderr(pty.child_end()?);

    // SAFETY: both calls are async-signal-safe, which is the whole of the
    // contract on `pre_exec`. `setsid` makes the child a session leader — so it
    // leads its own process group, and killing that group kills the tree —
    // and `TIOCSCTTY` gives it the terminal as its controlling one, without
    // which a UI that asks whether it is interactive is told no.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY.into(), 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    command.spawn().map_err(|_| ())
}

/// Kill a whole process group, best effort. The same shape as agent.rs, and for
/// the same reason: the thing to stop is a tree rather than a process.
#[cfg(unix)]
fn kill_group(group: Option<i32>) {
    let Some(group) = group else { return };
    // SAFETY: a negative pid names the group; an unknown group is an error this
    // call is allowed to ignore.
    unsafe {
        libc::kill(-group, libc::SIGKILL);
    }
}

#[cfg(not(unix))]
fn kill_group(_group: Option<i32>) {}

#[cfg(test)]
mod tests {
    use super::{
        authorize_url_of, build_mint_command, minted_token_of, plain_text, store_minted_token,
        Rendered, CONFIG_DIR_VAR, MINT_ARGV,
    };
    use crate::credential::{Kind, Security, API_KEY_ENV_VAR, SUBSCRIPTION_ENV_VAR};
    use std::sync::Mutex;

    /*
      No test here runs the real flow, and none can.

      `claude setup-token` opens a browser and authenticates a human, and what
      it prints is a live credential — one ended up in a session transcript
      during measurement and had to be rotated. So the seam is a *recorded
      shape*: the lines the flow produced, with the token replaced by an
      invented one, and every parse asserted against that.

      The invented token is assembled rather than written out, for the same
      reason its counterparts elsewhere are: the shape is one every secret
      scanner flags, and a literal of it blocks pushing for this repository and
      for every fork.
    */

    fn fake_token() -> String {
        format!("{}{}", concat!("sk-", "ant-oat01-"), "NEVERxLETxTHISxOUT_0123456789-abcdef")
    }

    const AUTHORIZE_URL: &str = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=hFtEXAMPLEchallengeEXAMPLEvalue&code_challenge_method=S256&state=EXAMPLEstate";

    /// The shape a real run produced, with the token replaced.
    ///
    /// Escape sequences and all: the values arrive inside a terminal UI, and a
    /// fixture without them would be testing an idealised render rather than
    /// the one the parse has to survive.
    fn recorded() -> Rendered {
        Rendered::of(&format!(
            concat!(
                "\u{1b}[?25l\u{1b}[2J\u{1b}[H",
                "Opening browser to sign in\r\n",
                "\u{1b}[2mBrowser didn't open? Use the url below to sign in (c to copy)\u{1b}[22m\r\n",
                "{url}\r\n",
                "\r\n",
                "Paste code here if prompted > \r\n",
                "\u{1b}[32m✓\u{1b}[39m Login successful\r\n",
                "\r\n",
                "\u{1b}[1mYour token:\u{1b}[22m\r\n",
                "{token}\r\n",
                "\r\n",
                "Store this token securely. You won't be able to see it again.\r\n",
                "\u{1b}[?25h",
            ),
            url = AUTHORIZE_URL,
            token = fake_token(),
        ))
    }

    /// The same run, with the token wrapped mid-string by the renderer.
    ///
    /// This is the case that made a naive parse dangerous: the value is split
    /// across two lines and a regex that stopped at the first newline would have
    /// stored the first half as the whole credential.
    fn recorded_wrapped() -> Rendered {
        let token = fake_token();
        let (head, tail) = token.split_at(24);
        Rendered::of(&format!(
            "\u{1b}[1mYour token:\u{1b}[22m\r\n{head}\r\n{tail}\r\n\r\nUse this token in the CLAUDE_CODE_OAUTH_TOKEN environment variable.\r\n",
        ))
    }

    /// Every call a run made, and nothing that reaches a keychain.
    ///
    /// The same recorder credential.rs uses, for the same reason: a test that
    /// forgot to supply one would write into the developer's own keychain, and
    /// `store_minted_token` has no default.
    struct Recorder {
        calls: Mutex<Vec<(Vec<String>, String)>>,
        answer: Result<i32, ()>,
    }

    impl Recorder {
        fn ok() -> Self {
            Recorder {
                calls: Mutex::new(Vec::new()),
                answer: Ok(0),
            }
        }

        fn answering(answer: Result<i32, ()>) -> Self {
            Recorder {
                calls: Mutex::new(Vec::new()),
                answer,
            }
        }

        fn calls(&self) -> Vec<(Vec<String>, String)> {
            self.calls.lock().expect("no test poisons this").clone()
        }
    }

    impl Security for Recorder {
        fn run(&self, args: &[&str], stdin: &str) -> Result<i32, ()> {
            self.calls
                .lock()
                .expect("no test poisons this")
                .push((args.iter().map(|a| a.to_string()).collect(), stdin.to_string()));
            self.answer
        }
    }

    /// What the write half would be handed for a given value.
    ///
    /// The assertion the parse is checked through, and the reason no accessor on
    /// `Secret` exists: what the token *is* is established by what reaches the
    /// keychain, which is hex of the exact bytes. Nothing reads a value back out
    /// to compare it.
    fn hex_script_for(value: &str) -> String {
        let hex: String = value.bytes().map(|b| format!("{b:02x}")).collect();
        format!(
            "add-generic-password -s varnick -a {} -X {hex} -U\n",
            Kind::Subscription.keychain_account()
        )
    }

    // -----------------------------------------------------------------------
    // The parse
    // -----------------------------------------------------------------------

    #[test]
    fn the_token_reaches_the_keychain_exactly_as_it_was_printed() {
        let security = Recorder::ok();
        store_minted_token(&security, &recorded()).expect("the recorded shape holds a token");

        let calls = security.calls();
        assert_eq!(calls.len(), 1);
        let (args, stdin) = &calls[0];
        // Ticket 24's path, unchanged: the value is never an argument, and the
        // script is hex so nothing about it can be read as a second argument or
        // as a keychain to write into.
        assert_eq!(args, &["-i".to_string()]);
        assert_eq!(stdin, &hex_script_for(&fake_token()));
    }

    #[test]
    fn a_token_the_renderer_wrapped_is_stored_whole() {
        /*
          The failure this ticket exists to prevent, and the one that is silent:
          a value stored short authenticates nothing, and fails days later with
          an error that points at the credential rather than at the parse. The
          wrapped shape has to produce byte-for-byte the same script as the
          unwrapped one.
        */
        let security = Recorder::ok();
        store_minted_token(&security, &recorded_wrapped()).expect("a wrapped token is a token");
        let (_, stdin) = security.calls().remove(0);
        assert_eq!(stdin, hex_script_for(&fake_token()));
    }

    #[test]
    fn a_token_that_cannot_be_read_whole_is_refused_rather_than_stored() {
        /*
          A rendering change is the fragility that was named when this was
          filed. The designed consequence is that it stops the mint loudly here
          rather than putting a truncated credential in the keychain.

          Three ways it can go wrong, and all three refuse: the sentence that
          ends the value is reworded, something that is not a token follows the
          prefix, and the value is cut off by the process ending.
        */
        let no_terminator = Rendered::of(&format!("Your token:\r\n{}\r\n", fake_token()));
        let junk = Rendered::of(&format!(
            "Your token:\r\n{}!!not a token!!\r\nStore this token securely.\r\n",
            concat!("sk-", "ant-oat01-"),
        ));
        let bare_prefix = Rendered::of(concat!("sk-", "ant-oat01-"));

        for rendered in [no_terminator, junk, bare_prefix] {
            let security = Recorder::ok();
            assert_eq!(
                store_minted_token(&security, &rendered),
                Err("unreadable-token")
            );
            assert!(security.calls().is_empty());
        }
    }

    #[test]
    fn a_flow_that_printed_no_token_is_a_different_failure() {
        // The developer declined in the browser, the account has no
        // subscription, or the watchdog killed it. Nothing was printed, so
        // there is nothing to have read wrong — a different sentence, and a
        // different next action.
        let security = Recorder::ok();
        let nothing = Rendered::of(
            "Opening browser to sign in\r\nBrowser didn't open? Use the url below to sign in\r\n",
        );
        assert_eq!(store_minted_token(&security, &nothing), Err("no-token"));
        assert!(security.calls().is_empty());
    }

    #[test]
    fn a_keychain_that_refused_comes_back_as_the_keychains_own_tag() {
        // The mint does not re-describe a write that failed. `store_credential`
        // already has one tag per next action, and the sentence a developer
        // reads is authored once, in packages/harness/src/credentials.ts.
        let refused = Recorder::answering(Ok(45));
        assert_eq!(
            store_minted_token(&refused, &recorded()),
            Err("store-refused")
        );
        let missing = Recorder::answering(Err(()));
        assert_eq!(store_minted_token(&missing, &recorded()), Err("no-keychain"));
    }

    #[test]
    fn no_failure_path_can_carry_the_token() {
        /*
          The signature is the assertion — every error is a `&'static str`, so
          there is no `String` on this path for a value to be formatted into.
          Written out anyway, over every way a mint can fail, because "an error
          quotes the credential" is the failure this module exists to make
          impossible and a mint is where one is most likely to be in hand.
        */
        let token = fake_token();
        let attempts = [
            store_minted_token(&Recorder::answering(Ok(45)), &recorded()),
            store_minted_token(&Recorder::answering(Err(())), &recorded()),
            store_minted_token(
                &Recorder::ok(),
                &Rendered::of(&format!("Your token:\r\n{token}\r\n")),
            ),
        ];
        for attempt in attempts {
            let tag = attempt.expect_err("each of these fails");
            assert!(!tag.contains(&token));
            assert!(!token.contains(tag));
        }
    }

    #[test]
    fn nothing_that_prints_what_the_command_rendered_prints_the_token() {
        // The same rule `Secret` follows, on the type that holds a credential
        // between the pty and the keychain. A pty capture in a transcript is
        // how a real token escaped once already.
        let printed = format!("{:?}", recorded());
        assert!(!printed.contains(&fake_token()));
        assert_eq!(printed, "Rendered([redacted])");
    }

    // -----------------------------------------------------------------------
    // The URL, which is the one thing that crosses the bridge
    // -----------------------------------------------------------------------

    #[test]
    fn the_authorize_url_is_read_out_of_the_render() {
        assert_eq!(authorize_url_of(&recorded()), Some(AUTHORIZE_URL.to_string()));
    }

    #[test]
    fn the_url_is_never_the_token() {
        /*
          Load-bearing, because both are read out of the same buffer and only
          one of them may be shown. The URL is an OAuth request the developer's
          browser is about to make; the token is a credential.
        */
        let url = authorize_url_of(&recorded()).expect("the recorded shape holds one");
        assert!(!url.contains(&fake_token()));
        assert!(!url.contains(concat!("sk-", "ant-oat01-")));
    }

    #[test]
    fn a_url_that_is_not_the_authorization_is_not_offered_as_one() {
        // The flow prints other links — documentation, a status page — and
        // sending a developer to one of those to authorize would leave them
        // waiting on a callback nothing is going to make.
        let other = Rendered::of(
            "See https://docs.claude.com/en/docs/claude-code for more.\r\nOpening browser to sign in\r\n",
        );
        assert_eq!(authorize_url_of(&other), None);
    }

    #[test]
    fn a_flow_that_has_printed_nothing_yet_has_no_url_to_offer() {
        assert_eq!(authorize_url_of(&Rendered::of("")), None);
        assert_eq!(
            authorize_url_of(&Rendered::of("Opening browser to sign in\r\n")),
            None
        );
    }

    // -----------------------------------------------------------------------
    // The spawn
    // -----------------------------------------------------------------------

    #[test]
    fn the_command_is_two_words_and_there_is_no_way_to_add_a_third() {
        // ADR-0003's bounded exception is written around this being a constant.
        // A field anywhere that reached the argv would be a way to run
        // something else as varnick, on the host, outside the Sandbox.
        assert_eq!(MINT_ARGV, ["claude", "setup-token"]);
        let command = build_mint_command(std::path::Path::new("/tmp/varnick-mint-test"));
        assert_eq!(command.get_program(), "claude");
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(args, vec!["setup-token"]);
    }

    /*
      **Load-bearing since ticket 38, where it used to be defensive.** The agent
      now owns the clone's configuration — its hooks, its skills, its plugins —
      and the whole of what makes that safe is that nothing derived from the
      clone is ever executed outside the Sandbox. This process is the one
      Claude Code varnick runs outside it, so this assertion is the fence.
    */
    #[test]
    fn the_command_runs_outside_the_clone_and_reads_its_configuration_there() {
        /*
          This is what closes ADR-0003's stated concern rather than arguing
          around it. The rule exists because a session runs `SessionStart` hooks
          from the clone's `.claude/settings.json`, which the agent can write.
          Both the working directory and `CLAUDE_CONFIG_DIR` point at a
          directory varnick made for this run, so there is no such file to find.
        */
        let directory = std::path::Path::new("/tmp/varnick-mint-test");
        let command = build_mint_command(directory);
        assert_eq!(command.get_current_dir(), Some(directory));
        let config = command
            .get_envs()
            .find(|(name, _)| *name == std::ffi::OsStr::new(CONFIG_DIR_VAR))
            .expect("the config directory is always set");
        assert_eq!(config.1, Some(std::ffi::OsStr::new("/tmp/varnick-mint-test")));

        // And it is not the clone. A relative path, or the repository root,
        // would put the settings file back in reach.
        assert!(directory.is_absolute());
    }

    #[test]
    fn neither_credential_is_handed_to_the_thing_minting_one() {
        /*
          This process holds a credential and was launched from a terminal that
          may export another. A mint that inherited either would be
          authenticating with the thing it exists to produce — and worse, it
          would succeed in a way that hid a missing subscription until the agent
          started.
        */
        let command = build_mint_command(std::path::Path::new("/tmp/varnick-mint-test"));
        for cleared in [API_KEY_ENV_VAR, SUBSCRIPTION_ENV_VAR] {
            let entry = command
                .get_envs()
                .find(|(name, _)| *name == std::ffi::OsStr::new(cleared))
                .expect("both are named");
            assert_eq!(entry.1, None, "{cleared} must be removed, not set");
        }
    }

    #[test]
    fn control_sequences_are_not_part_of_any_value() {
        // The measurement that made a pipe useless also makes a naive parse
        // useless: the values arrive drawn into a UI.
        assert_eq!(plain_text("\u{1b}[2mdim\u{1b}[22m plain"), "dim plain");
        assert_eq!(plain_text("\u{1b}]0;a title\u{7}after"), "after");
        assert_eq!(plain_text("one\r\ntwo"), "one\ntwo");
        assert_eq!(plain_text("\u{1b}[?25lhidden"), "hidden");
    }

    #[test]
    fn a_token_is_a_prefix_and_a_body_and_nothing_else() {
        // A character outside the token alphabet is what a rendering change
        // looks like from here — a box border drawn around the value, most
        // likely. Refused, because a credential with a border character in it
        // is not the credential that was minted.
        let boxed = Rendered::of(&format!(
            "│ {} │\r\n\r\nStore this token securely.\r\n",
            fake_token()
        ));
        assert!(matches!(
            minted_token_of(&boxed),
            Some(Err("unreadable-token"))
        ));
    }

    #[test]
    fn the_render_carrying_on_talking_is_not_joined_onto_the_credential() {
        /*
          The other half of what makes the join safe. Whitespace inside the
          value is deleted, because the renderer wraps it; a *blank* line is the
          render moving on, and everything after it belongs to the sentence
          rather than to the token.

          Without the cut, prose made of ordinary letters would pass the shape
          check and be stored as part of the credential — which is the same
          failure as a truncation, wearing different clothes.
        */
        let chatty = Rendered::of(&format!(
            "{}\r\n\r\nkeep it somewhere safe\r\n\r\nStore this token securely.\r\n",
            fake_token()
        ));
        let security = Recorder::ok();
        store_minted_token(&security, &chatty).expect("the value itself is intact");
        let (_, stdin) = security.calls().remove(0);
        assert_eq!(stdin, hex_script_for(&fake_token()));
    }
}
