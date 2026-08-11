// The credential, host-side.
//
// This is the half where the value exists, and this process is outside the
// Sandbox by construction.
//
// What keeps the agent out of the Keychain is `denyRead` on $HOME, because that
// is where the Keychain file lives — *not* the deny on /usr/bin/security, which
// stops the binary being read and does not stop it running, and would not help
// anyway since the Security framework links in-process. That reasoning was
// believed for two rounds and is corrected in
// docs/adr/0003-containment-wraps-the-process-tree.md; the TypeScript half of
// this subsystem already says so and this one did not.
//
// A value *arrives* in one of two ways — read out of the keychain by
// `read_credential`, or handed in by `store_credential` when a developer pastes
// one into the window — and it *leaves* in exactly one, into the environment of
// the agent subprocess through `credential_env`. Storing is the newer half and
// the sharper one: it is the only path on which a credential crosses the IPC
// boundary at all, it crosses inbound only, and what comes back is `Ok(())` or a
// tag. Nothing about a write is echoed, and no test can reach a real keychain —
// `store_credential` takes a {@link Security} with no default.
//
// A value cannot leave by any other route, and that is enforced rather than
// remembered:
//
//   * `Secret` has no `Serialize`, so it cannot cross the IPC boundary into the
//     webview, which is where the transcript and the Session mirror live.
//   * `Secret` has a hand-written `Debug` that prints `[redacted]`, so `{:?}`,
//     `dbg!`, and a struct that derives `Debug` around it all print nothing.
//   * every error string here is a literal chosen by a match arm. Nothing that
//     `security` printed is ever forwarded, because an authentication failure is
//     the one place a credential is most likely to be echoed back at you.
//
// The webview learns two things from a read, and neither is the value: which
// store answered, and what was in it — an API key or a Claude subscription
// token. The kind is decided here, from what was resolved, and it decides which
// variable the agent is spawned with (ADR-0011).
//
// What this module deliberately does not do: read Claude Code's own
// `Claude Code-credentials` keychain item. It holds an OAuth pair that a host
// process can read, and the access token in it was measured expiring 74 minutes
// after it was read — so consuming it means varnick implementing token refresh
// and writing back into an item another process is concurrently using. varnick
// does not read another application's credential store; a developer runs
// `claude setup-token` and varnick reads a string.
//
// This module used to be its own `#[tauri::command]`. It is now one route of
// the bridge (bridge.rs), which is the same call over the same IPC — but there
// is one seam for the whole Harness rather than one command per capability, and
// `route_of` is where "the credential is answered in this process" stopped being
// a convention and became a unit test.

use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::Mutex;

use serde::Serialize;

/// The variable an API key is injected into.
/// Mirrored as `CREDENTIAL_ENV_VARS` in packages/harness/src/credentials.ts,
/// which is the only place the TypeScript half names it —
/// `CREDENTIAL_ENV_VAR_NAMES` in agent.ts is derived from that map.
pub const API_KEY_ENV_VAR: &str = "ANTHROPIC_API_KEY";

/// The variable a subscription token is injected into.
///
/// A first-class authentication variable to the Agent SDK, listed beside the
/// one above in its own credential table — which is what makes supporting a
/// subscription one substitution rather than a second authentication path.
pub const SUBSCRIPTION_ENV_VAR: &str = "CLAUDE_CODE_OAUTH_TOKEN";

/// The keychain the host looks in first, whichever kind it is holding.
const KEYCHAIN_SERVICE: &str = "varnick";

/// The account an API key is stored under.
const API_KEY_KEYCHAIN_ACCOUNT: &str = "anthropic-api-key";

/// The account a subscription token is stored under.
///
/// varnick's own item, beside the key. Deliberately *not* Claude Code's
/// `Claude Code-credentials`: that item holds an access token measured expiring
/// 74 minutes after it was read, so consuming it would mean varnick
/// implementing OAuth refresh and writing back into an item another process is
/// also using. `claude setup-token` mints a long-lived token for exactly this.
/// ADR-0011 records that as a boundary rather than a convenience, and nothing
/// in this file reads another application's credential store.
const SUBSCRIPTION_KEYCHAIN_ACCOUNT: &str = "claude-oauth-token";

/// The value. No `Serialize`, and a `Debug` that refuses.
pub struct Secret(String);

impl Secret {
    /// Take ownership of a value on its way in.
    ///
    /// The one constructor outside this module, and it exists for the write:
    /// the bridge pulls a string out of a request and has to put it somewhere
    /// that cannot be printed or serialised before it does anything else with
    /// it. Reading builds one internally and never needed this.
    pub fn new(value: String) -> Self {
        Secret(value)
    }
}

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret([redacted])")
    }
}

/// Which store answered. Reportable — the value it held is not.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Keychain,
    Env,
}

/// What the credential turned out to be. Reportable, and not a setting.
///
/// Decided here, from what was resolved, rather than declared by the developer
/// in a place that could disagree with the store — ADR-0011's third rejection.
/// Orthogonal to {@link Source}: either kind can come from either store.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    ApiKey,
    Subscription,
}

impl Kind {
    /// The variable the agent subprocess is spawned with.
    pub const fn env_var(self) -> &'static str {
        match self {
            Kind::ApiKey => API_KEY_ENV_VAR,
            Kind::Subscription => SUBSCRIPTION_ENV_VAR,
        }
    }

    /// The other one, which the spawn removes from the child's environment.
    ///
    /// This process inherits whatever launched it, which on a developer's
    /// machine may be an exported `ANTHROPIC_API_KEY`. Injecting a subscription
    /// token beside an inherited key would hand the agent two credentials and
    /// let it authenticate as the one varnick did not resolve.
    pub const fn cleared_env_var(self) -> &'static str {
        match self {
            Kind::ApiKey => SUBSCRIPTION_ENV_VAR,
            Kind::Subscription => API_KEY_ENV_VAR,
        }
    }

    /// The keychain account this kind is stored under.
    pub const fn keychain_account(self) -> &'static str {
        match self {
            Kind::ApiKey => API_KEY_KEYCHAIN_ACCOUNT,
            Kind::Subscription => SUBSCRIPTION_KEYCHAIN_ACCOUNT,
        }
    }
}

/// The kind a request named, or `None` for a name this host does not know.
///
/// Closed rather than defaulted, for the same reason the reading's kind is
/// required on the way out: a store that guessed would write the wrong item, and
/// the symptom is an agent spawned with a variable nobody resolved. The two
/// names are the ones `Kind` serialises to, mirrored in
/// packages/harness/src/credentials.ts as `CredentialKind`.
pub fn kind_of(name: &str) -> Option<Kind> {
    match name {
        "api-key" => Some(Kind::ApiKey),
        "subscription" => Some(Kind::Subscription),
        _ => None,
    }
}

/// The success payload of the `read_credential` command.
///
/// Two facts, and neither is the value. `Secret` has no `Serialize`, so there
/// is no shape here a value could ride in even if this struct were wrong.
#[derive(Debug, Serialize)]
pub struct Reading {
    pub source: Source,
    pub kind: Kind,
}

/// What the host is holding, if anything. Tauri managed state.
#[derive(Default)]
pub struct CredentialStore(Mutex<Option<(Source, Kind, Secret)>>);

/// What both stores had to say, as four answers.
///
/// A struct rather than four positional arguments because two of the four have
/// the same type and two more do: transposing a pair would compile, and the
/// symptom would be varnick spawning the agent with the wrong variable.
pub struct Stores {
    pub keychain_subscription: Result<Option<String>, ()>,
    pub keychain_api_key: Result<Option<String>, ()>,
    pub env_subscription: Option<String>,
    pub env_api_key: Option<String>,
}

/// The precedence rule, with the stores passed in.
///
/// Pure, so it is testable without a keychain — no test here or anywhere else
/// may read the developer's actual keychain. Two rules, in this order:
///
///   * **The keychain beats the environment.** Unchanged, and it is why a fresh
///     clone is told to use the keychain; the environment variables stay as the
///     escape hatch for CI and for a developer who already exports one.
///   * **Within a store, a subscription beats a key.** A developer holding both
///     is taken to prefer the plan they already pay for (ADR-0011). CI, which
///     has a key and no plan, is unaffected either way.
///
/// A keychain that could not be read is only reported as such once the
/// environment has also come up empty. A working credential in the environment
/// should not be overruled by a denied keychain prompt.
pub fn resolve(stores: Stores) -> Result<(Source, Kind, String), &'static str> {
    let keychain_failed = stores.keychain_subscription.is_err() || stores.keychain_api_key.is_err();

    // The table, read in precedence order. Each row is one cell of it.
    let candidates = [
        (
            Source::Keychain,
            Kind::Subscription,
            stores.keychain_subscription.ok().flatten(),
        ),
        (
            Source::Keychain,
            Kind::ApiKey,
            stores.keychain_api_key.ok().flatten(),
        ),
        (Source::Env, Kind::Subscription, stores.env_subscription),
        (Source::Env, Kind::ApiKey, stores.env_api_key),
    ];

    for (source, kind, value) in candidates {
        let Some(value) = value else { continue };
        let trimmed = value.trim();
        // An account created and never filled in is not a credential, and must
        // not shadow a working one further down the table.
        if !trimmed.is_empty() {
            return Ok((source, kind, trimmed.to_string()));
        }
    }

    if keychain_failed {
        Err("store-unreadable")
    } else {
        Err("nothing-stored")
    }
}

/// `Ok(None)` when nothing is stored, `Err(())` when the store would not answer.
///
/// Nothing `security` wrote to stderr is captured or returned. Exit code 44 is
/// its "item not found", which is an empty store rather than a broken one.
///
/// One account per call, and the two accounts fail independently: a denied
/// prompt on one item must not hide a credential sitting in the other.
fn read_keychain(account: &str) -> Result<Option<String>, ()> {
    let output = Command::new("/usr/bin/security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            account,
            "-w",
        ])
        .output();

    let output = match output {
        Ok(output) => output,
        // No `security` binary at all — a platform without a keychain rather
        // than a keychain that refused. Fall through to the environment.
        Err(_) => return Ok(None),
    };

    if output.status.success() {
        return Ok(Some(String::from_utf8_lossy(&output.stdout).into_owned()));
    }

    match output.status.code() {
        Some(44) => Ok(None),
        _ => Err(()),
    }
}

/// Read the credential and hold it. Answers with which store replied.
///
/// The failure is a `&'static str` tag and nothing else, which is what makes
/// "no secret crosses the bridge" a property of the signature: there is no
/// `String` on this error path for a value to be formatted into. The prose a
/// developer reads is authored once, in packages/harness/src/credentials.ts, so
/// the two halves cannot drift into two different first-run instructions.
///
/// ## `keychain` is false in exactly one varnick
///
/// A **Preview**. Its parent host already holds a Credential and injects it
/// into the environment this reads (`preview_launch` in preview.rs), which is
/// the arrangement the primary agent has — so opening the Keychain here would
/// be a second process reaching for a secret that has already arrived. The
/// answer is then `Source::Env`, which is true and is what the window prints.
///
/// It is not a hardening of the Keychain: a Preview's host is not confined and
/// could run `security` itself. It is the removal of a *reason* to, which is
/// what makes "no new process comes to hold a secret" a description of the
/// code rather than a hope. See
/// docs/adr/0019-a-preview-is-confined-by-the-live-trees-policy.md.
///
/// A Preview whose parent had nothing to inject gets `nothing-stored` and the
/// first-run screen, rather than silently authenticating as whoever this
/// machine's Keychain belongs to.
pub fn read_credential(store: &CredentialStore, keychain: bool) -> Result<Reading, &'static str> {
    let ask_keychain = |account: &str| {
        if keychain {
            read_keychain(account)
        } else {
            Ok(None)
        }
    };
    let (source, kind, value) = resolve(Stores {
        keychain_subscription: ask_keychain(Kind::Subscription.keychain_account()),
        keychain_api_key: ask_keychain(Kind::ApiKey.keychain_account()),
        env_subscription: std::env::var(SUBSCRIPTION_ENV_VAR).ok(),
        env_api_key: std::env::var(API_KEY_ENV_VAR).ok(),
    })?;

    match store.0.lock() {
        Ok(mut held) => {
            *held = Some((source, kind, Secret(value)));
            Ok(Reading { source, kind })
        }
        // A poisoned lock means the host cannot vouch for what it is holding.
        // Reporting a read it cannot back up would be worse than reporting none.
        Err(_) => Err("store-unreadable"),
    }
}

/// `/usr/bin/security`, as a port.
///
/// A trait rather than a `Command` built where it is needed, and the reason is
/// the same one `openSecretsStore` takes a `SecretsKeychain` with no default: a
/// test that forgot to supply one would write into the developer's own login
/// Keychain, and `store_credential` has no way to reach the binary on its own.
/// The read half's seam is `resolve`, which is pure because the precedence rule
/// has no keychain in it; a write is nothing but the keychain, so the seam has
/// to be here.
pub trait Security {
    /// Run `security` with these arguments and this stdin, and answer with its
    /// exit code.
    ///
    /// Nothing it printed comes back — not stdout, not stderr. The one command
    /// on this machine that handles credentials is the one most likely to echo
    /// one, and every failure a caller can report is chosen by a match arm.
    fn run(&self, args: &[&str], stdin: &str) -> Result<i32, ()>;
}

/// The real one. The only implementation that touches a keychain.
pub struct SystemSecurity;

impl Security for SystemSecurity {
    fn run(&self, args: &[&str], stdin: &str) -> Result<i32, ()> {
        let mut child = Command::new("/usr/bin/security")
            .args(args)
            .stdin(Stdio::piped())
            // Captured and dropped. `security` writes its complaints here, and
            // an authentication store's complaint is the likeliest place for a
            // credential to be echoed back at you.
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| ())?;

        child
            .stdin
            .take()
            .ok_or(())?
            .write_all(stdin.as_bytes())
            .map_err(|_| ())?;

        child.wait().map_err(|_| ())?.code().ok_or(())
    }
}

/// The one line `security -i` is driven with, and the whole of it.
///
/// Hex, so the only part of this that varies is `[0-9a-f]+` and there is
/// nothing to quote: `security -i` has its own tokeniser, and a value carrying
/// a space or a quote would otherwise be parsed as two arguments. `-X` sets the
/// item's data to the bytes the hex decodes to, so what lands in the keychain is
/// the value itself and a developer opening Keychain Access sees their own
/// token. `-U` updates in place when the item already exists, so storing over
/// one is a single call rather than a delete and an add with a gap between them.
///
/// The same mechanism packages/harness/src/secrets.ts uses, and for the same
/// two reasons. The first is that `/bin/ps` is not on the Sandbox's denied list,
/// so a value in argv is readable by every user on the machine for as long as
/// the process lives. The second is narrower and has bitten this project twice:
/// `add-generic-password` takes the keychain as a *positional* argument, so a
/// `-w VALUE` written before it is read as the keychain to write into. This
/// command ends at a flag and names no keychain at all.
fn store_script(account: &str, value: &str) -> String {
    let hex: String = value.bytes().map(|b| format!("{b:02x}")).collect();
    format!("add-generic-password -s {KEYCHAIN_SERVICE} -a {account} -X {hex} -U\n")
}

/// Why a value cannot be stored as it stands, or `None` when it can.
///
/// The set this accepts is printable ASCII with no whitespace around it, which
/// is every API key and every subscription token and is deliberately not
/// everything. `find-generic-password -w` — which is how the read half of this
/// module gets the value back — prints an item as hex the moment its data holds
/// a byte outside printable ASCII, and there is no flag saying which of the two
/// forms you were handed. A credential stored outside that set would be handed
/// to the agent as a string of hex digits and fail as an authentication error
/// far from the cause.
///
/// The value is never quoted into the answer; the answer is a tag.
fn value_problem(value: &str) -> Option<&'static str> {
    if value.is_empty() {
        return Some("nothing-pasted");
    }
    if !value.chars().all(|c| (' '..='~').contains(&c)) {
        return Some("unstorable-value");
    }
    None
}

/// Write the credential for one kind into the keychain.
///
/// The one direction a value moves other than into the agent's environment, and
/// it is one-way: this answers `Ok(())` or a `&'static str` tag, so there is no
/// shape on either path a value could ride back in. Nothing here logs, prints
/// or formats the value, and the tag a caller reports is chosen by a match arm.
///
/// Which kind is written is the developer's choice; which kind is *resolved*
/// stays the host's, decided by what it finds on the next read. ADR-0011 refuses
/// a stored preference, and this is not one — nothing records that this account
/// was the one written, and the read that follows a store goes through the same
/// precedence table as a read on any other launch.
pub fn store_credential(
    security: &dyn Security,
    kind: Kind,
    value: Secret,
) -> Result<(), &'static str> {
    // Trimmed on the way in because `resolve` trims on the way out: a value
    // stored with a newline around it already works, and trimming here means
    // the item a developer opens by hand holds what they meant to paste.
    let trimmed = value.0.trim();
    if let Some(problem) = value_problem(trimmed) {
        return Err(problem);
    }

    let script = store_script(kind.keychain_account(), trimmed);
    match security.run(&["-i"], &script) {
        Ok(0) => {
            /*
              The keychain has it, so the scratch copy a failed parse left behind
              is spent — see `leave_setup_key` in mint.rs.

              Here rather than at the paste, and on *any* successful store rather
              than only one whose value came out of that file, because the thing
              being cleaned up is a live credential sitting in plaintext and the
              developer's route to being finished with it is not knowable from
              here. Someone who gave up on the file and pasted from a terminal
              instead has still finished with it.

              Deliberately not part of the answer. A store that worked is a store
              that worked; a file that would not delete is not a reason to tell
              them otherwise, and the next successful store tries again.
            */
            crate::mint::forget_setup_key();
            Ok(())
        }
        // The keychain answered and did not do it. Which code it chose is not
        // forwarded: the developer's next action is the same either way.
        Ok(_) => Err("store-refused"),
        // No `security` binary at all — a platform with no keychain, rather than
        // a keychain that refused. The read half falls through to the
        // environment on this; a write has nowhere to fall through to.
        Err(()) => Err("no-keychain"),
    }
}

/// What the spawn puts into the agent's environment, and what it takes out.
///
/// Three fields and only one of them is secret. The kind is *not* secret and
/// belongs beside the value rather than inside `Secret`, which is why this type
/// exists at all: `Secret` keeps its refusal to serialise or print, and this
/// carries the two names that decide where the value goes.
///
/// No `Serialize`, and a hand-written `Debug` that prints `[redacted]` — the
/// same two rules `Secret` follows, because this is the type that holds the
/// value outside it.
pub struct Injection {
    /// The variable the agent subprocess is spawned with.
    pub variable: &'static str,
    /// The other authentication variable, removed from the child's
    /// environment. See {@link Kind::cleared_env_var}.
    pub cleared: &'static str,
    pub value: String,
}

impl std::fmt::Debug for Injection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Injection")
            .field("variable", &self.variable)
            .field("cleared", &self.cleared)
            .field("value", &"[redacted]")
            .finish()
    }
}

/// The environment the agent subprocess is spawned with.
///
/// The one way the value leaves this module, and it goes into a child process's
/// environment rather than into any string the host keeps. Two callers, and
/// both are spawns of the same shape: the agent in agent.rs, and a **Preview**
/// in preview.rs — which is a varnick that will hand it on to an agent of its
/// own. Nothing that is not a spawn may call it.
///
/// The split that spawn implements, recorded here because this is the function
/// that would be misused: the Harness runtime holds the Sandbox, so the obvious
/// reading is that it should also spawn the agent — which would mean sending
/// the credential across the bridge, and that is exactly what may never happen.
/// `EstablishedSandbox.wrap()` hands back argv, an environment overlay and a
/// working directory, so the runtime computes the wrapping (no secret) and this
/// process does the spawning (the secret, still here). The agent stays inside
/// srt either way, because the wrapping is in the argv.
pub fn credential_env(store: &CredentialStore) -> Option<Injection> {
    let held = store.0.lock().ok()?;
    held.as_ref().map(|(_, kind, secret)| Injection {
        variable: kind.env_var(),
        cleared: kind.cleared_env_var(),
        value: secret.0.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::{
        credential_env, kind_of, resolve, store_credential, store_script, CredentialStore, Kind,
        Secret, Security, Source, Stores, API_KEY_ENV_VAR, KEYCHAIN_SERVICE, SUBSCRIPTION_ENV_VAR,
    };
    use std::sync::Mutex;

    /*
      The precedence table, and it is the whole of it.

      `resolve` is pure so that these cases can be written without a keychain —
      no test here or anywhere else in this repository may read or write the
      developer's own. Four inputs now rather than two, because a credential has
      a Kind as well as a Source (ADR-0011) and either kind can be in either
      store. The seven cases that predate the kind are all still here; each of
      them is now an api-key case, which is what it always was.
    */

    /// Nothing anywhere. Every case below names only what it is about.
    fn nothing() -> Stores {
        Stores {
            keychain_subscription: Ok(None),
            keychain_api_key: Ok(None),
            env_subscription: None,
            env_api_key: None,
        }
    }

    fn keychain_api_key(value: &str) -> Stores {
        Stores {
            keychain_api_key: Ok(Some(value.to_string())),
            ..nothing()
        }
    }

    fn keychain_subscription(value: &str) -> Stores {
        Stores {
            keychain_subscription: Ok(Some(value.to_string())),
            ..nothing()
        }
    }

    fn env_api_key(value: &str) -> Stores {
        Stores {
            env_api_key: Some(value.to_string()),
            ..nothing()
        }
    }

    fn env_subscription(value: &str) -> Stores {
        Stores {
            env_subscription: Some(value.to_string()),
            ..nothing()
        }
    }

    // -----------------------------------------------------------------------
    // The keychain beats the environment. Unchanged, and still the first rule.
    // -----------------------------------------------------------------------

    #[test]
    fn the_keychain_wins_when_both_answer() {
        let resolved = resolve(Stores {
            keychain_api_key: Ok(Some("from-keychain".into())),
            env_api_key: Some("from-env".into()),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::ApiKey, "from-keychain".to_string()))
        );
    }

    #[test]
    fn the_environment_answers_when_the_keychain_is_empty() {
        let resolved = resolve(env_api_key("from-env"));
        assert_eq!(
            resolved,
            Ok((Source::Env, Kind::ApiKey, "from-env".to_string()))
        );
    }

    #[test]
    fn a_trailing_newline_from_security_is_not_part_of_the_credential() {
        let resolved = resolve(keychain_api_key("from-keychain\n"));
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::ApiKey, "from-keychain".to_string()))
        );
        // The same for a token: `security -w` ends its output with a newline
        // whichever account it read.
        let resolved = resolve(keychain_subscription("a-token\n"));
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::Subscription, "a-token".to_string()))
        );
    }

    #[test]
    fn an_empty_entry_counts_as_nothing_stored() {
        assert_eq!(resolve(keychain_api_key("   ")), Err("nothing-stored"));
        assert_eq!(resolve(keychain_subscription("   ")), Err("nothing-stored"));
    }

    #[test]
    fn nothing_anywhere_is_the_first_run_case() {
        assert_eq!(resolve(nothing()), Err("nothing-stored"));
    }

    #[test]
    fn a_keychain_that_refused_is_a_different_failure() {
        assert_eq!(
            resolve(Stores {
                keychain_api_key: Err(()),
                ..nothing()
            }),
            Err("store-unreadable")
        );
        // Either account refusing is the same problem with the same fix: the
        // developer allows varnick to read the item.
        assert_eq!(
            resolve(Stores {
                keychain_subscription: Err(()),
                ..nothing()
            }),
            Err("store-unreadable")
        );
    }

    #[test]
    fn a_keychain_that_refused_does_not_overrule_a_working_environment() {
        let resolved = resolve(Stores {
            keychain_api_key: Err(()),
            keychain_subscription: Err(()),
            env_api_key: Some("from-env".into()),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Env, Kind::ApiKey, "from-env".to_string()))
        );
    }

    // -----------------------------------------------------------------------
    // Within a store, a subscription beats a key. ADR-0011.
    // -----------------------------------------------------------------------

    #[test]
    fn a_subscription_in_the_keychain_beats_a_key_beside_it() {
        // A developer holding both is taken to prefer the plan they already pay
        // for. A harness that billed per request with an unused plan beside it
        // would be making that cost decision on their behalf, silently.
        let resolved = resolve(Stores {
            keychain_subscription: Ok(Some("a-token".into())),
            keychain_api_key: Ok(Some("a-key".into())),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::Subscription, "a-token".to_string()))
        );
    }

    #[test]
    fn a_subscription_in_the_environment_beats_a_key_beside_it() {
        let resolved = resolve(Stores {
            env_subscription: Some("a-token".into()),
            env_api_key: Some("a-key".into()),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Env, Kind::Subscription, "a-token".to_string()))
        );
    }

    #[test]
    fn the_keychain_still_wins_across_kinds() {
        // The two rules in the order they apply: the store first, the kind
        // within it. A key in the keychain beats a token in the environment,
        // because the environment is the escape hatch — the way a developer or
        // a CI job overrides what is stored, and it cannot override by being
        // preferred.
        let resolved = resolve(Stores {
            keychain_api_key: Ok(Some("a-key".into())),
            env_subscription: Some("a-token".into()),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::ApiKey, "a-key".to_string()))
        );
    }

    #[test]
    fn either_kind_comes_from_either_store() {
        // Kind and Source are orthogonal, so all four cells of the table are
        // reachable. Two of them are covered above; these are the other two.
        assert_eq!(
            resolve(keychain_subscription("a-token")),
            Ok((Source::Keychain, Kind::Subscription, "a-token".to_string()))
        );
        assert_eq!(
            resolve(env_subscription("a-token")),
            Ok((Source::Env, Kind::Subscription, "a-token".to_string()))
        );
    }

    #[test]
    fn an_empty_subscription_entry_does_not_shadow_the_key_beside_it() {
        // An account created and never filled in is not a subscription. Letting
        // it win would be a developer with a working key and an empty token
        // item, told nothing is stored.
        let resolved = resolve(Stores {
            keychain_subscription: Ok(Some("\n".into())),
            keychain_api_key: Ok(Some("a-key".into())),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::ApiKey, "a-key".to_string()))
        );
    }

    #[test]
    fn one_account_that_refused_does_not_hide_the_other() {
        // Two reads now, and they fail independently. A denied prompt on the
        // token item must not deny a key that is sitting right there.
        let resolved = resolve(Stores {
            keychain_subscription: Err(()),
            keychain_api_key: Ok(Some("a-key".into())),
            ..nothing()
        });
        assert_eq!(
            resolved,
            Ok((Source::Keychain, Kind::ApiKey, "a-key".to_string()))
        );
    }

    // -----------------------------------------------------------------------
    // The kind decides what the agent is spawned with
    // -----------------------------------------------------------------------

    #[test]
    fn the_kind_names_the_variable_the_agent_is_spawned_with() {
        // Both are first-class authentication variables to the Agent SDK, which
        // lists them side by side — so this is one substitution rather than a
        // second authentication path.
        assert_eq!(Kind::ApiKey.env_var(), "ANTHROPIC_API_KEY");
        assert_eq!(Kind::Subscription.env_var(), "CLAUDE_CODE_OAUTH_TOKEN");
    }

    #[test]
    fn each_kind_names_the_other_so_the_spawn_can_take_it_away() {
        assert_eq!(Kind::ApiKey.cleared_env_var(), SUBSCRIPTION_ENV_VAR);
        assert_eq!(Kind::Subscription.cleared_env_var(), API_KEY_ENV_VAR);
        // The two are never the same variable, or one kind's injection would
        // remove itself.
        assert_ne!(API_KEY_ENV_VAR, SUBSCRIPTION_ENV_VAR);
    }

    #[test]
    fn each_kind_is_stored_under_its_own_keychain_account() {
        assert_eq!(Kind::ApiKey.keychain_account(), "anthropic-api-key");
        assert_eq!(Kind::Subscription.keychain_account(), "claude-oauth-token");
    }

    #[test]
    fn a_kind_this_host_does_not_know_is_not_guessed_at() {
        // Closed rather than defaulted: a store that guessed would write the
        // wrong item, and nothing about the result would say so until the next
        // launch resolved a credential the developer never stored.
        assert_eq!(kind_of("api-key"), Some(Kind::ApiKey));
        assert_eq!(kind_of("subscription"), Some(Kind::Subscription));
        assert_eq!(kind_of("oauth"), None);
        assert_eq!(kind_of(""), None);
        // And the two names are the ones the reading serialises to, so the
        // window sends back exactly what it was told.
        for kind in [Kind::ApiKey, Kind::Subscription] {
            let name = serde_json::to_value(kind).unwrap();
            assert_eq!(kind_of(name.as_str().unwrap()), Some(kind));
        }
    }

    #[test]
    fn a_reading_that_crosses_the_bridge_is_the_source_and_the_kind() {
        // The whole vocabulary the webview gets. `Secret` has no `Serialize`,
        // so there is no shape here a value could ride in even by accident.
        let reading = super::Reading {
            source: Source::Keychain,
            kind: Kind::Subscription,
        };
        assert_eq!(
            serde_json::to_value(reading).unwrap(),
            serde_json::json!({ "source": "keychain", "kind": "subscription" })
        );
    }

    /// A store holding one credential, built without touching a keychain.
    fn holding(kind: Kind, value: &str) -> CredentialStore {
        CredentialStore(Mutex::new(Some((
            Source::Keychain,
            kind,
            Secret(value.to_string()),
        ))))
    }

    #[test]
    fn a_subscription_is_injected_as_the_token_and_never_as_a_key() {
        let injection = credential_env(&holding(Kind::Subscription, "a-token"))
            .expect("the store is holding one");
        assert_eq!(injection.variable, SUBSCRIPTION_ENV_VAR);
        assert_eq!(injection.value, "a-token");
        // And the other variable is named so the spawn can remove it. The host
        // process may itself have been launched with an exported
        // ANTHROPIC_API_KEY, and a child that inherited one beside an injected
        // token would authenticate as somebody varnick did not resolve.
        assert_eq!(injection.cleared, API_KEY_ENV_VAR);
    }

    #[test]
    fn a_key_is_injected_exactly_as_it_always_was() {
        let injection =
            credential_env(&holding(Kind::ApiKey, "a-key")).expect("the store is holding one");
        assert_eq!(injection.variable, API_KEY_ENV_VAR);
        assert_eq!(injection.value, "a-key");
        assert_eq!(injection.cleared, SUBSCRIPTION_ENV_VAR);
    }

    #[test]
    fn an_empty_store_injects_nothing_rather_than_an_empty_credential() {
        // A spawn with no credential refuses. It never starts a process that
        // would fail to authenticate a moment later.
        assert!(credential_env(&CredentialStore::default()).is_none());
    }

    #[test]
    fn nothing_that_prints_an_injection_prints_the_value() {
        // The same rule `Secret` enforces, on the type that carries the value
        // out of this module. A `{:?}` in a log line is the likeliest way a
        // credential escapes, and it is refused here rather than remembered.
        let injection = credential_env(&holding(Kind::Subscription, "a-token"))
            .expect("the store is holding one");
        let printed = format!("{injection:?}");
        assert!(!printed.contains("a-token"));
        assert!(printed.contains("[redacted]"));
    }

    #[test]
    fn nothing_that_prints_a_secret_prints_the_value() {
        assert_eq!(
            format!("{:?}", Secret("a-token".to_string())),
            "Secret([redacted])"
        );
    }

    // -----------------------------------------------------------------------
    // The write
    //
    // A developer with an empty Keychain pastes a credential into the window
    // and the host writes it. Every test below runs against a {@link Security}
    // a test supplies, which is what makes "no test touches a real keychain" a
    // property of the signature rather than a rule anyone has to remember:
    // `store_credential` has no default and cannot reach `/usr/bin/security` on
    // its own.
    // -----------------------------------------------------------------------

    /// A value shaped like a real token, used to prove it never comes back out.
    ///
    /// Assembled rather than written out: the value is invented, but its shape
    /// is one every secret scanner flags, and a literal of that shape blocks
    /// pushing for this repository and every fork of it.
    fn looks_like_a_key() -> String {
        ["sk-", "ant-api03-NEVER-LET-THIS-OUT"].concat()
    }

    /// Every call a run made, and nothing that reaches a keychain.
    struct Recorder {
        calls: Mutex<Vec<(Vec<String>, String)>>,
        answer: Result<i32, ()>,
    }

    impl Recorder {
        fn answering(answer: Result<i32, ()>) -> Self {
            Recorder {
                calls: Mutex::new(Vec::new()),
                answer,
            }
        }

        fn ok() -> Self {
            Recorder::answering(Ok(0))
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

    #[test]
    fn the_value_is_never_an_argument() {
        // `/bin/ps` is not denied by the Sandbox policy, so a value on the
        // command line is readable by every user on the machine for as long as
        // the process lives. `security -i` reads its commands from stdin, which
        // is the mechanism packages/harness/src/secrets.ts already uses.
        let security = Recorder::ok();
        let value = looks_like_a_key();
        store_credential(&security, Kind::ApiKey, Secret::new(value.clone())).expect("a clean run");

        let calls = security.calls();
        assert_eq!(calls.len(), 1);
        let (args, stdin) = &calls[0];
        assert_eq!(args, &["-i".to_string()]);
        for arg in args {
            assert!(!arg.contains(&value));
        }
        // And not in the script either, which is hex rather than the string.
        assert!(!stdin.contains(&value));
    }

    #[test]
    fn the_script_writes_the_bytes_the_developer_pasted() {
        // `-X` sets the item's data to what the hex decodes to, so a developer
        // opening Keychain Access sees their own token rather than hex digits.
        let hex = "a-token"
            .bytes()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        assert_eq!(
            store_script(Kind::Subscription.keychain_account(), "a-token"),
            format!(
                "add-generic-password -s {KEYCHAIN_SERVICE} -a claude-oauth-token -X {hex} -U\n"
            ),
        );
    }

    #[test]
    fn nothing_positional_follows_the_command() {
        /*
          `add-generic-password` takes the keychain as a *positional* argument,
          so a value written where one is expected lands in whatever keychain
          follows. That has put a credential in the wrong keychain twice in this
          project's history.

          The script therefore ends at a flag, and the only free-standing token
          in it is hex — which cannot be read as a path, and cannot be read as
          two arguments however it is tokenised.
        */
        for kind in [Kind::ApiKey, Kind::Subscription] {
            // A value chosen to break a command line: spaces, a quote, and a
            // string that would be read as a path if it ever reached argv.
            let script = store_script(kind.keychain_account(), "a value 'with' /some/keychain");
            let tokens: Vec<&str> = script.split_whitespace().collect();

            // Eight tokens, whatever the value was. A value that could add a
            // ninth is a value that could name a keychain.
            assert_eq!(tokens.len(), 8);
            assert_eq!(tokens[0], "add-generic-password");
            assert_eq!(tokens[1], "-s");
            assert_eq!(tokens[2], KEYCHAIN_SERVICE);
            assert_eq!(tokens[3], "-a");
            assert_eq!(tokens[4], kind.keychain_account());
            assert_eq!(tokens[5], "-X");
            // The one token the value decides, and it is hex.
            assert!(tokens[6].chars().all(|c| c.is_ascii_hexdigit()));
            // Ends at a flag. Nothing follows for `security` to read as the
            // keychain to write into.
            assert_eq!(tokens[7], "-U");

            // `-w` is the flag that takes a value on the command line. It is
            // right for a developer typing the command by hand, where `security`
            // then prompts for the value, and wrong everywhere here.
            assert!(!tokens.contains(&"-w"));
        }
    }

    #[test]
    fn each_kind_is_written_to_its_own_account() {
        for (kind, account) in [
            (Kind::ApiKey, "anthropic-api-key"),
            (Kind::Subscription, "claude-oauth-token"),
        ] {
            let security = Recorder::ok();
            store_credential(&security, kind, Secret::new("a-value".into())).expect("a clean run");
            let (_, stdin) = security.calls().remove(0);
            assert!(stdin.contains(&format!("-a {account} ")));
        }
    }

    #[test]
    fn a_paste_with_nothing_in_it_never_reaches_the_keychain() {
        // An item created and never filled in is not a credential — `resolve`
        // already refuses to let one shadow a working credential beside it — so
        // writing one would produce a store that reads back as empty.
        for empty in ["", "   ", "\n"] {
            let security = Recorder::ok();
            assert_eq!(
                store_credential(&security, Kind::ApiKey, Secret::new(empty.into())),
                Err("nothing-pasted")
            );
            assert!(security.calls().is_empty());
        }
    }

    #[test]
    fn a_value_security_would_hand_back_hex_is_refused_rather_than_stored() {
        /*
          `find-generic-password -w` prints the item as hex the moment its data
          holds a byte outside printable ASCII, with no flag saying which of the
          two forms you were handed — measured in
          packages/harness/src/secrets.ts, which refuses the same set for the
          same reason. The read half of this module would hand such a credential
          to the agent as a string of hex digits, and it would fail as an
          authentication error far from the cause.
        */
        for bad in ["a\nb", "a\tb", "café"] {
            let security = Recorder::ok();
            assert_eq!(
                store_credential(&security, Kind::Subscription, Secret::new(bad.into())),
                Err("unstorable-value")
            );
            assert!(security.calls().is_empty());
        }
    }

    #[test]
    fn a_value_is_trimmed_on_the_way_in_because_it_is_trimmed_on_the_way_out() {
        // `resolve` trims what it reads, so a value stored with a newline around
        // it already works. Trimming here means the item a developer opens by
        // hand holds what they meant to paste.
        let security = Recorder::ok();
        store_credential(&security, Kind::ApiKey, Secret::new("  a-token\n".into()))
            .expect("a clean run");
        let (_, stdin) = security.calls().remove(0);
        assert_eq!(
            stdin,
            store_script(Kind::ApiKey.keychain_account(), "a-token")
        );
    }

    #[test]
    fn a_keychain_that_refused_is_a_tag_and_never_what_it_printed() {
        let security = Recorder::answering(Ok(45));
        assert_eq!(
            store_credential(&security, Kind::ApiKey, Secret::new("a-token".into())),
            Err("store-refused")
        );
    }

    #[test]
    fn no_security_binary_at_all_is_a_different_failure() {
        // A platform with no keychain, rather than a keychain that said no. The
        // read half falls through to the environment on this; a write has
        // nowhere to fall through to and says so.
        let security = Recorder::answering(Err(()));
        assert_eq!(
            store_credential(&security, Kind::Subscription, Secret::new("a-token".into())),
            Err("no-keychain")
        );
    }

    #[test]
    fn no_failure_path_can_carry_the_value() {
        /*
          The signature is the assertion — every error here is a `&'static str`,
          so there is no `String` on this path for a value to be formatted into.
          Written out anyway, over every way a store can fail, because "an error
          quotes the credential" is the failure this module exists to make
          impossible and the one an authentication path is likeliest to produce.
        */
        let value = looks_like_a_key();
        let attempts = [
            store_credential(&Recorder::answering(Ok(45)), Kind::ApiKey, Secret::new(value.clone())),
            store_credential(&Recorder::answering(Err(())), Kind::ApiKey, Secret::new(value.clone())),
            store_credential(
                &Recorder::ok(),
                Kind::ApiKey,
                Secret::new(format!("{value}\n{value}")),
            ),
            store_credential(&Recorder::ok(), Kind::ApiKey, Secret::new("  ".into())),
        ];
        for attempt in attempts {
            let tag = attempt.expect_err("each of these fails");
            assert!(!tag.contains(&value));
        }
    }

    #[test]
    fn a_store_answers_with_nothing_at_all() {
        // `Ok(())`, not `Ok(Reading)` and not `Ok(String)`. There is no shape on
        // the success path a value could ride back in either.
        let security = Recorder::ok();
        assert_eq!(
            store_credential(&security, Kind::ApiKey, Secret::new("a-token".into())),
            Ok(())
        );
    }
}
