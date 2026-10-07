---
problem: restart-ends-sessions
title: tmux as the persistence layer
summary: Each Claude and terminal pane runs in a session on a private tmux server, so pane processes outlive Launchy and reattach with tmux's own redraw of the screen.
status: rejected
reason: tmux is a terminal emulator in the middle. Every pane's keys, scrollback and rendering would go through tmux instead of SwiftTerm, at all times, not only on reattach. It also needs a binary Launchy would have to ship, which tmux doesn't publish for macOS. zmx (option 01) gives the same survival with the program talking to SwiftTerm directly.
---

## Solution

Launchy runs a tmux server of its own, on a private socket with its own config file: no status bar, no prefix key, mouse handling off. Each pane's terminal runs tmux new-session with attach-if-exists, named after the pane, with today's command. Restarting Launchy detaches the clients and the server keeps the processes running. Closing a pane kills its tmux session.

## Trade-offs

- **Mature and well known.** tmux has decades of use, and its attach, detach and redraw are well understood.
- **Always in the middle.** tmux parses the program's output and redraws it on its own model of the screen, all the time. Claude Code's rendering, the Kitty keyboard protocol, shift+enter, image paste and true colour all depend on what tmux supports and how it's configured, not on SwiftTerm.
- **Scrollback moves into tmux.** Pane output goes to tmux's history, so scrolling in SwiftTerm shows nothing. Scrolling back would need tmux's copy mode, a different interaction from every other pane.
- **One server holds every session.** If the tmux server crashes or is killed, every pane's process goes with it. zmx runs one daemon per session.
- **Same version risk as zmx.** A tmux client refuses to talk to a server from a different protocol version, so it also needs a pinned binary.
- **No binary to pin.** tmux isn't installed on this Mac, and its releases are source tarballs (as far as known). Homebrew's tmux links libevent, ncurses and utf8proc, so shipping a pinned copy means building it.

## User Stories

Same as option 01, stories 1 to 9.

## Implementation Decisions

- A private socket name and a config file Launchy writes, so the user's own tmux and its config never apply.
- Session name and lifecycle as in option 01: named after the pane, killed when the pane ends, left running on quit, swept at launch.

## Testing Decisions

As option 01, plus checking that keys and scrollback behave the same inside tmux as in a direct pane.

## Out of Scope

As option 01.

## Further Notes

- Re-propose only if zmx can't be made to work and building and pinning tmux becomes acceptable, for instance if SwiftTerm can't render zmx's restored screens but renders tmux's.
