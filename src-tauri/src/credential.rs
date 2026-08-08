// The credential, host-side.
//
// This is the half where the value exists. The agent cannot reach it: srt
// denies it read on /usr/bin/security, and this process is outside that sandbox
// by construction (docs/adr/0003-containment-wraps-the-process-tree.md).
//
// The value leaves this module in exactly one direction — into the environment
// of the agent subprocess, through `credential_env`. It cannot leave in any
// other, and that is enforced rather than remembered:
//
//   * `Secret` has no `Serialize`, so it cannot cross the IPC boundary into the
//     webview, which is where the transcript and the Session mirror live.
//   * `Secret` has a hand-written `Debug` that prints `[redacted]`, so `{:?}`,
//     `dbg!`, and a struct that derives `Debug` around it all print nothing.
//   * every error string here is a literal chosen by a match arm. Nothing that
//     `security` printed is ever forwarded, because an authentication failure is
//     the one place a credential is most likely to be echoed back at you.
//
// The webview learns one thing from a read: which store answered.
//
// This module used to be its own `#[tauri::command]`. It is now one route of
// the bridge (bridge.rs), which is the same call over the same IPC — but there
// is one seam for the whole Harness rather than one command per capability, and
// `route_of` is where "the credential is answered in this process" stopped being
// a convention and became a unit test.

use std::process::Command;
use std::sync::Mutex;

use serde::Serialize;

/// The variable the agent subprocess is spawned with.
/// Mirrored as CREDENTIAL_ENV_VAR in packages/harness/src/credentials.ts.
pub const ENV_VAR: &str = "ANTHROPIC_API_KEY";

/// The keychain item the host looks for first.
const KEYCHAIN_SERVICE: &str = "varnick";
const KEYCHAIN_ACCOUNT: &str = "anthropic-api-key";

/// The value. No `Serialize`, and a `Debug` that refuses.
pub struct Secret(String);

impl std::fmt::Debug for Secret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Secret([redacted])")
    }
}

/// Which store answered. This, and only this, is what the webview is told.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Keychain,
    Env,
}

/// The success payload of the `read_credential` command.
#[derive(Debug, Serialize)]
pub struct Reading {
    pub source: Source,
}

/// What the host is holding, if anything. Tauri managed state.
#[derive(Default)]
pub struct CredentialStore(Mutex<Option<(Source, Secret)>>);

/// The precedence rule, with the stores passed in.
///
/// Pure, so it is testable without a keychain — no test here or anywhere else
/// may read the developer's actual keychain. The keychain wins over the
/// environment because it is the store a fresh clone is told to use; the
/// environment variable stays as the escape hatch for CI and for a developer
/// who already exports one.
///
/// A keychain that could not be read is only reported as such once the
/// environment has also come up empty. A working `ANTHROPIC_API_KEY` should not
/// be overruled by a denied keychain prompt.
pub fn resolve(
    keychain: Result<Option<String>, ()>,
    environment: Option<String>,
) -> Result<(Source, String), &'static str> {
    let keychain_failed = keychain.is_err();

    if let Ok(Some(value)) = keychain {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Ok((Source::Keychain, trimmed.to_string()));
        }
    }

    if let Some(value) = environment {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Ok((Source::Env, trimmed.to_string()));
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
fn read_keychain() -> Result<Option<String>, ()> {
    let output = Command::new("/usr/bin/security")
        .args([
            "find-generic-password",
            "-s",
            KEYCHAIN_SERVICE,
            "-a",
            KEYCHAIN_ACCOUNT,
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
pub fn read_credential(store: &CredentialStore) -> Result<Reading, &'static str> {
    let (source, value) = resolve(read_keychain(), std::env::var(ENV_VAR).ok())?;

    match store.0.lock() {
        Ok(mut held) => {
            *held = Some((source, Secret(value)));
            Ok(Reading { source })
        }
        // A poisoned lock means the host cannot vouch for what it is holding.
        // Reporting a read it cannot back up would be worse than reporting none.
        Err(_) => Err("store-unreadable"),
    }
}

/// The environment the agent subprocess is spawned with.
///
/// The one way the value leaves this module, and it goes into a child process's
/// environment rather than into any string the host keeps. Used by the spawn
/// (ticket 03); nothing else may call it.
///
/// A note for that spawn, since the bridge makes it a live question: the Harness
/// runtime holds the Sandbox, so the obvious reading is that it should also
/// spawn the agent — which would mean sending the credential across the bridge,
/// and that is exactly what may never happen. `EstablishedSandbox.wrap()` hands
/// back argv and env for a `{ shell: false }` spawn, so the runtime can compute
/// the wrapping (no secret) and this process can do the spawning (the secret,
/// still here). The agent stays inside srt either way.
#[allow(dead_code)]
pub fn credential_env(store: &CredentialStore) -> Option<(&'static str, String)> {
    let held = store.0.lock().ok()?;
    held.as_ref().map(|(_, secret)| (ENV_VAR, secret.0.clone()))
}

#[cfg(test)]
mod tests {
    use super::{resolve, Source};

    #[test]
    fn the_keychain_wins_when_both_answer() {
        let resolved = resolve(Ok(Some("from-keychain".into())), Some("from-env".into()));
        assert_eq!(resolved, Ok((Source::Keychain, "from-keychain".to_string())));
    }

    #[test]
    fn the_environment_answers_when_the_keychain_is_empty() {
        let resolved = resolve(Ok(None), Some("from-env".into()));
        assert_eq!(resolved, Ok((Source::Env, "from-env".to_string())));
    }

    #[test]
    fn a_trailing_newline_from_security_is_not_part_of_the_credential() {
        let resolved = resolve(Ok(Some("from-keychain\n".into())), None);
        assert_eq!(resolved, Ok((Source::Keychain, "from-keychain".to_string())));
    }

    #[test]
    fn an_empty_entry_counts_as_nothing_stored() {
        assert_eq!(resolve(Ok(Some("   ".into())), None), Err("nothing-stored"));
    }

    #[test]
    fn nothing_anywhere_is_the_first_run_case() {
        assert_eq!(resolve(Ok(None), None), Err("nothing-stored"));
    }

    #[test]
    fn a_keychain_that_refused_is_a_different_failure() {
        assert_eq!(resolve(Err(()), None), Err("store-unreadable"));
    }

    #[test]
    fn a_keychain_that_refused_does_not_overrule_a_working_environment() {
        let resolved = resolve(Err(()), Some("from-env".into()));
        assert_eq!(resolved, Ok((Source::Env, "from-env".to_string())));
    }
}
