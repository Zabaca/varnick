---
problem: pane-kinds-are-built-in
title: Apps can be terminal commands too
summary: A manifest can say its app is a terminal program instead of a web server, and Launchy runs it in a terminal pane picked from the same split picker.
status: rejected
reason: A terminal pane already runs any command, so terminal apps add no capability, only a shortcut. They would double the contract (a terminal app and a web app start, show, restore and fail differently) before the first web app has shipped. The user put terminal-UI apps out of scope; they can come later, with the marketplace if wanted.
---

## Solution

The manifest gains a kind, web or terminal. A terminal app's entry runs in a terminal pane, in zmx like any terminal pane, and has no port.

## Trade-offs

- **One picker for every tool,** web or terminal.
- **Two app shapes to define and keep working.** Environment, restore, exit and output differ between them.
- **Little gained.** Picking Terminal and typing the command does the same, and a shell alias shortens it.

## User Stories

1. As someone who builds terminal tools, I want them in the split picker, so that I don't have to type their command.

## Implementation Decisions

- Not taken further.

## Testing Decisions

- Not taken further.

## Out of Scope

- Not taken further.

## Further Notes

- Option 01 lists terminal-UI apps as out of scope.
