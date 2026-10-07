---
problem: orchestration-lives-in-one-session
title: Launchy runs the agents as panes, and a Claude session stays the lead
summary: No engine. Launchy gains a small interface a session can call to open a Claude pane with an agent, a prompt and a folder, and to learn when the agent is waiting, done or gone and where its result is. The lead session starts its builders and reviewers that way instead of as hidden subagents, so each one is a pane the user can watch and answer, kept in zmx through restarts and crashes. The lead still orchestrates, turn by turn.
status: proposed
---

## Solution

Launchy exposes a way for a process on this Mac to ask it for a pane: which agent, which prompt, which folder (a worktree), which tab, and where to write a result. It opens a Claude pane exactly as a typed prompt does, `--agent` and all, kept in zmx when Keep sessions running is on. That includes skipping permission checks, Launchy's default, so the interface also decides whether a requested pane may skip them. The step is done when the agent writes its result to the path it was given. A Stop hook writes to a file named for the request each time the agent waits for input, so the caller can tell waiting from done.

The lead session (the orchestrator agent) uses this for the steps that need the user or take long: builders, reviewers, prototypers. It waits for a result file, reads it, and goes on. Short fan-out, such as two skeptics, can stay in the Workflow tool.

## Trade-offs

- **The most visible gain for the least new machinery.** Every long agent becomes a pane the user can watch, and type into to redirect it or answer its question.
- **Workers survive** while Keep sessions running is on (it is off by default, on here). Panes live in zmx, so a crash of the lead, of Launchy or of the Claude process hosting the lead leaves the builders running and their results landing in files. The 00:21 crash killed a lead that was itself running in zmx, cause unknown, so survival is shown for Launchy restarts (tested by hand on Oct 3), not yet for whatever that was.
- **Gates move into the panes.** An agent that needs a decision asks in its pane and waits, so a decision no longer splits a run.
- **Built from what exists:** panes, zmx, `--agent`, and the hook pattern of ADR 0001. No new language.
- **It is option 01's watchable runner.** If option 01 comes later, the interface is reused as is.
- **Useful beyond orchestration.** Scripts and other tools can open panes too; that was the need behind the scriptable-panes planning run that never finished.
- **The lead is still not durable.** Its plan, which steps are done and what was decided die with it. The workers survive, but someone has to pick up their results.
- **Orchestration is by hand, turn by turn.** A Workflow script can't drive panes, so loops (fix, recheck, repeat) are steps the lead takes one turn at a time.
- **Nothing is linked or budgeted.** Links, drift and statuses need option 03's fixes on top.
- **A panel full of panes.** Ten agents are ten panes; they need a tab or a place of their own.
- **A new way into Launchy.** Any process that can reach the interface can start a Claude session with an agent and prompt of its choosing, so it needs authorisation. With permission checks skipped, that means running any command as the user. And it works only while Launchy is running.

## User Stories

1. As the user, I want each builder and reviewer the lead starts to appear as a pane, so that I can watch it work.
2. As the user, I want to type into an agent's pane, so that I can answer it or redirect it without going through the lead.
3. As the user, I want an agent the lead started to keep running when the lead's session crashes, so that its work isn't lost.
4. As the lead session, I want to open a pane with an agent, a prompt and a worktree, and learn when it is waiting, done or gone and where its result is, so that I can run a step in a pane and continue from its result.
5. As the user, I want agent panes grouped in a tab per task, so that they don't crowd my own panes.
6. As the user, I want only my own sessions and tools to open panes, so that nothing else on my Mac can start a Claude session in my name.

## Implementation Decisions

- The interface is the scriptable-panes problem's to choose. That run's unfinished drafts compared a URL scheme, a command line over a local socket, and an MCP server. Its notes (unverified) favour authorising callers by the socket peer's user plus a per-pane secret that persists across restarts; it found that process ancestry fails because zmx daemons are reparented to launchd. They also favour failing fast when Launchy is down over relaunching it.
- A pane opened this way is an ordinary Claude pane: saved, restored and swept like any other.
- The result file alone says the step is done. Waiting and closing are reported by Stop and SessionEnd hooks writing to a per-request file, passed in `--settings` like the SessionStart hook (ADR 0001).
- The result path and its shape are in the prompt. Launchy doesn't read results; the caller does.

## Testing Decisions

- `make build` and checks by hand after a restart: open a pane through the interface, kill the calling session, and confirm the pane runs on and its waiting, end and result arrive.
- The authorisation check is logic that can be tested once a test target exists; until then, by hand.

## Out of Scope

- Orchestration in Launchy: no task state, links or budgets (option 01).
- Results Launchy itself parses.

## Further Notes

- The scriptable-panes planning run (Oct 3, 23:54 to 00:21) was killed by the 00:21 crash mid-draft, and nothing of it reached `docs/problems/`. This option needs that problem written properly first, or written here. Its run may still resume in its own session: four of its seven agents (two code maps, two outside surveys) finished and are cached in its journal, so only the three drafts would run again (unverified that the resume still works).
- Combines with option 03, which brings linking and the drift check. Together they're the cheapest way to make the work linked, visible and gated, with workers that survive a crash though the lead doesn't. Blast radius stays prose.
- Open questions:
  1. Is the lead's own durability worth an engine, once its workers survive? This is the real choice between this option plus 03, and option 01.
  2. One tab per task, or a place of their own for agent panes?
  3. Should the scriptable-panes problem be planned first, as its own problem, since both this option and option 01 need its answer?
  4. May a pane opened through the interface skip permission checks, and who decides: the caller, the setting, or a rule per agent?
  5. How does a dead lead or a waiting agent reach the user when they're away? Option 01's open question 7 asks the same.
