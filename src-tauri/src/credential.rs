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

use std::process::Command;
use std::sync::Mutex;

use serde::Serialize;

/// The variable an API key is injected into.
/// Mirrored as `CREDENTIAL_ENV_VARS` in packages/harness/src/credentials.ts and
/// as `CREDENTIAL_ENV_VAR_NAMES` in packages/harness/src/agent.ts.
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
pub fn read_credential(store: &CredentialStore) -> Result<Reading, &'static str> {
    let (source, kind, value) = resolve(Stores {
        keychain_subscription: read_keychain(Kind::Subscription.keychain_account()),
        keychain_api_key: read_keychain(Kind::ApiKey.keychain_account()),
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
/// environment rather than into any string the host keeps. Called from exactly
/// one place — the spawn in agent.rs — and nothing else may call it.
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
        credential_env, resolve, CredentialStore, Kind, Secret, Source, Stores, API_KEY_ENV_VAR,
        SUBSCRIPTION_ENV_VAR,
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
}
