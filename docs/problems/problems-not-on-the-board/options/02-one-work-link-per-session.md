---
problem: problems-not-on-the-board
title: The Problems tab with one work link per session on this Mac; subagents and peers later
summary: Option 01's Problems tab, column rule, branch ties and shipped rule, with a smaller link. Each Claude pane keeps one work record and a log in its folder, and a subagent's work links its session. The hook on file writes, `/work` (whose script writes the record itself), the builder's first step and the SessionStart line are option 01's. Building is an open session here linked to an option, or a tied branch not yet merged. A session that ends keeps its links in its saved record only. A paired Mac's sessions get no chips, so the protocol stays at 16. Everything it writes keeps its shape under option 01, which can follow. Rough effort is three days, in two branches.
status: proposed
---

## Solution

**The Problems tab** is option 01's: the same columns, rule, cards, evidence, Show evidence and keys, over the same projects.

**One record per pane.** Each Claude pane keeps one work record, the session's: none (the default), a problem, or an option of a problem, with the repository's main checkout. Every link made is also appended to the pane's work log, as in option 01, origin included. There are no subagent records: a subagent's link is its session's.

**Made the same four ways as option 01:**

1. The hook before Write, Edit, MultiEdit and NotebookEdit links the session by path. It never replaces an option record; the log keeps the write either way.
2. `/work problem <slug>`, `/work option <slug>/<NN>`, `/work none` and `/work`. Its script checks the files and writes the session's record itself. There is no hook after Bash.
3. The builder's first step is `/work option <slug>/<NN>`, which also ties its branch in git config.
4. The SessionStart line names `/work` and the open problems.

**Building** is an option that isn't shipped, rejected or abandoned, named by an open pane's record here, or by a tied branch with commits not on main. A builder that runs as a subagent links its orchestrator's session, so that session's chip stands for it.

**Shipped** is option 01's rule: the merge that completes an option sets `shipped` in the merge commit.

**Chips** are option 01's, from this Mac's panes and its ended and Completed cards. A paired Mac's open sessions have no chips.

**History.** When a pane closes, its log's links go into its saved record. Nothing goes into the search database, so the history lasts as long as the card or its Recent entry.

## Trade-offs

- **About half of option 01's work,** and one change of the claude command line: two hook entries instead of three.
- **No protocol change.** No host needs to move with this Mac, though the headless host needs its reinstall to get the hooks for its own sessions.
- **A session with subagents is one link.** An orchestrator linked to option X by its builder stays on X while its planner writes problem Y. Y gets the session's chip from the log, but the chips can't say which agent did what.
- **`/work` in a subagent changes its session's record,** since the script can't tell who runs it.
- **Paired Macs' work is invisible here** until option 01's peer step: their sessions show no chip and put nothing in Building.
- **History after Recent and Completed drop a session** is lost, at 20 each.
- The rest of option 01's trade-offs hold: deterministic, misses work that writes nothing, a denied write links, a few milliseconds per write, the SessionStart line's tokens.

## User Stories

Option 01's stories 1 to 8, 10, 11, 12 and 14. Not 9 (subagents' own links) or 13 (other Macs).

## Implementation Decisions

- Option 01's decisions for the tab, the model, the reads, the hook before file writes, the skill, the branch tie and the saved field, unchanged.
- The record and log are option 01's format, so option 01 adds subagent records, the hook after Bash and the peers' fields beside them without changing what this writes.
- `/work`'s script finds the pane folder from the session file's variable and writes by rename, as the hooks do. Outside a Launchy pane it says so and writes nothing.

## Testing Decisions

- Option 01's tests, less the subagent and peer cases.
- **By hand, after a restart:** a new session is unlinked and its first line names `/work`; writing a problem links it; a builder subagent's `/work option` puts the card in Building with its orchestrator's chip; the merge moves it to Shipped; closing the session leaves the chip on its ended card.

## Out of Scope

- Subagent records, the hook after Bash, links from paired Macs, the search database's history: option 01's.
- Everything option 01 leaves out.

## Further Notes

- **Two branches:** the tab from files and branch ties (option 03), then the hooks, `/work`, records, chips and saved links.
- Moving on to option 01 later costs a second change of the claude command line, so a second restart for links in sessions started before it.
- Once accepted, the same ADR, `CONTEXT.md` and `where-it-breaks.md` changes as option 01, less the peers'.
