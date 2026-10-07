---
title: The Mac not in control sees a frozen screen, not the session working
description: While one Mac is in control of a Claude session, the other Mac's pane shows the session's frozen screen, one snapshot fetched when control leaves and when the pane comes into view. The user can't watch Claude work from the other Mac. The snapshot is also drawn at the viewing pane's size, so a screen laid out for the Mac Studio's wider grid wraps in the MacBook Air's smaller pane.
impact: To follow a long task from the other Mac the user hides and shows the pane to fetch it again, or takes over, which moves the keyboard away from the Mac typing into it. A snapshot from a larger grid is harder to read than the session looked.
severity: mid
evidence: The user's request of 2026-10-05, with their measurements of the `screen` request. Code read at ace79c3, and at main's 2b5f10c for Release and for opening a peer's session on the card. zmx 0.8.1 read in its tagged source (8bab1f0), ghostty's formatter at the commit zmx pins, and upstream zmx's unreleased changes. Read-only checks on the Mac Studio over SSH on 2026-10-05. Nothing was run against a zmx session.
status: open
---

## What the user wants

1. **Real time.** The Mac not in control watches Claude work live.
2. **Read-only.** The view stays read-only, with exactly one Mac in control. It must never send input to the session.
3. **The controller's grid, scaled.** Output from Claude carries absolute cursor moves for the grid of the Mac in control, so drawing it on a smaller grid garbles it. The view draws at the controller's exact columns and rows and scales that to fit the pane, like screen sharing, and clips and scrolls once the text would get too small. The frozen snapshot is drawn the same way.
4. **The snapshot stays, as a building block:**
   - the first frame of every live view;
   - what a pane shows when it comes back into view, since a hidden pane streams nothing;
   - the fallback while the host can't be reached, marked "Last screen at HH:MM";
   - the frame shown while the view reconnects.
5. **A Linux host later.** Nothing on the host's side may rule out a headless Linux peer (a Ryzen box) hosting sessions.

## Today

Verified in the code unless marked otherwise.

- **What the frozen screen is.** On the host, `zmx history <name> --vt` is cut to its last 500 lines and has its private mode sets stripped (mouse, focus, paste, colour-scheme and size reports, the alternate screen). A peer gets it through the relay's `screen` request, and the host reads its own zmx directly. It is drawn in a terminal view with no process, which drops whatever the terminal would send back and never becomes first responder.
- **When it's fetched.** It is fetched when control leaves, and again two seconds later because the Mac that took control is still redrawing. It is also fetched when the pane's tab is activated, when the panel shows (for the active tab), and when the card's own five-second check finds another Mac in control. Nothing fetches it while it stays on screen.
- **Its size.** The view's grid follows the pane, so the snapshot wraps at the pane's width and is drawn again when the pane resizes. Nothing in Launchy knows the controller's grid.
- **Where it shows.** It shows on a peer whose pane lost control, and on the host while a peer is in control. It also shows on a peer that opened another Mac's open session from the session list, Recent or search, which opens on the card since 2b5f10c.
- **"Controlled on" or "Last controlled on".** The bar and the session list say "Last controlled on <Mac>" when the host's zmx reports no client attached to the session, and "Controlled on <Mac>" otherwise.
- **Requests to a peer.** Each is a new SSH command on the shared connection, and its output is read once the command exits. The only long-lived channel is a pane's `ssh -t` to the relay's `attach`, which turns into zmx's client.
- **Other cards keep no screen.** A card for a lost link, an unreachable host or a session being resumed clears the screen.
- **Take over and Release** both end by detaching every zmx client of the session.

## Measured

- **By the user, 2026-10-05:** a `screen` reply is 12–16 KB. It takes about 165–240 ms over the shared SSH connection, and about 350 ms over a new one.
- **Here, 2026-10-05, from this MacBook Air to the Mac Studio** (M3 Ultra, macOS 26.5.1), with a new connection each time:
  - `ssh … true` took 0.24–0.33 s, and the relay answering a malformed request took 0.27–0.28 s.
  - On the Studio, the relay binary answers that request in about 10 ms, and `zmx version` and a login zsh each start in under 10 ms. Tailscale SSH runs each command under `/usr/bin/login`.
  - Ping over the tailnet was 16–113 ms, 55 ms on average.
- **What that means.** A `screen` call's time is mostly SSH session setup and round trips on the link, not starting the relay. Polling pays that on every call, and a long-lived channel pays it once. The split over the shared connection wasn't measured here: the control socket's path from this session's scratch folder was over the length limit.
- The Studio's relay answers with protocol version 7, as main has.

## Facts the options rely on

### zmx 0.8.1, read in its source

- **Every connection is a client.** Any process that connects to a session's socket gets every byte the session's program writes, whether or not it ever sends anything.
- **Only some messages change the session.** A client becomes the leader, whose size the session takes, in one of two ways: it sends Init or Resize while there is no leader, or it sends typed input. A client that sends nothing never leads and never resizes the session.
- **Init, the message `zmx attach` sends first, does more than set a size:**
  - It marks the client as a terminal. When the session goes from no terminal client to one, or back, zmx writes a focus-in or focus-out report into the program's input. Claude turns focus reports on.
  - A client that sends Init while there is no leader becomes the leader, and the session is resized to it.
  - Separately, 0.8.1 counts a kitty keyboard status reply (`CSI ? flags u`) as typing, so a terminal's automatic reply can take the lead. Upstream has fixed this but not released the fix.
- **`zmx tail <name>`** connects and sends nothing, so it is read-only and never changes the size.
  - It gets no screen to start from. zmx sends the restored screen only in answer to Init, so tail gets only output written after it connects.
  - It passes every chunk through a filter that keeps printable bytes, CR, LF, tab and backspace, and drops every escape sequence (CSI, OSC, DCS). The changelog marks this as breaking since 0.7.0. There is no flag to keep the escape sequences, and no read-only attach.
  - The filter starts a new parser for each chunk, so an escape sequence split between two reads of the terminal leaks its tail as text.
- **`zmx history --vt` and the restore are built differently:**
  - `history --vt` writes the whole scrollback and the screen in one pass, with modes, scrolling region, cursor and style. It goes through ghostty's formatter, which always trims trailing blank lines (its own documentation says so). It carries no grid size.
  - The restore zmx sends an attaching client is built for exact cursor positions: scrollback, then clear and home, then the visible screen from its top row (zmx issue #31).
  - So output that continues from a `history --vt` picture lands too low by as many blank rows as the screen had at its bottom, whenever there is scrollback above. Inferred from the two serializations, not seen.
  - Upstream's unreleased `Capture` request serializes the screen plus at most a given number of scrollback rows. With none, it would give a picture that starts at the top row and lines up exactly.
- **`zmx ls` counts every connection but the one asking** as a client: `tail`, `history` and any reader count while connected.
- **`zmx detach`, used by Take over and Release, closes every connection**, `tail` and readers included.
- **Upstream declares the socket protocol frozen:**
  - Each message is an 8-byte header (a tag byte, a 32-bit little-endian length, padding) followed by the payload.
  - Tags are fixed numbers (Output 1, Init 7, History 8), and new features get new tags that old daemons ignore.
  - The socket is `$ZMX_DIR/<name>`.
- **A client that stops reading** makes the daemon queue output for it without limit. Each client's outgoing buffer grows in memory until it drains.
- **The session's size** is set on its pseudo-terminal whenever the leader sends Init or Resize. Info, the record each listing line comes from, carries the pid of the session's program but not its size.

### The host can read the grid

- Claude's processes have a controlling terminal: `ps` lists `ttys003` and so on for them (checked on this Mac).
- Reading that terminal's window size from another process of the same user, as `stty size` does, should give the grid zmx set. This is POSIX behaviour, inferred and not tried on a session.
- The pid is in `zmx ls`. On Linux the terminal is found through `/proc/<pid>/fd/0`, and the same call works.

### SwiftTerm

- A terminal view's grid follows its frame: columns are the width over the cell width, and rows the height over the cell height. Given a grid, it reports the frame that fits it. So a view can keep a fixed grid by sizing its frame from the grid at a chosen font size, instead of from the pane.
- A live pane feeds SwiftTerm bytes in whatever chunks the terminal delivers, so the parser must already carry escape sequences and UTF-8 characters across feeds. Inferred from how live panes use it.

## Not part of this problem

- Typing from the Mac not in control, or any shared control.
- Moving to a newer zmx.
- A Linux build of Launchy's relay. Here, only not ruling one out.
