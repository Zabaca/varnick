---
title: Launchy's planning and build work is orchestrated inside one Claude session
description: The flows that plan and build Launchy (problem, options, the user's pick, tickets; then build, review, verify, fix, the user's hand test, merge) are run by a lead Claude session through Claude Code's Workflow tool and its subagents. Everything that work knows lives in that session. A crash loses the agents in flight, the user can't watch an agent or answer one, every decision of the user's splits a run in two, and an option's tickets live only in gitignored scratch folders.
impact: In about 15 hours on 2026-10-03/04, two crashes killed three reviewers and a 7-agent planning run; the reviews were redone by hand, the planning run's journal was never resumed, and after the second crash nothing ran for ten hours while the user was away; a ticket and a spec were deleted with their worktrees; and a builder's test renamed Launchy's real scratch folder in Application Support. The recorded runs spent about 9.9M tokens across 57 agents. The user carries the plan and the decisions between runs in their head.
severity: high
evidence: Measured 2026-10-04 from the Workflow tool's run records and per-run journals in Claude Code's folder for this project (two lead sessions, and the session that ran the scriptable-panes plan), git log of main, the main checkout's .scratch, and the product-board prototype (branch prototype/product-board) with its snapshot of 2026-10-04 12:40. The crash times were checked against the sessions' transcripts and zmx crash reports; the HOME incident is recorded in docs/agents/where-it-breaks.md.
status: open
---

## Today

A lead session (the user's own, or one running the `launchy-orchestrator` agent) runs the work. It hands planning to `launchy-planner`, code to `launchy-builder` in its own worktree, and review to `launchy-reviewer`. Longer stretches run as Workflow tool scripts: phases of agents with typed results, skeptic panels that vote on review findings, fix-and-recheck loops. The tool keeps each run's script, its journal of agent results and its agents' transcripts in the lead session's folder under Claude Code's own directory, and resumes a run only inside the session that started it.

Anything that needs the user happens between runs. The lead asks, the user answers, and the lead starts the next run with the answer in its prompt.

## Runs measured

Every Workflow run recorded for this project, Oct 3 23:20 to Oct 4 13:20 (local time). The table counts Workflow runs only. Seven of the 11 branches merged on Oct 3–4 never went through one: Agent-tool builders and reviewer teammates did that work, and both crashes killed reviewer teammates.

| Run | Agents | Tokens | Minutes | Outcome |
|---|---|---|---|---|
| Research for the local reranker | 4 | 1.49M | 34 | completed |
| Training queries for the reranker | 8 | 0.79M | 9 | completed |
| Plan scriptable panes | 7 | not recorded | 27 | killed by the 00:21 crash with 4 of 7 agents finished; never resumed, nothing in the repo |
| Review, verify and fix custom apps ticket 2 | 5 | 0.42M | 19 | completed; redoes a review the 00:21 crash killed |
| Review, verify and fix custom apps ticket 3 | 5 | 0.52M | 30 | completed; redoes a review the 00:21 crash killed |
| Write the local-reranker problem | 9 | 2.63M | 79 | completed |
| Build custom apps ticket 4, with a nested review loop | 9 | 1.09M | 61 | completed |
| Write the prototyper agent: draft, critique, revise | 3 | 0.43M | 33 | completed |
| Build the local reranker | 6 | 1.05M | 68 | completed |
| Diagnose restored app panes, three investigators | 4 | 1.21M | 31 | stopped by hand once the investigators agreed |
| Fix restored app panes | 4 | 0.22M | 15 | completed |

## Where it fails

**It isn't durable.** macOS XProtect killed the lead's Claude process at 22:07 on Oct 3, 20 seconds into a zmx review. At about 00:21 on Oct 4 the lead and the session running the scriptable-panes plan both died; the cause wasn't recorded. The lead was running inside zmx at the time (it reported its zmx session at 22:42 and kept it through two restarts), so zmx didn't save it from whatever that was. The reviewers were Agent-tool teammates inside the lead's process, with no journal to resume from, so all three reviews started again from nothing: the first 12 minutes later, the other two the next morning inside the review runs above. The scriptable-panes run did keep a journal. Four of its seven agents had finished, and when its session was next opened, at 10:32, the tool offered to resume the run with them cached. Nobody acted on it. The user had left at 23:44 asking the lead to drive the work to the end; after the 00:21 crash nothing ran until they came back at 10:43.

**It isn't visible.** Agents run inside the lead's process. The user sees a run's phases and each agent's state, not its work: no transcript to read, nothing to type into, and every question goes through the lead. Twenty-seven minutes into the diagnosis run, the user asked the lead: "this is taking a long time, whats going on?"

**It isn't gated.** A Workflow agent can't ask the user anything, so every decision ended one run and began another: accepting options, whether Claude panes get `LAUNCHY_PROJECT`, layout choices, hand tests and merge go-aheads (11 branches merged to main on Oct 3–4). What was decided between runs lives in the lead's context.

**It isn't linked.** Since 2026-10-09 most of this is recorded: a builder ties its branch to its option, hooks and `/work` link sessions and subagents to what they work on, the merge that finishes an option sets `shipped`, and the Problems tab reads these links rather than guessing them from shared words (ADR 0020). What is left:

- Builders keep tickets and specs in their worktree's gitignored `.scratch`, so removing a merged worktree deletes them. Custom apps ticket 1 went that way: the main checkout's issue folder holds tickets 2 to 4, copied by hand. So did the spec for reordering tabs by dragging, whose merge now traces to nothing.
- `shipped` is set only by a merge that remembers to. An audit on 2026-10-09 found two merged options still `accepted`, and one marked `shipped` with a ticket unbuilt.

**It isn't bounded.** A step's blast radius is prose in its prompt and nothing else: Launchy starts Claude panes with permission checks skipped unless the user turns that off, and the agents a lead starts inherit its permissions. The review runs paste the same constraints paragraph into every agent's prompt: no restart, a throwaway zmx folder, a temporary HOME, hands off the main checkout. The prose was wrong once, and nothing stopped the agent. A builder's migration test with a temporary HOME still renamed Launchy's real scratch folder in Application Support, restored within a minute, because Foundation ignores HOME. Risky steps also came just before both crashes: LaunchAgent and `launchctl` spikes in the lead's own process before the XProtect kill (the probable trigger the orchestrator agent records), and a reviewer had just started a `zmx run` test when the 00:21 crash came, whose cause is unrecorded. Agents' zmx tests left six zmx crash reports between 00:16 and 00:21, the last four seconds after that reviewer's test started.

**Agent results are claims.** The verify steps are what held up. Skeptics, harness proofs and rechecks caught real bugs before the user's hand test: a pane reconnecting on port 0, `bun add` editing the project's own `package.json`, a stuck Vite overlay. Ten of the 11 branches merged on Oct 3–4 got commits fixing review findings, twelve rounds in all. A fix for this problem has to keep verification as a step of its own.
