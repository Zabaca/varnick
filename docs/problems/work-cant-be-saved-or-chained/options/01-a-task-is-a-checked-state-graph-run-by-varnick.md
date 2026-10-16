---
problem: work-cant-be-saved-or-chained
title: A Task is a state graph in a JSON file that Varnick checks, run by an engine in Varnick's shared Swift package, with JSON Schema values and Jev choosing the branches
summary: A Task is a JSON file found on disk, as custom apps and agents are. It holds its input and result as JSON Schema (a small subset), and its steps as a graph. Each step uses one capability (Claude, Website, Judge, Notify, or another Task), takes its values from the input and from earlier steps, and names the next step for each outcome. Claude writes Tasks, and Varnick checks each one as a compiler would before it can run. The engine is a pure transition function in the shared package, so the headless relay can run it later. The running Varnick hosts it as it hosts automations, and keeps each Run in a file of its own, written before every wait. A Judge step's Choice labels are its branches: Jev picks at 0.7, and Claude picks below that or without TypeSafe, as in the website loop. Grants live in Varnick, not in the file. An Automation becomes a cadence, a Task and input values, and today's prompt becomes the built-in Claude prompt Task. Accepted 2026-10-15. Slice 1 is the record shape on this Mac, with no protocol bump: automations as triggers at file version 2, the Run in a runs file of its own, the two built-in Tasks, and the Task pane renamed the Website pane. The headless host's slice 2 is built on that shape, and the engine comes after it.
status: accepted
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

- **Claude:** a hidden Claude pane, started as an automation's run is (ADR 0040). It answers through a `task_result` tool on Varnick's MCP server, whose input schema is the step's result schema.
  - The running Varnick checks each call over its socket, as it checks the automation tools, and refuses one that doesn't fit, naming each wrong field. Claude then tries again.
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
2. **Task files and the engine, this Mac.**
   - the check, the schema subset, its skill and `task_check`;
   - the five capabilities;
   - bindings, branches and sub-tasks;
   - the restart rules;
   - the Run's notice;
   - Runs started by hand, by a session and by a parent;
   - `!task`'s list and form;
   - the task tools;
   - `task` and `input` on the automation tools.
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

### Open questions, recommendation first

Both are for slice 2.

1. **A session waiting on a Run's result:** a status tool it calls again (recommended: no long MCP call, and the Run's own notice tells the user), or a call that blocks until the result.
2. **The Judge step's bar:** 0.7 for every Judge step (recommended, the measured bar), or a bar each step sets.
