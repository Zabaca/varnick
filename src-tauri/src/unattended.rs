// What the agent may ask this host to do, host-side: land a branch, cut a
// pre-release.
//
// Both are writes to the developer's clone that the agent itself may not make —
// `git merge` writes `packages/core/**` and a release bumps `package.json`, and
// `denyWrite` refuses the agent both, in the live tree, on every branch and
// none. **That does not change here.** What this file adds is a second, narrower
// door: the host performs the write, on the agent's request, and only when the
// answer to a question the agent cannot influence says it may. See
// docs/adr/0023-a-second-door-rather-than-a-wider-one.md.
//
// ## This process decides almost nothing
//
// It is the middle of three, and that is the whole of its job:
//
//   * the **agent** names a worktree, or a feature slug. Nothing else crosses;
//   * **this process** turns a worktree name into a path, by looking it up in a
//     table `git worktree list` built — `resolve_worktree` in preview.rs, reused
//     rather than reimplemented, because a second lookup is a second answer;
//   * the **Harness runtime** asks `unattendedLanding` about what git says the
//     branch changed, and merges only if it may. That is where every decision
//     is, in TypeScript, provable with no repository at all.
//
// The feature slug is forwarded unexamined, which is the one place this differs
// from the worktree name and it is deliberate. It becomes an argument to
// `bun run release` in the runtime and nowhere else, so the runtime is where its
// shape is decided (`isFeatureSlug` in packages/harness/src/unattended.ts) — the
// same call bridge.rs already makes about a worktree diff's path, and for the
// reason written there: a validation on both sides is a validation that drifts,
// and the side that has to be right is the side holding the spawn.
//
// ## Prose crosses, and it is never this process's prose
//
// A Preview's answer is a tag and nothing else, because a sentence composed here
// is the string most likely to carry a path, an environment or an OS error into
// a confined process — this is the host that holds the Credential and performs
// spawns. That rule is kept, in the form that survives a refusal having to
// explain itself: **an outcome this process decides carries no detail at all**,
// and a detail exists only when it came up from the runtime, which wrote it in
// TypeScript about work it did. That is the division `report_merge` already
// makes for a merge briefing, and the tests below are written against it.

use serde_json::Value;

/// How the agent asks for a Worktree to be landed. One line on its stdout.
pub const LAND_WORKTREE_KIND: &str = "land-worktree";

/// How the agent asks for a Pre-release to be cut.
pub const CUT_RELEASE_KIND: &str = "cut-release";

/// How this host answers a landing. One control line on the agent's stdin.
pub const LANDING_ANSWER_KIND: &str = "landing-answer";

/// How it answers a release.
pub const RELEASE_ANSWER_KIND: &str = "release-answer";

/// The outcomes a landing may end in, as `LANDING_OUTCOMES` in
/// packages/harness/src/unattended.ts names them.
///
/// Mirrored rather than shared, like `PreviewOutcome::tag` beside it, and the
/// mirror is load-bearing rather than documentation: the confined half refuses a
/// control request whose outcome it does not know, so an answer forwarded with a
/// tag this build invented would leave a tool call waiting for ever. Anything
/// not on this list becomes {@link NO_LANDING} on the way past.
pub const LANDING_OUTCOMES: [&str; 8] = [
    "landed",
    "refused",
    "dirty-live-tree",
    "unmergeable",
    "branch-moved",
    "unknown-worktree",
    "no-worktrees",
    "no-landing",
];

/// The outcomes a release may end in. See {@link LANDING_OUTCOMES}.
pub const RELEASE_OUTCOMES: [&str; 4] = ["cut", "refused", "not-a-feature", "no-release"];

/// The name is not one git reports under `.claude/worktrees/`.
pub const UNKNOWN_WORKTREE: &str = "unknown-worktree";

/// git could not be asked what worktrees exist, so nothing was checked.
pub const NO_WORKTREES: &str = "no-worktrees";

/// The question reached nothing, or the answer was not one this build can read.
///
/// **Never `refused`.** A refusal is a decision about a branch, and an
/// orchestrator hands a refused branch to a person and stops — so a runtime that
/// did not answer must not produce one, or a night's finished work is reported
/// as fenced when nothing looked at it.
pub const NO_LANDING: &str = "no-landing";

/// The release could not be run, or did not answer readably.
pub const NO_RELEASE: &str = "no-release";

/// One request to land a Worktree, as the agent host wrote it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LandingRequest {
    /// Which call this answers. Chosen by the agent host, opaque here.
    pub request_id: String,
    /// What the agent asked for. **Not yet a path, and not yet trusted.**
    pub worktree: String,
}

/// One request to cut a Pre-release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseRequest {
    pub request_id: String,
    /// The run being released. Forwarded, never joined onto anything here.
    pub feature: String,
}

/// What happened, as it goes back to the agent.
///
/// The detail is a sentence the *runtime* composed, or nothing. See the module
/// header: this process never fills it in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Answer {
    pub outcome: String,
    pub detail: Option<String>,
}

impl Answer {
    /// An outcome this process decided, which by construction carries no prose.
    pub fn tag(outcome: &str) -> Self {
        Answer {
            outcome: outcome.to_string(),
            detail: None,
        }
    }
}

/// A line the agent host wrote, if it is a request to land a Worktree.
///
/// Rebuilt out of two strings, like every other parse on this wire. A request
/// carrying a `path`, a `base` or a list of changed paths alongside loses them
/// here — which is what makes "the predicate is asked about what git says"
/// a property of the parse rather than a rule someone upstream keeps.
pub fn landing_request_of(line: &str) -> Option<LandingRequest> {
    let (request_id, worktree) = two_strings(line, LAND_WORKTREE_KIND, "worktree")?;
    Some(LandingRequest {
        request_id,
        worktree,
    })
}

/// A line the agent host wrote, if it is a request to cut a Pre-release.
///
/// One field beside the id, and it is the slug. A request naming a version, a
/// tag or an artifact loses all three here: what a release announces is decided
/// by `packages/core/release.ts` from what actually landed, and an agent that
/// could name a version would be an agent announcing whatever it liked.
pub fn release_request_of(line: &str) -> Option<ReleaseRequest> {
    let (request_id, feature) = two_strings(line, CUT_RELEASE_KIND, "feature")?;
    Some(ReleaseRequest {
        request_id,
        feature,
    })
}

/// The two strings one of these requests is, or nothing.
///
/// An empty request id is refused because it names no call, and an answer to no
/// call is an answer nothing resolves. The argument may be empty — that is a
/// name that resolves to nothing and a slug that is not one, both of which are
/// answers rather than parse failures, and both of which say so in words.
fn two_strings(line: &str, kind: &str, field: &str) -> Option<(String, String)> {
    let value: Value = serde_json::from_str(line.trim()).ok()?;
    if value.get("kind").and_then(Value::as_str)? != kind {
        return None;
    }
    let request_id = value.get("requestId").and_then(Value::as_str)?;
    let argument = value.get(field).and_then(Value::as_str)?;
    if request_id.is_empty() {
        return None;
    }
    Some((request_id.to_string(), argument.to_string()))
}

/// The answer, as one control line for the agent host's stdin.
///
/// `serde_json` escapes newlines, so nothing here can split a control request
/// across two lines — the same framing every other line on this pipe uses, and
/// it matters more for this one: a detail is composed from git's account of a
/// branch, which is text nobody here chose.
///
/// A detail that is absent is absent, rather than an empty string: the confined
/// half drops a blank one anyway, and sending `""` would mean this process had
/// said something.
pub fn answer_line(kind: &str, request_id: &str, answer: &Answer) -> String {
    let line = match &answer.detail {
        Some(detail) => serde_json::json!({
            "kind": kind,
            "requestId": request_id,
            "outcome": answer.outcome,
            "detail": detail,
        }),
        None => serde_json::json!({
            "kind": kind,
            "requestId": request_id,
            "outcome": answer.outcome,
        }),
    };
    format!("{line}\n")
}

/// What the runtime said, or the tag that says it did not say it readably.
///
/// **The one place a string from another process becomes an answer**, so it is
/// pure and it is where the tests are. Two rules:
///
///   * the outcome must be one this build knows, because the confined half
///     refuses one it does not and a refused control request is a tool call that
///     never returns;
///   * the detail is taken only when the outcome was, so a reply that carried
///     prose beside an unreadable tag loses the prose with it. Nothing this
///     process observed may become a sentence the agent reads, and the safest
///     reading of "I did not understand the answer" is that there is no answer.
pub fn answer_of(reply: &Value, known: &[&str], fallback: &'static str) -> Answer {
    let Some(outcome) = reply.get("outcome").and_then(Value::as_str) else {
        return Answer::tag(fallback);
    };
    if !known.contains(&outcome) {
        return Answer::tag(fallback);
    }
    let detail = reply
        .get("detail")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|said| !said.is_empty())
        .map(str::to_string);
    Answer {
        outcome: outcome.to_string(),
        detail,
    }
}

/// The whole of what happens when the agent asks for a Worktree to be landed.
///
/// Three steps, and the first two are this process's entire contribution: which
/// worktrees exist, and which of them the agent named. Neither is a decision
/// about the branch — those are all one hop further on, in the runtime, where
/// `unattendedLanding` is asked about what git says the branch changed.
///
/// The clone root is this process's own — `VARNICK_CLONE_ROOT` or the build path
/// — and never anything the agent sent, exactly as `answer_preview`'s is.
///
/// A runtime that will not answer is `no-landing`, which fails closed: nothing
/// is merged, and the tag says the machine rather than the branch. There is no
/// path here that merges anything without the runtime having said it may.
pub fn answer_landing(app: &tauri::AppHandle, worktree: &str) -> Answer {
    use tauri::Manager;

    let clone_root = crate::bridge::clone_root(std::env::var(crate::bridge::CLONE_ROOT_VAR).ok());

    let Some(listing) = crate::preview::worktree_listing(&clone_root) else {
        return Answer::tag(NO_WORKTREES);
    };
    // The same table a Preview is resolved against, and the same rule: the
    // agent's string is only ever a key, and the answer is a value git wrote.
    // `../..`, an absolute path and a name git does not report are one answer.
    let Ok(path) = crate::preview::resolve_worktree(worktree, &listing, &clone_root) else {
        return Answer::tag(UNKNOWN_WORKTREE);
    };

    match app.state::<crate::bridge::HarnessRuntime>().land_worktree(&path) {
        Ok(reply) => answer_of(&reply, &LANDING_OUTCOMES, NO_LANDING),
        // The failure is not forwarded. It is this process's account of a pipe,
        // and the agent's answer is a tag whose sentence is written on the far
        // side — see the module header.
        Err(_) => Answer::tag(NO_LANDING),
    }
}

/// The whole of what happens when the agent asks for a Pre-release.
///
/// One step, because there is nothing here to resolve: a slug names a directory
/// under `.scratch/` that the *release* reads, and this process neither joins it
/// onto anything nor passes it to a command. It goes to the runtime as a field,
/// which checks its shape before it can become an argument.
pub fn answer_release(app: &tauri::AppHandle, feature: &str) -> Answer {
    use tauri::Manager;

    match app
        .state::<crate::bridge::HarnessRuntime>()
        .cut_pre_release(feature)
    {
        Ok(reply) => answer_of(&reply, &RELEASE_OUTCOMES, NO_RELEASE),
        Err(_) => Answer::tag(NO_RELEASE),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        answer_line, answer_of, landing_request_of, release_request_of, Answer, LandingRequest,
        ReleaseRequest, LANDING_OUTCOMES, NO_LANDING, NO_RELEASE, RELEASE_OUTCOMES,
    };
    use serde_json::json;

    // -----------------------------------------------------------------------
    // What may cross, on the way out
    // -----------------------------------------------------------------------

    #[test]
    fn a_landing_request_is_two_strings_and_a_changed_path_list_is_not_one_of_them() {
        /*
          The failure this parse exists to prevent. A request that brought its
          own account of what the branch changed would be the agent answering
          the protected-path question about itself — so the fields are rebuilt,
          and everything else sent alongside is a field that was never read.
        */
        let request = landing_request_of(
            r#"{"kind":"land-worktree","requestId":"l1","worktree":"agent-one",
                "changed":["README.md"],"base":"HEAD","force":true,"path":"/etc"}"#,
        );
        assert_eq!(
            request,
            Some(LandingRequest {
                request_id: "l1".to_string(),
                worktree: "agent-one".to_string(),
            })
        );
    }

    #[test]
    fn a_release_request_cannot_name_a_version_a_tag_or_an_artifact() {
        let request = release_request_of(
            r#"{"kind":"cut-release","requestId":"r1","feature":"autonomous-runs",
                "version":"9.9.9","tag":"v9.9.9","artifact":"/tmp/x.tgz"}"#,
        );
        assert_eq!(
            request,
            Some(ReleaseRequest {
                request_id: "r1".to_string(),
                feature: "autonomous-runs".to_string(),
            })
        );
    }

    #[test]
    fn the_three_shapes_on_this_pipe_are_told_apart_and_none_reads_another() {
        // A Turn event, a Preview request and these two share one pipe and are
        // told apart by kind and by which id they name. A parse that accepted a
        // neighbour would deliver a landing to a Preview, or a Turn to a merge.
        let landing = r#"{"kind":"land-worktree","requestId":"l1","worktree":"agent-one"}"#;
        let release = r#"{"kind":"cut-release","requestId":"r1","feature":"runs"}"#;

        assert!(landing_request_of(release).is_none());
        assert!(release_request_of(landing).is_none());
        assert!(landing_request_of(r#"{"kind":"delta","turnId":"t1","text":"hello"}"#).is_none());
        assert!(release_request_of(r#"{"kind":"delta","turnId":"t1","text":"hello"}"#).is_none());
        assert!(crate::preview::preview_request_of(landing).is_none());
        assert!(crate::agent::agent_event_of(landing).is_none());
        assert!(crate::agent::agent_event_of(release).is_none());
    }

    #[test]
    fn a_request_missing_a_half_is_not_a_request() {
        for broken in [
            r#"{"kind":"land-worktree"}"#,
            r#"{"kind":"land-worktree","requestId":"l1"}"#,
            r#"{"kind":"land-worktree","worktree":"agent-one"}"#,
            r#"{"kind":"land-worktree","requestId":"","worktree":"agent-one"}"#,
            r#"{"kind":"land-worktree","requestId":"l1","worktree":42}"#,
            "not json",
            r#"{"ready":true}"#,
        ] {
            assert!(landing_request_of(broken).is_none(), "{broken}");
        }
        for broken in [
            r#"{"kind":"cut-release"}"#,
            r#"{"kind":"cut-release","requestId":"r1"}"#,
            r#"{"kind":"cut-release","feature":"runs"}"#,
            r#"{"kind":"cut-release","requestId":"","feature":"runs"}"#,
        ] {
            assert!(release_request_of(broken).is_none(), "{broken}");
        }
    }

    #[test]
    fn a_name_that_resolves_to_nothing_is_still_a_request_because_the_answer_is_a_sentence() {
        // Refusing to parse it would leave the tool call unanswered. It parses,
        // and `answer_landing` turns it into `unknown-worktree`, which the agent
        // reads as a sentence saying what a worktree name is.
        assert_eq!(
            landing_request_of(r#"{"kind":"land-worktree","requestId":"l1","worktree":"../.."}"#)
                .map(|request| request.worktree),
            Some("../..".to_string())
        );
    }

    // -----------------------------------------------------------------------
    // What may cross, on the way back
    // -----------------------------------------------------------------------

    #[test]
    fn an_answer_is_exactly_one_line_and_carries_the_runtimes_sentence_untouched() {
        let line = answer_line(
            super::LANDING_ANSWER_KIND,
            "l1",
            &Answer {
                outcome: "refused".to_string(),
                detail: Some(
                    "src-tauri/src/bridge.rs is protected — src-tauri/** may not be landed without a human."
                        .to_string(),
                ),
            },
        );
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(line.trim()).unwrap(),
            json!({
                "kind": "landing-answer",
                "requestId": "l1",
                "outcome": "refused",
                "detail": "src-tauri/src/bridge.rs is protected — src-tauri/** may not be landed without a human.",
            })
        );
    }

    #[test]
    fn an_outcome_this_host_decided_carries_no_prose_at_all() {
        /*
          The rule the whole module is written to keep. This process holds the
          Credential and performs spawns; a sentence composed here is the string
          most likely to carry a path or an environment into the Sandbox. So
          every answer it decides for itself is a bare tag, and the sentences for
          those tags are authored in packages/harness/src/unattended.ts.
        */
        for outcome in [
            super::UNKNOWN_WORKTREE,
            super::NO_WORKTREES,
            NO_LANDING,
            NO_RELEASE,
        ] {
            let answer = Answer::tag(outcome);
            assert_eq!(answer.detail, None);
            let parsed: serde_json::Value =
                serde_json::from_str(answer_line("landing-answer", "l1", &answer).trim()).unwrap();
            assert!(parsed.get("detail").is_none(), "{outcome} said something");
        }
    }

    #[test]
    fn an_outcome_this_build_does_not_know_becomes_the_tag_that_says_nothing_happened() {
        /*
          A runtime one version ahead — or a reply that lost its way — must not
          become an answer nothing wrote. The confined half checks the tag
          against its own closed list and refuses a control request that fails
          it, and a refused control request is a tool call that never returns.
          So an unknown tag is converted here, into the one outcome that is
          honest about it.

          And it must not be `refused`: that reads as a decision about the
          branch, which nobody made.
        */
        for reply in [
            json!({ "outcome": "landed?" }),
            json!({ "outcome": "declined" }),
            json!({ "outcome": 7 }),
            json!({ "detail": "it went fine" }),
            json!({}),
        ] {
            let answer = answer_of(&reply, &LANDING_OUTCOMES, NO_LANDING);
            assert_eq!(answer.outcome, NO_LANDING);
            assert_eq!(answer.detail, None, "prose survived an unreadable tag");
        }
        assert_eq!(
            answer_of(&json!({ "outcome": "cut?" }), &RELEASE_OUTCOMES, NO_RELEASE).outcome,
            NO_RELEASE
        );
    }

    #[test]
    fn every_outcome_the_runtime_can_send_survives_the_crossing() {
        // The mirror of `LANDING_OUTCOMES` and `RELEASE_OUTCOMES` in
        // packages/harness/src/unattended.ts. A tag missing from either list
        // here is a tool call that hangs, so the list is asserted whole rather
        // than sampled.
        for outcome in LANDING_OUTCOMES {
            let reply = json!({ "outcome": outcome, "detail": "because." });
            let answer = answer_of(&reply, &LANDING_OUTCOMES, NO_LANDING);
            assert_eq!(answer.outcome, outcome);
            assert_eq!(answer.detail, Some("because.".to_string()));
        }
        for outcome in RELEASE_OUTCOMES {
            assert_eq!(
                answer_of(&json!({ "outcome": outcome }), &RELEASE_OUTCOMES, NO_RELEASE).outcome,
                outcome
            );
        }
        // The two lists are not each other's, which is what keeps a release
        // answer from reading as a landing.
        assert_eq!(
            answer_of(&json!({ "outcome": "landed" }), &RELEASE_OUTCOMES, NO_RELEASE).outcome,
            NO_RELEASE
        );
    }

    #[test]
    fn a_blank_detail_is_no_detail_rather_than_a_blank_sentence() {
        for reply in [
            json!({ "outcome": "landed", "detail": "" }),
            json!({ "outcome": "landed", "detail": "   " }),
            json!({ "outcome": "landed", "detail": 42 }),
            json!({ "outcome": "landed" }),
        ] {
            assert_eq!(answer_of(&reply, &LANDING_OUTCOMES, NO_LANDING).detail, None);
        }
    }
}
