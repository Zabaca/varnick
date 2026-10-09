---
problem: sessions-out-of-reach-from-the-phone
title: The Mac's running Launchy serves the page itself
summary: Launchy gets an HTTP and websocket server of its own, on an owner-only Unix socket published with `tailscale serve`. It answers the phone from its own model, with the same host functions a peer's requests reach, and runs the phone's terminals in pseudo-terminals of its own. Devices, checks, the page and the reconnect rules are as in option 01. Mac only. It meets everything but the user's Linux requirement, and puts a listener in the app.
status: rejected
reason: Not chosen in ADR 0011. It is Mac only and puts a listener in the app, and the Linux host needs the page too.
---

## Solution

The running Launchy listens on an owner-only Unix socket in its Application Support folder, and `tailscale serve` publishes it on port 8444, tailnet only, as in option 01. It serves the same page.

**Answers come from Launchy's own model, with no relay in between:**
- the tabs and Recent;
- projects and agents;
- start, resume and end, through the functions that answer a peer's `start`, `resume` and `end` today.

**Terminals and the live view.**
- For each terminal, Launchy runs the same zmx attach the relay would (with take, when the user pressed it) in a pseudo-terminal of its own, off the main actor, and carries the bytes over the websocket.
- The live view reads the session with the in-process reader that the accepted live view already gives the host's own card.

**The rest is as in option 01:**
- devices, and how the caller is identified;
- the Host and Origin checks;
- the page;
- take only after a press, and the reconnect rules.

## Trade-offs

- **No new runtime.** Everything is in Swift. No Bun server and no xterm.js server, though the page still needs xterm.js.
- **The model is right there.** Names, titles and state are current, with no relay hop and no file for devices: they can live in UserDefaults with the peers.
- **Mac only.** A Linux host has no Launchy app. So the user's requirement that the page work on Linux isn't met, unless option 01's server is built for Linux as well, which makes two implementations of one page.
- **A listener in Launchy,** which ADR 0007 turned down for peers (that problem's option 03). It means request handling, a websocket server with no new dependencies (Network.framework), and Settings for the socket.
- **Restarting Launchy drops every phone terminal, and the page with it.** Restarts are frequent while Launchy is developed. The relay's "works with Launchy not running" doesn't carry over.
- **The phone's traffic shares Launchy's process.** Terminal bytes stay off the main actor, but a stall or crash in the app stalls or ends the phone's view. A crash in the server ends every Claude pane that isn't in zmx.

## User Stories

As option 01, without story 14 (Linux hosts).

## Implementation Decisions

- **Devices** are as in option 01, kept in UserDefaults beside the peers, since only Launchy reads them.
- **The server** is a Network.framework listener on the Unix socket, with a websocket for each terminal and live view. It never runs on the main actor, and never inside a view update.
- **The page's files** are bundled with Launchy, xterm.js pinned among them.
- **Terminals** are pseudo-terminals Launchy opens for zmx attach. The relay's rules for the attach are kept:
  - the session-name check;
  - relabel, then detach, then attach when taking;
  - `/usr/bin/false` as the command;
  - `ZMX_SESSION` unset.
- **The setting, and Settings' serve status,** are as in option 01.

**Scope and ticket order:** option 01's tickets 1 to 5, with the server inside Launchy, and no Linux ticket.

## Testing Decisions

As option 01, without Linux, and with the restart check reversed: restarting Launchy drops the phone's terminal, and the page reconnects once Launchy is back.

## Out of Scope

As option 01, plus Linux hosts.

## Further Notes

- **Not recommended.** It fails the user's Linux requirement, and puts in the app the listener ADR 0007 kept out. Its gain, no Bun server, is small, since Launchy already runs Bun servers for custom apps.
- **Re-propose** if Linux hosts are dropped and the user would rather have no server outside the app.
