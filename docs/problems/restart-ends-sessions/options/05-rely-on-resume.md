---
problem: restart-ends-sessions
title: Rely on --resume
summary: Leave pane processes as Launchy's children and keep today's recovery: restored Claude panes run `claude --resume`, terminals start fresh, and agents leave restarts to the user.
status: rejected
reason: The conversation already comes back with `--resume`; what the problem is about is the work that was in flight, which this loses on every restart.
---

## Solution

No change. A restart, quit or crash ends every pane. Restored Claude panes resume their session when shown (ADR 0001), terminals start fresh in their last folder, and CLAUDE.md keeps telling agents to leave restarts to the user.

## Trade-offs

- **Nothing to build or depend on.**
- **In-flight work is lost** each time: tool calls, background subagents and commands, the turn being written, a terminal's running command.
- **Agents can't check their own Launchy changes** with a restart, since it would end their session.

## User Stories

None beyond today's.

## Implementation Decisions

None.

## Testing Decisions

None.

## Out of Scope

Everything in option 01.

## Further Notes

- `--resume` remains the fallback under option 01, once sessions are gone after a reboot or logout.
