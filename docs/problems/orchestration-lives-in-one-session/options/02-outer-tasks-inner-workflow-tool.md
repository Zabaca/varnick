---
problem: orchestration-lives-in-one-session
title: Launchy owns the outer task layer, and Claude Code's Workflow tool runs the inner fan-out
summary: Launchy gets option 01's outer layer (tasks, gates, the event log, links, artifacts and the board), but a step that fans out (a review with skeptics, investigators, a fix-and-recheck loop) is handed to a Claude session that runs a saved Workflow tool script and returns one result. Two orchestrators split the work at that seam.
status: proposed
---

## Solution

The outer layer is option 01's step 1: task types, workflows that nest, gates as states, an event log, engine-owned artifacts and recorded links, and the board. It also needs a way to start a Claude session for a step and collect its result.

Inner work that fans out isn't modelled in the engine. A step of the kind **workflow run** starts a Claude session whose prompt names a Workflow script saved in the repo, with the step's inputs as arguments. The script runs its agents, panels and loops as today and writes one result where the engine collects it. To the engine the whole review-verify-fix loop is one step.

## Trade-offs

- **The inner tool exists and works today.** Eleven runs in 15 hours used it: typed agent results, parallel panels with votes, nested loops, saved scripts run as child runs (the ticket 4 run called the saved review script by path), a worktree and a model per agent (builders ran on Sonnet, reviewers on Opus), a journal that resumes a stopped run with its finished agents cached, and phases shown while it runs. Anthropic maintains it and will improve it.
- **New fan-out shapes are cheap.** A lead writes a one-off script for a one-off flow (three investigators and a synthesis) without defining a task type.
- **Today's scripts carry over** nearly unchanged; they only need saving in the repo and a result written at the end.
- **It needs one runner, the watchable one.** Fan-out stays in the hosting session's Workflow tool, so the engine never needs the headless adapter or the Agent SDK. Option 01 needs both runners, since its fan-out is headless (its open question 2). Headless runs on the subscription too (answered by the user on 2026-10-04), so this saves building the adapter, not money.
  - **The counter-case:** once a runner exists, fan-out in the engine is a concurrency-limited loop and a join, a few lines, and the seam keeps the pains below.
- **Inner steps keep today's pains.** A crash loses the agents in flight. The run resumes from its journal with finished agents cached, but only in the session that started it, so that session has to be resumed first; whether the engine can do that unattended is unverified. Its agents can't be watched. They can't stop at a gate, so a decision mid-loop still splits the run. That is most of the agent work: in the runs measured, the fan-out runs were the long and expensive ones.
- **Two state stores and two resume models,** the engine's log and the tool's journal, with a recovery rule needed for every way they can disagree.
- **The board sees half.** An inner run is one opaque step: no per-agent cost, findings or verdicts until it ends.
- **The user's nesting already covers fan-out.** A verify task whose children are agent steps, then a join, is the same shape as a skeptic panel, inside one model.
- **The tool is outside Launchy's control.** It is opt-in, tied to one session, and its script API, journal format and resume rules can change without notice.

## User Stories

1. As the user, I want a task to hand a review loop to a saved Workflow script and get one result back, so that the engine doesn't model each agent.
2. As someone writing a one-off flow, I want to write a Workflow script on the spot, so that I don't define a task type for it.
3. As the user, I want gates, links and artifacts from the outer layer, so that the gains of option 01's step 1 still arrive.

## Implementation Decisions

- The outer layer is option 01 step 1 plus a runner for the session that hosts a script.
- Scripts are saved in the repo and take their inputs as arguments; each writes one typed result to a path the engine gives it.
- An inner run's journal is copied into the engine's store when the run ends, for the board.
- A crashed inner run is resumed by resuming its hosting session by id and relaunching the run from its journal.

## Testing Decisions

- As option 01 for the outer layer.
- Each saved script is tried by hand once per change, as today.

## Out of Scope

- Changing the Workflow tool.

## Further Notes

- The 2026-10-03/04 discussion weighed this against option 01, and the user was persuaded by the case against it: the runner is needed anyway, fan-out is then small, and the seam keeps the inner steps' pains while doubling the state. It stays on record as the fair alternative, not as a rejected one, since nothing has been decided.
- Unverified: whether a session started in print mode can run the Workflow tool at all. If it can't, the hosting session has to be interactive, which makes this the watchable runner of option 01 with a script inside.
- Open questions:
  1. Is there a fan-out shape the engine's verify and child-task steps can't express, that only a script can? If so, which one?
  2. Would keeping the tool for one-off flows run by hand, outside any task, cover the flexibility this option is for? Option 01 already assumes that.
