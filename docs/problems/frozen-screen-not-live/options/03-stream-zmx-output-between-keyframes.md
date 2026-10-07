---
problem: frozen-screen-not-live
title: Stream the session's output, read from zmx's socket, between keyframes
summary: The channel of option 04, also carrying every byte Claude writes between snapshots. The host reads them from the session's zmx socket without ever sending input, Init or a size. Truly live and the cheapest while Claude works. In zmx 0.8.1 the snapshots don't line up exactly with the output that follows, so frequent keyframes bound the garbling.
status: proposed
---

## Solution

While a card is shown, the viewing Mac holds one channel to the host's relay (option 04's `watch`). The relay connects to the session's zmx socket itself and never sends input, Init or a size. It sends a keyframe first, which is the snapshot with its grid, and then every byte the session's program writes, as zmx passes it to every client, with mode sets stripped as they go by. When the grid changes, when the view falls behind, and every few seconds while output flows, it sends a new keyframe. On the host's own card, Launchy does the same in process.

**Why a rejected idea comes back.** This is the live view of the sibling problem's option 04 (`sessions-tied-to-one-mac`), which ADR 0007 didn't choose for now. That option was a second `zmx attach` that never forwarded keys. Its reasons no longer apply here:
- The reader isn't an attach. It has no keyboard path that could leak a stray byte, and no Init that could make it the leader or tell Claude a terminal is focused.
- It never resizes the session.
- The controller's grid problem is answered by the user's scaled view (option 02).
- Take over needs no ordering, since the reader can't lead.

## Trade-offs

- **Truly live.** Bytes arrive as Claude writes them, as smoothly as the controller sees them.
- **Cheapest while Claude works.** The stream is what the controller's own terminal receives (an estimated 2–20 KB/s), plus keyframes. Idle, it is nothing.
- **Read-only by construction.** The reader sends only history requests. In 0.8.1 nothing it does reaches Claude's input. The only writes to the program are a client's typed input, `send`, `run` and `write`, zmx's own answers to device queries while no terminal client is attached, and focus reports when terminal clients come and go. A reader is none of those.
- **Snapshots don't line up exactly in 0.8.1.** The only picture a client without Init can get is `history --vt`, which trims trailing blank rows. Output that continues from it lands too low by as many blank rows as the screen had at its bottom, whenever there is scrollback above. Until the next keyframe, Claude's redraws then land on the wrong rows. Upstream's unreleased `Capture` request would end this: a keyframe of the screen alone, drawn from the top row.
- **A short garble on resize.** Output for the new grid arrives before the host sees the change (within a quarter second) and sends a keyframe.
- **Launchy speaks zmx's socket protocol.** It depends on zmx's message format, which upstream declares frozen, and on how 0.8.1 treats clients that never send Init. Both were read in the source, and zmx stays pinned.
- **A reader counts as a zmx client**, which today decides between "Controlled on" and "Last controlled on". The host has to know its readers and leave them out (as option 04).
- **The most to build:** everything in option 04, plus the output stream, a stripper that works on a stream, and the keyframe rules.

## User Stories

As option 02, with story 1 reading: as a user at the Mac not in control, I want to watch Claude work as it happens, as smoothly as on the Mac in control.

## Implementation Decisions

- **The channel, the frames, the reader's registry, the SSH kind, the lifecycle, reconnecting, and Linux:** as option 04. Frames here are either keyframes or output.
- **Size and the view:** as option 02. Each keyframe is a snapshot. Output between keyframes is fed to the view's terminal as it arrives. A keyframe resets the terminal, sets the grid and draws.
- **Order at a keyframe.** The reader asks for the history on its own connection. Output that arrives before the history's answer is dropped, because the picture already has it. Output that arrives after is sent, because the picture doesn't. zmx handles one connection's messages in order, so nothing is lost and nothing repeats.
- **When keyframes come:**
  - at the start;
  - when the host reads a new grid (it reads the terminal's window size every 250 ms while the stream runs);
  - after a resync;
  - one second after output stops following a burst;
  - and at least every five seconds while output flows.

  The last two bound the 0.8.1 misalignment to a few seconds at worst.
- **Stripping on a stream.** The mode-set strip runs on each chunk and carries over what it can't finish: an unfinished sequence at the end of a chunk, a lone ESC included, waits for the next chunk. The set of modes is the one stripped from the frozen screen.
- **Fed as bytes.** Output reaches the view's terminal as bytes, never turned into text chunk by chunk, because a split character would become a replacement mark.
- **Coalescing.** Output is sent at most every 100 ms, to wake the Wi-Fi radio and both CPUs less often.
- **Falling behind.** The reader always drains zmx's socket, so the daemon's buffer never grows. Once more than 256 KB is waiting to be written to the channel, the waiting output is dropped, and a keyframe follows when the channel catches up. A paused view (scrolled back) gets a keyframe when it resumes.

### What the user asked to see for each option

- **Stripping:** sequences can split between chunks, so the strip carries them over, as above.
- **Size:** the grid comes with each keyframe, read from the session's terminal. When the controller resizes, the host sees the new grid within 250 ms and sends a keyframe. Until then, output meant for the new grid lands on the old one.
- **Battery and bandwidth** (estimates): Claude's own output rate while it works, guessed at 2–20 KB/s, plus at most one 12–16 KB keyframe every five seconds (under 3 KB/s), and nothing while idle. At most ten sends a second. Spike step 2 measures the output rate (option 04, Further Notes).
- **Reconnect and lifecycle:** as option 04. Every new stream starts with a keyframe.
- **Linux:** as option 04.

### State and protocol

- No saved fields and no UserDefaults.
- The `watch` request (option 04) gains output frames, so the protocol version goes up.

**Scope and ticket order:**
1. Option 02's ticket 1: the grid and the scaled view.
2. Option 04's ticket 2: the `watch` channel with snapshots only.
3. Output between keyframes: the stream stripper, the keyframe rules and falling behind.

## Testing Decisions

- No test target. The pure seams for the first tests:
  - the stream stripper fed one sequence split at every possible byte, which must give the same result as stripping it whole;
  - dropping and passing output around a history answer;
  - the keyframe rules on a timeline of output and grid changes;
  - decoding zmx's header.
- **By hand:** option 04's checks, plus:
  - On the Air, Claude's spinner and streamed text move smoothly, as on the Studio.
  - Resize the Studio's panel while Claude works: a brief garble at most, then the right picture.
  - Put a session's prompt box at the bottom with blank rows under it, show the card, and let Claude redraw: misplaced rows are fixed by the next keyframe, within five seconds.
  - On a slow link, hold the view behind and let it catch up: it resyncs with a keyframe, and `zmx ls` and the host's memory don't grow.

## Out of Scope

- Typing from the viewer.
- Moving to a zmx with `Capture` (it would end the misalignment, but it is a separate change).
- Compressing the stream.

## Further Notes

- **Recommended after option 04, not instead of it.** Option 04 is its first two tickets. This option adds smoothness and lower bandwidth, at the price of the 0.8.1 misalignment and the stream rules. It becomes the clear choice once a zmx with screen-only capture is pinned, because keyframes would then line up exactly.
- **Considered within this option:**
  - **Keyframes from Init (the restore zmx gives an attaching client), which line up exactly.** Not chosen. Init makes zmx tell Claude a terminal is focused when the reader is the only terminal client, and a reader that sends Init while no one leads becomes the leader. Both reach the session.
  - **`zmx tail` as the source:** it strips every escape sequence (option 01).
  - **Running a terminal emulator on the host** to make aligned keyframes. Too heavy for the relay, and it would differ from what zmx itself holds.
- **Verified:** zmx 0.8.1's client, broadcast, leader, Init, history, detach and buffer behaviour, and the trimming in ghostty's formatter at zmx's pinned commit. **Inferred:** how often Claude's screen ends in blank rows with scrollback above (spike step 5's comparison shows it), the output rate, and reading the grid from the terminal.
- **Records.** Accepting this needs an ADR: a long-lived relay channel, and Launchy reading zmx's socket protocol, which ADR 0004 and 0007 don't cover. It also changes ADR 0007's line that a live view was not chosen, and the Frozen screen entry in `CONTEXT.md`, which avoids "live view".
