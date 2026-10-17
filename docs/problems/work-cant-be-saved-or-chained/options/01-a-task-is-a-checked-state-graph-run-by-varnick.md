---
problem: work-cant-be-saved-or-chained
title: A Task is a state graph in a JSON file that Varnick checks, run by an engine in Varnick's shared Swift package, with JSON Schema values and Jev choosing the branches
summary: A Task is a JSON file found on disk, as custom apps and agents are. It holds its input and result as JSON Schema (a small subset), and its steps as a graph. Each step uses one capability (Claude, Website, Judge, Notify, or another Task), takes its values from the input and from earlier steps, and names the next step for each outcome. Claude writes Tasks, and Varnick checks each one as a compiler would before it can run. The engine is a pure transition function in the shared package, so the headless relay can run it later. The running Varnick hosts it as it hosts automations, and keeps each Run in a file of its own, written before every wait. A Judge step's Choice labels are its branches: Jev picks at 0.7, and Claude picks below that or without TypeSafe, as in the website loop. Grants live in Varnick, not in the file. An Automation becomes a cadence, a Task and input values, and today's prompt becomes the built-in Claude prompt Task. Accepted 2026-10-15. Slice 1 is the record shape on this Mac, with no protocol bump: automations as triggers at file version 2, the Run in a runs file of its own, the two built-in Tasks, and the Task pane renamed the Website pane. The headless host's slice 2 is built on that shape. Slice 2, the engine on this Mac, comes in two parts: 2a, Task files, the check and the engine with Claude, Judge, Notify and sub-task steps, started by hand, by a session and by a parent, built beside the headless host's slice 2; 2b, Website steps and automations of any Task, built after it.
status: in-progress
---

## Solution

### A Task

A **Task** has:
- a name and a one-line description;
- its **input** and its **result**, each an object of named, typed fields;
- its **steps**: named states, one of them the start;
- an **end** that builds the result from the input and the steps' results.

Each **step** uses one **capability**, takes its values from the Task's input and from earlier steps' results, and names the next step for each of its outcomes.

**Where Tasks come from:**
- **Files on disk,** as custom apps and agents are found ([ADR 0002](../../../adr/0002-agents-and-projects-come-from-disk.md), [ADR 0005](../../../adr/0005-custom-apps-are-local-web-servers.md)):
  - a project's tasks folder, beside its custom apps folder, or the user's own;
  - a project's Task hides the user's Task of the same name;
  - the files are read again each time a list of Tasks shows.
- **Two built-in Tasks** that ship with Varnick:
  - **Claude prompt:** one Claude step, whose input is a prompt, a folder and an agent. It is today's automation.
  - **On this site:** one Website step, whose input is a site and a goal. It is today's `!task`.

### Written as JSON, typed with JSON Schema

This prototype encodes the decisions: the subset of JSON Schema, bindings in braces, one edge per outcome, `else`, and a Judge step whose answers are its branches.

```json
{
  "name": "Delivery price",
  "description": "What delivering a product to a country costs on a site",
  "input": { "type": "object", "required": ["product", "site", "country"],
    "properties": { "product": { "type": "string" }, "site": { "type": "string", "format": "uri" }, "country": { "type": "string" } } },
  "result": { "type": "object", "required": ["quote"],
    "properties": { "amount": { "type": "number" }, "currency": { "type": "string" }, "quote": { "type": "string" } } },
  "start": "look",
  "steps": {
    "look":  { "use": "website", "with": { "site": "{input.site}", "goal": "How much is delivery of {input.product} to {input.country}?" },
               "next": { "found": "check", "else": "fail" } },
    "check": { "use": "judge", "with": { "noul": "Does `quote` state the cost of delivery to `country`?",
               "state": { "quote": "{steps.look.text}", "country": "{input.country}" } },
               "next": { "yes": "read", "no": "fail" } },
    "read":  { "use": "claude", "with": { "prompt": "The delivery cost stated in this text, as a number and an ISO currency code: {steps.look.text}" },
               "result": { "type": "object", "required": ["amount", "currency"],
                 "properties": { "amount": { "type": "number" }, "currency": { "type": "string" } } },
               "next": { "ok": "end" } }
  },
  "end": { "amount": "{steps.read.amount}", "currency": "{steps.read.currency}", "quote": "{steps.look.text}" }
}
```

- **Types are a fixed subset of JSON Schema:**
  - string, with the formats uri and date;
  - number, integer and boolean;
  - enum;
  - an object with required fields;
  - an array of one type.

  Nothing else is accepted: no references, no oneOf, no patterns. JSON Schema because it already crosses each seam unchanged:
  - a Task's input is the argument schema of the MCP tool that starts it;
  - a Claude step's result is the schema of the tool it answers with;
  - the panel and, later, the phone draw a form from it.
- **TypeSafe's types are a Judge step's results.** They aren't the language of the Task:
  - a Choice gives one of its labels with the probabilities;
  - a Noul gives a probability;
  - a Score gives a position and its legend.

  A Choice's labels, and a Noul's yes and no, are the step's outcomes, so a judgment picks the branch. That is the harness-owns-the-loop design applied to a whole Task: Jev picks each branch, and Claude is asked only when Jev is unsure.
- **Bindings** are `{input.field}` and `{steps.name.field}`:
  - a string that is exactly one binding keeps the field's type, so a number stays a number;
  - a binding inside longer text is written as text.

### The capabilities

| Capability | Takes | Outcomes | Result |
|---|---|---|---|
| **Claude** | a prompt, a folder (Home when absent), an agent, and the step's result schema | ok, failed | the fields of its schema |
| **Website** | a site and a goal | found, finished, gave up | the passing text, and the page it ended on |
| **Judge** | one Choice, Noul or Score question, and the state it reads | a Choice's labels; yes and no for a Noul; ok for a Score | the label, probability or position |
| **Notify** | a title and a body | ok | none |
| **Task** | a Task's name and its input | ok, failed | the child's result |

- **Claude:** a hidden Claude pane, started as an automation's run is (ADR 0040). It answers through a `task_result` tool on the pane's own MCP server, whose input schema is the step's result schema, read from a file the host writes into the pane's folder before the pane starts.
  - The pane's MCP server checks each call against that schema, as it answers `notify`, and refuses one that doesn't fit, naming each wrong field. Claude then tries again. An accepted value goes into a result file in the pane's folder, and the host moves it onto the step. So the headless host's relay can answer it with no running Varnick. Amended 2026-10-15 at the user's word: the running Varnick was to check each call over its socket.
  - A turn that ends with no valid result is failed: "ended without a result".
  - A Needs you mid-step is the pane's own notice, as for any run.
- **Website:** the loop of ADR 0039, unchanged, in a Website pane (today's Task pane) that opens the site before it starts.
  - The person's rules hold whatever the Task's grants say: they type secrets, tick terms and allow every submit but a search.
  - Stop by the person ends the whole Run. It is never an outcome a Task can catch.
- **Judge:** Jev, under the relevance filter's TypeSafe consent, in the shape the task's Jev call already uses.
  - Jev's top label is followed at 0.7 or more, the bar the website loop acts on.
  - A Noul is yes at 0.7 or more and no at 0.3 or less.
  - Between those, or without TypeSafe, or when Jev fails, Claude picks from the same labels, and the Run's line says so.
  - Never this Mac's Gemma, for ADR 0039's reason: its probabilities were measured not to separate right from wrong.
- **Notify:** a notice of the Run's own (below), which goes to the phone by the same routing.
- **Task:** a sub-task. The child is a Run of its own, linked to its parent, and its result is the step's result.

### The graph and its failures

- **An edge for each outcome.** `else` catches the outcomes a step doesn't name.
- **`end` and `fail` are the two ends.** `end` builds the result. `fail` ends the Run failed, with the step and the outcome that led there.
- **A failure travels up.** An outcome with no edge and no `else` fails the Run with that outcome, and a parent's Task step then takes `failed` with the child's reason. Stop ends the whole tree: the parent and every child.
- **Loops are allowed, and bounded.** A step can lead back to an earlier one (try another site). Each Run has three bounds:
  - at most 50 steps;
  - its working limit in awake time, counted as an automation's is;
  - sub-tasks at most 3 deep.
- **A Task may never reach itself** through its sub-tasks, directly or through others.

### Checked before anything runs

Claude writes Tasks, and Varnick's check is the compiler. A skill tells Claude the format, as the custom-apps skill does for apps. The check runs at every read, and confirms that:
- the file parses, and its schemas are in the subset;
- every step's capability exists, and its `with` fits that capability;
- every edge lands on a step, `end` or `fail`;
- every binding names a field that has a value on every path to that step, and its type fits where it goes;
- `end` gives every required result field;
- every sub-task exists, is valid, and makes no cycle within the depth limit.

An invalid Task is listed with each of its problems and can't start. A `task_check` MCP tool returns the same list for a file, so a session can fix a Task before anything runs.

### Starting a Task

- **By an Automation:** a cadence, a Task and the input values, with the permissions override it has today.
- **By hand:** `!task` lists the Tasks, built-ins first. Choosing one shows a form in the panel, drawn from its input schema, and ↩ starts a Run. On this site opens its Website pane at once, as `!task` does today.
- **By a session,** through Varnick's MCP server, behind the Tasks switch:
  - `tasks_list` gives each Task with its input and result schemas, its capabilities and whether it is valid;
  - `task_run` takes a Task's name and an input, checked against the schema, and answers the Run's id;
  - `task_run_status` gives the Run's state, its current step and, once it has ended, its result.

  They are answered by the running Varnick over its socket, as the automation tools are. A run's own session never gets them.
- **From the phone:** later, with the headless host's protocol (slice 3).

Every way in checks the input against the schema before anything starts, and a refusal names each wrong field.

### Grants live in Varnick, not in the file

- **Settings › Tasks keeps each Task's grants** for its Claude steps. These are exactly an automation's choices today:
  - Varnick's Skip permissions by default;
  - or Ask, Allowed tools only or Skip;
  - and the allowed tools.

  An Automation can override them for its own runs, as it can now.
- **A file can't grant itself anything.** So a session that writes or edits a Task can't give it Skip, which is slice 3's rule for automations. A file that a session wrote or changed is marked as automations are, by a change in its contents, until the user has seen it.
- **A Claude step's MCP config** lists `notify` and `task_result` alone. It never gets Screen access, Panel access, the automation tools or the task tools, so a Run starts other Tasks only through a Task step in its graph.
- **A Website step with nobody watching:**
  - a gate is Needs you, and the Run waits, up to 24 hours as an automation's run does;
  - it is answered on the Mac only, since the Website pane isn't listed to the phone;
  - under Allowed tools only, a gate fails the step ("gave up: needs your Allow") instead, so that run never waits;
  - one Website step runs at a time on this Mac, and a second waits its turn instead of failing.
- **A sub-task runs with its own grants,** never with its parent's.

### Showing and resuming a Run

- **A Run** is one execution of a Task. Its record holds:
  - what started it: an automation, by hand, a session's title, or a parent Run;
  - the Task as it was at the start, a copy kept in the record, so an edit doesn't change a Run that is going;
  - its input;
  - each step's state and result;
  - its outcome.
- **The board's Runs tab** lists every Run newest first, whatever started it, with its Task, its state and its current step. Opening one shows:
  - its steps as lines written from facts, marked with who acted (Jev, Claude, the harness, the person), as the Website pane's trail is;
  - its result as fields.
- **One run tab for each Run,** hidden until opened ([ADR 0040](../../../adr/0040-automations-are-fired-by-the-host-that-keeps-them-and-a-run-is-a-pane-kept-out-of-sight-until-opened.md)'s rule):
  - Claude and Website steps are panes in it, each added as its step starts;
  - Judge and Notify steps are lines only;
  - a sub-task's Run has a tab of its own and a line in its parent that opens it.
- **The Run's own notice:**
  - Done when it ends with a result;
  - Needs you when a step waits on the person and no pane of its own raises the notice;
  - Stopped on an error when it fails;
  - a Message from Notify.

  This is the notice for a run rather than a pane that `prompts-cant-run-on-a-schedule` open question 2 needs too.
- **After a restart or a crash:**
  - **Claude step:** its pane is restored hidden, as a run's is today, and the engine reattaches to it by the pane's id.
  - **Website step:** its pane is never saved (ADR 0039), so it is interrupted. It is tried once more from the start if no submit was allowed in it. Otherwise the Run waits on the person with Retry and Stop, since a second try could buy twice.
  - **Judge step:** asked again, since it has no effect.
  - **Notify step:** recorded as sending before it is sent and as sent after. A restart between the two sends nothing again, so it is sent at most once.
- **Sleep:** nothing advances. The once-a-minute check, the launch and the wake move Runs on, as they fire automations.

### What today's two become

- **An Automation is a trigger:** a cadence, a Task and its input values. It keeps its permissions override, zone, working limit, switch, last slot, slot history and mark.
  - Today's prompt, folder and agent become the input of the built-in Claude prompt Task.
  - A slot that ran names its Run.
  - The automation tools take a Task and an input beside today's prompt fields.
- **Today's Task is the Website capability.** Its loop, gates and secrets are unchanged, its pane is the Website pane, and `!task`'s one-off is a Run of On this site started by hand.
- **A Run is any Task's execution.** It is no longer only one slot of an automation.

## Trade-offs

- **For:**
  - **The engine owns the loop, and judgments pick the branches.** It is the System 1 / System 2 split ADR 0039 measured, one level up. Mechanical steps cost no Claude turn, and Claude is woken only for writing, for steering and when Jev is unsure.
  - **One language crosses every seam.** The same JSON Schema is the MCP tool's arguments, Claude's answer tool, the panel's form and the check.
  - **Nothing runs that the check hasn't passed.** A wrong binding or a missing branch is found before the first step, not at step four.
  - **It builds on what exists.** It follows `AutomationSlot.check`'s pattern (a pure function in the shared package that the relay can call), the automation store's file rules, the run tab, the automation tools' socket path, and the harness unchanged.
  - **Grants stay the user's,** with the same choices automations already have.
- **A new format to learn and to keep stable.** JSON graphs are verbose to write by hand, so this relies on Claude writing them and the check catching mistakes. A changed format needs a version and a reader for the old one.
- **Less expressive than code.** There is no arithmetic, no "the cheaper of two" except through a Claude or Judge step, and no fan-out in this design. A "map over sites" step and parallel branches are later.
- **A second engine,** if `orchestration-lives-in-one-session` option 01 is built in Bun as proposed. Accepting this option points that problem at this engine: its problem and build types become Tasks once an Ask capability (a Choice put to the user) and fan-out exist.
- **Website steps with nobody watching are often stuck.** Any page with a field that isn't a search box asks at every link (`Gate.asks`), so unattended price checks will stop at Needs you, or fail under Allowed tools only, until follow-up test 5 of `tasks-cant-be-handed-to-varnick` narrows the gate.
- **A Run's notice is new machinery.** The notifier and the page server read panes today, and both have to learn Runs.
- **More leaves the Mac,** only in kinds already consented to: a Judge step's state to TypeSafe, and Claude steps to Anthropic. The privacy page names them.

## User Stories

1. As the user, I want to save "delivery price for {product} on {site}" once and run it for any product and site, so that I don't write a new automation for each.
2. As the user, I want a Task's result to come back as fields (an amount, a currency, the quote), so that another Task, or code, can compare it.
3. As the user, I want one Task to run another and use its result, so that "the cheaper of two shops" is built from "delivery price".
4. As the user, I want an automation to run a Task with the values I gave it, so that a check runs every morning with no typing.
5. As the user, I want to start a Task by hand from a form, so that I fill its fields instead of writing a prompt.
6. As the user, I want a Claude session to list my Tasks, start one with an input and read its result, so that I can hand work on from a conversation.
7. As the user, I want Claude to write a Task and Varnick to tell it what's wrong before anything runs, so that a broken Task never starts.
8. As the user, I want Jev to pick each branch and Claude to be asked only when Jev is unsure, so that a run costs few Claude turns.
9. As the user, I want every Run on the board with its steps and its result, so that I can see what each step did.
10. As the user, I want a Run to carry on after a restart without repeating anything that could buy or send twice.
11. As the user, I want a Task's permissions set in Varnick and never by the file, so that a Task a session wrote can't give itself Skip.
12. As the user, I want passwords, terms and submits to stay mine in every Website step, so that an unattended run never buys or signs up by itself.
13. As the user, I want a failed sub-task to fail its parent with the reason, unless the parent says where to go instead.

## Implementation Decisions

### Shapes, in the shared package (Foundation only, so the relay can build them)

- **The Task definition:**
  - its name, description, input and result schemas, start, steps and end;
  - each step's capability, `with`, optional result schema and edges.
  - It is decoded from the file and checked by one function, which returns either a valid Task or every problem it found.
- **The schema subset** is a small value type of its own, not a general JSON Schema library: no new dependency, and Foundation is enough. It does three things:
  - checks a value;
  - writes itself out as JSON Schema for MCP;
  - lists the fields for a form.
- **The Run record:**
  - an id;
  - the Task's name, with a copy of its definition;
  - the trigger;
  - the input, and the parent Run;
  - the step states (pending, started with its pane's id, done with its result, failed with its reason, sending and sent for Notify);
  - the current step;
  - the outcome;
  - the steps taken, and the awake time worked.
- **The engine is one pure function:** a Run and an event in, the next Run and the commands out. The commands are:
  - start a step through its capability;
  - end the Run;
  - start a child Run.

  The events are the capabilities' outcomes, a restart's findings and Stop. It holds no clock, no I/O and no model.

### Hosting on a Mac

- **The running Varnick hosts the engine on the main actor,** as `AutomationRunner` hosts the slot function. There is one adapter per capability:
  - **Claude:** the run start that `startRun` does today, plus `task_result`.
  - **Website:** a Website pane in the run tab, with the site opened first.
  - **Judge:** a TypeSafe caller in the shape the task's Jev call already uses, with Claude in Jev's place.
  - **Notify:** the Run's notice.
  - **Task:** a child Run.
- **Recording before waiting** (from `orchestration-lives-in-one-session` option 01): a step's start, with its pane's id, is written to the file before the engine waits on it.
- **The runs file is a file of its own** in Varnick's support folder. It is never `sessions.json` and never `automations.json`.
  - Only the running Varnick writes it.
  - It is never written over when unreadable or newer (ADR 0030's rule).
  - Ended Runs are kept to a cap per Task, as automations keep 20.
- **Tasks are read from disk off the main thread,** with the last list shown meanwhile, as project scans are.

### Automations

- **The record becomes a trigger:** a Task's name and its input replace the prompt, folder and agent.
- **`automations.json` goes to version 2.** An older build would drop the Task reference on its next write, and now reads the file as newer and never writes over it.
- **A version 1 file is read as Claude prompt triggers.** No automation is saved yet (the coordinator's statement), so nothing migrates in practice.
- **The automation tools gain `task` and `input`** and keep the prompt fields as the Claude prompt shorthand. The permission rules of slice 3 are unchanged.

### The tools and the switch

- **The `!task` list and its form, Settings › Tasks, the task tools and `task_result`** are all behind the Tasks switch, which also gates the Website capability as it does today.
- **Automations that use a Task** need both switches.

### Documents

- **A new ADR:** Tasks are checked state graphs run by Varnick's own engine, with JSON Schema values and judgments as branches. It amends ADR 0039, whose loop becomes the Website capability, and ADR 0040, whose automation is now a trigger and whose run is a Task's.
- **CONTEXT.md:**
  - **Task**, redefined;
  - **Step** and **Capability**, new;
  - **Run**, widened;
  - **Automation**, a trigger;
  - **Website pane**, for the Task pane, whose column becomes its trail;
  - _Avoid_: workflow (Claude Code's Workflow tool), job, pipeline, flow, routine, recipe.
- **where-it-breaks:**
  - the check and its rules;
  - recording before waiting;
  - the restart rules per capability;
  - the grants;
  - the runs file.
- **The privacy page:** what a Judge step and a Claude step send.

## Testing Decisions

- **A make target over a table of cases,** as `make check-slots` is, building the shared package alone:
  - **the check:** each kind of problem, and a binding that has a value on one path only;
  - **the engine:** every capability's outcomes, `else`, propagation and a failed sub-task, the 50-step cap, the depth limit, and Stop through a tree;
  - **restarts:** a restart in each step state, with fake adapters. A Claude step is reattached. A Website step is tried again only with no submit allowed. A Notify step is sent at most once.
  - **the files:** version 2 read by the version 1 reader (newer, never written), and a version 1 file read as triggers.
- **`make check-mcp`** lists the task tools and their schemas, and never calls one: a call would reach the running Varnick and start a real Run.
- **`make build`.**
- **By hand, by the user after a restart:**
  - Delivery price from the form;
  - the same from an automation, hidden, stopping at Needs you on a gate;
  - a parent that runs it for two sites and keeps the cheaper;
  - a restart during a Claude step, which is reattached;
  - a restart during a Website step, which is tried again;
  - `task_run`, then `task_run_status` until the result comes, from a session.
- **One small eval in agent-lab,** by the eval agent: about three chained tasks on the practice shop, run as a Task against one Claude prompt that has the same capabilities as tools. Claude alone is the bar, as in the hybrid pilots.

## Out of Scope

- **Parallel branches and a step that maps over a list.**
- **An Ask capability** (a Choice put to the person), which orchestration's gates need.
- **Screen access as a capability,** and the user's own browser (option 02 of `tasks-cant-be-handed-to-varnick`).
- **Starting Tasks from the phone,** and Tasks on the headless host. Both are slice 3.
- **Cron,** and triggers other than a cadence, by hand and a session (a file appearing, a Run ending).
- **A visual editor.**
- **Moving Varnick's own planning and build work onto Tasks.**
- **Refactor worth raising:** a shared TypeSafe client. This adds a fifth caller in the existing shape, as ADR 0039 added the fourth.

## Further Notes

### Accepted 2026-10-15

The user accepted this option. Their decisions, relayed by the coordinator:

1. **This option.**
2. **The order:**
   - first, the record shape: the Run record, automations as a cadence, a Task and input values at file version 2, and the two built-in Tasks (slice 1 below);
   - then the headless host's slice 2 of `prompts-cant-run-on-a-schedule` option 01, built on that shape;
   - then the engine.

   Built the other way round, protocol 29 and the headless host's file would hold today's shape (a fixed prompt, and a run with no value), and changing it would cost a protocol bump and a migration on every host.
3. **A Website gate with nobody watching** waits as Needs you, up to 24 hours. It fails the step instead only under Allowed tools only.
4. **A Task a session writes runs at once, with a mark.** Permissions are set in Varnick, never in the file.

**Taken as recommended,** since the user didn't push back:
- **Types:** the JSON Schema subset, with TypeSafe's Choice, Noul and Score only as a Judge step's results.
- **An unsure Jev** (below 0.7, without TypeSafe, or after a failure) hands the pick to Claude. A Task that names an `unsure` edge goes there instead.
- **The words:**
  - the Website capability;
  - the Website pane, for the Task pane, whose column is its trail;
  - `!task` lists Tasks;
  - Step and Capability in the glossary.
- **One engine.** `orchestration-lives-in-one-session` should run on this engine. Its option 01 notes it, and its status is unchanged.

### Slices

1. **The record shape, this Mac, no protocol bump** (below).
2. **Task files and the engine, this Mac,** in two parts (below): 2a, the language and the engine, built beside the headless host's slice 2; 2b, Website steps and automations of any Task, built after it.
3. **The headless host and the phone.** Runs on the headless host with Claude, Notify and Task steps only, advanced by slice 2's timer; Tasks listed and started from the phone. The protocol after 29.

### Slice 1: the record shape (this Mac, no protocol bump)

**Goal.** The shapes protocol 29 will carry are this option's: an automation is a cadence, a Task and its input, and a Run is a record of its own in a runs file. Every automation behaves exactly as it does now, and the Task pane takes its new name.

**In it:**
1. **The two built-in Tasks,** as values in the shared package:
   - **Claude prompt:** `prompt` (text, required), `folder` and `agent` (text, optional);
   - **On this site:** `site` (an address) and `goal` (text).

   Only Claude prompt can be an automation's Task in this slice. On this site is what `!task` starts by hand, as it does today.
2. **A value type for inputs and results:** text, a number, true or false, a list, an object, or nothing. It is Codable and Foundation only. The schema subset waits for slice 2; the two built-ins' inputs are checked in code.
3. **The automation record becomes a trigger.**
   - `task` (a Task's name) and `input` replace `prompt`, `folder` and `agent`, and `runs` leaves the record. Everything else stays.
   - For Claude prompt, the prompt, folder and agent stay readable and writable through the input, so the editor, the tools and the start keep reading them as before.
4. **The Run record:**
   - its id;
   - its Task's name;
   - the input it started with, a copy, so an edit to the automation doesn't change what a past Run says it ran;
   - its trigger, which in this slice is always an automation: its id, the slot, late, and whether it was Run now;
   - its state, detail and count, as a run's are today;
   - when it started and ended, and whether it was opened;
   - its steps;
   - its result, which is nothing in this slice.

   A **step** holds its name and capability. A Claude step also holds its pane, its conversation, what it was started with (folder, agent, permissions, allowed tools) and its awake time worked. A Claude prompt Run has one step, and a slot that didn't run has none.
5. **Panes are found through steps.** Everything that looks up a run's pane goes through its step's pane, never through the Run's id, so slice 2's Runs of several panes change nothing there. A Claude prompt Run keeps its pane's id as its own, as a run does today, so notices and the Runs tab keep their ids.
6. **The runs file** is a file of its own in the support folder, at version 1.
   - Only the running Varnick writes it, owner-only and atomic.
   - It follows the automations file's rules: unreadable or newer stops every check and every save, and Settings says so.
   - Each automation keeps its last 20 Runs, with today's rules: a Run still going is never dropped, and consecutive skipped or missed slots with one reason are one record with a count.
   - Deleting an automation drops its Runs, as now.
7. **Two files, one order.**
   - A check writes the Runs first and the automation's last slot after.
   - It judges an automation's slots from the newer of its last slot and its newest Run's slot.

   So a crash between the two writes neither starts a slot twice nor records it missed twice.
8. **A hidden run tab that no Run names is released at launch** as an ordinary tab, before the first check. That covers a version 1 file, whose runs aren't carried over, and a runs file that was lost or moved aside. Nothing stays hidden that nothing tends.
9. **Everything that read an automation's runs reads the run store:**
   - the Runs tab;
   - the Settings row's status;
   - `automations_list`'s last outcome and run going;
   - the overlap rule and the limits;
   - opening and resuming a run;
   - the notice of an ended run;
   - and above all the lookup by conversation that keeps `notify` alone for a run's conversation resumed from search.
10. **The rename's reach** and the documents (below).

**The files:**
- **`automations.json` goes to version 2.** An older build reads it as newer, runs nothing and never writes over it.
- **A version 1 file is read and converted in memory.**
  - Each automation becomes a Claude prompt trigger, with its prompt, folder and agent as the input.
  - Its run history is not carried over: no automation is saved yet (the coordinator's statement), and item 8 releases any hidden tab of one.
  - The file is written as version 2 at the first save, not when it is read, so a build rolled back before then finds its own file.
- **The Default folder move** at launch, which gives an old setting's folder to the automations that have none, reads either version and writes version 2.
- **`make check-slots` gains these cases:**
  - a version 1 file read as triggers;
  - a version 3 automations file, and a version 2 runs file, both read as newer;
  - an unreadable runs file;
  - the cap and the folding, moved to the runs list;
  - the anchor when a Run is newer than the last slot.

**The four automation tools:**
- **`automations_list`:** each automation gains `task` ("Claude prompt"). Prompt, folder and agent stay where they are, as that Task's input. The last outcome and run going come from the run store. Nothing else changes.
- **`automation_create` and `automation_edit`:** their arguments don't change, and they make and edit Claude prompt triggers. Their descriptions say that an automation runs the Claude prompt Task. `task` and `input` arrive in slice 2, when there is another Task to name.
- **`automation_switch`:** unchanged.
- **The socket request keeps its version,** since no argument changes. `make check-mcp` follows the new descriptions.

**The rename's reach:**
- **The UI says Website pane where it said Task pane.** Nothing else changes name.
  - the split picker's tile: Website;
  - the pane's title: "Website: …";
  - `!task`'s row: On this site, or "Show the running one" while one runs, with its detail;
  - the Tasks switch keeps its name, since it will gate Tasks, and its detail says Website pane and Website tile;
  - the stop shortcut's title in Settings › Shortcuts names the Website pane;
  - the pane's own lines that call its work "a task" stop doing so: "another Website pane is working, and one works at a time", "open the site first", and "nothing starts without Claude Code logged in".
- **Code keeps its names:**
  - `TaskPane`, `TaskController`, `TaskPage` and the TaskHarness package;
  - `Panes.task` and `SessionRecord.task`;
  - `Settings.tasksOn` and its UserDefaults key;
  - `ShortcutAction.stopTask`;
  - the `!task` word.

  A changed key or id would lose a setting or a rebinding, and the rest would be a rename for its own sake. The primitive's new types never take the bare name `Task`, which is Swift's own. This slice's types are the built-in Tasks, the value type, the Run (`TaskRun`), its trigger and its steps.
- **Docs:**
  - **CONTEXT.md:**
    - **Task:** the saved workflow, with the two built-ins.
    - **Website pane:** called the Task pane until 2026-10, and the code still says Task.
    - **Run:** any Task's execution, in this build always an automation's.
    - **Automation:** a trigger, a cadence, a Task and input values.
    - **Step** and **Capability.**
    - The _Avoid_ lines that point at the old Task (Automation, Run, Panel access, the Task pane) follow.
  - **A new ADR** recording this option (the whole design, with this slice as built), amending ADR 0039 and ADR 0040.
  - **where-it-breaks:** Automations gains the two files and their order, the release rule and the lookup through steps. Tasks is retitled for the Website pane.
  - **The guide and the privacy page:** their Task pane lines.
  - **Older records** (problems, ADR bodies, commit messages) keep the old name, as ADR 0024 did for Launchy.

**Where it touches,** by symbol:
- **Sibling for the runs file and its store:** `AutomationFile` and `AutomationStore`.
- **The record and its reading:** `Automation`, `AutomationRun` (its fields move into the Run and its step), `Automation.record` (moves to the runs list), `AutomationFile.read` and `giveFolder`.
- **The model's half:**
  - `AutomationRunner.check` (the order and the anchor);
  - `startRun` (returns a Run);
  - `tendRuns`, `endRun`, `runClosed`, `isRunGoing`;
  - `openRun`, `applyRunFields`, `endedRun`;
  - `releaseRuns`, `runOpened`, `startAutomations` (the release at launch).
- **The readers:** `AutomationAccess`'s list, `RunsBoard.refresh`, the Settings row's status in `AutomationsView`, and `SessionNotifier`'s ended-run lines.
- **The checks:** the slot-check target.

**Not in it:**
- Task files, the check, the schema subset, the engine, Judge, Notify, sub-tasks, `task_result`, the task tools, `!task`'s list and form, and the Run's own notice. All of that is slice 2.
- Runs started by hand, by a session or by a parent, and the Website pane's work recorded as a Run.
- Any change to the Website loop, its gates or what its switch does.
- The headless host, protocol 29 and the phone. Protocol 29 is the next build, on this shape.
- A Task picker in the automation editor.

**By hand, by the user after a restart with Automations and Tasks on:**
1. **Make an automation** in Settings › Automations ("say hello, then notify me with the time", every 15 minutes) and press Run now. Nothing opens, the Message notice comes with its name, the Runs tab lists it, and opening it shows the pane live, as before.
2. **Look at the files** in the support folder. `automations.json` says version 2, and the automation has task "Claude prompt" with its prompt, folder and agent under input. The runs file holds the run.
3. **Restart Varnick while a run works.** It comes back hidden, the Runs tab shows it going, and its notice still comes.
4. **Let a slot pass with the Mac asleep.** One late run comes at wake, and the older slots are marked missed, as before.
5. **Use the tools** in a Claude pane started since. "List my automations" shows task "Claude prompt", and "make one that says hello every 15 minutes" makes it, with the mark.
6. **Delete the automation while a run goes.** The run becomes an ordinary tab, and its Runs leave the Runs tab.
7. **Check the Website pane.** `!task` reads On this site, the split picker shows a Website tile, and the pane's title says Website. A finding task on the practice shop runs as before, and the Stop shortcut stops it.

### Slice 2: Task files and the engine (this Mac), in two parts

The user's word, later on 2026-10-15 (relayed by the coordinator): the engine is built now, beside the headless host's slice 2 of `prompts-cant-run-on-a-schedule` option 01, on this Mac only. It is too much for one build, so it comes in two parts, and neither bumps the protocol:
- **2a, the language and the engine:** Task files and the check, the engine, and Claude, Judge, Notify and sub-task steps, started by hand, by a session and by a parent. It changes no automation's record or tools, so it can be built beside the headless host's slice 2.
- **2b, Website steps and automations of any Task.** It changes the automation record and tools that protocol 29 carries, so it is built after the headless host's slice 2 is merged.

#### Decided in planning

Where the code forced a choice the Solution leaves open. Each is the planner's and stands unless the user says otherwise; the user's answers are under Resolved for slice 2a.

1. **The Claude prompt Task keeps slice 1's path** in both parts. Only an automation starts it, `startRun` builds its Run and `tendRuns` tends it, as now. The headless host's slice 2 builds this Task's runs on the relay at the same time, and two rewrites of one start would collide. It moves onto the engine together with the headless host's engine (slice 3). A Claude step of any other Task shares its pane start and its limits.
2. **`else` catches every outcome but `failed`.** A `failed` outcome takes a `failed` edge or fails the Run, which then travels up. Otherwise `{"yes": …, "else": …}` would send a Judge's or a sub-task's failure down the "no" branch. Judge gains the outcome `failed`, for when neither Jev nor Claude answered.
3. **A Judge asks a Choice or a Noul.** Score waits: nothing in Varnick calls it, its request shape is unmeasured, and no Task here needs it. The check says it isn't in this build. A Choice's options are a list, each a label and a criterion, so Jev gets them in the written order. `TaskJev` keeps that order because a label's place is part of what was measured.
4. **Tasks are found from a folder,** as apps are: the project's Tasks first, then the user's, by name.
   - A session finds them from its own folder.
   - `!task` uses the focused pane's folder, or Home with no tab.
   - A parent uses the folder its own Task came from.
   - An automation keeps a folder of its own (2b).

   Grants and marks are kept per Task file.
5. **A binding to a field that may be absent** goes only into an optional field, and is left out when the value is absent. A field may be absent because its schema makes it optional or because some outcomes don't give it. A binding inside text writes a whole number with no decimal point, and a list or an object as JSON.
6. **A form lists the required fields in `required`'s order, then the rest by name.** Foundation's JSON reader doesn't keep key order, and one form doesn't justify a reader that does.
7. **A grant of Skip covers only the contents the user has seen.** A Task that is new or changed since (marked) runs with Varnick's setting in place of Skip. Ask, Allowed tools only and the allowed tools still apply. Without this rule, a session that edits a Task the user set to Skip would give the new contents Skip, which slice 3's rule forbids for automations. The Run's line says when this happened.
8. **The bounds.** An automation's Run has the automation's working limit, any other Run has 60 minutes, and a child has its parent's. Each Run counts its own awake work, as a check counts a run's. Passing that limit, 50 steps or the depth limit fails the Run with that reason. This isn't an outcome a step can branch on, and it reaches a parent as its Task step's `failed`.
9. **A Run started by hand opens nothing,** just as Run now doesn't. The board's Runs tab shows it selected.
10. **A Claude step's pane raises Needs you and Messages only.** Its Done and its errors are the step's outcome, and the Run's own notice says how the Run ended.
11. **Tasks off stops every Run that's going, through its tree,** and turns its hidden tabs into ordinary ones, as Automations off does for runs.
12. **`runs.json` goes to version 2.** Every new field is optional, so an automation's Run is written exactly as slice 1 wrote it and protocol 29 carries it unchanged. An older build reads version 2 as newer and writes nothing.
13. **A tab of several panes loses only the pane that ended.** Today, when an unopened run's pane exits, `sessionExited` removes its whole tab. A Run's tab can hold a finished step's pane beside a live one.

#### Slice 2a: the language and the engine

**Goal.** Claude or the user writes a Task file, and Varnick checks it. The user starts it from a form, a session starts it through Varnick's tools, or another Task runs it. Its Claude, Judge, Notify and sub-task steps run out of sight, and each is recorded before it waits. The Run ends with its result as fields, raises its own notice and shows its lines on the board.

**In it:**
1. **Task files** are `*.json` in a project's `.varnick/tasks` folder or the user's own, beside the custom apps folders.
   - They are read off the main thread whenever a list shows (`!task`, Settings › Tasks, `tasks_list`), and the last list read stays on screen meanwhile.
   - A file is marked New or Changed by its contents until the user presses Seen in Settings › Tasks.
2. **The schema subset** is a value type of its own. It:
   - reads the subset, `description` included, and refuses anything else by name;
   - checks a `TaskValue`, naming each wrong field by its path;
   - writes itself out as JSON Schema;
   - lists a form's fields.
3. **The definition and the check:** one function that turns a file's data into either a valid Task or a list of every problem in it. It checks the Solution's list plus decisions 2 to 5. Two capability problems belong to this build only: a Website step "arrives in the next build" (2b), and a Score Judge isn't in it.
4. **The engine** is one pure function: a Run and an event in, the next Run and its commands out.
   - **Events:** start, a step's outcome (with its result or reason), a child Run's end, a restart's finding for a step, awake time worked, Stop.
   - **Commands:** start a step (its `with` resolved), start a child, stop a step, end the Run.
   - **It** resolves bindings, follows edges (`else`, `failed`, `unsure`), builds the result at `end` and keeps the three bounds.
   - **Website's outcomes and its restart rule are in it already,** so 2b adds only the adapter.
5. **The Run record,** at version 2:
   - **The trigger** also records who started a Run that no automation started: by hand, a session (its title), or a parent (its Run and step). Its automation becomes optional, and for those Runs its slot is the start time.
   - **The Run** gains a copy of its Task, the folder the Task was found from, its working limit and awake time, and two states, failed and stopped.
   - **A step** gains its state (pending, started, waiting, done, failed, sending, sent, interrupted), its outcome, its result or reason, its child, who acted, Jev's probability, and when it started and ended. Each visit to a step is a new entry, so every pass through a loop is on record, and a binding reads the latest.
   - **The list** keeps each automation's last 20 Runs, as now, and each Task's last 20 of the Runs that no automation started. A Run still going is never dropped.
6. **The host** runs on the main actor, as `AutomationRunner` hosts the slot function.
   - Every Run the engine returns is written to the file before any of its commands is carried out.
   - A pane's id is on its step before the pane starts.
   - It advances when a step's pane changes turn, and on its own tick every two seconds, which also reads the result files.
   - It counts awake time as a check does.
   - At launch it applies the restart rules, once the saved tabs are restored, beside `startAutomations`.
7. **Claude:** a hidden pane, started as `startRun` starts one.
   - It runs in the folder `with` names, Home when absent, and is refused for the same reasons about the folder, the agent or trust. It runs with its Task's grants (decision 7).
   - Its record names its Run. The Run's tab, named after the Task, is made at the Run's first pane step, and each later pane is split into it.
   - Its MCP config lists `notify`, plus `task_result` while the pane's folder holds the step's result schema. The prompt ends with Varnick's fixed line asking for `task_result`.
   - With a result schema, the step is ok at a valid `task_result`, and fails with "ended without a result" if its turn ends without one. Without a schema, it is ok when its turn ends. Amended 2026-10-15 (the user's decision, relayed by the coordinator): in a step whose tab the person has opened, a turn that ends with no result keeps waiting, up to 24 hours, since the tab is theirs to go on in; the Run says so, and raises a notice of its own, so the stall is seen.
   - Waiting 24 hours fails it. Once a step is done, its process ends 10 minutes after its turn came to wait, if nobody opened it, as a run's does.
8. **`task_result`** is answered by the pane's own MCP server, as `notify` is (Resolved for slice 2a, 3).
   - The server lists the schema the host wrote into the pane folder.
   - It checks each call against that schema and refuses a wrong one, naming each wrong field.
   - It writes an accepted value to a result file in the same folder, and refuses a second call.
   - The host moves the file's value onto the step, and removes both files when the step ends.
9. **Judge:** Claude takes Jev's place through `ClaudeSystem1`, on a conversation opened for that one call, with a judging preface of fixed words. The line says who picked and why.
10. **Notify, and the Run's own notice.**
    - The notifier keeps notices for Runs beside those for panes, by the Run's id, with the same kinds and switches.
    - The menu line is written from the Run: Done with a result, Stopped on an error ("Failed at check: no"), or a Message from Notify. Choosing one shows the Run.
    - A Notify step is recorded as sending, then raised, then recorded as sent.
    - These notices stay on this Mac (Resolved for slice 2a, 4).
11. **Task:** a sub-task is a child Run, with its own grants. Its Task is found from the parent's folder and copied when the child starts. The child's end is the outcome of the parent's step. Stop on any Run stops its whole tree.
12. **The restart rules:**
    - a Claude step reattaches to its restored pane by its id; one whose session is gone fails with "the session had ended", unless its result file is there;
    - a Judge that was waiting for an answer is asked again;
    - a Notify still marked sending counts as sent;
    - a pending step starts;
    - a child Run follows its own rules.
13. **The Runs tab** lists every Run, newest first, under its automation's name or its Task's, and says how it started.
    - ↩ on a Claude prompt Run opens it, as now.
    - ↩ on any other Run shows its view: its lines, written from the step records with who acted; its result as fields; a line for each child, which opens that child; its Task's mark, if it has one; and Open tab and Stop. Esc goes back to the list.
14. **`!task`** shows the Tasks in the panel, the way Resources is shown.
    - On this site comes first, and opens the Website pane at once, as now.
    - The Tasks found from the focused pane's folder follow. An invalid one is dimmed and shows its problems.
    - ↩ on a Task shows its form. ↩ on the form checks the input: each wrong field is named under it, or the Run starts and the Runs tab shows it.
15. **The task tools** are the `--tasks` set, listed in every Claude pane started while Tasks is on, but never in a Run's pane.
    - **`tasks_list`:** each Task found from the session's folder, with its input and result schemas, its capabilities, whether it is valid (with its problems), and its mark.
    - **`task_run`:** a Task's name and an input object, checked against the schema. The answer is the Run's id, and says the Run's notice will tell the user.
    - **`task_run_status`:** a Run's state, its current step and its lines, and once it has ended, its result or its failure. A session calls it again until then (Resolved for slice 2a, 1).
    - **`task_check`:** a file's path. The file is checked as if it sat in the tasks folder of the project it is in, and the answer is its problems or that it is valid.

    The running Varnick answers them over the socket, with the checks in `AutomationAccess`'s order: the switch, Varnick having started, the calling pane, the runs file, then the tool. The calling pane must be a Claude pane on this Mac whose record names no automation and no Run. The automation tools now refuse a Run's pane, as they already refuse a run's.
16. **Settings › Tasks,** shown while Tasks is on, lists each Task with:
    - the grants for its Claude steps: Varnick's setting by default, or Ask, Allowed tools only or Skip, and the allowed tools;
    - its mark, with Seen;
    - its problems.
17. **The tasks skill,** next to the custom-apps skill and linked the same way, covers the format, the capabilities and their outcomes, bindings, the check and `task_check`.

**Saved state.**
- `runs.json` goes to version 2 (decision 12).
- Grants and the seen contents are settings, kept in UserDefaults per Task file.
- While a Claude step is going, its pane folder holds the step's schema file and its result file.
- Nothing else new is saved.

**The tools.** The automation tools don't change, apart from refusing a Run's pane. `make check-mcp`:
- lists `--tasks` alone and with the other sets;
- lists `task_result` for a schema in a scratch folder, and calls it there with a good value and a bad one (it writes only in that folder);
- never calls a task tool, since that would reach the running Varnick and start a real Run.

**Where it touches,** by symbol:
- **Siblings:**
  - `AutomationSlot.check` and `make check-slots`, for the engine and its check;
  - `NotifyTool`, for `task_result`;
  - `CustomApp.available`, for the files;
  - `AutomationRunner`, `startRun` and `tendRuns`, for the host and Claude;
  - `TaskJev` and `ClaudeSystem1`, for Judge;
  - `AutomationAccess` and `AutomationMCP`, for the tools;
  - `showResources`, for `!task`'s view;
  - `AutomationsSettingsView`, for Settings › Tasks.
- **The record:** `TaskRunTrigger`, `TaskRunStep`, `TaskRun`, `RunState`, `TaskRunList.record`, `TaskRunFile`; and on `SessionRecord`, the Run a pane belongs to.
- **A Run's pane:**
  - `launchClaude`'s run test and its MCP config;
  - `checkConversation`'s left record;
  - `sessionExited`'s run branch (decision 13);
  - `runClosed`, `releaseHiddenRuns`, `releaseUnnamedRuns`, `openRun`, `applyRunFields` and `endedRun`;
  - `AutomationAccess.run`'s check for a call from a run.
- **The rest:** `ScreenMCP.Sets` and `answer`, the `--mcp` entry, `PeerManager.handle`, `SessionNotifier`, `RunsBoard`, `LauncherModel.run(_:)`, `panelHeight`, `coversTabs`, `LauncherCommand`, `SettingsSection`.

**Testing.**
- **`make check-engine`,** a new target that builds the shared package alone and runs a table of cases:
  - the Solution's cases for the check, the engine and restarts (Website's fed as events);
  - decisions 2, 5 and 8;
  - the schema's types, formats, refusals and form order;
  - `task_result`'s files, in a scratch folder;
  - runs files at versions 1, 2 and 3;
  - an automation's Run, written byte for byte as slice 1 wrote it.
- **`make check-slots`** still passes.
- **`make build`.**

**Documents.**
- **ADR 0041** gains an amendment for this slice: the runs file at version 2, the widened trigger, `task_result` in the pane's own server, and the Run's notice.
- **CONTEXT.md:** Task (its files and the check), Run (any trigger), Notice (a Run's).
- **where-it-breaks** gets a section of its own, Tasks: the engine. It covers the check, recording before waiting, the restart rules, the grants and marks, the result files, a Run's pane marks and decision 13. The Automations section points to it for the runs file.
- **The privacy page:** what a Judge step and a Claude step send.
- **The guide:** `!task` and Settings › Tasks.

**Not in it:**
- Website steps, and On this site recorded as a Run;
- automations of any Task other than Claude prompt, and `task` and `input` on the automation tools;
- the Claude prompt Task started by hand or from a session;
- Score;
- the Run's notice on the phone;
- the headless host.

**By hand, by the user after a restart with Tasks on.** Never by an agent: a Run starts real Claude sessions and TypeSafe calls on the user's accounts.
1. **Write one.** In a Claude pane started since the restart, ask for a Task called Haiku:
   - its input is `topic`;
   - a Claude step writes a haiku, with the result `text`;
   - a Judge Noul asks "Is `text` a haiku about `topic`?": yes goes to a Notify and then `end`, no goes back to the Claude step;
   - its result is `text`.

   `task_check` passes, and Settings › Tasks lists it, marked New.
2. **Break it.** Bind `{steps.write.title}`: `task_check` and `!task` both name the field, and the Task can't start.
3. **From the form.** `!task` › Haiku, give a topic, press ↩. Nothing opens, and the Runs tab shows the Run. Its Message comes, then Done. Opening it shows the lines (Claude, Jev's pick with its probability, the Notify) and `text`. Open tab shows the Claude pane.
4. **Without TypeSafe** (the relevance filter set to local): the Judge's line says Claude picked.
5. **A parent.** "Two haiku" runs Haiku twice and returns both. Its Run shows two child lines, and each opens its own Run.
6. **A restart during the Claude step.** The pane comes back hidden, and the Run goes on to its result.
7. **Stop** the parent during a child's Claude step. Both Runs stop, and their panes end.
8. **From a session.** `tasks_list` shows Haiku with its schemas. `task_run` with a number for `topic` is refused, naming `topic`; with text it answers an id. `task_run_status` gives the result once the Run ends.
9. **Grants.** Set Haiku to Ask: a tool the step wants raises the pane's Needs you. Then set Skip, press Seen and edit the file: it is marked Changed, and its next Run follows Varnick's setting and says so.
10. **Tasks off.** A Run that's going stops, and its tab becomes an ordinary one. `!task` and the tools refuse.

#### Slice 2b: Website steps and automations of any Task

**Goal.** A Task's Website step works on a site out of sight, and stops for the person only at a gate. An automation runs any Task with its input values. `!task`'s On this site is recorded as a Run.

**In it:**
1. **Website:** a Website pane in the Run's tab. It opens the site and, once the page has loaded, starts the loop with the goal. `TaskController` reports to the host, not only to its pane. The outcomes are found (`text`, `page`), finished (`page`) and gave up (`reason`).
   - **Nobody watching** means the Run's tab hasn't been opened. A gate then raises the Run's Needs you notice, with the question, and waits up to 24 hours, after which the step gives up with "waited on you for 24 hours". Under Allowed tools only it gives up at once, with "needs your Allow". Once the tab is opened, gates are the person's, as today.
   - **One at a time:** a Website step that finds another Website pane working stays pending ("waiting its turn") and starts when that one ends.
   - **Recorded before acting:** an Allow, or "I'll do it", is written on the step before the press, so after a restart Varnick knows a submit may have happened.
   - **Stop in the pane** stops the whole Run.
   - **After a restart** the step is interrupted. If no submit was allowed, it starts again from the site. Otherwise the Run waits on the person, raising Needs you, with Retry and Stop in its view.
2. **On this site is recorded as a Run.** `!task`'s one-off opens the pane at once, as now, and once ↩ starts it, it is recorded as a Run started by hand, with the goal as its input. A session's `task_run` and a parent run it hidden.
3. **An automation runs any Task:**
   - it keeps the folder its Task is found from; `automations.json` goes to version 3, which an older build reads as newer;
   - it can run when its Task is found and valid, its input fits, and both switches are on;
   - a due slot records a Run as starting before `lastSlot` moves; the host then reads the Task and either begins the Run or records "couldn't start" with the reason;
   - its overlap rule reads the Run's state, and its working limit and permissions override apply to the Run.
4. **The automation tools gain `task` and `input`.**
   - `task` names a Task found from the calling session's folder; when it is absent, the Task is Claude prompt.
   - `input` is an object checked against that Task's schema, and every wrong field is named.
   - `prompt`, `folder` and `agent` stay as shorthand for Claude prompt, and are refused beside any other Task.
   - `automations_list` gives each automation's input and task folder.
   - The permission rules of slice 3 don't change. The request's version goes up.
5. **The editor's Task picker,** using `!task`'s form for the Task's input.

**Where it touches,** by symbol:
- `TaskController` (`start`, `decide`, `needsYou`, `finishedWith`);
- `SavedTab.withoutTasks`, for a run tab that held only a Website pane;
- `openTask`;
- `Automation` and `isRunnable`, `AutomationFile`;
- `AutomationRunner.check`, `isRunGoing`, `runNowRefusal`;
- `AutomationTools.read`, `make` and `edit`;
- `AutomationMCP`'s schemas and `AutomationRequest.version`, `AutomationAccess.list`;
- `AutomationEditor`;
- the slot-check cases for version 3.

**Not in it:** the headless host, the phone, Score, and the Claude prompt Task on the engine.

**By hand, by the user after a restart with Automations and Tasks on:**
1. **Delivery price** (the prototype above), from the form, on the practice shop. The Website step finds the price out of sight, and the Run's result has the amount, the currency and the quote.
2. **A gate with nobody watching.** A Task whose site asks for a postcode raises Needs you. Opening the Run's tab shows the gate, and Allow lets the step go on.
3. **The same under Allowed tools only.** The step gives up with "needs your Allow", and the Run takes its edge or fails.
4. **Two at once.** A second Website Run waits its turn.
5. **A restart during a Website step.** With no submit allowed, the step starts again. After an Allow, the Run shows Retry and Stop.
6. **An automation of Delivery price,** made by a session with `task` and `input`. A wrong input field is refused by name. The automation runs at its slot, and `automations_list` shows its Task and input.
7. **The editor.** Pick Delivery price and fill in its form.
8. **`!task` › On this site.** The pane opens at once, and the Runs tab lists its Run.

#### What the headless host needs to run Tasks (slice 3)

- **The engine, the check, the schema and `task_result` live in the shared package,** Foundation only and with no clock. The relay calls them unchanged, as it will call `AutomationSlot.check`.
- **Its timer run is the host.** Each run reads the pane folders (turns and result files), feeds the events in, writes the Run, then starts the next step. A Claude step there is a hidden pane started through its launch code. Its `--mcp` lists `notify` and `task_result`, both answered by the server itself, with no running Varnick (the Solution's Claude capability).
- **Its runs file is `TaskRunFile` at version 2.** If protocol 29 is built on version 1, its requests don't change, since an automation's Run is written the same way in both.
- **It can host Claude, Notify and Task steps.** It can't host Website (no WebKit) or Judge. It has no TypeSafe key (inferred), and no text helper for Claude to take Jev's place: none of its sources or scripts mentions one.
- **What it needs from the Mac:** the grants (kept in Settings › Tasks on the Mac, never in a file), its list of Tasks, and a Run's own notice in its listing for its page server to push. Each is a request in the protocol after 29.
- **The Claude prompt Task moves onto the engine** there and on the Mac at the same time.

### Verified and inferred

- **Verified on main at 65cf38a:**
  - `TaskRunner` takes a sentence and returns `Outcome`, and `AnswerShape` is a check;
  - `Gate.asks` and `formFields`;
  - `Automation`'s fields, and `AutomationFile`'s version 1 with its newer rule and the Default folder move;
  - `startRun`'s path, and the readers of an automation's runs listed under slice 1;
  - the automation tools' JSON Schema, their string arguments and their socket path;
  - the Runs tab reading automations' runs;
  - the Jev callers' Choice and Noul shapes;
  - `Settings.tasksOn`'s UserDefaults key, and the Task pane's strings in the split picker, the command row, the switch, the shortcut and the pane;
  - Bun on the headless host (the installer checks its version).
- **From TypeSafe's live docs, 2026-10-15:** Choice, Score and Noul, with answers limited to the options supplied.
- **Inferred, unverified:**
  - that a Website pane can sit in a hidden run tab as a Claude pane does (the spike found that a hidden web view keeps working, but in a plain window, not the panel);
  - that the headless host has no TypeSafe key;
  - how often unattended Website steps meet a gate on real sites.
- **Verified on main at 9e66872, for slice 2:**
  - slice 1's record: `TaskRunTrigger` names an automation on every Run, `runs.json` is at version 1, and every reader listed under 2a's "A Run's pane";
  - `sessionExited` removes a whole hidden run tab when its pane exits;
  - a web pane's web view is made with its record and loaded by `start()`, which `startRun` calls on a pane nobody has shown;
  - `NotifyTool` is answered in the pane's own server and shared with the relay;
  - `TaskJev` asks Choice and Noul questions, and nothing in Varnick asks TypeSafe a Score;
  - the socket's handler is async, so a task request can read files off the main thread;
  - a pane's server waits 15 s for an answer over the socket, and `AutomationAccess` answers on the main actor;
  - none of the headless relay's sources or scripts mentions a text helper.
- **Inferred for slice 2, unverified:**
  - that a two-second tick advances a Run soon enough;
  - that Jev's 1.5 s deadline is long enough for a Judge's state.

### Resolved for slice 2a (2026-10-15)

The user answered all four as recommended (relayed by the coordinator):

1. **A session polls `task_run_status`** for a Run's result. No call blocks until the Run ends: a Run can wait a day at a gate, but a pane's server waits only 15 s for the running Varnick. The Run's own notice tells the user either way.
2. **Every Judge step uses the 0.7 bar,** the measured one. A step can't set a bar of its own.
3. **`task_result` is checked in the pane's own MCP server,** against the schema file the host writes into the pane's folder, as `notify` is answered. The user agreed to amend the accepted text, and the Solution's Claude capability now says so.
4. **A Run's notice is this Mac's only until slice 3.** A push names a tab and a pane to open, and a Run has neither on the phone until slice 3 lists Runs there.
