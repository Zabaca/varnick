---
problem: tasks-cant-be-handed-to-varnick
title: Hey Varnick starts a task, speaks its progress and stops it by voice
summary: Builds on option 01, later. Hey Varnick's route gets one more answer, `task`, for a request to carry something out on a site ("Hey Varnick, find out how much delivery to Canada costs on pebbleandpine.example"). It is asked of Jev in the route call, as ADR 0037 has every decision asked, and of the Text generation model when Jev isn't used. A request read as a task opens a Task pane in a new tab without showing the panel. Claude, in the values job, writes the start address from the request, and the task runs as in option 01 with every progress line spoken. "Hey Varnick, stop" ends it. Passwords, terms and Allow still need the pane. It reverses the rule that a spoken request never opens anything, so it needs an ADR amending ADR 0015, and a route eval first, since a new answer changes what the route's measured thresholds mean.
status: proposed
---

## Solution

- **Noticing.** One more answer in the route call: "The person asks Varnick to carry out something on a website for them: find something on a particular site, fill in a form, create an account, order something." It is read after the clock and can't-do answers and before the screen. A task is something Varnick can now do, so it leaves the can't-do criterion.
- **Telling a task from a web question.** "What does a Brava kettle cost" stays a question, answered from the rows or the web. "Find the price on pebbleandpine.example" is a task. The eval measures the line between them.
- **The start.** The request becomes the task's text. Claude's first values reply carries the start address, or "none". With none, the pane waits and Varnick says "Which site? Open it in the Task pane."
- **What opens.** A Task pane in a new tab, not shown. The acknowledgement is "Starting a task on pebbleandpine.example". Every option 01 line is spoken, page changes included, since the user isn't looking.
- **Stopping by voice.** "Hey Varnick, stop" while a task runs is read by the route as stopping it, a second new answer, and the task stops as Stop does. Allow, passwords and terms still need the pane. "Show me the task" opens it, as `!task` does while one runs.
- **Needs** Listening on, Hey Varnick, and option 01's Tasks switch.

## Trade-offs

- **For:** the most natural way to hand something off, and the user needn't look until a gate.
- **Reverses ADR 0015's "nothing is shown or opened".** A tab opens unseen, and the glossary's Spoken request changes.
- **The route's thresholds were measured on its exact questions.** Two more answers change them, so the route eval has to run again on the shipped questions with the new ones.
- **A misheard site name** starts a task on the wrong site. The first spoken line names the site, so the user hears it, and Stop is a word away.
- **More goes to Anthropic before anything is shown:** the request and the pages of a task the user hasn't seen start.

## User Stories

1. As the user, I want to say "Hey Varnick, find the delivery price to Canada on Pebble & Pine" and hear the answer, without opening anything.
2. As the user, I want to hear which site it opened, so that a misheard name is caught at once.
3. As the user, I want "Hey Varnick, stop" to end a running task.
4. As the user, I want to hear "I need you: your password" and find the pane ready when I open it.

## Implementation Decisions

- The two answers go in the one route call, worded once for Jev and for the Text generation fallback, as ADR 0037 has it.
- No phrase list decides "task" or "stop".
- The task's start reuses option 01's `task` command path. Nothing about tasks is duplicated in the spoken pipeline.

## Testing Decisions

- **A route eval in agent-lab before building.** Made-up task requests, web questions about sites and products, own-History questions naming a site, and "stop" phrasings. It covers Jev and the Text generation fallback, and checks the existing answers' rates before and after.
- **By hand:** with the pane hidden, a spoken task, its lines, a gate, and a spoken stop.

## Out of Scope

- Allowing a submit by voice.
- Saying a password.

## Further Notes

- Ordered after option 01 is in use, so the loop is known to work before it is started blind.
