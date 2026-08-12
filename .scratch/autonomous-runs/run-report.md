# Autonomous runs — implementation run report

Run of 2026-08-11/12. Ten tickets queued, one orchestrator, one authoring
subagent per ticket in its own Worktree, two independent reviewers per branch on
the Standards and Spec axes.

`main` went from `75a6e42` to `1615543`: **74 commits, 91 files, +13,138 / −1,303.**

## Outcome

**All ten tickets merged.** Six new tickets filed from defects found on the way.

| # | Ticket | Landed by |
|---|---|---|
| 01 | Deny the tracked hooks directory | human merge |
| 02 | A protected-path predicate | human merge |
| 03 | Previews run confined, dialog gone | human merge |
| 04 | The window shows its version | **unattended** |
| 05 | The main window serves a built artifact | human merge |
| 06 | Cut a pre-release | **unattended** |
| 07 | Keep the previous build | **unattended** |
| 08 | Promote the pre-release | human merge |
| 09 | The pre-release skill | **unattended** |
| 10 | ADR: Userspace shares Core's realm | **unattended** |

Five landed with no human in the loop, and the pattern is the feature working:
the Fence merges came first, and each one removed merges from the tickets after
it. Ticket 07 needed no human **because** ticket 05 had moved the serving
decision into Core. Ticket 06 stayed landable because it refused to touch
`src-tauri/**` and filed the one-line fix as a ticket instead.

Final state: typecheck 0, lint clean, `drive` **1269 assertions** green (from
830 at the start), `cargo test` 144, `bun test packages` 838–839 pass / 1 skip /
0–1 fail — the one failure being intermittent and filed as ticket 13.

## The structural finding

Four of the five wave-1 tickets were Fence, and everything downstream sat behind
them. The spec is right that a human is needed "exactly once per Fence change";
the frequency is what bites. **The tickets that build the autonomous-run feature
are almost all Fence, because the feature is about the fence.** The first night
is four merges before anything else can start.

That is the bootstrap, not a defect. But it means the loop cannot be evaluated on
its first run, and the second run is the one that shows what it is worth.

## What review found that authoring did not

Every branch was reviewed by two agents that had not written it. The findings
that changed code:

**Ticket 02 — two false `land` verdicts on protected paths.** With git's default
`core.quotePath=true`, `git diff --name-only` emits non-ASCII paths *with the
quotes attached*, and the leading `"` defeated every entry — so a branch touching
`scripts/café.sh` would have landed unattended. Separately, `--name-only` reports
only a rename's *destination*, so `sandbox-policy.baseline.json → baseline.json`
printed as `baseline.json` and landed: a branch could have **deleted the sandbox
baseline, or moved `src-tauri/*` and `scripts/*` out of the protected tree**,
with the gate saying yes. Both reproduced against real git before and after.

**Ticket 03 — a nested Preview confined by a policy the agent wrote.** Two
reviewers disagreed on reachability; sending it back to be settled *by
construction* rather than by argument produced the run's most serious finding.
The chain is three steps, all available inside a Preview: write
`x/sandbox-policy.json` → `git worktree add .claude/worktrees/y` →
`launch_preview("y")`. The dismissing argument — that no sibling worktree path
matches — was true of siblings and silent about children.

Probe 11d then established the sharper fact: **the ticket created the
reachability.** Before it, a Preview's agent could not run git at all. The
capability and the hole were one change. ADR-0019 now carries the
generalisation: *a feature that quietly creates the reachability of a hole it
documents elsewhere is not a documented hole.*

**Ticket 04 — the dev server rendered a blank app.** Vite 8 does not apply
`define` under `vite serve`. All 17 of the branch's assertions passed while the
server was broken, because all 17 were pure and the bug was not.

**Ticket 07 — a false positive whose trigger was already in the repo.**
`entryScriptSources` saw `<script src>` inside HTML comments, and
`packages/core/index.html` ships a 19-line design brief that Vite copies verbatim
into every artifact. One pasted example and every build would have read as
"fails to start", falling back over a deliberately promoted release.

**Ticket 08 — three blockers, and criterion 8 ticked and false.** Nothing in
`drive.ts` covered the promotion at all, so it *looked* driven while proving
nothing — and all three blockers were things a driven refusal would have caught:
an unhandled invoke error on the region's initial state that took down the whole
window at launch; a crash between the changelog write and the record clear that
wedged the band into offering a shipped release for ever; and a "try again"
control that targeted `failed` rather than re-requesting the restart.

**Ticket 08 — the band never rendered on the screen the ticket was about.** Two
`ReleaseBand` renders in the diff branch, none in the chat branch. Every other
part of that ticket was downstream of a band nobody could see.

## The defect that lived between two branches

Ticket 04's assertions covered the **serve** half of the version module. Ticket
05 made the **build** half the path the window runs. So a bundler-side regression
would have blanked the window every morning with all of 04's assertions green —
the same defect as 04's original, pointing the other way, produced by two
branches neither of which was wrong alone. Neither reviewer could have found it;
each saw one branch.

This is the argument for an orchestrator that reads across branches, and against
reviewing branches only in isolation.

## One pattern, seven times

Branches were pulled up repeatedly for **a claim stronger than the mechanism**:
policy prose saying git works; comments saying a module reloads and fails loudly;
an ADR saying an artifact appears "whole or not at all" when the code is
whole-or-*absent*; an ADR saying a variable is read once when it is read twice;
a skill instructing a repair loop that cannot work; a machine comment describing
an `onError` that was not there; and the orchestrator passing a reviewer's
unverified claim through to an agent, which checked it and found it false.

Two sharper variants appeared:

- **Ticket 07 invalidated two *true* neighbouring comments** — a "the only copy
  of those tokens" claim made false by a second copy forty lines below. Nobody
  wrote anything wrong; the diff that falsified them did not touch the lines they
  were on.
- **Ticket 06 caught two documents that were true when written and false on
  merge** — both saying "no ticket carries this field yet" while the same commit
  made one carry it.

Ticket 08's author diagnosed the mechanism rather than the instances: all three
of its cases were places it *wrote the prose before the behaviour and never
re-read the pair together*.

## Corrections made during the run

A report that reads as a clean sweep is the one that gets believed.

- The two "pre-existing failures" had **two different causes**, conflated by four
  agents and the orchestrator before anyone measured: `~/.gitconfig` (ticket 11)
  and a nix read-allowlist gap (ticket 13).
- The remaining failure is **intermittent in full-suite runs** — measured 0/1/1
  across three consecutive runs on one tree. Per-file counts were used to gate
  merges instead. Recorded in ticket 13 so a lucky run cannot close it.
- `reap-worktree` was called a hole by the orchestrator and is not: `contentLanded`
  proves via `merge-tree --write-tree` that the branch is already in `HEAD`'s
  tree, host-side, past the bridge.
- Both ticket 10 reviewers reported its ADR number as a hard error; it was
  correct, and they could not see that 0018–0021 were reserved across six
  concurrent agents.
- The orchestrator **left tickets 11–13 and this report untracked for hours** —
  the exact failure `change-core` warns authoring agents about, committed only
  after ticket 06 noticed a ticket it had been told about did not exist.
- The orchestrator twice used a relative `cd` from inside a worktree and reported
  a missing worktree and a dirty live tree that were artifacts of the shell's
  cwd. Two agents hit the same trap. It produces a confident wrong answer.
- The orchestrator instructed ticket 08 to close the announcement race on its
  branch. The agent declined with a better argument and was right.

## Follow-ups filed

| # | Ticket | Why it matters |
|---|---|---|
| 11 | git cannot run inside the Sandbox with a global config | `git --version` exits 128, so **ADR-0014's model does not work** on any machine with a `~/.gitconfig`. The one defect that stops varnick running a night unattended at all. |
| 12 | A quoted Fence path raises no flag | The hole ticket 02 closed in the landing gate exists in `isFencePath` too, now landing on the review band. Must not be fixed by copying 02's answer — the two predicates want opposite failure directions. |
| 13 | Read-allowlist gaps report as boundary failures | The containment probe is red for environmental reasons in the two files where containment is *measured*. It absorbed a real defect's diagnosis for most of this run. |
| 14 | The bundle takes its version from the manifest | One line in `tauri.conf.json`, human-merged once, after which no release touches `src-tauri/**` again. |
| 15 | A carried note loses its paragraph | Every re-cut shrinks a carried announcement to its first sentence, silently, in exactly the case the accumulator exists for. |
| 16 | The announcement races the restart it announces | New and unique to the release region, not inherited. Carries the design notes from the attempt that was stopped and reverted. |

**Ticket 11 outranks all of them.** Until it is closed, this run could only happen
because the orchestrating agent ran *outside* the sandbox. varnick cannot yet do
this to itself.

## What the run is worth knowing for

Five tickets landed with no human. Every branch that needed one needed it for a
reason that was stated before it was hit. No ticket was parked, no finding
survived a fix aimed at it, and no branch reached the three-round review limit.

The reviews were worth more than the authoring. Six defects that would have
shipped were found by an agent that had not written the code, and two were found
only because two reviewers disagreed and the disagreement was settled by
construction rather than by picking the more confident one.
