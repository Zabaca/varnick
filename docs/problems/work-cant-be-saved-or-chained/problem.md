---
title: Work can't be saved as a named task that takes typed input, returns a typed result and feeds another
description: The user wants a Task to be Varnick's foundational primitive. A Task is a saved, named workflow, a state machine of steps that use capabilities (a Claude session, Varnick's own browser, a typed judgment from Jev, notify, and later others). It takes typed input, so one Task serves many inputs ("check the delivery price for {product} on {site}"). It returns a typed result, so one Task's result can feed another's input, and a step can run a sub-task. Automations would trigger Tasks, and a Task could also be started by hand, by a session or from the phone. In Varnick today, each kind of work stands alone and takes free text. The website loop takes a sentence and returns a quoted text. An automation runs one fixed prompt and returns nothing but its conversation. Nothing passes a result from one piece of work to the next.
impact: Every variation of a recurring job is a new automation with its prompt rewritten. Every job of several parts is one long Claude prompt that does the mechanical parts in Claude turns, which the System 1 / System 2 design was built to avoid. The website loop can't run on a schedule or take its site and product as inputs, and its answer is a sentence that code can't compare. The Automation record is about to set the shape of what a trigger starts across the headless host's protocol 29. Changing that shape after slice 2 of `prompts-cant-run-on-a-schedule` ships costs another protocol bump and a migration on every host.
severity: mid
evidence: The user's idea of 2026-10-15, relayed by the coordinator (below). Code and docs read on main at 65cf38a. TypeSafe's question types come from its live documentation (the primitives page), read 2026-10-15. That no automation is saved on any machine yet is the coordinator's statement, not checked here. Nothing was run.
status: open
---

## What the user wants (2026-10-15)

- **A Task is a foundational primitive:** a saved, named workflow. It is a state machine of steps, and each step uses a **capability**:
  - a Claude session;
  - Varnick's own browser (today's website loop);
  - a typed judgment from Jev on TypeSafe;
  - notify;
  - later, others.
- **A Task takes typed input,** so it isn't fixed to one input, and **returns a typed result.**
- **Tasks are built to be chained and sub-tasked.** One task's result feeds another's input, and a step can run a sub-task.
- **The browser is one capability.** A browser task puts the browser to a specific use, such as "check the delivery price for {product} on {site}".
- **Automations trigger Tasks.** An Automation becomes a trigger: a cadence, a Task and input values.
- **A Task can also be started by hand,** by a session through MCP, or from the phone.
- **A Run is one execution of a Task.**

## Why this is its own problem

- **`tasks-cant-be-handed-to-varnick`** built the website loop (option 01, accepted; [ADR 0039](../../adr/0039-varnick-carries-out-a-task-in-a-browser-of-its-own-with-jev-choosing-each-step-and-claude-steering.md)). Here that loop is one capability among several, and it keeps its own rules. The word **Task** moves from the loop to the new primitive.
- **`prompts-cant-run-on-a-schedule`** shipped Automation and Run ([ADR 0040](../../adr/0040-automations-are-fired-by-the-host-that-keeps-them-and-a-run-is-a-pane-kept-out-of-sight-until-opened.md)). Option 01's slices 1 and 3 are this Mac only, and slice 2, the headless host with protocol 29, isn't built. Here an Automation becomes a trigger, and a Run becomes the execution of any Task, whatever started it.
- **`orchestration-lives-in-one-session`** wants the same shape for Varnick's own planning and build work: task types, workflows as state machines of steps, gates, and nesting. Its option 01, a Bun engine written with Effect, is proposed, not built. One engine should serve both problems, and each option here says which.
- **Principles this problem inherits, not restated here:**
  - the harness owns the loop, Jev takes every action it can, and Claude writes and steers (the user's concept in `tasks-cant-be-handed-to-varnick`);
  - choosing TypeSafe is consent to send what a feature needs ([ADR 0016](../../adr/0016-a-spoken-requests-decide-step-asks-typesafe-jev.md)'s amendment of 2026-10-09);
  - agents never drive the user's screen without approval each time;
  - passwords, terms and submits go to the user.

## Today

Verified on main at 65cf38a unless marked.

### The website Task

- **It starts from free text.** The harness takes the task's sentence and the page the pane shows (`TaskRunner`).
- **It ends in one of four ways** (`Outcome`):
  - found, with the text that passed the read checks;
  - finished, on the page it ended on;
  - stopped;
  - gave up, with why.
- **The answer's shape is a check, not a type.** It is one of eight shapes asked of System 1 at the start (`AnswerShape`). Code checks a read against it, but the result is still a sentence.
- **One task runs at a time on this Mac.** Its pane is never saved, so a restart ends it.
- **A paused or waiting task raises no Notice** (ADR 0039, its first slice).
- **Every link on a page with a form waits for the person's Allow,** and so does every button there (`Gate.asks`; a search box doesn't count as a form). So a delivery page with a postcode field stops at every link, which matters for a step that runs with nobody watching.

### Automations and runs

- **The record holds a fixed prompt.** An `Automation` keeps a name, a prompt, a folder (Home when there is none), an agent, a cadence and its zone, permissions with allowed tools, a working limit, its switch, its last slot, its last 20 runs and a session's mark.
  - The prompt goes to Claude as written, with no placeholders.
  - A run's outcome is a state (running, waiting, done, a message's title, and the ways a slot didn't run). It holds no value.
- **The file is at version 1.** A newer version is read as "newer" and never written over (`AutomationFile`), so raising the version keeps an older build away from a new shape.
- **A run is a typed prompt's pane, kept out of sight until opened.** Its MCP config lists `notify` alone.
- **The board's Runs tab** lists the runs of automations, and nothing else starts a run.
- **Sessions on this Mac make, edit and switch automations** through four MCP tools (slice 3). The running Varnick answers them over its socket, so it can refuse a call and give an id back.

### What Varnick already has that is typed

- **TypeSafe's question types are judgments.** Its live docs list three:
  - Choice, a label from a set with a probability for each;
  - Score, a position on levels the asker writes;
  - Noul, a probability of yes.

  Every answer is limited to the options supplied. Varnick uses Choice and Noul (the spoken route, the judge, the screen picker, the relevance filter and the task's Jev), and doesn't use Score. These types can describe what a judgment returns, but not a task's free values: a price, an address, a list of sites.
- **MCP tool inputs are JSON Schema,** as MCP requires. Varnick's automation tools build `object` schemas with properties and required fields.
- **The text helper's conversation mode** passes text and asks for no schema.

### What a step would need that isn't there

- **A notice belongs to a pane.** The notifier and the page server read pane folders. A Run that ends, or that waits on the person in a step with no Claude pane, has nothing to raise a notice from. `prompts-cant-run-on-a-schedule` option 01 has the same gap as its open question 2.
- **Commands take no argument.** Each `!` command is one word, so a Task's input needs a form, not a command line.
- **The headless host has no WebKit,** so a website step can't run there. That it has no TypeSafe key is inferred, not checked. It runs nothing between requests until slice 2's timer.
- **Nothing passes a value between two pieces of work,** and nothing records one.

## Left to decide

- **How a Task is defined and written:**
  - a declarative file, a state graph in JSON or YAML;
  - code, in Swift or in TypeScript on Bun as custom apps are;
  - something Claude writes and Varnick checks;
  - whether a Task Claude writes runs at once or waits for the user.
- **Where the engine runs, and how a Run survives a restart, a crash and sleep:**
  - inside the running Varnick;
  - a process of its own;
  - inside a Claude session.
- **The types of inputs and results:** JSON Schema, TypeSafe's types, or both, and which one a step's branches follow.
- **Chaining and sub-tasks:**
  - how a result binds to an input;
  - how a step calls a task;
  - how a failure travels up to the step that called it;
  - what bounds loops and depth.
- **Capabilities granted per Task:**
  - permissions, and who sets them;
  - what may run with nobody watching;
  - what a website step does at a gate when the person isn't there.
- **How a Run of several steps is shown and resumed:** the board, tabs and panes, notices, and what a restart does to each kind of step.
- **What today's Task and Automation become,** and the glossary's new words. Task changes meaning, Run widens, Automation becomes a trigger, and the Task pane needs a new name.
- **Order:** whether the Task layer, or only its record shape, comes before slice 2 of `prompts-cant-run-on-a-schedule` option 01.
