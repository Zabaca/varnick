---
problem: work-cant-be-saved-or-chained
title: A Task is a typed prompt that one Claude run carries out, calling the capabilities as tools, and Varnick checks its input, its calls and its result
summary: A Task is a markdown file, an agent-like definition. Its frontmatter holds a name, an input and a result schema, and the capabilities it may use; its body holds instructions in plain words with the input's fields in braces. A Run is today's run: a hidden Claude pane whose prompt is the body with the input filled in. Its MCP server lists the Task's capabilities as tools (website_task, judge, run_task, notify) and a task_result tool that ends the Run with a result checked against the schema. Claude is the engine. The order of steps, the branches and the chaining are Claude's choices, and the state is its conversation, kept in zmx across restarts. The smallest build by far, and the most flexible. But it isn't the state machine the user described: every Run is a whole Claude session even when every step is mechanical, the same input can take different paths, and nothing shows what a Task will do before it runs. Not recommended as the primitive. Fits as a way to try Tasks quickly, or as the Claude capability's own shape inside option 01.
status: proposed
---

## Solution

- **A Task is a markdown file** found on disk, as agents are ([ADR 0002](../../../adr/0002-agents-and-projects-come-from-disk.md)), in a project's tasks folder or the user's own.
  - **Its frontmatter** holds a name, an input and a result (as JSON Schema, the subset of option 01), the capabilities it may use, and a folder and agent for its Run.
  - **Its body** holds the instructions in plain words, with `{field}` for each input field.
  - Claude writes it as it writes an agent, and Varnick checks the frontmatter (the schemas, the capabilities named, the placeholders matching the fields).
- **A Run is today's run** (ADR 0040): a hidden Claude pane in a run tab, whose prompt is the body with the input filled in. Its MCP config lists `notify` and, by the Task's frontmatter, some of:
  - **`website_task`**: a site and a goal. It runs ADR 0039's loop in a Website pane added to the run tab and answers its outcome and text.
  - **`judge`**: a Choice, Noul or Score that Claude writes. It is asked of Jev under the relevance filter's TypeSafe consent, and answers the typed result.
  - **`run_task`**: another Task's name and its input, checked against that Task's schema. It starts a child Run and answers its id. A `run_status` call answers the child's state and, once it has ended, its result.
  - **`task_result`**: the result. Varnick checks it against the result schema, refuses it naming each wrong field, and on a valid one marks the Run ended with that result.
- **Claude is the engine.** It reads the instructions, decides the order, calls the tools and branches on what they return. Chaining is Claude passing one tool's answer into the next call, and a sub-task is `run_task`. A failure is a tool answer that Claude reads and acts on.
- **State is the conversation.** It lives in the run pane's zmx session, so a Varnick restart with Keep sessions running on keeps it. A Website call in flight at a restart is lost: its tool answers "interrupted", and Claude decides whether to try again.
- **Grants:**
  - the run's permissions are an automation's (ADR 0040), set in Varnick per Task;
  - the tools listed are only the capabilities the frontmatter names;
  - the Website loop's person-only rules hold inside `website_task`.
- **Triggers and display are as in option 01:** an Automation is a cadence, a Task and its input values; `!task` has a form; there are task tools for sessions; a Run is shown on the board's Runs tab, and its tab holds the Claude pane and any Website panes.
- **Today's Task and Automation:**
  - the loop becomes the `website_task` tool;
  - an Automation becomes a trigger;
  - today's prompt automation is a Task with no input fields and no tools beyond `notify`.

## Trade-offs

- **For:**
  - **The smallest build.** It is today's run, with the input filled in and four tools on the existing MCP server and socket path. There is no engine, no graph and no runs file of its own.
  - **The most flexible.** Claude handles what a graph would need a branch for: an odd page, a result that needs reading, a step that needs redoing.
  - **A session can write a Task in words,** with only its frontmatter to get right.
  - **The run is a pane the user already knows,** with its notices, its resume and its search.
- **It isn't a state machine.** The user described a Task as a state machine of steps, and this has no states Varnick can see. Nothing shows what a Task will do before it runs, and the steps column is whatever Claude did.
- **It runs against the System 1 / System 2 design.** Claude owns the loop and every Run is a whole Claude session, so mechanical steps cost Claude turns. ADR 0039's pilots measured the opposite split as better: the harness owns the loop, and Claude is woken only when needed.
- **Not repeatable.** The same input can take different paths, so a chained Task's behaviour is a sample, not a definition, and a test of it is an eval.
- **Guarantees hold only at the tools.** Varnick can check every call and the result, but not that Claude called `judge` before acting, or tried the second site.
- **Long tool calls.** A Website step can take five minutes, so `website_task` and `run_task` have to start and be asked again, not block, and Claude has to keep asking (inferred: Claude Code limits how long an MCP call may take).
- **A Run that ends without calling `task_result`** has no result, and the only remedy is to resume the conversation and ask.

## User Stories

1. As the user, I want to write a Task as instructions with fields, so that a new Task is as quick as a prompt.
2. As the user, I want Claude to work out the steps from my instructions, so that I don't draw a graph.
3. As the user, I want the result checked against its fields before the Run counts as done, so that another Task can rely on it.

## Implementation Decisions

- **The tools** are a set on Varnick's MCP server, listed in a run's config by the Task's frontmatter, never in an ordinary pane's. They are answered by the running Varnick over its socket as the automation tools are.
- **The Run record** is today's run record, plus the Task's name, its input, its result and its parent.
- **`automations.json` goes to version 2,** as in option 01.

## Testing Decisions

- The frontmatter check and the tools' schemas, by the make targets.
- Each tool by hand in an opened run, by the user.
- Whether Claude follows a Task's instructions reliably is an eval in agent-lab, against option 01's graph for the same Tasks.

## Out of Scope

- A graph, a check of the order of steps, and parallel steps, which are left to Claude.

## Further Notes

- **As a piece of option 01.** Option 01's Claude capability is this option's Run reduced to one step: a prompt, a result schema and `task_result`. Building option 01 builds most of this along the way.
- **As a first trial.** If the user wants to try typed, chained Tasks within days, this is the fastest way to learn which Tasks they write. Its Task files would then need rewriting as graphs for option 01.
- **Verified on main at 65cf38a:** a run's MCP config is chosen at each start (`notify` alone today), and the automation tools' socket path answers with ids and refusals.
