---
problem: orchestration-lives-in-one-session
title: A task engine in Launchy runs every workflow, and Claude sessions are its workers
summary: Launchy gets its own engine, a Bun process written with Effect, that is the only orchestrator. A task has a type, each type has a workflow (a state machine of steps), and workflows nest. Every transition goes into an event log; the user's decisions are states a task waits in; an agent runner starts Claude sessions, headless or as panes the user can watch, and records their session ids so a crash reattaches instead of re-running; verify and fan-out are step types with per-task concurrency and token budgets; tickets, specs, findings and the links between them belong to the engine. Built in four steps, the first with no agents at all. The leading candidate after the 2026-10-03/04 discussion.
status: proposed
---

## Solution

**Tasks and workflows.** A **task** is a piece of work with a type, such as a problem or a build. Each type has a workflow: a state machine whose states are steps and whose transitions are typed events. A step is one of a few kinds:

- **Agent step.** One Claude session, given an agent, a prompt, a folder, a declared blast radius and a budget. Its typed result is an event.
- **Check step.** Work the engine does itself and can trust: `make build`, a git query, a file existing.
- **Gate.** A state that waits for the user's decision, for as long as it takes. Nothing runs meanwhile.
- **Verify step.** Several agents look at one claim, then a join decides: a majority vote, all must agree, or the first refutation wins. Today's skeptic panels are this.
- **Child tasks.** Start tasks of another type and wait for them. This is how workflows nest, and with verify it is all the fan-out needed: a verify task's children are agent steps, then a join.

Two types come first, matching the flows run by hand today:

- **Problem**: write the problem and options, gate on the user's pick, write tickets. A picked option spawns one build task per ticket.
- **Build**: build in a worktree, review, verify the findings, fix and recheck until clean, gate on the user's hand test, gate on the merge.

**Event log.** Every transition, agent start (with its session id), result, decision and cost is appended to a log in the engine's own SQLite file. A task's state is the log folded through its workflow. After a crash or restart the engine replays the log, then reconciles each agent that was running.

**Agent runner.** One way to run a step, with two ways to host it:

- **Headless**: the Claude Agent SDK, inside the engine process, streaming every message (subagents included) into the log.
- **Watchable**: a Claude pane Launchy opens with `--agent` and the prompt, through option 04's interface. The user sees it and can type into it, and it survives Launchy restarts while Keep sessions running is on. A result file says the step is done; hooks say whether the agent is waiting for the user or its pane has closed.

Agent steps aren't idempotent: a builder run twice commits twice. So the runner records the session id before it waits. Recovery reattaches to a live zmx session or resumes the session by id, and never starts a fresh agent on its own.

**Blast radius.** Each step declares what it may touch: its folder, the paths it may write, commands it may not run (restarts, `launchctl`, installs), and the environment it gets (a temporary HOME together with `CFFIXED_USER_HOME`, a throwaway zmx folder). For headless steps the runner enforces the declaration through the SDK's permission callback and hooks. A watchable step is a Claude pane, which Launchy starts with permission checks skipped by default; enforcing the declaration there needs the pane started without the skip and with the step's rules passed in `--settings` (open question 3).

**Artifacts and links.** Tickets, specs, review findings and verdicts are the engine's, kept in its store, and no worktree holds the only copy. When a task runs, the engine records the links as they happen: option to tickets to branch to commits to merge. Problems and options stay committed markdown that the user owns. The engine reads them and links to them.

**Where it runs.** A Bun process using Effect 4, the TypeScript process from the earlier discussion of splitting Launchy, with its own SQLite file through Bun's built-in driver. The task board is a custom app (ADR 0005) that talks to the engine on a local port. The `launchy-orchestrator` agent shrinks to the user's chat front end to the engine: it starts tasks, shows them and records decisions.

**Build order.** Each step is usable before the next starts:

1. **Store and two task types, steps done by hand.** The event log, the problem and build workflows, gates, the links, and the board. Agent steps are marked done by hand or by the lead session, with their results attached. This already fixes lost artifacts, drift and the board's guessing, and makes every gate a state.
2. **The agent runner,** headless first or watchable first (an open question), with recorded session ids and recovery.
3. **Verify and fan-out steps,** with per-task concurrency and token budgets.
4. **The orchestrator agent shrinks** to a chat front end.

## Trade-offs

- **One store, one resume model.** A crash of any Claude session, Launchy or the engine loses no decided work. The log says which steps finished, and running agents are reattached or resumed rather than started again.
- **Every agent can be seen.** Watchable steps are panes. Headless steps stream into the log, which the board shows.
- **A decision can wait for hours.** A gate is a state, so the user's answer resumes the same task and no run splits. The lead no longer carries decisions between runs.
- **Links are recorded, not guessed.** The board reads the store instead of matching words, and nothing the engine writes can drift.
- **Blast radius becomes enforced for headless steps,** through the SDK's permission callback, instead of pasted into prompts where a wrong rule (temporary HOME alone) went unnoticed. A watchable step is a Launchy Claude pane, which starts with permission checks skipped by default. Enforcing it there needs agent panes started without the skip and with per-step rules passed in `--settings`, as the SessionStart hook is. Either way it is a per-step permission profile, which ADR 0002 chose not to have for agents.
- **Spend becomes visible, and capped for headless steps** through the SDK's per-run cap; a watchable pane has no cap. The SDK's `usage` leaves out subagent work and its dollar figure is an estimate, so a token budget reads per-model usage.
- **Fan-out is small once the runner exists:** a concurrency-limited loop over agent steps and a join. That is the main reason not to keep a second orchestrator for it (option 02).
- **Worktrees and merges become the engine's.** The Agent tool creates worktrees today and the lead unlocks and removes them; the lead also merges, and ticket 3 needed main merged in to settle a shared skill file. Each becomes a check step or an agent step.
- **A gate nobody sees is a stall.** The user needs a notification when a task waits on them or an agent dies, or the ten-hour stall of Oct 4 repeats with another cause. Launchy posts no notifications today.
- **Tickets in the store** change `issue-tracker.md` and every skill that publishes tickets to `.scratch`.
- **The biggest build of the options.** Bun and TypeScript are already in the repo for custom apps; the new cost is a long-running service Launchy's own work depends on, with its own dependencies (Effect, the Agent SDK), in an app whose standards say "no new dependencies". It has to be built, kept running, tested and upgraded.
- **The payoff arrives in pieces.** Step 1 fixes linking and gates but not durability or visibility; those need step 2. Until then the Workflow tool keeps running agents.
- **Effect's durable-workflow modules are unstable** (see Further Notes). The engine owns its event log and uses Effect's stable core (Effect, Schema, Scope, Schedule, Semaphore). Effect's SQL layer is tagged unstable too, so the store either calls `bun:sqlite` directly or accepts that churn.
- **Headless agents die with the engine** (inferred: the SDK runs claude as its child). Resume by session id brings back the conversation, not a tool call in flight. Watchable agents in zmx survive both Launchy and the engine, though the 00:21 crash killed a lead that was running in zmx, cause unknown.
- **The watchable runner needs Launchy to open panes on request,** and Launchy has no interface for that today (option 04's piece).
- **The engine can now break the work it runs.** A wrong transition table can strand a task, so the workflows need tests; unlike the Swift UI, they can have them.
- **Two places a Launchy feature can live,** Swift and TypeScript, and agents have to know which.

## User Stories

1. As the user, I want to start a task of a type, such as a problem or a build, so that the work follows that type's workflow without my steering each step.
2. As the user, I want a picked option to start one build task per ticket, so that I don't hand each ticket to a builder myself.
3. As the user, I want a task to wait at a gate until I decide, even hours later, so that my decision continues the same task instead of starting a new run.
4. As the user, I want to make a decision from the board or from my chat with the orchestrator, so that I can answer where I am.
5. As the user, I want to watch an agent's session while it works and type into it, so that I can redirect it or answer its question.
6. As the user, I want a crash of any Claude session, of Launchy or of the engine to lose no decided work, so that I never restart a review by hand.
7. As the user, I want an interrupted agent reattached or resumed rather than started again, so that a builder never commits the same work twice.
8. As the user, I want tickets, specs and findings kept when a worktree is removed, so that nothing is lost at merge.
9. As the user, I want the board to show each option's tickets, branch, commits and merge from recorded links, so that it never guesses.
10. As the user, I want an option's status and its problem's to follow the gates I passed, so that I don't fix statuses by hand.
11. As the user, I want each step to declare what it may touch, and the runner to stop it touching anything else, so that a test can't rename my real folders.
12. As the user, I want each task to have a token budget and a limit on concurrent agents, so that a loop can't spend without bound.
13. As the user, I want to see what each task and step cost, so that I know where tokens go.
14. As the user, I want review findings checked by a verify step before a builder fixes them, so that agents' claims are tested as they are today.
15. As the user, I want a verify step to stop as soon as its join is decided, so that nobody stops a run by hand, as the lead did when the investigators agreed and it stopped the diagnosis before its synthesis and skeptics.
16. As the user, I want to define a new task type by composing existing steps, so that a new flow (a diagnosis, a prototype) is a small addition, not new engine machinery.
17. As the user, I want my chat session with the orchestrator to show and drive tasks, so that I keep the conversational way of working.
18. As the user, I want the first step usable with agent steps done by hand, so that the store and gates prove themselves before agents run on them.
19. As the user, I want to be told when a task waits on me or an agent dies, so that work doesn't stand still while I'm away.

## Implementation Decisions

- **Process and language.** Bun with Effect 4: Schema, Effect, Scope, Schedule and concurrency are stable in 4.0; the SQL modules are not. The engine is a separate package in this repo with its own lockfile, outside the Swift build.
- **Store.** Its own SQLite file, never Launchy's search database (`where-it-breaks.md`: that database's syncs rewrite rows in place under a reader). Tables for tasks, an append-only event log, artifacts and links. Each task's current state is also written to a row, so lists don't fold every log.
- **Workflows as typed transition tables.** States and events are Effect Schema tagged unions with an exhaustive match. A pure transition function takes a state and an event and returns the next state plus commands. The engine runs commands as Effects, and their results come back as events. One transaction writes the event, the new state and the pending commands.
- **Not in step 1:** `effect/workflow` and `effect/cluster`, Effect's durable engine. It is tagged unstable, has no execution listing and no documented rules for changing workflow code with runs in flight. Revisit after step 2 if replay by hand proves heavy. Whether the transition tables are written by hand or come from a state-machine library is open (question 4).
- **Agent runner as one module with two adapters,** headless and watchable, behind one interface: start a step, get a handle carrying the session id, await the outcome, reattach. Two adapters make it a real seam. A fake runner is a third adapter, for tests.
- **Recording before waiting.** An agent step's "started" event, with its session id, is written before the engine waits on it. On recovery: a live zmx session is reattached; a dead one is resumed by id with a note that it was interrupted; a headless session is resumed by id; and if none of those works, the task goes to a gate asking the user.
- **Headless runs** use an allow-list and a permission callback that enforce the declared blast radius, and a per-run spending cap. They never run with permissions bypassed.
- **Watchable runs** start through a Launchy interface for opening a pane with an agent, a prompt and a folder. They are ordinary Claude panes opened through option 04's interface, so the launch sweep keeps them like any saved pane. Closing one ends its zmx session; the runner then finds the session dead and resumes it by id or asks at a gate.
- **Completion of a watchable run** copies the SessionStart hook's pattern (ADR 0001): the agent writes its result to a file named in its prompt, and that file alone says the step is done. A Stop hook, passed in `--settings` like the SessionStart hook, marks the agent waiting for the user; a SessionEnd hook marks the pane closed or crashed. Who closes a finished agent's pane, the runner or the user, is open.
- **Gates** are resolved by a decision event from the board, or from the chat front end (through a small engine command line the orchestrator agent calls). Watching option files is open question 6.
- **Links** are written by the engine as it acts: the option a ticket came from, the worktree and branch a build task made, the commits a step reported, the merge a gate approved.
- **Concurrency** is a semaphore per task under one shared limit, so no task starves the rest. Budgets add up the cost from each agent's result.
- **Engine lifecycle**: recommended for discussion, a long-lived process in a zmx session of its own name, started by Launchy at launch when it isn't running, like an app server. A custom app ends when its pane closes (ADR 0005), so the board is the custom app and the engine is not.

## Testing Decisions

- Transition tables are tested through the pure transition function with Bun's test runner: every path through each task type, every gate, and a replay of a recorded log after a simulated crash in each state.
- The runner is tested through its interface with the fake adapter: recovery when a session is live, dead, or unknown.
- One hand-run trial per real adapter: a headless reviewer and a watchable builder, each killed mid-step and recovered.
- The Swift side (the pane-opening interface) is checked with `make build` and by hand after a restart. Launchy still has no test target, and the engine's tests don't change that.
- A good test asserts on events and resulting state, not on how the engine got there.

## Out of Scope

- Moving any of Launchy's existing Swift features into the engine. That was the wider TypeScript split, and nothing here needs it.
- Projects other than Launchy, other users, and anything remote (open question 15).
- An ADR: written once an option is accepted.
- Rewriting today's Workflow scripts. They keep running until step 2 replaces them, and stay usable by hand after.

## Further Notes

**What exists, per the 2026-10-04 research (primary sources linked; not re-checked here):**

- **Claude Agent SDK** (`@anthropic-ai/claude-agent-sdk`). A streaming query with a folder per run; agents defined in code or named; JSON-Schema structured output on the result; a session id on every result, with resume and fork; hooks for session start, stop and end, before and after each tool use, and subagent start and stop; permission modes, an allow-list and a per-tool callback; cost on every result and a per-run spending cap. Subagent messages arrive in the stream tagged with their parent; `usage` leaves out subagent work, and the dollar cost is a client-side estimate. Sources: [TypeScript reference](https://code.claude.com/docs/en/agent-sdk/typescript.md), [hooks](https://code.claude.com/docs/en/agent-sdk/hooks.md), [permissions](https://code.claude.com/docs/en/agent-sdk/permissions.md), [sessions](https://code.claude.com/docs/en/agent-sdk/sessions.md), [cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking.md).
- **Headless CLI**: print mode with JSON or streaming JSON output, a JSON schema, resume by id, permission mode and an allow-list ([headless](https://code.claude.com/docs/en/headless.md)).
- **Effect 4.0**: stable since 2026-09-30, with long-term support to at least Sep 2029 ([release post](https://effect.website/blog/releases/effect/40)). Durable workflows (journal replay, durable deferreds for human waits, durable timers) ship in `effect/workflow` and `effect/cluster`, and can be wired to run in one process on SQLite under Bun (end to end unverified, below; [SingleRunner](https://github.com/Effect-TS/effect/blob/effect%404.0.0/packages/effect/src/cluster/SingleRunner.ts#L1-L61)). `cluster`, `persistence`, `sql` and `workflow` are all on the unstable list ([MIGRATION.md](https://github.com/Effect-TS/effect/blob/effect%404.0.0/MIGRATION.md#L40-L66)). The workflow engine has no way to list executions ([WorkflowEngine.ts](https://github.com/Effect-TS/effect/blob/effect%404.0.0/packages/effect/src/workflow/WorkflowEngine.ts#L39-L210)).
- **SQLite on Bun**: a first-party Effect driver over `bun:sqlite`, in WAL mode on one serialized connection. Its busy waits block the event loop ([driver source](https://github.com/Effect-TS/effect/blob/effect%404.0.0/packages/sql/sqlite-bun/src/SqliteClient.ts#L1-L105)). Deno has no first-party driver, which is part of why Bun was preferred.
- **State machines for Effect**: Effect 4 has none of its own. XState v5's pure `transition()` returns the next state and its actions without running anything, which fits an engine-owned log ([pure transitions](https://stately.ai/docs/pure-transitions)). `@xstate/effect` needs XState v6, in alpha, whose snapshots are incompatible with v5's ([registry](https://registry.npmjs.org/@xstate%2Feffect), [v5 to v6](https://stately.ai/docs/xstate/v6/xstate-v5-to-v6)). `effect-machine` takes Effect 4 schemas for states and events, but is a one-maintainer v0.28 ([repo](https://github.com/cevr/effect-machine)).

**Unverified or contradicted:**

- The SDK under Bun: reported to work for plain queries, with compiled bundles needing the CLI's path. Not tried here.
- Whether the SDK loads this repo's agent files by name without extra settings, and the exact shape of its structured-output option (the research spells it two ways).
- Whether a headless run passes its agent's question to the caller within the run; the research says so ([streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)).
- The research says the CLI has no `--agent` flag. Launchy already starts every agent pane with `claude --agent` (verified in the code), so that is wrong for interactive sessions. Whether print mode honours it is unverified.
- The research's example of a SessionEnd hook in settings is unverified. Launchy's working SessionStart hook is the pattern to copy.
- Whether a headless agent outlives the engine process (inferred no).
- Effect's durable engine on SQLite under Bun end to end, its pickup latency (10 s default poll), and the cross-process "database is locked" issue: all unverified, and avoided by the decisions above.

**The earlier TypeScript-split discussion** (Bun over Deno for its built-in SQLite; the SQLite database as the first contract between Swift and TypeScript) isn't written down in this repo; docs and git log were checked. This option uses its process and runtime, not its whole split.

**An alternative durable core.** An off-the-shelf durable-execution server, such as Temporal or Restate, could take the event log's place: mature replay, signals for human waits, its own history UI. It wasn't researched. It would add a daemon to install, pin and keep alive, as zmx did (ADR 0004), and its store wouldn't be the board's. The runner, blast radius, artifacts and links would still be Launchy's to build. Worth researching only if replay by hand proves heavy after step 2.

**Terms for `/domain-modeling`.** Task, workflow, step, gate and runner aren't in `CONTEXT.md`. "Workflow" also names Claude Code's Workflow tool, so one of the two needs another word.

**Open questions, most consequential first:**

1. **Subscription or API key** for agent steps? Answered by the user on 2026-10-04: print mode and the Agent SDK run on the Claude subscription, no API key (bare mode still needs one). Headless steps cost plan usage, not dollars, so budgets are in tokens and the plan's limits.
2. **Headless or watchable first?** Recommendation: watchable. It answers "can't watch" and "can't ask", survives restarts in zmx, and copies what Launchy already does. Headless follows for verify fan-out, where nobody wants ten panes. It brings watching and answering, not enforcement or caps, which come with headless. The research also says a headless run can pass its agent's question to the caller within the run (unverified), so answering an agent doesn't require a pane.
3. **Which kinds of step run as panes and which run headless** (builder, reviewer, skeptic, investigator, planner)? May an agent pane skip permission checks? Recommendation: builders, reviewers and planners as panes, since the user redirects and answers them; skeptics and investigators headless. A pane the engine starts doesn't skip permission checks and gets its step's rules in `--settings`, which revisits ADR 0002 for engine-started panes only.
4. **Transition tables: written by hand, XState v5's pure transitions, or a state-machine library built for Effect** (`effect-machine` now, `@xstate/effect` once XState v6 is stable)? This was the user's starting idea. Recommendation: write the build workflow's table by hand and with XState v5's pure `transition()` in a throwaway prototype before step 1, then pick; `effect-machine` and `@xstate/effect` are too young to hold saved state.
5. **What happens to `launchy-orchestrator` and the user's chat from step 1?** The lead could become the engine's client at once (starting tasks, passing gates, marking steps done by hand), stay as it is until step 2, or retire once the board answers gates. Recommendation: the engine's client at once, since step 1's agent steps are marked done by hand anyway.
6. **Where are gates answered, and how much of the board is in step 1?** The board, chat, editing the option file, or all three; status and recorded links only, or also the place gates are answered; and which prototype layout, A, B or C, whose verdict is pending. Recommendation: the board and chat in step 1, watching option files later if wanted; the layout waits on the prototype verdict.
7. **How does a waiting gate, a dead agent or a dead lead reach the user when they're away?** This applies to options 03 and 04 too. Recommendation: a macOS notification; whether the engine or Launchy raises it is open.
8. **Who merges:** the engine as a check step after the merge gate, an agent step when there are conflicts, or the user? Recommendation: a check step after the merge gate, an agent step when it conflicts, and a gate if the agent can't settle it.
9. **What shows that step 1 has proved itself, or that it isn't worth continuing?** Story 18 sets no bar. Recommendation: two features taken from problem to merge through it with every link recorded and no status fixed by hand; if the user keeps a parallel plan in chat, stop.
10. **Who writes statuses past `proposed`?** They belong to the user today. Recommendation: the engine writes them and commits only when the user passes the matching gate, so the user's decision is still the source.
11. **Where do tickets live:** only in the engine's store, or also as files in the main checkout for agents to read? Recommendation: the store, with a file written into each builder's worktree as a read-only copy.
12. **Should step 1 import the existing problems, options, merges and tickets,** with links recovered by hand where the board guessed? And what happens to the tickets in `.scratch` and to the issue-tracker convention? Recommendation: import, copying tickets from the main checkout's `.scratch`, and change the convention in the same step.
13. **How does the engine run:** a zmx session Launchy starts, a LaunchAgent (with the XProtect gotcha recorded in the orchestrator agent), or started by hand? Recommendation: zmx, started by Launchy.
14. **Does a task type live in code or in data?** Recommendation: code (typed tables) until there are three types.
15. **Is this for Launchy's own repo only, or for every project Launchy opens,** with task types in a project's `.launchy/` the way custom apps are? Recommendation: Launchy's repo only for now, with the store keyed by project so the choice stays open.
