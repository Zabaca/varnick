# Pane processes live in zmx so they outlive Launchy

Claude and terminal panes run their process inside a zmx session, one background daemon per pane named after it, instead of as a child of Launchy's terminal view. Restarting, quitting or crashing Launchy then only detaches them, and the pane reattaches with its screen restored when Launchy is back. Closing a pane ends its session, and `claude --resume` (ADR 0001) is the fallback once sessions are gone after a reboot or logout. We chose zmx over tmux because zmx restores the screen without a terminal emulator sitting between the program and SwiftTerm, so panes keep SwiftTerm's keys, scrollback and rendering, and because zmx publishes a single binary per release. We chose it over a terminal host of our own because that would be the same daemon, socket protocol and screen restore, written and kept compatible here. The problem and its options are in `docs/problems/restart-ends-sessions/`.

## Considered Options

- **tmux**: rejected. It redraws every pane through its own emulation at all times, moves scrollback into copy mode, and publishes no macOS binary to pin.
- **A Launchy-owned terminal host**: rejected. Same shape as zmx with a second executable and protocol to maintain; SwiftTerm can't serialize a screen to restore it.
- **Re-executing Launchy with the terminals kept open**: rejected. It survives only restarts Launchy performs itself, not crashes, signals, kickstart or Quit.
- **dtach, abduco**: not chosen. They detach and reattach but don't restore the screen.
- **`--resume` alone**: rejected. The conversation comes back, but in-flight work doesn't.

## Consequences

- A runtime dependency besides the Swift packages of ADR 0003: zmx, a prebuilt binary `make build` fetches at a pinned version and checksum and puts next to Launchy. Launchy uses only that copy. A zmx release that changes its IPC protocol can't reach daemons started by the previous one, so bumping the pin ends running sessions once.
- Off by default behind a setting until SwiftTerm's rendering of a reattached Claude Code screen is checked.
- Quit no longer stops sessions; closing a pane does. Launch kills Launchy's zmx sessions that no restored pane points to, unless the saved tabs failed to load.
- Every zmx command Launchy runs sets `ZMX_DIR=/tmp/zmx-<uid>`. Under launchd, zmx would otherwise use `$TMPDIR`, which interactive shells don't, and that path nearly reaches macOS's 104-byte socket path limit. The user's own zmx sees the same sessions.
- zmx attach exits 0 however the session ended, so Launchy no longer gets a zmx pane's exit code.
- Once the setting is on by default, a restart no longer ends the sessions open in Launchy, and the CLAUDE.md rule leaving restarts to the user can be relaxed.
