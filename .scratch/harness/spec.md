# Harness — v1

**Status:** ready-for-agent

## Problem Statement

A developer who wants an agent to work unattended on their own machine has no good options. Running it with permissions bypassed puts every SSH key, cloud credential, and unrelated repository on the machine within reach of an injected instruction in any file the agent reads. Running it with permission prompts on means answering prompts instead of working, which defeats the point. The tooling that exists treats the conversation as the destination, so there is nowhere for the work to accumulate and nothing to build around.

Worse, the failure mode is silent. The Claude Agent SDK ships a `sandbox` option that looks like a boundary and confines only shelled-out commands; `Read`, `Grep`, and `Glob` walk straight past it. A developer can believe they are confined, be wrong, and never find out.

The developer wants to hand an agent real autonomy, describe the blast radius in one sentence, and have the conversation survive whatever the agent does to the code.

## Solution

varnick is a desktop Harness for a coding agent with a chat inside it. The developer clones the repository, runs it in dev mode, and works with an agent that is confined by the kernel across its entire process tree — not by a prompt, and not by a mechanism that covers only some of its tools.

The Harness supplies four things the developer would otherwise build before they could trust the setup. Confinement: the agent runs under a sandbox scoped to the clone, with the home directory, other repositories, and the network denied except for an allowlist. Credentials: the agent authenticates without ever being able to reach the system keychain, because the host reads the credential and injects it. Secrets: the agent writes code that names a secret and never sees a value. Durability: the Session is persisted twice, so the transcript survives a crash, a restart, and a build the agent just broke.

Inside that, the developer builds their own Workspace by asking for it. Surfaces are discovered from the filesystem, so adding one never requires editing Core — which the agent cannot write anyway. When a Surface fails to load, it fails alone: the chat stays alive, and the conversation that caused the failure is the conversation that fixes it.

Everything the developer builds on top is theirs. What ships is a Harness small enough to read.

## User Stories

### Confinement

1. As a developer, I want the agent's entire process tree confined by the kernel, so that a tool added to the SDK later is covered without me changing anything.
2. As a developer, I want `Read`, `Grep`, and `Glob` to be denied the same paths that `Bash` is denied, so that the confinement I was promised is the confinement I get.
3. As a developer, I want my home directory unreadable to the agent, so that an injected instruction in a file it reads cannot exfiltrate my SSH keys, cloud credentials, or age keys.
4. As a developer, I want my other repositories unreadable to the agent, so that work on one project cannot leak the contents of another.
5. As a developer, I want the agent unable to execute `security`, `osascript`, `open`, and `sudo`, so that it cannot read my keychain, script other applications, launch anything outside its boundary, or elevate.
6. As a developer, I want the agent's network egress limited to an allowlist, so that its reach is bounded even when it is running unattended.
7. As a developer, I want to see exactly which paths and hosts the policy permits, so that I can decide whether I believe the boundary before I walk away from it.
8. As a developer, I want the README to state plainly where confinement is partial, so that I am not relying on a protection that does not exist.
9. As a developer cloning this on Linux or Windows, I want to be told clearly whether confinement is enforced on my platform, so that I do not assume macOS behaviour.
10. As a developer, I want the agent's run to fail loudly if the sandbox cannot be established, so that it never silently runs unconfined.

### Credentials

11. As a developer, I want to launch varnick and have the agent authenticate without me exporting anything, so that a desktop application behaves like a desktop application.
12. As a developer, I want the credential read by the host process and injected into the agent, so that the agent can authenticate without being able to read the keychain that holds it.
13. As a developer, I want a clear first-run path when no credential is available, so that a fresh clone tells me what to do instead of failing obscurely.
14. As a developer, I want the agent to refuse to start when no credential is present, so that I get one legible error rather than a stream of authentication failures mid-task.
15. As a developer, I want an expired or rejected credential surfaced as its own state, so that I can tell it apart from the agent being broken.

### Secrets

16. As a developer, I want to store an API key that the agent can never read, so that a secret in my Workspace is not one prompt injection away from leaving it.
17. As a developer, I want the agent to write code referencing a secret by name, so that it can build integrations without ever holding a value.
18. As a developer, I want the host to resolve secret names when it runs the code the agent wrote, so that the built Surface works while the agent that built it stayed blind.
19. As a developer, I want to add, rename, and remove secrets without restarting varnick, so that setting up an integration is not a restart cycle.
20. As a developer, I want the agent told which secret names exist, so that it can write correct code without knowing any values.
21. As a developer, I want secrets kept out of the transcript and out of logs, so that durability of the Session does not become durability of my keys.

### Session durability

22. As a developer, I want my transcript to survive quitting and relaunching varnick, so that a day's work is not a day's conversation lost.
23. As a developer, I want my transcript to survive a crash, so that an unattended run that dies is recoverable rather than opaque.
24. As a developer, I want the transcript intact after the agent writes code that does not compile, so that the conversation that broke the build is the one that fixes it.
25. As a developer, I want to resume the Session where it left off rather than starting a new one, so that context is not rebuilt by hand.
26. As a developer, I want the Session stored somewhere I can read and back up, so that durability is not a claim I have to take on faith.

### Chat

27. As a developer, I want to send a message and watch the response stream, so that I can tell the difference between working and hung.
28. As a developer, I want to interrupt a running turn, so that a wrong direction costs seconds rather than minutes.
29. As a developer, I want to see the agent's tool calls as they happen, so that unattended work is auditable rather than a black box.
30. As a developer, I want sending refused with an explanation when the agent cannot run, so that a dead input box tells me why.
31. As a developer, I want the chat to keep working when a Surface fails, so that the failure is a thing I can talk about rather than a thing that removes my ability to talk.

### The Core/Userspace boundary

32. As a developer, I want the agent physically unable to write Core, so that it cannot break the chat I would use to recover.
33. As a developer, I want the agent physically unable to edit the build configuration or package scripts, so that it cannot reach the host by writing a plugin or an install hook.
34. As a developer, I want the agent to be told what it cannot write and why, so that it proposes an Escalation instead of retrying a denied write.
35. As a developer, I want to change Core myself in a separate session in the same repository, so that the harness stays improvable without weakening the boundary.

### Surfaces

36. As a developer, I want to ask for a Surface and have it appear without editing Core, so that the main loop of the product is not blocked by its own safety boundary.
37. As a developer, I want Surfaces discovered from the filesystem, so that adding one is creating a file rather than registering in a list.
38. As a developer, I want a Surface that fails to load to show me what failed and why, so that I can fix it from the chat.
39. As a developer, I want one broken Surface to leave the others running, so that a mistake in one part of my Workspace does not cost me the rest.
40. As a developer, I want to retry a failed Surface without restarting varnick, so that the fix-and-see loop stays short.

### Cloning and first run

41. As someone who did not write varnick, I want a fresh clone to run without personal configuration baked in, so that it is genuinely usable rather than nominally open source.
42. As someone cloning varnick, I want first launch to be an empty chat that works, so that I can start building immediately rather than configuring.
43. As someone cloning varnick, I want the Harness readable in a sitting, so that I can decide whether to trust it and know where to edit it.
44. As a developer, I want varnick isolated from my existing Claude Code configuration by default, so that its behaviour does not depend on machine state I forgot I set.
45. As a developer, I want a flag to inherit my Claude Code environment, so that my existing skills and MCP servers are available when I want them.

### States the prose did not predict *(machine phase)*

Discovered while writing the machines and building the states page. Each one is a
card at `#/states`.

46. As a developer, I want the first frame after launch to be a usable empty chat rather than a splash or a spinner, so that a fresh clone looks like a product and not like a build step. *(machine phase)*
47. As a developer, I want the wait while the credential is read and the sandbox is established to claim nothing about the outcome, so that a slow start is not mistaken for a granted permission. *(machine phase)*
48. As a developer, I want a partially streamed answer rendered as an answer rather than as a placeholder, so that I can read it while it arrives and act before it finishes. *(machine phase)*
49. As a developer, I want an interrupted turn to keep what had already arrived, so that pressing escape costs me the rest of the answer and not the part I was reading. *(machine phase)*
50. As a developer, I want a failed turn to offer both retry and dismiss, so that I can decide whether the failure is worth another attempt without the error becoming permanent furniture. *(machine phase)*
51. As a developer, I want a failed save to be visibly a different problem from a failed turn, so that I do not retry the conversation when the disk is what went wrong. *(machine phase)*
52. As a developer, I want a save to be able to fail while a turn is still running and neither to cancel the other, so that persistence trouble never costs me work in flight. *(machine phase)*
53. As a developer, I want a refused start to name the precondition that refused it, so that a click that does nothing is impossible. *(machine phase)*
54. As a developer, I want a failed credential read to say what failed, so that "no credential" is distinguishable from "never tried". *(machine phase)*
55. As a developer, I want the agent to crash without taking the transcript with it, so that a restart is a restart and not a reset. *(machine phase)*
56. As a developer, I want every state of this surface visible on one page, driven by the real machines, so that the states a screenshot never shows are reviewed rather than discovered in production. *(machine phase)*
57. As a developer, I want that page to go amber when a machine gains a state with no card, so that coverage is checked by the build rather than remembered by a person. *(machine phase)*
58. As a developer, I want a design-free page showing raw machine state and one button per accepted event, so that behaviour can be judged with no design covering for it. *(machine phase)*

### Decided at the visual gate *(visual gate)*

Behavioural changes made while using the high-fidelity page. Each one changed
which events are legal, so each looped back through the machines.

59. As a developer, I want `/` in the composer to open a command menu, so that I do not have to remember what the harness accepts. *(visual gate)*
60. As a developer, I want the menu to list only commands the machines will actually accept right now, so that it cannot advertise capability the product does not have. *(visual gate)*
61. As a developer, I want Tab to complete a command and Enter to send, so that completing and running are separate decisions. *(visual gate)*
62. As a developer, I want Escape to close the menu without clearing what I typed, so that dismissing a suggestion is not the same as losing a draft. *(visual gate)*
63. As a developer, I want to keep typing while the agent works, so that I can queue the next instruction instead of waiting. *(visual gate)*
64. As a developer, I want `/model` and `/effort` to list every value as its own entry with the current one marked, so that the menu answers "what is this set to" without a settings panel. *(visual gate)*
65. As a developer, I want a model or effort change to apply to the next turn without disturbing the turn in flight, so that changing my mind is not destructive. *(visual gate)*
66. As a developer, I want `/compact` to summarise the conversation and say so while it runs, so that reclaiming context is a visible act rather than a silent rewrite. *(visual gate)*
67. As a developer, I want a failed compaction to state that the conversation is unchanged, so that I do not have to guess whether history was lost. *(visual gate)*
68. As a developer, I want `/clear` to reset the transcript and the context count together, so that the meter cannot disagree with what is on screen. *(visual gate)*
69. As a developer, I want context used out of the window on the same line as the model and effort, so that the cost of the next turn is answered in one glance. *(visual gate)*
70. As a developer, I want plan usage for the 5-hour and weekly windows shown outside the chat, so that I know how much runway I have before starting something long. *(visual gate)*
71. As a developer, I want any number the build has not actually measured marked as seeded, so that a prototype cannot be mistaken for a reading. *(visual gate)*
72. As a developer, I want the shell to use the full window with only prose capped, so that a transcript of diffs and paths is not folded into an essay column. *(visual gate)*
73. As a developer, I want no control shown for a mode the product does not have, so that the surface does not describe a keyboard shortcut that does nothing. *(visual gate)*

## Implementation Decisions

**Two packages.** The Harness is a package inside the repository — sandbox policy generation, credential resolution, the Secrets Store, and Session persistence — consumed by Core, which owns the chat and the Surface loader. The Harness is not published; it stays editable in the clone, because the thing a fork most wants to change is the sandbox policy. Extraction later is a move, not a rewrite.

**Containment is `@anthropic-ai/sandbox-runtime` around the agent's process tree.** The Agent SDK's own `sandbox` option is disabled and must stay disabled — the kernel refuses to apply a sandbox inside an existing one, so enabling both kills every Bash command. This is [ADR-0003](../../docs/adr/0003-containment-wraps-the-process-tree.md).

**Four binaries are made unreadable, and three of them run anyway.** This originally read "execution is denied by denying read" — `sandbox-runtime` has no execute allowlist, so the reasoning went, a binary is blocked by making it unreadable. Measured, that is false: `srt`'s profile carries an unconditional `(allow process-exec)`, and `denyRead` emits `file-read-data` denials, which is a different operation. `security`, `osascript` and `open` all execute; only `sudo` is blocked, for its own setuid reason. The list is kept and is now called `UNREADABLE_BINARIES` — a binary the agent cannot open is one it cannot copy or patch — but nothing may depend on those four failing to run. See ADR-0003's correction.

**The sandbox policy denies Core.** `packages/core/**`, the build configuration, and package scripts are unwritable by the Userspace Profile, per [ADR-0002](../../docs/adr/0002-core-userspace-boundary.md). This is what makes the boundary kernel-enforced rather than conventional, and it is also what closes the build-pipeline escape.

**Surfaces are discovered, never registered.** The loader scans a Userspace directory at load time. No imports array exists for the agent to append to, because the agent cannot write the file that would hold it.

**Core loads Surfaces dynamically and never statically imports them**, per [ADR-0004](../../docs/adr/0004-core-never-statically-imports-userspace.md), enforced by a lint rule rather than by discipline. Each Surface load is wrapped so a failure is contained to that Surface.

**The credential is read by the host and injected as an environment variable** into the sandboxed subprocess. The host process is outside the sandbox by construction, which is the same property that makes Custom Tools the sanctioned escape hatch.

**Secrets resolve at the point the host runs built code**, never inside the agent's process. The agent is given the list of names and no values. Egress substitution was considered and rejected — it requires owning a proxy, and clients that validate credential format locally break on a placeholder. This is [ADR-0006](../../docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).

**The Secrets Store is the system keychain, one item per secret plus an index item** *(stage 6)*, under the `varnick-secrets` service, reached through `/usr/bin/security` and injected as a port so no test can touch a developer's real keychain. The transcript's answer — a file you can `cat` — is deliberately not reused: right for a transcript, wrong for a key. `security` cannot enumerate a service, which is why the names are an item of their own; a name is an identifier and can therefore never address that item. Values are written through `security -i`, with the value on stdin and hex-encoded, so a secret never appears in argv where `ps` would find it. The accepted value set is single-line printable ASCII, because `security` hands anything else back hex-encoded with no way to tell which form you were given.

**The store was chosen partly on a claim that turned out to be false, and is safe for a different reason** *(stage 6)*. The Sandbox denies the agent read on `/usr/bin/security`, and that was taken to mean the agent could not run it. Measured, it runs — srt allows `process-exec` unconditionally — and the Security framework links in-process anyway, so no binary is needed. What actually keeps the store out of reach is `denyRead` on `$HOME`, where the login Keychain file lives: inside the Sandbox it is not in the search list and cannot be opened. An intermediate measurement claimed the store *was* reachable; it used a throwaway keychain in a readable location. All of it is in ADR-0003's corrections and asserted in `packages/harness/src/sandbox.boundary.test.ts`.

**Story 45 is narrower than it was written, and the narrowing is the Sandbox's** *(stage 11)*. The agent is isolated from the developer's Claude Code by default — `settingSources: []`, `strictMcpConfig`, and every `CLAUDE*` and `ANTHROPIC_*` variable dropped except the credential — with `VARNICK_INHERIT_CLAUDE_CONFIG=1` as the flag out. What the flag cannot do is what story 45 asks for by name: `denyRead` covers `$HOME`, so `~/.claude` — user settings, user `CLAUDE.md`, skills, plugins, stdio MCP servers installed there — is unreachable with the flag or without it. Reaching them means a read-allow over the home directory, which is the mistake ADR-0003 records twice and is what keeps the login Keychain shut. `~/.claude.json` also holds MCP server credentials. So the flag restores the clone's own configuration and the developer's environment, and the spec's story is met in that narrower form. See [ADR-0010](../../docs/adr/0010-the-agent-is-isolated-from-the-developers-claude-code.md). `CLAUDE_CONFIG_DIR` moves to `<clone>/.varnick/claude` in both modes, which is containment rather than preference: measured under the policy, nothing under `$HOME` is writable, so a Claude Code process left pointing at `~/.claude` cannot write its own state.

**The Session is persisted twice**: by the Agent SDK for resumption, and mirrored host-side so it survives a broken build and gives the UI a queryable store.

**The mirror is JSON Lines, one file per Session** *(stage 6)*, under the Tauri app-data directory with the root injectable so no test writes to a developer's real transcripts. Chosen on the criterion the decision was carried for: durable that cannot be read is a claim taken on faith. `cat` and `jq` are the whole reading procedure and copying a file is the whole backup procedure, which SQLite and a single JSON blob both fail. A save appends when what is on disk is a prefix of what is being saved and replaces the file through a rename when history was rewritten — Compaction and `/clear` rewrite it, and an append-only file would keep both versions. Secrets are removed inside the store on the write path, so no caller can forget: exact values from the Secrets Store, plus credential shapes for the keys no exact-value list can know about.

**The network allowlist is a configuration file in v1**, not a UI. Its contents are readable and editable, and the honest limit is documented: any allowed host is an exfiltration path, so the allowlist bounds blast radius rather than data egress.

**Machine decomposition, as built** *(machine phase — replaces the proposal this spec carried)*. Three machines: `harness` is the parent, `session` is one child spawned once and outliving every agent restart, `surface` is one child per discovered Surface. The Harness is parallel across four regions — `credential`, `sandbox`, `subscription`, `agent` — because they are genuinely independent facts, and the Session is parallel across three — `turn`, `persistence`, `composer` — for the same reason. A save can fail while a turn streams, and the command menu can open mid-turn. Recorded in [ADR-0007](../../docs/adr/0007-state-decomposition-for-the-harness.md).

Two things fell out of that shape and are load-bearing:

- **Regions publish their state into context.** An XState v5 guard receives only `{ context, event }` and cannot read a sibling region, so each region assigns its own state to `credentialState` / `sandboxState` on entry and the start guard reads those. The UI reads the same two fields, so the affordance and the rule cannot drift.
- **START's refusal is an unguarded fallback, not a disabled button.** `can({type:'START'})` is therefore permanently true and nothing may bind `disabled` to it; readiness comes from `canStartAgent()`. A refused start explains itself instead of swallowing the click.

**Implementations swap at one seam** *(machine phase)*. Machines declare actor contracts and never import an implementation; `actors/index.ts` chooses `seeded` or `live` for the whole system, and `?actors=live` overrides at runtime. Live actors exist and throw with the name of what is missing, so an unwired path fails loudly at the actor rather than appearing to work — which is what a silent stub did once already here. `UNIMPLEMENTED` is the list the seeded marker reads, so the UI stops claiming a thing is fake the moment it stops being.

**The states page is the third build of the same code, not a demo** *(machine phase)*. `#/states` renders the shipped component driven by the shipped machine, frozen through `provide()` — actors that never settle, named delays held. Entry points are inputs on the machines (`enterCredential`, `enterSandbox`, `enterAgent`, `enterSubscription`, `enterTurn`, `enterPersistence`, and a `sessionInput` the parent spawns the Session with), which is why the machines name their delays instead of writing numeric literals in `after`.

**Every actor declares its real-service contract when the machine is written** — input shape, output shape, error shape — for `spawnAgent`, `readCredential`, `persistSession`, and `loadSurface`. Failure and retry branches are asserted against seeded failures, not just happy paths.

## Testing Decisions

A good test here asserts external behaviour and, more than usual, asserts **refusals**. Most of what this feature promises is something not happening: a path not readable, an event not accepted, a failure not spreading. A test that only exercises the happy path proves almost nothing about a containment boundary.

**Seam 1 is built and green** *(machine phase)*. `packages/core/scripts/drive.ts`, run with `bun run drive`, carries 293 assertions over the three machines with no DOM and no components. It also asserts the states page from the same data: that every declared state path has a scenario, that no scenario names a path no machine declares, that each scenario created cold actually reaches the state it claims, and that a frozen card does not advance on its own. Scenarios live in `src/data/scenarios.ts` as plain data precisely so this check is headless.

The bugs it and the bare page caught, kept here because each one is a rule worth not re-learning: a `START` swallowed after a refusal; `EDIT_DRAFT` scoped to `turn.idle`, which made the composer inert mid-turn; `DISCOVER_SURFACES` spawning duplicate actors on a rescan; a root-level `READ_SUBSCRIPTION` transition that tore down every parallel region and with it the Session; and two actors missing from `provide()`, which fell back to default stubs silently.

**Seam 1 — the harness machine, driven headlessly.** No DOM, no framework, no components. Assertions: send refused with no credential; send refused while the agent process is down; interrupt legal only while streaming; a failed Surface leaves its siblings and the transcript intact; a Session restored after a simulated crash carries its transcript; a seeded actor failure recovers on retry; a final state accepts nothing. Actors are provided as seeds here, so latency and failure states are proven rather than assumed.

**Seam 2 — containment probes against a real sandboxed process.** This seam exists because a mocked sandbox proves nothing about the only claim the product rests on, and because the `Read`/`Grep` hole in the SDK's sandbox option was found only by running the real thing and reading the output. Assertions: a probe file outside the boundary is unreadable by `Bash`, `Read`, `Grep`, and `Glob` alike; each `UNREADABLE_BINARIES` entry is refused a read, and three of the four execute anyway — the criterion originally written here, "each denied binary reports as not found", is false and is corrected above; a non-allowlisted host is unreachable; an allowlisted host is reachable; the run fails rather than proceeding when the sandbox cannot be established. This seam is slow and needs a real machine, and that is accepted.

**Where Harness code is tested** *(stage 5)*. Seams 1 and 2 cover the machines and the containment boundary. The tickets are mostly neither: sandbox policy generation, credential resolution, the Session mirror, and the Secrets Store are ordinary code in `packages/harness`, and until this was written down there was nowhere to put a failing test for any of them.

The convention: `packages/harness/**/*.test.ts`, run by `bun:test` through `bun test` at the repo root. Test the package's exported functions and nothing below them — a policy generator is tested by the policy it produces, not by how it assembles the string. Every agent building a ticket tests here unless the ticket says otherwise, so that "test at the agreed seam and nowhere else" means the same thing to all of them.

Three tickets are exceptions, and say so: 04 is seam 2 and runs a real process; 13 is prose; 14 changes machine-adjacent code and belongs in `drive.ts`.

**ADR-0004 is checked by `drive.ts`.** The ADR says the no-static-Userspace-import rule is enforced by lint rather than discipline, and this repo has no linter — which made it a promise. `drive.ts` now walks Core's sources and fails if any file statically imports Userspace. A real lint rule can replace it later without changing what is asserted.

**Prior art** is `zbc/packages/agent` — its `sandboxed.test.ts` and `e2e/smoke.ts` are the closest existing examples of seam 2, and its ADR-0002 is the record of what happens when containment is asserted from documentation rather than measurement.

## Out of Scope

**Rendering Surfaces: cut at the visual gate, then partly restored** *(visual gate, then stage 5)*. Stories 36–40 assumed full dynamic Surface loading in v1. That was cut — the boundary ADRs govern how a Surface behaves once one exists, they do not require one to ship, and v1 is the chat.

Cutting it took host-side secret resolution with it, which the stage-5 split surfaced: resolution happens when the host runs code the agent wrote, and with nothing running Userspace code there is no such moment. A Secrets Store with no consumer makes ADR-0006 a claim rather than a demonstrated property.

So **a minimal execution path is back in v1** — enough of the loader to run one real Userspace module, and no more. Not a Surface framework, not a layout system, not a registry. Stories 36–40 are met in that narrow form; anything wider stays out. See ticket 14, and `PRODUCT.md` → v1 scope.

The canvas or artifact panel. Multiple concurrent Sessions, session switching, and session forking — the data layer models Sessions as a collection because that is a one-way door, but the v1 UI shows one. A settings and provenance panel. A UI for the network allowlist. Any plugin API, versioned extension contract, or published Harness package.

The Core Profile and the Escalation path are out of v1. Changing Core in v1 means opening a separate Claude Code session in the repository; the Clone, Collect, and double-gated Escalation described in [ADR-0005](../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md) are the design those will follow when built.

Also out: multi-user anything, authentication, tenancy, hosted deployment, and the morning-inbox workflow, which is a Userspace build on top of this and not part of the product.

## Further Notes

**Tickets, and the states with none** *(stage 5)*. Twenty-one tickets live in `issues/` — thirteen integration slices when this was written, and eight more since, the last of them the close-out reviews. Run the check both directions: every state path named by a ticket has a card at `#/states`, and every card resolves either to a ticket or to work already done.

Three cards deliberately have no ticket, because nothing is stubbed underneath them — they are pure machine logic that already ships:

- `agent.startRefused` — the refusal is a guard and an unguarded fallback, both real
- `composer.menu` — derived from the draft and the command names, no service behind it
- `turn.idle` after a failed compaction — the state is `idle`; only the actor in ticket 08 is missing

Four tickets deliberately name no state path — 04 (containment probes), 10 and 12 (secrets), and 13 (documenting where confinement stops). The first is evidence for 01 and 03; the secrets pair is a Harness capability with no machine and no v1 UI; the last is prose that can only be written once the probes have measured something. All four are named here so their absence from the states page is not read as missed work.

**One ticket is `needs-info`, not `ready-for-agent`.** Splitting the Secrets Store in two exposed that host-side secret resolution has no execution moment in v1: resolution happens when the host runs Userspace code, and v1 deliberately runs none. Ticket 12 records the three ways out and stays blocked on that decision. The store half (ticket 10) is buildable today and unaffected.

**The boundary is partial by design, and the documentation must say so.** Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run — that is the point of the product and cannot be closed without abandoning it. The Sandbox protects the home directory, other repositories, and the network. It does not protect the clone from the code the agent writes into it. Git is the undo.

**One question could close part of that hole and nobody has checked it:** whether the dev server can itself run inside the sandbox. If it can, the remaining escape narrows considerably at low cost. Worth answering during the machine stage.

**Platform confinement is macOS-only until proven otherwise.** `sandbox-runtime` has bubblewrap and Windows backends; neither has been exercised here, and the README should claim only what has been measured.

Open decisions carried from `PRODUCT.md`: the open-source licence, and whether built binaries are distributed. Neither the Session mirror's mechanism nor the Secrets Store's is among them any more — both were settled in stage 6 and are recorded under Implementation Decisions. A new one opened in their place: **where the Secrets Store should live now that the Sandbox is measured not to keep the agent out of the keychain**, recorded in the correction to [ADR-0003](../../docs/adr/0003-containment-wraps-the-process-tree.md).

**Nothing carries a Harness call from the renderer to the host yet** *(stage 6)*. Core's live actors run in the Tauri webview and the Harness needs a host process: a filesystem for the mirror, a keychain for the credential, a subprocess for the agent. `persistSession` calls the real store through a filesystem port and works from any host process; in the webview it throws into `persistence.saveFailed` with a message naming the missing bridge. Every ticket that wires a live actor meets this, so the bridge wants to be one piece of work rather than five.

---

# Core in a Worktree — amendment

**Status:** ready-for-agent

Amends the spec above. Everything before this line still holds except where named.

## Problem Statement

The developer asks the agent for a change and is told it cannot be made. Core is denied at the kernel, so the agent can build *around* varnick and never build varnick itself — which is the thing the product exists to allow. The design had an answer, [ADR-0005](../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md): a second Profile working in a disposable Clone, a queued Escalation, a host-initiated Collect. None of it was built, and its premise turned out to be wrong.

Two measurements settle it. A linked worktree's whole git surface — `<main>/.git/worktrees/<name>` for HEAD, index, logs and refs, and `<main>/.git` for objects via `commondir` — sits inside the clone, which the Sandbox names in both `allowRead` and `allowWrite`. And `denyWrite` names *absolute live-tree paths*, so a worktree's `packages/core/**` matches nothing.

So the agent can already author Core in a worktree, and the change becomes running code only when a human merges it. What is missing is everything that makes that loop usable: the agent cannot run what it wrote, cannot show it to anyone, and the developer has no way to see what changed.

## Solution

The agent authors Core in a git worktree under `.claude/worktrees/` — Claude Code's own default, so `EnterWorktree` and subagent worktree isolation work unmodified.

It proves the change headlessly with the tools it already has, and can now bind a local port, so a dev server, a test server and a headless browser all work. When the change is worth looking at, it asks the host to launch a **Preview**: a second varnick running from the worktree, in its own window. A Preview whose worktree touches **Fence** code raises a native dialog first; everything else launches without asking.

The developer sees what changed in a diff view that ships in Core, with Fence hunks distinct. They merge with git, restart, and the change is live.

## User Stories

1. As a developer, I want the agent to make Core changes, so that varnick can become the thing I want rather than only host the thing I build beside it.
2. As a developer, I want those changes to reach the running app only through a merge I performed, so that a confined agent stays confined.
3. As a developer, I want the agent to use worktrees the way Claude Code already uses them, so that I am not learning a bespoke mechanism.
4. As a developer, I want the agent to run a dev server, so that it can prove a UI change rather than describe one.
5. As a developer, I want the agent to run a headless browser, so that it finds a rendering defect before I do.
6. As the agent, I want to bind a local port without egress widening, so that observing my own work costs the developer no boundary.
7. As a developer, I want to ask for a Preview and get a window, so that reviewing a change means using it.
8. As a developer, I want a Preview of an ordinary Core change to launch without asking, so that the flow is fast where it is safe.
9. As a developer, I want a native dialog before a Preview whose worktree edits the Fence, so that the one path from confined to unconfined is one I chose.
10. As a developer, I want that dialog to show the hunks, so that I approve bytes rather than a sentence the agent wrote.
11. As a developer, I want that dialog drawn by the host, so that Userspace cannot forge one and train me to click through.
12. As a developer, I want a Preview to run beside the varnick I am already using, so that I do not lose my conversation to look at a change.
13. As a developer, I want a Preview to have its own Session, so that its conversation does not enter mine.
14. As a developer, I want to see every worktree with pending Core changes, so that nothing the agent finished waits unnoticed.
15. As a developer, I want Fence hunks rendered distinctly in that diff, so that a widening cannot hide in four hundred lines.
16. As a developer, I want that diff view in Core rather than as a Surface, so that the agent cannot rewrite the thing that shows what the agent changed.
17. As a developer, I want a Core change to reload the window rather than hot-swap a module, so that I do not lose the conversation that asked for the change.
18. As a developer, I want git hooks to be tracked files, so that code that runs on my machine at commit time arrives through the same review as everything else.
19. As a developer, I want `.git/hooks` and `.git/config` denied to the agent, so that the one thing no diff shows cannot execute ahead of the gate.
20. As a developer, I want the claim that a nested sandbox cannot widen the outer one measured rather than assumed, so that a load-bearing belief is not prose.

## Implementation Decisions

- **One Profile.** The Userspace/Core Profile split collapses; see [ADR-0014](../../docs/adr/0014-core-is-authored-in-a-worktree.md). **Clone**, **Escalation** and **Collect** retire.
- **The gate is `denyWrite`, not a permission system.** Landing a Core change means writing `packages/core/**` in the live tree, which the kernel refuses. A developer who deletes those entries gets agent-merges, and that is their call.
- **Worktree base is `.claude/worktrees/`** — already inside the clone, already gitignored, outside Vite's root. Nothing to configure.
- **`allowLocalBinding: true`.** Measured against srt 0.0.67: egress stays bounded by the allowlist. See [ADR-0015](../../docs/adr/0015-the-agent-binds-local-ports.md).
- **`.git/hooks/**` and `.git/config` join `denyWrite`; `core.hooksPath` points at a tracked `.githooks/`.** See [ADR-0016](../../docs/adr/0016-gits-own-directory-is-outside-the-review-path.md).
- **The dev server's port becomes an input**, threaded to `tauri.conf.json`'s `devUrl`, so a Preview does not collide with `1420`.
- **A change under `packages/core/**` triggers a full page reload, never a module swap.** Safe because the Session resumes from the mirror.
- **`launch_preview` is a Custom Tool whose work happens outside the Sandbox.** A confined process cannot open a window — srt gates mach lookups by service name and varnick's policy names none. The tool takes a worktree name validated against what git reports, never a command: it is a host-side process spawn driven by agent input.
- **The dialog is native, drawn by the Rust host**, and shows the Fence hunks.
- **Fence is `packages/harness/**`, `src-tauri/**`, `sandbox-policy.baseline.json`.** Smaller than Core: `packages/core/**`, `vite.config.*` and `package.json` are Core and launch silently.
- **The diff view ships in Core, not as a Surface**, because a Surface is Userspace and the agent writes Userspace freely.
- **The Preview's agent is git-blind**, accepted for v1. Its `allowRead` is the worktree; the worktree's `.git` points outside it. The fix, if it bites, is `allowRead` on the clone root instead.

## Testing Decisions

Existing seams, in order of preference — no new seam is proposed:

- **`sandbox.ts`'s policy generation**, asserted by `sandbox.test.ts` and `sandbox.boundary.test.ts`. Owns the policy changes. The boundary assertions are load-bearing and may only be strengthened.
- **`containment.probe.test.ts`**, which runs real operations under a real policy. Owns the nested-sandbox claim, because a probe is the only honest form of that assertion.
- **`drive.ts`**, the actor seam, headless. Owns every machine and view change: the worktree list, the diff view's states, the reload rule's pure half.
- **Rust `#[cfg(test)]` in `src-tauri`**, which owns route dispatch and argument validation. Owns the worktree-name validation and the spawn's argument shape. No test may open a dialog or spawn a real Preview.
- **`bun test packages`** for the harness units: the control-request round trip for `launch_preview`, and the Fence classification of a changed path.

What makes a good test here is what already makes one in this repo: assert the refusal, not only the success. A `launch_preview` that accepts `../..` as a worktree name is the failure that matters, and it is invisible in a passing happy path.

## Out of Scope

- Escalation queues, approval inboxes, and anything else that asks a human for a decision varnick could have declined to need.
- varnick rendering a general git client. The diff view shows pending worktree changes and nothing else.
- Giving the Preview's agent git. Named, deferred, fix recorded.
- Fixing ticket 30's second-root case. A Preview launched *in* its worktree has build root == clone root, which is the default path, so ticket 30 does not gate this work.
- Windows and Linux. Unmeasured, as before.

## Further Notes

**Bootstrapping.** The diff view is Core, so the agent cannot build it, and every later change to it goes through the flow it enables. The first one is hand-written.

**The one path from confined to unconfined is now short and named.** Agent edits `sandbox.ts` in a worktree, calls `launch_preview`, host spawns a varnick whose fence the agent wrote. The dialog is what stands in it. That is worth stating plainly rather than leaving in an ADR, because everything else in this amendment is a convenience and this is not.

**A claim carried in as reasoning, not measurement.** Nested Seatbelt profiles are believed to intersect, which is why a Preview launched from inside the Sandbox would be safe-but-useless and why `enableWeakerNestedSandbox: false` means what it says. Ticket 47 turns it into a probe.

*Measured (ticket 47, probe 11).* The conclusion holds and both reasons above were wrong. Nothing intersects, because nothing is established: the kernel refuses `sandbox_apply` inside any profile at all, so a nested profile granting nothing is refused exactly as a wider one is. And `enableWeakerNestedSandbox` is passed only in srt's `case 'linux'` branch — bubblewrap's `/proc` under an unshared PID namespace, in Docker — so it never governed this on macOS. A Preview launched from inside the Sandbox is still safe-but-useless, for a stronger reason than the one written here. See [ADR-0014](../../docs/adr/0014-core-is-authored-in-a-worktree.md).

---

# The window a developer actually sits in — amendment

Three findings from using varnick for a day's work, none of them about
containment and all of them about the window. They are grouped into one
amendment because they share a cause: the chrome around the conversation was
built to be *correct* and has never been asked to be *lived in*.

## Problem Statement

**The runtime panel cannot be got out of the way.** It occupies a permanent 320px
column and is read perhaps twice a session — once on a fresh clone, and again
when something is wrong. The rest of the time it is a description of the agent
sitting where the agent's output should be. On a laptop the conversation is
narrower than its own prose measure because of a panel nobody is reading.

**The composer moves by character or by line and nothing in between.** ⌥→ and ⌥←
move by word, because the platform does that for every text field. The Emacs
bindings a terminal-shaped developer reaches for — ⌥f and ⌥b — do not: they
insert `ƒ` and `∫` into the draft. The developer who typed them notices only
after sending, because the glyphs are small and the field is dark. Every other
Emacs motion in this composer works, which is what makes the two that do not
worth fixing: the muscle memory is already half-rewarded.

**The runtime panel says `credential none` while the agent is authenticated and
answering.** The row exists to prove that injection worked — that the host read a
credential and the confined process found it — and it is the one row on the panel
that says the opposite of the truth. `apiKeySource` is the SDK's word for which
store an *API key* came from, so a Session running on a subscription token gets
`none` and always will. The developer reading it has no way to tell that from the
failure it looks exactly like.

## Solution

**The runtime panel collapses, and the column goes with it.** A `runtime` toggle
lives in the composer's status line, beside the model and effort chips, where it
is visible whether or not the panel is. Hiding the panel removes it from the
right-hand column entirely; if there are also no Surfaces, the column is not
rendered and the conversation takes the full width. The toggle is in the Session
machine, not in a `useState`, so the states page can park in both readings and
`drive.ts` can prove the event is never refused.

**⌥f and ⌥b move by word, and ⇧⌥f / ⇧⌥b extend the selection.** The boundary
search is a pure function over `(text, caret)` in `domain.ts`; the component does
nothing but read the keystroke, call it, and set the field's selection. Keyed off
`event.code` rather than `event.key`, because ⌥f on a US layout arrives as `ƒ`
and the physical key is what the binding is about.

**The credential row reports what varnick injected, measured inside the confined
process.** The agent host can see its own environment, so it says which credential
variable is present — a name, never a value, exactly as `apiKeySource` already is
— and the panel renders that. When neither variable is present *and* the SDK says
`none`, the row is a warning rather than a fact, because that combination is the
real failure this row was built to catch and it has never once been able to show
it.

## User Stories

1. As a developer on a laptop, I want to hide the runtime panel, so that the conversation gets the width it was designed for.
2. As a developer who hid it, I want the toggle to stay visible, so that bringing the panel back does not require remembering a menu item or a keystroke.
3. As a developer with no Surfaces loaded, I want the right-hand column to disappear along with the panel, so that hiding it actually returns the space rather than leaving an empty gutter.
4. As a developer with Surfaces loaded, I want them to stay where they are when I hide the runtime panel, so that hiding one Core panel does not take Userspace's output with it.
5. As a developer reading the states page, I want a card showing the panel hidden, so that the collapsed reading is covered rather than only reachable by clicking in the live app.
6. As a developer whose agent is mid-Turn, I want hiding the panel to be accepted anyway, so that the chrome is not hostage to what the agent is doing.
7. As a developer typing a long prompt, I want ⌥f to move the caret forward one word, so that the motion I use everywhere else works here.
8. As the same developer, I want ⌥b to move back one word, so that the pair is symmetric and neither half is a special case.
9. As a developer correcting a phrase, I want ⇧⌥f and ⇧⌥b to extend the selection by word, so that selecting a phrase does not mean reaching for the mouse.
10. As a developer, I want ⌥f at the end of the draft to do nothing rather than wrap, so that a motion at a boundary is a no-op and not a surprise.
11. As a developer, I want ⌥f and ⌥b never to insert `ƒ` or `∫`, so that a motion cannot silently become an edit.
12. As a developer with the slash menu open, I want ⌥f and ⌥b to still move the caret, so that the menu does not swallow motions it has no use for.
13. As a developer whose draft spans several lines, I want word motion to cross the newline, so that the last word of a line and the first of the next are one motion apart.
14. As a developer running on a subscription token, I want the credential row to name the variable my token arrived in, so that I can see injection worked.
15. As a developer running on an API key, I want the same row to name that variable, so that the row means one thing under both credential kinds.
16. As a developer whose credential did not reach the agent, I want the row to say so as a warning, so that the one genuine failure is distinguishable from the two healthy cases.
17. As a developer, I want the row to remain a name and never a value, so that reading the panel over someone's shoulder cannot leak a credential.
18. As a developer resuming a Session, I want the row to be as true after a resume as on a fresh start, so that the panel does not degrade into a first-launch-only fact.
19. As a reviewer, I want the states page to hold a card for the failed-injection reading, so that the warning is looked at during design rather than only when it fires.

## Implementation Decisions

**The panel toggle is Session state, not view state.** A `TOGGLE_RUNTIME` event on
the Session machine's root, alongside `TOOL_CALL` and `TOOL_RESULT`, and a
`runtimeHidden: boolean` on its context defaulting to `false`. Root-level for the
reason those two are: it is a fact about the window, and no Turn state has
standing to decline it. `SessionInput` accepts it so a scenario can seed either
reading.

**Not persisted.** A reload starts with the panel shown. Persisting it means
either the machine reading `localStorage` — which breaks ADR-0001 — or the host
carrying a preference store, which is a feature rather than a fix. Named here so
the next person does not have to rediscover that it was a decision.

**The column's own emptiness is the component's decision, not the machine's.** The
`<aside>` renders when there is anything to put in it: an unhidden runtime panel,
or at least one Surface. That keeps ADR-0004 intact — a Surface never depends on
Core's panel being visible — and it is why story 3 and story 4 are separate.

**Word boundaries are a pure function in `domain.ts`.** `wordBoundaryForward(text,
caret)` and `wordBoundaryBackward(text, caret)` return the new caret index.
Emacs semantics: skip any run of non-word characters in the direction of travel,
then skip the run of word characters that follows. A word character is
`\p{L}`, `\p{N}` or `_`, matched with the Unicode flag, so a prompt containing
accented text or CJK moves the way the language reads rather than the way ASCII
does. `domain.ts` because it has zero imports by design and `drive.ts` already
imports it — the highest seam available, and no new one.

**The component does no boundary arithmetic.** The composer's `onKeyDown` matches
`event.altKey && event.code === 'KeyF' | 'KeyB'`, calls the function, and assigns
`selectionStart`/`selectionEnd` on the field. `event.code` rather than
`event.key` because ⌥f produces `ƒ`; `preventDefault` unconditionally on a match,
which is what stops the glyph. Placed above the slash-menu branch so story 12
holds.

**`RuntimeReport` gains `credentialSource`.** The name of the credential
environment variable the agent host observes in its own environment, or the empty
string when neither is set. Computed in `agent.ts` from `CREDENTIAL_ENV_VAR_NAMES`
and handed to `runtimeReportFrom` as an argument, the way `resumed` already is —
the SDK does not know what varnick injected, and a field read off the init message
would be inventing an answer. It travels the same wire and is rebuilt field by
field on the way back, like every other member.

**The row's three readings.** `credentialSource` is a name → render it.
`credentialSource` is empty and `apiKeySource` names something → render that,
because the runtime found a credential by a route varnick did not take. Both
empty or `apiKeySource` is `none` with no source → render a warning, in the same
colour the `memory` row uses for the fresh-agent case, saying the agent is
running without a credential varnick can account for.

**No new machine states.** All three changes are an event, a pure function and a
report field. The states page gains cards; `SESSION_STATE_PATHS` does not change.

## Testing Decisions

Existing seams only. No new seam is proposed.

- **`drive.ts`** owns the toggle and the word boundaries. `TOGGLE_RUNTIME` is asserted accepted from a Turn in flight, and asserted to flip and flip back — a toggle that only turns on is the failure this catches. The boundary functions are asserted directly against a table of drafts, including the two ends, a multi-line draft, a run of punctuation, and a non-ASCII word.
- **`bun test packages`** owns the report field: `runtimeReportFrom` under each credential variable and under neither, and the round trip through `parseRuntimeReport`, which is where a field nobody agreed to would be dropped. `turn.test.ts` already pins `apiKeySource` in three places and is the prior art.
- **The states page** owns the readings: a card with the panel hidden, and a card whose report has no credential source, so the warning is a thing that was looked at.

What makes a good test here is unchanged: assert the refusal and the boundary, not only the success. ⌥f at the end of a draft returning the same index is the assertion that stops the wrap bug nobody would think to look for.

## Out of Scope

- Persisting the panel's visibility across a reload. Decided against above, with the reason.
- A View-menu item or a keyboard accelerator for the panel. The status-line toggle is the whole affordance; a second one in Rust is Core surface for no new capability.
- The rest of the Emacs motion set — ⌃a, ⌃e, ⌃k, ⌥d. Only the two the developer reached for are in scope; the others are a separate decision about how far this composer imitates a terminal.
- Making `apiKeySource` itself correct. It is the SDK's field and its meaning is the SDK's to define; varnick reports beside it rather than over it.
- Any change to how a credential is read, stored or injected. This amendment only changes what is *said* about one.

## Further Notes

**The credential row is the one that matters.** The other two are comfort. This
one is a panel built to prove injection worked, printing the word `none` on every
subscription-token Session since it shipped — which is most of them. It is worth
noting that nothing failed: the agent answered, the Turns ran, and the only thing
wrong was the sentence describing them. That is the exact failure mode the panel
was ported from forge to catch, reproduced inside the panel itself.
