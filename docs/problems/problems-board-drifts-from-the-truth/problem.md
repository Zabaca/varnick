---
title: The Problems board and the work links drift from what is true
description: The Problems board puts each problem in a column from its option statuses, the branches tied to options and the work links of live sessions, and each of these drifts. Merges that build part or all of an option leave it accepted, so built work shows as Decided, and problems whose options shipped stay open under titles that are no longer true. A branch nobody works on keeps its option Building. `/work` prints "Linked to…" before anything is recorded, so an agent whose hooks can't record believes it is linked. A builder resumed for review fixes loses its link after its first round, a builder's own helpers are never linked, and only the lead's briefs, not the agent definitions, tell builders and planners to link at all.
impact: The user can't trust the board: it shows built work as waiting on a decision, abandoned work as being built, and solved problems as open. Keeping it true takes catch-up commits by hand, six so far (58c1649, 1e57d71, ac6aceb, c42bc6a, 0d1d161, 373f3bf). Chips and Building say less than the agents actually did, so the board can't answer who is working on what.
severity: mid
evidence: Two read-only audits on 2026-10-17 at bda4a64, over git (merges, statuses, branch ties), the code, the pane folders and Claude Code's transcripts on the user's machine; figures from the user's own data stay off the repository. Code read at bda4a64. Claude Code 2.1.302, installed here, read from the strings in its binary for its hook inputs and its resume path; nothing was run. Git checked in a throwaway repository for what deleting a branch does to its tie. The statuses the audit found wrong were corrected in 373f3bf.
status: open
---

## What the user wants

Decided on 2026-10-17, relayed by the coordinator, after reading the audits: the board and the links say what is true without catch-up commits.

1. The agent definitions, not each brief, tell builders and planners to link first.
2. A link that wasn't recorded fails loudly.
3. A subagent resumed with SendMessage gets its link back, and forks and nested helpers take their parent's where that is feasible.
4. Stale state is cleared or ignored: ties to deleted branches or to options that are shipped or rejected, and links whose option is shipped or rejected or whose pane is gone.
5. The merge decides the status, and closes the problem when nothing is left.
6. Partly built work with no live branch shows as being built, not Decided.

## Today

Verified in the code at bda4a64 unless marked.

### The board's columns

- **The rule.** A closed problem is Closed. Otherwise an `in-progress` option, a live session or subagent linked to an open option, or a tied branch with commits main lacks makes it Building; else an accepted option makes it Decided, a shipped one Shipped, a proposed one Backlog (`ProblemRules.column`).
- **Statuses lag the merges.** `issue-tracker.md` says a merge that leaves an option unfinished sets nothing. Slice merges therefore said "the option stays accepted": prompts-cant-run-on-a-schedule 01 after all three slices, work-cant-be-saved-or-chained 01 after two of four, and tasks-cant-be-handed-to-varnick 01 after its whole build. All three showed Decided. runs-only-from-a-checkout 02 stayed accepted a week after its last ticket merged. repo-not-ready-to-open-source 01 stayed in-progress after its last step was done, outside git.
- **No merge closes a problem.** Every problem closed so far was closed by a catch-up commit; 373f3bf closed fourteen.
- **A stalled branch keeps an option Building.** listening-never-answers 06 was accepted and its tied branch had two unmerged commits. Options 09 and 10 shipped in its place, and the board showed the problem Building for three days, until 373f3bf rejected 06.
- **What is already ignored.** A tie counts only for an option that isn't shipped, rejected or abandoned (`ProblemRules.liveBranches`), and a tied branch git can't count is left out (`ProblemsReader.ties`). Deleting a branch drops its tie: git removes the branch's config section (checked in a throwaway repository).
- **Leftover options on a closed problem.** `issue-tracker.md` says nothing about them. They stay proposed: two from before (frozen-screen-not-live 03, session-search-sees-only-the-start 02) and those of the problems 373f3bf closed. The board doesn't show them, since Closed wins.

### Work links

- **`/work` claims a link it can't see.** The script checks its arguments, prints the marker and "Linked to …", and exits. The record is written afterwards, by the hook after Bash, which reads the marker in the command's output. The hooks are fixed when claude starts. A session started before they existed, with the Problems board switch off, or by a build whose marker differs records nothing, and its agents read "Linked". This happened on the user's machine on 2026-10-10 in a pane resumed by a build from before the rename. Several builders' links were never recorded, and an unconsumed marker file was left in the pane's folder.
- **A resumed subagent loses its link.** SubagentStop deletes the subagent's record at the end of each round. When the lead sends a builder its review fixes with SendMessage, the builder works on under its first id (its later writes are logged under it) but has no option record. Four builders' logs show this. Between rounds, Building rests on the branch tie alone.
- **Helpers are never linked.** A subagent with no record works under its session's record, which is usually none. So a builder's own Explore or general-purpose helper, and a fork of it, shows as unlinked.
- **Only briefs say to link.** The builder definition says to tie the branch "as `issue-tracker.md` gives", and only that doc names `/work`. The planner definition says writing a problem's files links it, which misses its edits made through Bash. The orchestrator definition says nothing about links. Subagents never see the SessionStart line about `/work`; only the lead does. Since 2026-10-12 every builder whose brief named an option was linked to it, because the lead wrote `/work` into each brief. Before then, about a third ran no `/work`, and two briefs told builders to tie by hand instead.
- **Old records are ignored.** A session record stays in its pane's folder after the pane is gone, and is cleared only by `/work none`. The board counts a record only while its pane is live (`SessionBoard`'s cards) and only for an option that isn't shipped, rejected or abandoned (`ProblemWork.of`). So a dead pane's record makes nothing Building.

### What Claude Code's hooks carry (2.1.302, read from its binary, not run)

- Every hook's input has `session_id`, `transcript_path`, `cwd` and the permission mode. A subagent's call adds its `agent_id` and `agent_type`. No input names a parent agent.
- A `SubagentStart` event exists, with `agent_id` and `agent_type`.
- A subagent resumed by SendMessage runs again through the same runner that fires SubagentStart, under its own agent id (inferred from the code; not seen in a run).
- Beside each subagent's transcript Claude Code writes a metadata file. For a nested subagent it names the parent's agent id (seen on disk; undocumented).

## Unverified

- Whether SubagentStart fires on a SendMessage resume, and whether the metadata file exists when it fires.
- Whether `transcript_path` in a subagent's hook names the session's transcript or the subagent's.
- Whether a teammate's calls carry `agent_id` (already open in ADR 0020).
- Why one builder's record was removed at a lead's restart while the builder kept running. A pane that starts claude clears its subagents' records, but whether that is what happened was not confirmed.
- Whether a tab reopened from Recent or Completed brings back its pane's old session record. The record lives in the pane's folder, and whether a reopened pane keeps that folder's id was not checked.
