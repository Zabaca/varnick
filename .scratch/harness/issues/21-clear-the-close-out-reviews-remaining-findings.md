# 21 — Clear the close-out review's remaining findings

**What to build:** The rest of the close-out review, worked rather than remembered. None of these breaks the product; all of them are the kind of thing that decays into folklore if it lives only in a report.

**Blocked by:** None.

**Status:** ready-for-human — every finding is worked. D15, D16, D17, R3, R4 went first; D18, D19 and D20 were finished after ticket 22 merged, and what they turned up is recorded below. N4 is the one thing left, and it is a decision rather than a fix.

**Realizes:** no state path.

The review ran over the whole 51-commit run. Its severe findings are fixed: the runtime/client answer mismatch that broke every launch (D1), the duplicated `runTurn` invoke that aborted and re-billed every Turn (D2), the retry that appended an empty message (D3), the unload button that left a dead panel (D7), and four documents asserting the opposite of what a probe measures (D4, D5, D6). A separate pass covers the documentation drift (D8–D11, D13, D21, D22, R1) and ticket 20 covers the Secrets Store's missing producer (D12).

What is left is below. Each was verified by the reviewer; none has been re-verified since, so **check before changing** — several of this project's confident findings have turned out to be measurement artefacts.

## Assertions that cannot fail (D15)

- `drive.ts:1818` — `check('every turn state the harness realizes was reached to be measured', at.size === 6)`. `at` is filled by six literal `at.set(...)` calls with distinct keys, so `at.size` is 6 regardless of the machine.
- `drive.ts:1921` — `UNIMPLEMENTED.every(...)` over a list that is now `[]`. True by definition.
- `drive.ts:1456` — `check('a final Surface accepts nothing', !can({type:'RETRY'}))` on a stopped actor. XState returns `false` from `can()` for *any* stopped actor.
- `drive.ts:406` and `:673` — both assert `can({type:'EDIT_DRAFT'})`, handled unconditionally at the root, so true in every state.

Each should either assert something that can fail or be deleted. An assertion that cannot fail is worse than none: it reads as coverage.

## A control that can pass for the wrong reason (D16)

`containment.probe.test.ts:804` uses `cat ~/.zshrc` to prove a denial is about *location*. On a machine with no `.zshrc`, `cat` exits non-zero for "No such file" and the control proves nothing. Every other probe in the suite guards this with an unsandboxed `accessSync` first.

## Guards that can never be true (D17)

`packages/core/src/machines/surface.ts:61-62` route on `context.enter === 'loaded' | 'failed'`. `enter` comes only from `SurfaceInput`, and none of the three instantiation sites passes it — `frozen.ts:47-52` documents deliberately not using the entry point for Surfaces. Both arms are dead and `routing` always falls through to `loading`. Either wire the entry point or remove it along with `SurfaceContext.enter` and `SurfaceInput.error`.

## Comments describing behaviour the code no longer has (D18)

- `src-tauri/src/lib.rs:16-18` — "the credential is answered in this process; everything else is forwarded to the runtime". `route_of` now sends nine of twelve kinds to the host. The summary is the inverse of the truth.
- `src-tauri/src/bridge.rs:89` — `/// This process. The credential, and only the credential.`
- `packages/harness/src/agent.ts:637-660` — two overlapping paragraphs, both opening "Five methods, and…"; `AgentSessionPort` has six. The doc's argument is that this list is the complete audit of what reaches into the Sandbox, so a wrong count weakens what it exists to strengthen.
- `packages/harness/src/agent.ts:323-335` — a doc block describing `inheritedConfigVariables` sits above `VARNICK_OWNED_VARIABLES`, the opposite set. A const was inserted between a doc and its function.
- `packages/core/src/actors/live.ts:22-39` and `actors/index.ts` — still describe unimplemented actors that "throw loudly". `LIVE_NOT_IMPLEMENTED` is empty and `notImplemented` has no caller.
- `packages/harness/src/index.ts:8-11` — "the two modules that import no Node"; there are three.
- `src-tauri/src/agent.rs:571-579` — `run_turn`'s header describes only starting a Turn; interrupts and compactions route through it too.
- `CLAUDE.md:7` — "Four things about this repo" above five bullets, and its denyWrite list omits `packages/harness/**`, `sandbox-policy.json` and the baseline.

## Logic that must now be kept in sync by hand (D19)

- Newline framing, character for character, in `agent.ts:898-913` and `runtime.ts:318-339`. Both files call it load-bearing; a fix to one would silently not reach the other.
- Stored-message validation in `bridge.ts:417-432` and `runtime.ts:177-184`. Adding a role in one turns a valid transcript into `malformed` at the other.
- `secrets-cli.ts:127` hardcodes the string `SECRET_ADD_COMMAND` exists for.

## Dead exports (D20)

`SECRET_REMOVE_COMMAND`, `HARNESS_VERSION`, `notImplemented`, `makeIdFactory`. Also `CREDENTIAL_ENV_VAR` duplicates the load-bearing `CREDENTIAL_ENV_VAR_NAME` and is referenced only by its own test — while `credential.rs` points at the dead one. And `packages/harness/src/index.ts` is imported by no source file or test: its header documents the package's architecture and nothing keeps it honest.

## Two risks worth writing down rather than fixing (R3, R4)

- **The clone's `.claude/settings.json` is agent-writable and the developer runs Claude Code in this repo.** ADR-0003 records that varnick must never spawn a host-side session; it does not say that the developer's own `claude` in this repo runs those hooks unconfined. That belongs in "Where confinement stops".
- **The write boundary's documented edge is one of several.** ADR-0002 and the README name `packages/userspace/package.json`. Also agent-writable and host-executed: `packages/lint/package.json`, `bun.lock`, `tsconfig.json`, `eslint.config.js`, and `scripts/clean-clone.sh`, which the README tells the developer to run. Same accepted class; the prose reads as if the list were complete.

## Was open until ticket 22 merged; now cleared

Everything in this section waited on files ticket 22 had checked out. All of it
was re-read against the merged code before anything was changed, and one item
had stopped existing.

**D18 — the comments.** Five rewritten, each verified by reading what the code
does now rather than what the review said it did:

- `src-tauri/src/lib.rs` said the credential is answered in this process and
  *everything else* forwarded. It is the other way round. `route_of` sends
  twelve kinds to the host and three to the runtime, and the rewrite names the
  split by what each half needs — the credential and the Session that rides the
  process holding it, against the Sandbox and the filesystem — rather than by a
  count, which is what rotted the first one. The review's own "nine of twelve"
  was already out of date when this was read.
- `src-tauri/src/bridge.rs`'s `Route::Host` said "the credential, and only the
  credential" over an arm listing twelve kinds. The module header two hundred
  lines above it was already right; only the one-liner was wrong.
- `packages/harness/src/agent.ts` had two paragraphs on `AgentSessionPort` both
  opening "Five methods, and…" — a bad merge, and six members. Merged into one
  that says six and says which of the three callers each is there for. The
  `usage` member's own "the fifth method" was checked and left: it is fifth.
- `agent.ts`'s doc for `inheritedConfigVariables` still sat above
  `VARNICK_OWNED_VARIABLES`. Split in two, and the export's claim about "the
  boundary probe" was corrected to what actually happens: the agent host calls
  it twice inside the confined process and `sandbox.boundary.test.ts` reads the
  two numbers out of the report.
- `packages/core/src/actors/live.ts` described actors that "throw loudly" and a
  `notImplemented` helper with no caller. The helper is gone and the prose says
  what is true — the list is empty, live is the default because of it. The two
  module notes above it became a `/* */` block: half of one was a `/** */`
  attached to the helper, and with the helper gone it would have read as
  documentation for the empty list.
- `packages/core/src/actors/index.ts` said `UNIMPLEMENTED` "shrinks as the
  harness is written". It is empty, and now says so, with the two places that
  read it named.
- **`src-tauri/src/agent.rs` was on D18's original list and off the still-open
  one, but had not been fixed.** `run_turn`'s header described starting a Turn;
  interrupts and Compactions route through it as well. Rewritten.

**D19 — the two duplications, decided differently.**

- *Newline framing* is now one function: `readLines` in
  `packages/harness/src/framing.ts`, called by `serveHarness` and by the agent
  host's control channel. Unified rather than checked because it is a pure text
  reader with no protocol in it — it does not know what a line means — so
  sharing it couples nothing but the framing itself, which is the thing that has
  to be identical. The two copies were identical character for character, and
  the coverage was not: only the agent side had a split-across-chunks test, and
  only the runtime side had the newline-in-a-reason test. Both now cover both.
- *Stored-message validation* is deliberately **not** unified, and is checked
  instead — see the new block in `join.test.ts`, which drives eight candidate
  values through the save path and the restore path and asserts only that the
  two agree. Not unified because the two ends are not interchangeable:
  `bridge.ts` is bundled into the webview and must reach no Node, `runtime.ts`
  imports the filesystem, and the shared parser would have been the module the
  renderer pulls the host half in through. They also guard opposite directions,
  so neither could be dropped in favour of the other. The test was falsified
  before it was committed: adding a third role to `runtime.ts` alone turns it
  red, and it is the only thing in the suite that goes red.

**D20 — no longer applies, and what took its place.** `CREDENTIAL_ENV_VAR` and
`CREDENTIAL_ENV_VAR_NAME` do not exist. Ticket 22 replaced both with
`CREDENTIAL_ENV_VAR_NAMES` in `agent.ts`, and `credential.rs` points at the live
one. But the duplication survived the reshaping in a new form: `agent.ts` held
the two names as literals and `credentials.ts` held the same two, keyed by Kind,
as `CREDENTIAL_ENV_VARS` — which had no caller outside its own test. So the dead
half was the *other* one this time. It is resolved by deriving rather than
deleting: `CREDENTIAL_ENV_VAR_NAMES` is now those two values in order, the map
is load-bearing, and no assertion was removed. The TypeScript half has one
definition; `credential.rs` is the only remaining mirror, in a language that
cannot read it, and both tests still pin it against literals.

## What was cleared, and what it turned up

- **D15** — five assertions replaced, and the replacement for `at.size === 6` was falsified before it was committed: removing `turn.compacting` from `SESSION_STATE_PATHS` turns the suite red.
- **D16** — probe 7's control writes its own marker under `$HOME` and asserts the bytes never arrive, so a missing `~/.zshrc` can no longer stand in for a denial.
- **D17** — `enter` removed rather than wired, for the reason `frozen.ts` already gives.
- **D20**, the interesting half — `packages/harness/src/index.ts` claimed Core imports "the two modules that import no Node"; there are three. It is a lint rule now rather than a sentence. Writing it found two things: scoping it to `packages/core/**` wrongly rejected `drive.ts`, which is a headless Node script and may import what it likes, and banning the barrel as a `group` banned every subpath under it, because a gitignore pattern matches children. Both are recorded at the rule.
- **R3, R4** — both written into the README's *Where confinement stops*, with the `.claude/settings.json` claim verified against `git ls-files` and against the six paths `sandbox.ts` denies.
- **D18, the useful part** — three of the seven comments were wrong about something the reviewer had not noticed, and one file the still-open list had dropped (`agent.rs`) was still wrong. Reading the code rather than the report also turned up ticket 29: the seeded marker's tooltip renders a heading with an empty list under it and tells a developer to append the query parameter that is already the default. Filed rather than fixed — this pass changed no rendered text.

## One thing to decide rather than fix (N4)

`bun test packages` establishes a Sandbox against **this repository** and generates `sandbox-policy.json` and its baseline into it, cleaning up only if the run created them. Deliberate and documented, but it means the test suite mutates the repo root on a clone that has never launched.
