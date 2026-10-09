---
title: Restarting Launchy ends every session open in it
description: Every Claude, terminal and transcript pane runs as a child of Launchy's own terminal view, so any restart, quit or crash ends them all. `--resume` brings a Claude conversation back, but work it had in flight (running tool calls, background subagents, a shell's dev server) is lost and has to be started again.
impact: A long session running several subagents is set back to its last finished turn on every restart, and the lost work costs time and tokens to redo. Developing Launchy restarts it often, so this happens repeatedly, and agents are told to leave restarts to the user because a restart may end the session they run in.
severity: high
evidence: Spike on 2026-10-03 (see option 01, Further Notes) showed a process kept in zmx survives `launchctl kickstart -k` and SIGKILL of the parent holding its terminal. CLAUDE.md, under Working here, tells agents to leave restarts to the user for this reason.
status: closed
---

Each pane that runs a process (a Claude session, a terminal, the live **Transcript**) is started by SwiftTerm on a pseudo-terminal Launchy owns, so the process is Launchy's child. Launchy stops in several ways, and each one takes every pane's process with it:

- `make run` restarts Launchy from a detached script that kills the running instance with `pkill`.
- `make install` and `launchctl kickstart -k` restart the LaunchAgent instance.
- Quit from the menu bar.
- A crash.

When Launchy starts again, tabs come back dormant and each pane starts when first shown. A Claude pane runs `claude --resume` on the session it was last on (ADR 0001), so the conversation is there. A terminal starts a fresh shell in its last folder, and the transcript pane starts following today's file again. Anything that was running is gone: a tool call midway through, background subagents and background shell commands, the turn Claude was writing, a dev server or build in a terminal. Scratch-area Vite servers outlive a signal, but Launchy kills them at launch and starts them again when their pane is shown.

A reboot or logout also ends every session. Nothing short of saving process state could survive that, and it happens far less often than a restart.
