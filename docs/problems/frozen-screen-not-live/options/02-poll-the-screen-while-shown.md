---
problem: frozen-screen-not-live
title: Poll the screen while the card is shown, drawn at the controller's grid
summary: The card fetches the frozen screen about every second while it is on screen, not only when it comes into view. Each snapshot carries the grid the host read from the session's terminal, and the view draws at that grid, scaled to fit the pane. Smallest change; it lags by up to a poll, and every poll pays an SSH session.
status: rejected
reason: Not chosen in ADR 0008. Every poll pays an SSH session, and the host serializes the screen even while Claude is idle. Option 04 shipped instead and sends a frame only when the screen changed.
---

## Solution

**The controller's grid.** Each time the host takes a snapshot, it also reads the session's grid (columns and rows) from the session's terminal and sends it with the screen. The view draws the snapshot at exactly that grid and scales the result to fit the pane, so it looks as it did on the Mac in control, only smaller. The same view serves today's frozen screen, and options 03 and 04 use it.

**Polling.** While the card is on screen, it fetches the screen about once a second, backing off while nothing changes. A poll that finds the screen unchanged gets a short answer. Nothing runs while the card isn't shown, and showing it fetches at once, as today.

## Trade-offs

- **The smallest change.** The `screen` request and the frozen view exist already. This adds the grid, the scaled view, an "unchanged" answer and a timer.
- **It lags.** The view is up to one interval plus a round trip (about 0.2 s) behind, and half an interval on average. Claude's spinner and streamed text move in steps of a second or more.
- **Every poll pays an SSH session:** a channel on the shared connection, `/usr/bin/login`, a shell, the relay and zmx on the host, and an ssh process on the viewing Mac. That is most of a poll's 165–240 ms, and it is paid whether or not Claude is working.
- **Hard to break.** Each answer is a whole picture at its own grid, so there is no stream to keep in step. A resize shows up as the next picture, and a failed poll only makes the view stale.
- **Nothing new on the host's side:** no long-lived channel, no reading of zmx's socket, and no zmx client beyond the moment of a fetch.

## User Stories

1. As a user at the Mac not in control, I want the screen to keep up with Claude while I look at it, so that I can follow a long task without taking it over.
2. As a user on the Air watching a session the Studio controls, I want the screen drawn as the Studio sees it, scaled down to fit, so that Claude's layout isn't wrapped or garbled.
3. As a user, I want watching never to type into the session or change its size, so that it can't disturb the Mac typing into it.
4. As a user, I want a pane I'm not looking at to cost nothing, and to show the current screen as soon as I look at it.
5. As a user whose pane is too small for the controller's grid, I want the text to stop shrinking at a readable size, and to scroll to see the rest.
6. As a user scrolling back through the view, I want it to hold still until I return to the bottom.
7. As a user whose link to the host drops, I want the last screen kept with its time ("Last screen at 14:32"), and the view to pick up again by itself.
8. As a user, I want Take over and Release to work as today, with the view following whichever Mac ends up in control.

## Implementation Decisions

### Size and the view

Options 03 and 04 use this section too.

- **Reading the grid.** The host reads the window size of the session's terminal, found from the pid of the session's program in zmx's listing.
  - It reads it before and after taking the snapshot, and takes the snapshot again once if the two differ, so a resize between them can't pair a picture with the wrong grid.
  - If the grid can't be read, it is left out, and the view does what it does today (sized to the pane).
- **Sending it.** The `screen` reply carries the grid with the screen.
- **A fixed grid.** The view's terminal keeps the snapshot's grid whatever the pane's size.
  - It picks the font size at which that grid fits the pane, never above the user's terminal font size, and sizes its frame from the grid at that font.
  - It lays itself out again when the pane or the grid changes, but the pane's size never changes the grid.
  - The scaling is done with the font size, not by magnifying an image, so text stays sharp.
- **Below the floor.** The font stops shrinking at 60% of the user's font size, and never goes under 7 points (open question 1). Beyond that the grid overflows the pane: the view shows its bottom-left corner, where Claude's prompt box and newest output are, and scrolling pans to the rest.
- **A larger pane.** If the whole grid fits at the user's font size, it is drawn at that size in the top-left corner, not enlarged (open question 2).
- **Scrolling back.** Scrolling back pauses the view where it is, and the bar says so. A newer screen is kept but not drawn until the user scrolls back to the bottom.
- **Where it is used:** everywhere a frozen screen shows today (a peer's card, the host's card, a peer's session opened on the card), and every snapshot of options 03 and 04.
- **What the view drops is unchanged:** it has no process, sends nothing, never becomes first responder, and the mode sets are stripped on the host.
- **The note under the bar.** It shows nothing extra while fetches succeed. Once one fails, or the host stops answering, it says "Last screen at HH:MM" with the reason, as today's failure note does.

### Polling

- **When it runs.** Only while the card is shown: its tab is the active one and the panel is on screen and not fully covered, by the window's occlusion state. The timer starts when the card becomes shown, which also fetches at once, as today, and stops when it stops being shown.
- **The interval.** One second after a poll that found a change, backing off to four seconds while the screen stays the same.
- **"Unchanged".** The request carries a digest of the screen the view has, and the host answers "unchanged" without the screen when it matches. This saves bandwidth, not the SSH session or the host's work.
- **On the host.** The host's own card polls its own zmx at the same pace, off the main actor.

### What the user asked to see for each option

- **Stripping:** unchanged. Each snapshot is whole and stripped on the host, as today, so nothing is split.
- **Size:** each snapshot carries its grid. When the controller resizes, the next poll brings the new grid and the view lays itself out again, with no garbling in between.
- **Battery and bandwidth** (estimates): about 13–17 KB a second while Claude works at one poll a second, and well under 1 KB a second idle, thanks to "unchanged". Each poll starts about five short processes on the host and one ssh on the viewer, and wakes the Wi-Fi radio, working or idle. Spike steps 1–3 measure the snapshot sizes and how often they change (option 04, Further Notes).
- **Reconnect and lifecycle:**
  - There is no connection to keep. A failed poll keeps the last screen with its time and keeps polling at the slow pace, and the card's own five-second check goes on as today.
  - Polling stops when the card is hidden, and on Take over (the pane goes live).
  - It stops on Release: the host's card goes live, and the releasing peer's pane closes.
  - It stops when the session ends: the card's check closes the pane, as today.
- **Linux:** the host's side is the relay, zmx and a terminal size read, all Foundation and POSIX. On Linux the terminal is found through `/proc`. A headless host is never a viewer, so nothing it needs touches SwiftTerm.

### State and protocol

- No saved fields and no UserDefaults.
- The `screen` request and reply change shape (the grid, the digest, "unchanged"), so the protocol version goes up.

**Scope and ticket order:**
1. **The grid and the scaled view.** On its own, this improves today's frozen screen, and options 03 and 04 start with it.
2. **Polling while shown,** with "unchanged" and "Last screen at HH:MM".

## Testing Decisions

- No test target. The pure seams for the first tests are:
  - the font size and frame for a grid in a pane, with the floor;
  - pairing a grid with a snapshot when the reads before and after differ;
  - the digest comparison.
- **By hand, on both Macs** after `make build` and a restart the user does:
  - The Studio in control in a wide pane, the Air watching in a narrow split: the Air shows the Studio's layout scaled down, not wrapped.
  - Resize the Studio's panel: within a poll, the Air's grid follows.
  - Shrink the Air's pane below the floor: the text stops shrinking, the bottom-left shows, and scrolling pans.
  - Scroll back on the Air: the view pauses. Scroll to the bottom: it follows again.
  - Turn the Air's Wi-Fi off for a minute: "Last screen at HH:MM" shows. Turn it back on: the view follows again.
  - Take over on the Air: the Air's pane is live at its own size, and the Studio's card now polls. Release, then hide the panel: no polls reach the host while it is hidden (watch `ps` for the relay on the host).
  - Run `zmx ls` on the host during all of this: no client beyond a fetch's moment.

## Out of Scope

- Typing from the viewer.
- Showing a last screen on the Lost connection and Not reachable cards (open question 3).
- Compressing snapshots.
- A Linux build of the relay.

## Further Notes

- **Verified and inferred:** as in the problem. In short, verified: zmx's behaviour, the code paths for fetching and showing, and the timings. Inferred: reading the grid from the session's terminal (spike step 5), and every byte rate.
- **Records.** Accepting this changes the Frozen screen entry in `CONTEXT.md`, which says "never live". It needs no ADR: it adds no channel and no new kind of request.
- **Open questions:**
  1. **The smallest text before the view clips and scrolls.** Recommendation: 60% of the user's terminal font size, never under 7 points.
  2. **Enlarging a small grid in a large pane.** Recommendation: no. Draw at the user's font size, top-left, so a short session isn't blown up.
  3. **"Last screen at HH:MM" on the Lost connection and Not reachable cards** of the Mac that was in control, which keep no screen today. Recommendation: later, as its own change. The wish is met here on the card of the Mac not in control.
