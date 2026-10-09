---
problem: frozen-screen-not-live
title: Push changed screens from the host over one long-lived channel
summary: While a card is shown, the host's relay watches the session's zmx socket for output. Whenever something changed, it sends a fresh snapshot with its grid, at most five a second. Every frame is a whole picture at the controller's grid, so nothing garbles and nothing is sent while Claude is idle. It is near live rather than smooth, and sends more bytes than a raw stream while Claude works.
status: shipped
---

## Solution

While a card is shown, the viewing Mac holds one SSH channel to a new relay request on the host, `watch`. The relay connects to the session's zmx socket and never sends it input, Init or a size. Any output on the socket means the screen changed. At most every 200 ms while it has changed, the relay asks zmx for the history on the same connection. It prepares the history as the `screen` request does and sends it with the grid read from the session's terminal, unless both match the last frame sent. The view draws each frame at its grid, scaled to fit the pane (option 02). On the host's own card, Launchy runs the same reader in process.

The snapshot is the only kind of frame. It is the first frame, what a pane shows when it comes back into view, and what stays on screen through a lost link or a reconnect. Option 03 is this channel with Claude's output also sent between frames.

## Trade-offs

- **Near live.** A change shows within 200 ms plus the link. Claude's spinner and streamed text move in up to five steps a second rather than smoothly.
- **Never garbled.** Every frame is a whole picture at its own grid. A resize is just the next frame, and there is no stream to keep in step, so option 03's misalignment in zmx 0.8.1 can't happen.
- **Nothing while Claude is idle, on either Mac.** No output means no snapshot and no frame.
- **More bytes than a raw stream while Claude works:** up to five frames a second of 12–16 KB, against Claude's own output rate in option 03.
- **The host serializes the scrollback for each frame,** up to five times a second while Claude works. That costs little on the Studio and more when the Air is the host.
- **Launchy reads zmx's socket,** but only to notice output and to ask for the history. It never sends input, Init or a size, so it can't lead, resize the session, or set off a focus report.
- **A reader counts as a zmx client,** and that count decides between "Controlled on" and "Last controlled on". The host has to know its readers and leave them out.
- **A fair amount to build:** a long-lived channel kind, framing, the reader, a registry of readers and the lifecycle. Option 03 adds output frames to all of it.

## User Stories

As option 02, with story 1 reading: as a user at the Mac not in control, I want to see Claude's screen change as it works, several times a second, so that I can follow a long task without taking it over.

## Implementation Decisions

### The `watch` channel

Option 03 uses this section too.

- **The request.** `watch` (session) is answered only to a listed Mac, after the name check, like `screen`. It needs only zmx, so it works with Launchy not running on the host.
  - The relay first prints one JSON reply line: version, `ok` or the error, and `unlisted`. The client's usual checks apply, and Tailscale SSH swallowing exit codes doesn't matter.
  - It then writes frames until the session ends, until the reader is detached (Take over, Release), or until the channel closes.
- **Frames.** Each frame is length-prefixed, never base64. A frame is the grid and the prepared snapshot, the same text `screen` sends. Option 03 adds output frames.
- **The reader.**
  - It connects to the session's socket in Launchy's zmx folder and sends only history requests.
  - It reads the socket at all times, so zmx's buffer for it never grows.
  - Any output marks the screen changed. A frame is taken at most every 200 ms while it has changed, and sent only if the screen or the grid differs from the last frame sent.
- **The latest frame wins.** A frame not yet written to the channel is replaced by a newer one, never queued behind it.
- **Ending.**
  - The relay exits when the session's socket closes: the session ended, or Take over or Release detached every client.
  - It also exits when its own input or output closes. The viewing Mac keeps the ssh's input open, so a viewer that quits or crashes ends the reader at once.
- **The registry of readers.**
  - While it runs, each reader, whether a relay or the host's own, records its session and pid in a folder under Launchy's Application Support.
  - The host's `status` and its open sessions count zmx clients minus the live readers, so "Last controlled on" stays right. An entry whose pid is gone is ignored and removed.
  - Nothing in `sessions.json` or UserDefaults.
- **SSH.** A third kind in the SSH runner, beside requests and pane terminals: a long-running command on the shared connection.
  - Its output is read as it arrives, never on the main actor.
  - Its input is held open.
  - Cancelling it ends the ssh process.
- **The host's own card** runs the same reader in process, off the main actor, with no SSH.
- **When it runs.** It starts when the card becomes shown (as option 02 defines it). Its first frame is a snapshot, which meets the user's "first frame" and "refreshed when shown". It stops ten seconds after the card stops being shown, so a quick hide and show keeps it.
- **Take over and Release** close the reader, as they detach every client.
  - A pane that took control is live, so it needs no reader.
  - A card still showing another Mac in control starts a new reader.
  - The channel ending is never taken as the session ending. The card's own check decides, from the label and zmx, as today.
- **Reconnecting.** A dropped channel leaves the last frame on screen, marked "Last screen at HH:MM". While the card is shown, the view reconnects after 1, 2, 5 and 10 seconds, then every 30. The card's five-second check goes on as today.
- **Scrolled back.** Frames are kept but not drawn until the user scrolls back to the bottom (option 02).
- **What a frame holds.** A frame holds what `screen` sends today: the screen plus a 500-line tail. If the spike shows frames are too large, later frames can be cut to the screen and a short tail, with the full tail sent when the view pauses.

### Size and the view

As option 02.

### What the user asked to see for each option

- **Stripping:** each frame is a whole snapshot, stripped on the host as today, so nothing is ever split.
- **Size:** each frame carries its grid. When the controller resizes, Claude repaints, which is output, so the next frame, within 200 ms, comes at the new grid. Nothing garbles in between.
- **Battery and bandwidth** (estimates):
  - Nothing while Claude is idle, on either Mac.
  - While it works, up to five frames a second of 12–16 KB, so 60–80 KB/s, or about 20–40 KB/s if frames are cut to the screen.
  - The host serializes up to five times a second, and the viewer redraws up to five times a second.
  - Spike steps 1 and 3 measure how often the screen changes and how big it is.
- **Reconnect and lifecycle:** as above.
- **Linux:**
  - The reader needs only a Unix socket, polling and a terminal size read.
  - zmx's header has the same byte order on arm64 and x86-64.
  - Launchy sets the zmx folder, so the socket path doesn't depend on Linux's defaults.
  - The relay stays in Foundation. On Linux, the session's terminal is found through `/proc`.

### State and protocol

- The new request bumps the protocol version.
- The registry folder isn't saved state. The registry is cleaned as it is read.

**Scope and ticket order:**
1. Option 02's ticket 1: the grid and the scaled view.
2. **The `watch` channel:** the request and its frames, the reader, the registry, the SSH kind, the lifecycle and reconnecting, and the host's own card.

## Testing Decisions

- No test target. The pure seams for the first tests:
  - encoding and decoding frames, and decoding zmx's header;
  - the frame rule, "changed, at most every 200 ms, only if different";
  - counting clients minus live readers.
- **By hand,** on both Macs after `make build` and a restart the user does. Option 02's checks, plus:
  - Claude's spinner moves on the Air's card several times a second.
  - An idle session sends no frames: the relay on the host stays quiet and uses no CPU.
  - While a card is shown, `zmx ls` on the host shows one more client, but the bar still says "Last controlled on" when the Mac in control has no client.
  - Take over and Release from each side: the reader ends and starts again as above, and no session ends.
  - Quit Launchy on the Air while its card is shown: the relay on the Studio exits within a second.
  - Hide the panel: the relay exits after ten seconds.
  - Restart Launchy on the host: the frames keep coming, since the relay needs only zmx.

## Out of Scope

- Claude's output between frames (option 03).
- Typing from the viewer.
- Compressing frames, until the spike says they're too large.
- A last screen on the Lost connection and Not reachable cards (option 02, open question 3).

## Further Notes

### Recommendation

Recommended. It meets every wish but perfect smoothness. It can't garble, it costs nothing while Claude is idle, and it keeps the snapshot as the only kind of frame, which is the building block the user described. Option 03 is the same channel plus output frames. It is worth adding once a zmx with screen-only capture is pinned, or if this one's frames prove too costly.

### Considered within this option

- **Polling the history on the host every 200 ms** instead of watching for output. It is simpler, with no reading of zmx's socket and no registry, but it serializes five times a second even while Claude is idle. That is a steady drain when the Air is the host.
- **`zmx tail` as the change signal.** It avoids zmx's socket protocol, but costs an extra process per card. It also misses changes that only move the cursor or erase, because tail drops those.
- **Compressing frames.** Later, if the spike shows frames are too large.

### Risks

- **The SSH channel limit.** Every shown card holds a channel on the shared connection, beside each attached pane's. OpenSSH allows ten sessions per connection by default, and Tailscale SSH's limit isn't known (spike step 7). Each attached pane already takes one.
- **A reader that outlives its viewer** would leave "Controlled on" showing, since it counts as a client. That is why the reader exits when its input or output closes.

### Verified and inferred

- **Verified:** zmx 0.8.1's client, history and detach behaviour, and the timings in the problem.
- **Inferred:** the frame rates and sizes, the grid read, and the channel limit.

### Records

Accepting this needs an ADR: a long-lived relay channel, and Launchy reading zmx's socket, which ADR 0004 and 0007 don't cover. It also changes ADR 0007's line that a live view was not chosen, and the Frozen screen entry in `CONTEXT.md`, which says "never live" and avoids "live view". The new name goes to `/domain-modeling`.

### Open questions

1. **Is "up to five screens a second" live enough?** Recommendation: yes for now. Option 03 adds smoothness later on the same channel.
2. **The smallest text, and enlarging a small grid:** as option 02's open questions 1 and 2.
3. **Should the view keep running while the panel is pinned but covered by other windows?** Recommendation: no. The window's occlusion state decides, as it does for hiding.
4. **The name for the view in `CONTEXT.md`.** Recommendation: keep "Frozen screen" for the snapshot shown while the link is down or the pane is hidden, and add a term for the card's live screen.

### Spike

Run it by hand on the Mac Studio, in Terminal.app, not in a Launchy pane. Use a throwaway zmx folder, never the user's `/tmp/zmx-501`. zmx sessions are made with `zmx attach` on a terminal, as `docs/agents/where-it-breaks.md` asks. It measures every option at once.

1. **A throwaway session, recorded.** `script` records everything the session sends to its terminal:
   ```
   export ZMX_DIR=/tmp/zmx-spike; mkdir -p "$ZMX_DIR"
   Z="$(dirname "$(readlink "$HOME/Library/Application Support/Launchy/launchy-peer")")/zmx"
   cd <a scratch copy of a repo>
   script -q "$ZMX_DIR/raw.log" "$Z" attach spike
   ```
   In it, run `claude` with the window sized like a usual pane. Give it a task with tool calls and long answers for two or three minutes, then leave it idle for a minute.
2. **The output rate (option 03).** In a second window: `while sleep 1; do stat -f %z /tmp/zmx-spike/raw.log; done | awk 'NR>1{print $1-p} {p=$1}'` prints bytes a second, working and idle.
3. **Snapshots (options 02 and 04).** In a third window, with the same `ZMX_DIR` and `Z`:
   ```
   p=; while sleep 0.2; do s=$("$Z" history spike --vt | tail -n 500); h=$(printf %s "$s" | shasum); [ "$h" != "$p" ] && echo "$(date +%T) $(printf %s "$s" | wc -c)"; p=$h; done
   ```
   It prints one line per changed snapshot, with its size. Lines a second times size gives option 04's rate, and the size gives option 02's cost per poll.
4. **tail (option 01).** In a fourth window, while Claude works: `"$Z" tail spike` for 30 seconds, then ctrl-C.
5. **The grid, and lining up (all options; option 03).**
   - `"$Z" ls` shows the session's `pid=`. Then `ps -o tty= -p <pid>`, and `stty -f /dev/<tty> size` prints rows and columns.
   - Resize the first window and ask again: the numbers should follow.
   - Then, in a window set to the same size (check with `stty size`), run `clear; "$Z" history spike --vt | sed $'s/\e\\[?[0-9;]*h//g'` and compare it with the first window. Claude's prompt box on the same rows means no misalignment at that moment.
   - Repeat a few times, including just after a permission prompt closes. Close that window afterwards.
6. **Clients and detach (options 03 and 04).**
   - While step 4's tail runs, `"$Z" ls` shows one more client.
   - Then `env ZMX_SESSION=spike "$Z" detach`. The first window's client and the tail both exit, and `"$Z" ls` still lists the session.
7. **Channels on one SSH connection (options 03 and 04).** From the Air:
   ```
   ssh -o ControlMaster=yes -o ControlPath=/tmp/cm-spike -o ControlPersist=120 -fN alex@mac-mini
   for i in $(seq 14); do ssh -o ControlPath=/tmp/cm-spike alex@mac-mini 'sleep 20; echo ok' & done; wait
   ssh -o ControlPath=/tmp/cm-spike -O exit alex@mac-mini
   ```
   Count the `ok` lines.
8. **Clean up:** `"$Z" kill spike; rm -rf /tmp/zmx-spike`.

**Battery,** once the chosen option's channel is built: on the Air, compare Activity Monitor's Energy tab for Launchy and ssh, or `top -l 0 -s 10 -o power -stats pid,command,cpu,power`. Run ten minutes with a card shown while Claude works, against ten minutes with it hidden.

## Decided by the user, 2026-10-05

1. **Option 04 is accepted.** Option 03's raw stream can be added later, best once a zmx release has the screen-only capture.
2. **Scaling:** always scale the controller's grid to fit the pane. Never clip, however small the text gets. This overrides the 60% / 7 pt default.
3. **When it updates:** only while the window is visible. A pinned panel covered by other windows stops updating and gets a fresh frame on return.
4. **Defaults the user hasn't overruled:**
   - a small grid in a big pane is drawn at the user's font size, top-left, not enlarged;
   - "Last screen at HH:MM" on the Lost connection and Not reachable cards comes later, as its own change;
   - "Frozen screen" stays the name for the snapshot, and the live view gets its own term in CONTEXT.md.
