---
name: tasks
description: Tasks for Varnick, saved JSON state graphs it checks and runs. Use when writing, editing, checking or starting a Task, or working in a `.varnick/tasks` folder.
---

# Tasks

A Task is a JSON file: a typed input, steps that each use one capability, and a typed result. Varnick checks it as a compiler would before anything runs, so write it, run `task_check`, and fix what it names. For why it is shaped this way read `adr-0041.md` in this folder; for the terms, **Task**, **Step**, **Capability** and **Run** in `CONTEXT.md` in this folder (both are links into the Varnick repo).

## Make one

1. Write `<project>/.varnick/tasks/<name>.json` (this project) or `~/.varnick/tasks/<name>.json` (every project). The project is the git repo containing your folder. A project's Task hides the user's of the same `name`.
2. Call `task_check` with the file's path. Done when it answers "is valid". It lists every problem at once, each starting with where it is (`steps.check.next`).
3. Tell the user. A new or changed file is marked New or Changed in Settings › Tasks until they press Seen. You can't grant it permissions: those are theirs, kept in Varnick, never in the file.
4. Start it only when the user asked: `task_run` with the name and an `input` object, then `task_run_status` with the Run's id until `ended` is true. It never blocks, since a Run can wait on the user for a day. Varnick's own notice tells them how it ended.

`tasks_list` gives each Task found from your folder with its schemas, capabilities, validity, problems and mark. All four tools exist only while Tasks is on, and never in a Run's own session.

## The file

Keys: `name`, `description`, `input`, `result`, `start`, `steps`, `end`. All are required except `description`. Nothing else is accepted.

```json
{
  "name": "Haiku",
  "description": "Writes a haiku until a judge says it is one",
  "input": {"type": "object", "required": ["topic"], "properties": {"topic": {"type": "string"}}},
  "result": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}},
  "start": "write",
  "steps": {
    "write": {"use": "claude", "with": {"prompt": "Write a haiku about {input.topic}."},
              "result": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string"}}},
              "next": {"ok": "check", "failed": "fail"}},
    "check": {"use": "judge", "with": {"noul": "Is `text` a haiku about `topic`?", "state": {"text": "{steps.write.text}", "topic": "{input.topic}"}},
              "next": {"yes": "tell", "no": "write"}},
    "tell": {"use": "notify", "with": {"title": "Haiku ready", "body": "{steps.write.text}"}, "next": {"ok": "end"}}
  },
  "end": {"text": "{steps.write.text}"}
}
```

**Types** are a subset of JSON Schema: `string` (with `format` `uri` or `date`, or an `enum` of strings), `number`, `integer`, `boolean`, `object` (`properties`, `required`) and `array` (`items`), plus `description`. `input` and `result` are objects. Any other keyword (`pattern`, `$ref`, `oneOf`, `additionalProperties`) is refused by name. Field and step names are letters, digits, `_` and `-`. An object takes no field its schema doesn't list.

**Steps** have `use`, `with`, `next` and, for Claude only, `result`. Step names are not `end` or `fail`, which are the two ends: `end` builds the result, `fail` fails the Run with "Failed at <step>: <outcome>".

| `use` | `with` | Outcomes | Gives |
|---|---|---|---|
| `claude` | `prompt` (required), `folder` (Home when absent), `agent` | `ok`, `failed` | the fields of its `result` schema; none without one |
| `judge` | one question (below), optional `state` | a Choice's labels, or `yes`/`no`; `unsure`; `failed` | `probability`, and `label` for a Choice |
| `notify` | `title` (required), `body` | `ok` | nothing |
| `task` | `task` (another Task's name, literal), `input` | `ok`, `failed` | the child's result fields |
| `website` | — | — | refused by the check: "arrives in the next build" |

A Claude step answers through a `task_result` tool whose arguments are the `result` schema; a wrong call is refused with each field named and Claude tries again. A turn that ends with no valid result fails the step ("ended without a result"). The built-in Tasks can't be sub-tasks.

**Judge.** A Choice: `{"choice": "Which?", "options": [{"label": "a", "criterion": "…"}, …], "state": {…}}`. A Noul: `{"noul": "Is it so?", "state": {…}}`. Labels are the branches; they can't be `else`, `failed` or `unsure`. `state` is the only thing Jev reads, so put in it every value the question mentions. Jev's pick is followed at 0.7; a Noul is yes at 0.7 or more and no at 0.3 or less. Anything else, no TypeSafe, or a Jev failure goes to Claude, and the Run's line says so. A step can't set another bar. A Score question is refused ("isn't in this build").

**Edges.** `next` maps an outcome to a step, `end` or `fail`. `else` covers every outcome that has no edge of its own except `failed` and `unsure`. The check requires an edge or `else` for every outcome but those two. An unnamed `failed` fails the Run with the step's reason, and a parent's Task step then takes `failed` with it. A Judge that names `unsure` goes there when Jev is unsure; without it, Claude picks. Loops are allowed.

**Bindings** are `{input.field}` and `{steps.name.field}`.
- A text that is exactly one binding keeps the field's type; inside longer text a number is written without a decimal point and a list or object as JSON. A loop's binding reads the step's latest finished visit.
- A step's field must be on every path to where it is used. The check says "might not have a result" otherwise. A field that may have no value (optional in a schema, or given by only some outcomes) goes only where it can be left out: an optional field of the result or of a sub-task's input, `state`, `body`, `folder`, `agent`. Never inside longer text.
- A binding's type must fit where it goes (an integer fits a number; text doesn't fit a number).
- Braces around anything that isn't a dotted word (JSON in a prompt) are text. `{inputs.topic}` is a problem, not text.

`end` lists a value for every required field of `result`, each a literal or a binding.

## Bounds and grants

A Run takes at most 50 steps (loops count) and works at most 60 minutes of awake time; a sub-task has its parent's limit and Runs nest 3 deep. A Task may not reach itself through sub-tasks. Passing a bound fails the Run with that reason; a Task step then takes `failed`.

Permissions for a Task's Claude steps are the user's, set in Settings › Tasks and never in the file, so a Task you write has none of its own. A Claude step's session lists `notify` and `task_result` alone, so it starts nothing else; a Run starts other Tasks only through a `task` step.

## Test

Never call `task_run` to test: a Run draws on the user's Claude subscription and TypeSafe. `task_check` is the test. To see a Run work, ask the user to start it from `!task`.

## Gotchas

- A file that isn't JSON, or has a duplicate `name` in its folder, is listed with the problem.
- The check reads again each time a list shows, so an edit needs no restart.
- Sub-tasks are found from the folder the parent was found from; the check finds them the same way.
