---
problem: work-cant-be-saved-or-chained
title: A Task is a TypeScript module run by a durable Bun engine, the engine of orchestration-lives-in-one-session option 01, with Effect Schema types
summary: A Task is code: a TypeScript module found on disk, as custom apps are. It exports its input and result as Effect Schema, and a function that is given the capabilities as calls. Chaining is calling another Task, a failure is a typed error, and parallel steps come free. The engine is one long-lived Bun process in a zmx session that Varnick starts, the engine `orchestration-lives-in-one-session` option 01 proposes. Each capability call is written to a journal in SQLite before it starts and when it ends, and after a crash the function runs again from the top with the recorded results handed back. Capabilities that belong to the app (panes, the Website pane, notices, the TypeSafe key) are requests on Varnick's socket. The most expressive option, and one engine for Varnick's own build work too. But it is the biggest build, adds a resident process and new dependencies, asks every author (Claude included) to write replay-safe code, and can't enforce a Task's grants, since the module itself runs with the user's rights. Not recommended now.
status: proposed
---

## Solution

- **A Task is a module** in a project's tasks folder or the user's own, found as custom apps are ([ADR 0005](../../../adr/0005-custom-apps-are-local-web-servers.md)). It exports:
  - its input and result, as Effect Schema;
  - a function from the input and a set of capabilities to the result.

  Capabilities are calls: Claude (a prompt, a folder, an agent and a result schema), Website (a site and a goal), Judge (a Choice, Noul or Score), Notify, and Task (a name and an input).
- **Chaining and sub-tasks are code.** A result is a value, a sub-task is a call, a failure is a typed error the caller can catch or let through, and parallel steps are a concurrency-limited `all`. A loop is a loop, bounded by the engine's step and time budgets.
- **The engine is `orchestration-lives-in-one-session` option 01's:**
  - a Bun process written with Effect's stable core;
  - its own SQLite file;
  - kept in a zmx session of its own that the running Varnick starts at launch when it isn't running.

  Varnick's own problem and build flows become Tasks of this kind too.
- **Durable by replay:**
  - every capability call is written to the journal before it starts, with the pane's id where it has one, and again with its result when it ends;
  - after a restart or a crash the engine runs each unfinished Task's function again from the top, and every call already journaled returns its recorded result at once;
  - a call that started and never ended is reattached (a Claude pane, by its id), tried again if it has no effect (a Judge), or put to the person (a Website step that may have submitted).
- **Capabilities that live in the app are requests on Varnick's socket:**
  - starting a hidden Claude pane in a run tab and waiting on its result;
  - a Website pane;
  - the Run's notice;
  - a Judge call, made by the app so the TypeSafe key never leaves it.

  A Claude step can instead run headless, through the Agent SDK inside the engine, with its result schema as structured output (orchestration option 01's two runners).
- **Types:** Effect Schema in the module. JSON Schema is generated from it for the MCP tools and the forms, and a Judge call's answer is a literal union of its labels.
- **Triggers** are as in option 01: an Automation (a cadence, a Task and input values), `!task`'s form by hand, MCP tools for a session, and the phone later. Varnick hands each start to the engine.
- **Runs are shown** from the engine's journal. The board's Runs tab reads it over the engine's socket, and Claude and Website steps are panes in a hidden run tab, as in option 01.
- **Today's Task and Automation map as in option 01:** the loop is the Website capability, an Automation is a trigger, and a Run is any Task's execution.

## Trade-offs

- **For:**
  - **The most expressive.** Arithmetic, "the cheaper of two", maps over a list, fan-out and retries are plain code, with no format to outgrow.
  - **Real types and real tests,** through the language's types and Bun's test runner.
  - **One engine for both problems.** This is the engine `orchestration-lives-in-one-session` option 01 proposes, and its verify and fan-out steps are code here.
  - **Claude writes TypeScript well,** and the type checker catches what option 01's check catches.
  - **Bun is already on every host,** the headless one included.
- **Grants can't be enforced.** A module is code with the user's rights, as custom apps are (ADR 0005: no sandbox), so a Task can read files, reach the network and start processes without calling a capability. Grants bind only the capability calls, so they are a convention, not a boundary.
  - That breaks slice 3's rule that a session can't give an unattended run Skip: it can write a Task that does what Skip would allow.
  - Deno's permission flags could close it per Task, but ADR 0005 moved custom apps from Deno to Bun, and orchestration option 01 chose Bun for its SQLite.
- **Replay needs deterministic code.** No clock, no randomness and no I/O outside the capabilities, or a replay takes a different path than the first run did. Every author has to keep to it, Claude included, and the mistake shows only after a crash.
- **The biggest build.** It needs:
  - a long-lived process that Varnick starts, watches and upgrades;
  - Effect and a SQLite layer (CODING_STANDARDS: no new dependencies);
  - a socket protocol for every capability the app owns;
  - two languages for one feature.
- **A crash of the engine stops every Run** until it is back. The Claude panes keep going in zmx, but nothing moves to the next step.
- **On the headless host** the engine is a resident service, past ADR 0009's "nothing resident" and past slice 2's single timer.
- **The board and the Runs tab read another process,** so a Run shows only while the engine answers.

## User Stories

1. As the user, I want to write a Task as a function, so that a loop, a comparison or a fan-out is ordinary code.
2. As the user, I want a Task's input and result to be types the editor checks, so that a wrong field is caught as I write it.
3. As the user, I want Varnick's own build and review flows to run on the same engine, so that there is one place work is orchestrated.
4. As the user, I want a Run to carry on after a crash without repeating a capability call that already finished.
5. As the user, I want Tasks tested by Bun's test runner with fake capabilities, so that a change to one is checked before it runs.

## Implementation Decisions

- **The engine package** is orchestration option 01's: Bun with Effect 4's stable core, outside the Swift build, with its own lockfile. It is extended with:
  - a Task module's contract (schemas and a function);
  - the journal of capability calls;
  - replay.
- **Not Effect's durable workflow modules,** which are tagged unstable (orchestration option 01's reasons). The engine owns its journal.
- **The capability socket** is a request line per call, answered by the running Varnick on the main actor, as the automation and panel tools are, with the Tasks switch checked first.
- **Grants** are kept in Varnick, as in option 01, and checked at each capability request. The module itself is not confined.
- **Automations** become triggers, as in option 01's slice 1, with `automations.json` at version 2.

## Testing Decisions

- Bun's test runner over each Task with fake capabilities, and over replay: a recorded journal cut at each call.
- The socket half on the Swift side by `make build` and by hand after a restart.
- By hand, by the user: a Run killed in each kind of step, then the engine restarted.

## Out of Scope

- Confining a module (Deno, or a sandbox of Varnick's own).
- Moving any existing Swift feature into the engine.

## Further Notes

- **A combination worth keeping in mind.** Option 01's checked graphs could later gain a code step that runs in this engine, for the arithmetic a graph can't do. That needs this engine to exist, so it isn't a reason to build it first.
- **Order against the headless host's slice 2:** as option 01. Settle the record shape first. The engine comes later, and on the headless host it needs a resident service.
- **Verified on main at 65cf38a:** custom apps run with the user's rights and no sandbox (ADR 0005), and Bun is on the headless host. The rest of the engine is orchestration option 01's design, unbuilt and unverified (its Further Notes).
