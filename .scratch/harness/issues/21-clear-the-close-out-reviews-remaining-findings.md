# 21 — Clear the close-out review's remaining findings

**What to build:** The rest of the close-out review, worked rather than remembered. None of these breaks the product; all of them are the kind of thing that decays into folklore if it lives only in a report.

**Blocked by:** None.

**Status:** ready-for-agent

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

## One thing to decide rather than fix (N4)

`bun test packages` establishes a Sandbox against **this repository** and generates `sandbox-policy.json` and its baseline into it, cleaning up only if the run created them. Deliberate and documented, but it means the test suite mutates the repo root on a clone that has never launched.
