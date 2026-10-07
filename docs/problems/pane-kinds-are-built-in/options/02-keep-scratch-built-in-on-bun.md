---
problem: pane-kinds-are-built-in
title: Keep Scratch built in and switch it to Bun
summary: Leave Scratch inside Launchy as it is and change only its runtime, from `deno install` and `deno run -A npm:vite` to `bun install` and Vite under Bun.
status: rejected
reason: It fixes only the runtime. Launchy still owns one tool's process handling, every Claude session in every folder still carries its prompt and extra directory, and the next tool still has to be written into Launchy. The user wants an extension point, with Scratch as its first use.
---

## Solution

Scratch stays a Launchy module. Its shared root is installed with `bun install`, and each pane's server starts with Bun running Vite instead of Deno. Everything else, from the appended prompt to the orphan pass at launch, stays as it is.

## Trade-offs

- **Smallest change.** Two commands and the install check change; nothing else moves.
- **Every Claude session still pays for Scratch,** in every folder, used or not (2 of 36 panes here built a page).
- **Launchy keeps Scratch's survival logic** beside zmx's: port and pid files, adoption and orphan killing.
- **Nothing for the next tool.** The split picker stays fixed.

## User Stories

1. As a Launchy user, I want Scratch on Bun, so that its developer experience matches the tools I use.

## Implementation Decisions

- Not taken further.

## Testing Decisions

- Not taken further.

## Out of Scope

- Any change to the split picker.

## Further Notes

- Its one goal, Scratch on Bun, is part of option 01.
