---
problem: restart-ends-sessions
title: Hand terminals to a relaunched Varnick
summary: A planned restart re-executes Launchy in place, keeping every pane's pseudo-terminal open and its process as a child, and the new build picks them up without any extra process.
status: rejected
reason: It covers only restarts Launchy performs itself. A crash, `pkill`, `launchctl kickstart -k` and Quit would still end every session, and `make run` and the LaunchAgent stop Launchy from outside today. It also needs SwiftTerm to adopt an existing pseudo-terminal, which it can't.
---

## Solution

Instead of being killed, Launchy is asked to restart. It saves each pane's pseudo-terminal descriptor and process id, clears close-on-exec on those descriptors, and executes the new binary in the same process. The new Launchy reads the saved list and reconnects each pane to its descriptor. The children never notice, since their parent's process id doesn't change. Claude redraws on the resize that follows.

## Trade-offs

- **No extra process and no dependency.**
- **Planned restarts only.** Nothing survives a crash, a signal, kickstart, `make install` or Quit, which are most of the ways Launchy stops today.
- **The screen isn't restored,** only redrawn by programs that redraw on resize. A shell's output above the prompt is lost.
- **Needs a SwiftTerm change.** Its local process starts new processes only and keeps its descriptor private, so adopting one means forking SwiftTerm or replacing its process handling.
- **Changes how restarts are triggered.** `make run` and `make install` would ask Launchy to restart instead of killing it, and fall back to killing when it doesn't answer.

## User Stories

Option 01's stories 1 and 12, for `make run` only.

## Implementation Decisions

Not worked out.

## Testing Decisions

Not worked out.

## Out of Scope

Crashes, signals, kickstart, `make install` and Quit.

## Further Notes

- Would only be worth reconsidering as a complement to option 01, for a pane kind zmx can't host.
