# Autonomous runs — implementation run report

Run of 2026-08-11. Ten tickets queued, one orchestrator, one authoring subagent
per ticket in its own Worktree, two independent reviewers per branch on the
Standards and Spec axes.

`main` started at `75a6e42` and is at `987b9ad`.

## What landed

| # | Ticket | Branch | State |
|---|---|---|---|
| 10 | ADR: Userspace shares Core's realm | `realm-adr` | **merged** |
| 04 | The window shows the version it is running | `window-shows-version` | **merged** |

## What is finished and waiting on a human

All four are complete, reviewed, fixed, re-merged against current `main`, and
land as fast-forwards. Every one of them writes `packages/harness/**` or
`src-tauri/**`, which the kernel refuses from inside the fence — so the landing
is the developer's, by design rather than by failure. Spec user story 33.

| # | Ticket | Branch | Commits | Fence files | Checks |
|---|---|---|---|---|---|
| 01 | Deny the tracked hooks directory | `deny-tracked-hooks` | 5 | 4 | typecheck 0, lint 0, drive 856, boundary **8/0** |
| 02 | A protected-path predicate | `protected-path-predicate` | 3 | 4 | typecheck 0, lint 0, drive 856, 840 pass |
| 03 | Previews run confined, dialog gone | `previews-run-confined` | 7 | 18 | typecheck 0, lint 0, drive 830, cargo 144 |
| 05 | The main window serves a built artifact | `main-window-serves-build` | 10 | **1** | typecheck 0, lint 0, drive 945, cargo 144 |

All four verified as fast-forwards onto `987b9ad` at the end of the run.
Worktrees and branches are left on disk deliberately — the diff is worth more
than any description of it.

Ticket 05 is the cheapest decision of the four and the most consequential: its
whole Fence footprint is **one line**, `beforeDevCommand` in
`src-tauri/tauri.conf.json`, and it is what unblocks 06, 07, 08 and 09. It is
irreducible — that field is the entire mechanism by which "what serves the
window" reaches `bun tauri dev`, and moving it into a `--config` overlay would
leave the documented first-run command still starting a dev server on the live
tree.

What to read before deciding it: that one line, and
`docs/adr/0020-the-main-window-serves-a-built-artifact.md`, which carries the
argument and names both losses — live Surface hot-reloading in the main window,
and Core edits in the live tree being invisible until built.

## What did not run, and why

| # | Ticket | Blocked by |
|---|---|---|
| 06 | Cut a pre-release | 05, which is Fence and pending |
| 07 | Keep the previous build | 05 |
| 08 | Promote the pre-release | 06 |
| 09 | The pre-release skill | 06 |

**These four were never started.** Not attempted and failed — never begun,
because the skill's rule is that a ticket is runnable when everything it names
has *merged*, and a branch that has not landed is not something the next ticket
can build on.

### The structural finding

Four of the five wave-1 tickets are Fence. Every remaining ticket sits behind
one of them. So the queue could not advance past the first wave without a human,
and no amount of further agent work would have changed that.

The spec anticipates a human merge as a rare event — *"A human remains required
exactly once per Fence change, and for nothing else."* True, and the frequency
is the thing: the tickets that *build* the autonomous-run feature are almost all
Fence, because the feature is about the fence. The first night is four merges
before anything downstream can start.

That is not a defect in the design. It is the bootstrap, and it is worth knowing
before the loop is relied on: **the autonomous-run feature cannot be built by an
autonomous run.**

## What review found that authoring did not

Every branch was reviewed by two independent agents that had not written it.
Findings that changed the code, rather than the prose:

**Ticket 04 — the dev server rendered a blank app.** Vite 8 does not apply
`define` under `vite serve`, only under `vite build`. The dev server was serving
`export const VARNICK_VERSION = __VARNICK_VERSION__;` with nothing defining the
identifier. Since ticket 05 keeps the dev server specifically for Previews, and
story 25 is *"a Preview to be a working varnick I can talk to"*, this would have
broken every Preview in a feature whose point is Previews. All 17 of the
branch's original assertions passed while the server was broken, because all 17
were pure and the bug was not. Replaced with a virtual module and an assertion
that boots a real server and fetches over HTTP.

**Ticket 02 — two false `land` verdicts on protected paths.** With git's default
`core.quotePath=true`, `git diff --name-only` emits non-ASCII paths *with the
quotes attached*, and the leading `"` defeated every entry, so a branch touching
`scripts/café.sh` would have landed unattended. Separately, `--name-only` reports
only a rename's *destination*, so `sandbox-policy.baseline.json → baseline.json`
printed as `baseline.json` and landed — meaning a branch could have deleted the
sandbox baseline, or moved `src-tauri/*` and `scripts/*` out of the protected
tree, with the gate saying yes. Both reproduced against real git before and
after the fix.

**Ticket 03 — a nested Preview was confined by a policy the agent wrote.** Two
reviewers disagreed on whether this was reachable; sending it back to be settled
by construction rather than by argument produced the run's most serious finding.
The chain is three steps, all available to an agent inside a Preview: write
`x/sandbox-policy.json` → `git worktree add .claude/worktrees/y` →
`launch_preview("y")`. The dismissing argument — that `worktrees_of` admits only
paths under `<clone_root>/.claude/worktrees` and no sibling matches — was true of
siblings and silent about children.

Probe 11d then established the sharper fact: **this ticket created the
reachability.** Before it, a Preview's agent could not run git at all
(`git status` exit 128), which ADR-0014 records as "git-blind, and that is
accepted for now" and which the branch had cited as a *benefit* it delivers. The
capability and the hole are one change. ADR-0019 now carries the generalisation:
*a feature that quietly creates the reachability of a hole it documents
elsewhere is not a documented hole.*

**Ticket 01 — a test passing for the wrong reason.** `git config core.hooksPath
/tmp/evil` was green while measuring nothing: the command died on an unreadable
`~/.gitconfig` before ever reaching the write, and the string `not permitted` in
that error satisfied the matcher. Also, the branch's security comment credited
the wrong mechanism — it said the deny holds because an undeletable README keeps
the directory from being swapped for a symlink, when measurement showed the
directory protected while *empty* and while *absent*. What actually holds it is
srt's move-blocking on the glob's static prefix.

**Ticket 05 — a correct fix in the wrong place.** The symlink hole itself was
found by the agent in its own self-review, before any reviewer saw the branch,
and correctly fixed with `dereference: true`. What review caught is subtler and
more useful: the fix would not have **survived its own feature**. The install
sequence was inlined in `build.ts`; ticket 06 also writes an artifact and has no
reason ever to open that file, so it would have re-implemented the sequence
without the flag and silently reopened a hole that had already been closed once.

The lesson is not "review finds bugs the author missed" — the author found this
one. It is that a fix living where only its author will look is a fix with an
expiry date. Lifted into a shared module so the property holds by construction.

### The defect that lived between two branches

The best finding of the run belongs to no branch and no reviewer, because it only
existed in the interaction of two.

Ticket 04's new assertions cover the **serve** half of the version module — the
right choice, since its bug was that `define` never runs under `vite serve`.
Ticket 05 then made the **build** half the path the main window actually runs.
So a regression in the bundler half would blank the window a developer opens
every morning, with all of ticket 04's assertions still green. The same defect as
04's original, pointing the other way, produced by two branches neither of which
was wrong on its own.

Ticket 05's agent found it by reading ticket 04's comment carefully enough to
notice which direction its argument ran, then wrote the matching block and proved
it bites by putting `apply: 'serve'` on the version plugin — which fails that
block and nothing else. Neither reviewer could have found it: each saw one branch.

This is the argument for a serial merge queue with an orchestrator that reads
across branches, and against reviewing branches purely in isolation.

### One pattern, five times

Three branches, and the orchestrator once, were pulled up for the same class of
defect: **a claim stronger than the mechanism.** Ticket 01's generated policy
prose said git works. Ticket 04's comments said the module reloads and fails
loudly. Ticket 05's ADR said an artifact appears "whole or not at all" when the
code is whole-or-*absent*. Ticket 03's ADR said a variable is read once when it
is read twice. And the orchestrator passed a reviewer's claim that a
trailing-slash strip was load-bearing straight through to an agent, which checked
it and found it false.

None was a correctness bug. All were in the register this repo explicitly
optimises against, and the reviews caught every one.

## Corrections made during the run

Recorded because a report that reads as a clean sweep is the one that gets
believed.

- The two "pre-existing failures" have **two different causes**, not one. One is
  `~/.gitconfig` (ticket 11); the other is a nix read-allowlist gap (ticket 13).
  Four agents and the orchestrator conflated them before it was measured.
- Whole-suite pass counts are **not a stable signal** — the second failure passes
  in some full-suite runs and fails in isolation. Per-file isolated counts were
  used to gate merges instead.
- `reap-worktree` was called a hole by the orchestrator and is not: `reapWorktree`
  calls `contentLanded`, which proves via `merge-tree --write-tree` that the
  branch is already in `HEAD`'s tree, and returns `false` on every error path.
  The guard is host-side and holds against any caller.
- Both ticket 10 reviewers reported its ADR number as a hard error. It was
  correct; they could not see that 0018–0021 were reserved across six concurrent
  agents.
- Ticket 01 corrected its own `sandbox.test.ts` figure (73→78, not 78→83), having
  quoted a post-change number as the baseline.

## Follow-ups filed

Three defects found by agents working on something else, kept off the branches
that found them.

| # | Ticket | Why it matters |
|---|---|---|
| 11 | git cannot run inside the Sandbox with a global config | `git --version` exits 128, so **ADR-0014's model does not work** on any machine with a `~/.gitconfig`. Needs a developer decision between widening the read allowlist and setting `GIT_CONFIG_GLOBAL` in the agent's environment overlay. |
| 12 | A quoted Fence path raises no flag | The hole ticket 02 closed in the landing gate exists in `isFencePath` too. Lower severity — its consumers are the two *reading* mechanisms — and it must not be fixed by copying ticket 02's answer, since the two predicates want opposite failure directions. |
| 13 | Read-allowlist gaps report as boundary failures | The containment probe is red on this machine for environmental reasons, in the two files where containment is *measured* rather than asserted. It absorbed a real defect's diagnosis for most of this run. |

Ticket 11 is the one that matters most: until it is closed, varnick cannot run a
night unattended on this machine regardless of what else lands.

## One coupling worth knowing about

Ticket 04's new `drive` section boots a real server and fetches over HTTP, so
`drive` now depends on `allowLocalBinding` being `true` in whatever policy
confines it. It is true today and `sandbox.test.ts` pins it — but a policy field
that was previously only asserted is now one the build needs, and if a clone ever
has it false the symptom will be `drive` failing with nothing mentioning the
sandbox.

## Nothing was parked

No ticket hit the three-round review limit, and no finding survived a fix aimed
at it. The four unlanded tickets are pending a human merge, which is a different
outcome from parking and should not be read as one.
