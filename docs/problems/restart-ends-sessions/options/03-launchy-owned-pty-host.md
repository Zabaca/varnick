---
problem: restart-ends-sessions
title: A Launchy-owned terminal host
summary: A second, small Launchy executable owns every pane's pseudo-terminal and process, outlives the app, and streams each pane to Launchy over a Unix socket, restoring the screen on reconnect.
status: rejected
reason: It is option 01 written and maintained here. It needs the same per-session daemon, socket protocol, screen restore and version skew, and adds a second executable target and a protocol to keep compatible across builds. Reconsider only if zmx proves unworkable and its reason no longer holds, for instance if SwiftTerm can't render zmx's restored screens.
---

## Solution

A helper executable, built from this repo, starts pane processes on pseudo-terminals it owns and detaches from Launchy (its own session, or a LaunchAgent). Launchy connects to it over a Unix socket per pane, sends input and size, and receives output. The host keeps each pane's screen in a headless terminal (SwiftTerm's terminal model, without a view) and sends a snapshot when Launchy reconnects. Closing a pane tells the host to end it.

## Trade-offs

- **No new dependency,** and full control over naming, environment and exit codes. The host can pass a pane's real exit code, which zmx doesn't.
- **Much larger.** A second executable target, a socket protocol, a daemon lifecycle, and a way to turn a terminal's state into bytes that redraw it. SwiftTerm exports only a buffer's plain text, without colours, cursor or modes, so that would be written here.
- **The same version skew, now ours.** Every Launchy build that changes the protocol ends running sessions unless the host stays compatible, and Launchy is rebuilt far more often than zmx is released.
- **Another always-on process** to start, find and clean up, with the same launchd questions the zmx spike answered for zmx.

## User Stories

Same as option 01.

## Implementation Decisions

Not worked out. Shape only: one host process or one per pane, a socket per pane under a short path, a snapshot on reconnect, and the same lifecycle rules as option 01 (end on close, survive quit, sweep at launch).

## Testing Decisions

Would get a test target for the protocol and the snapshot round trip, both of which are pure.

## Out of Scope

As option 01.

## Further Notes

- SwiftTerm can't take over a pseudo-terminal it didn't create: its process type only starts new ones. So Launchy's side would read and write the socket itself and feed a terminal view, rather than reuse its current local-process view.
