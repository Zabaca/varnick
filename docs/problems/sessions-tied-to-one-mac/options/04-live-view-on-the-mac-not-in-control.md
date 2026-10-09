---
problem: sessions-tied-to-one-mac
title: A live view, not a frozen screen, on the Mac not in control
summary: Builds on option 01 (or 02). The Mac not in control stays attached as a second zmx client and shows the session live, while Launchy sends it no keys. Take over relabels the session, detaches every client, and reattaches the new controller first and the old one second, as a viewer.
status: abandoned
reason: Superseded by frozen-screen-not-live option 04 (ADR 0008), a live view through a reader that never sends the session input, Init or a size.
---

## Solution

zmx 0.8.1 lets several clients attach to one session and makes the last one to type the leader, the only client whose size applies. This option uses that for viewing. The Mac in control is attached as today. The Mac not in control is attached too, and its Launchy never forwards a key to the session, so it never becomes the leader. Take over relabels the session and detaches every client, then attaches the taking Mac first, so it becomes the leader at its own size, and the other Mac second, as a viewer.

## Trade-offs

- **Live.** The other Mac shows the session working, not its last screen.
- **Drawn at the leader's size.** zmx sends every client output laid out for the leader. A viewer pane of another size wraps or clips it, and Claude's full-screen redraws make that worse.
- **One stray byte takes control.** Any typed input from the viewer, a paste, or a key Launchy fails to hold back, makes it the leader, which is the shared typing the user ruled out. Launchy has to filter every path into the viewer's terminal, not just the keyboard.
- **Twice the traffic** for a session viewed from another Mac, across SSH.
- **More to get right in the takeover.** Two attaches in a fixed order, and a viewer that attaches before the new leader would take the lead by attaching first.

## User Stories

As option 01, with story 6 reading: as a user on the Mac that lost control, I want to keep watching the session live.

## Implementation Decisions

- The viewer's terminal is attached, but nothing it receives from the keyboard, paste or mouse goes to its process. Focus goes to the bar with Take over.
- A viewer pane resizes the terminal it draws to the leader's size and scales or letterboxes it, rather than sending its own size.
- Everything else as the option it builds on.

**Scope and ticket order:** one ticket after option 01's ticket 3, replacing the frozen screen.

## Testing Decisions

As option 01, plus: with the viewer pane narrower and wider than the leader's, Claude's screen stays readable; typing, pasting, scrolling and clicking in the viewer never move the leader (zmx's client count and the leader's size don't change).

## Out of Scope

As option 01.

## Further Notes

- Not recommended now: the user asked for a snapshot, and the size and stray-input problems are real. Worth revisiting once option 01's frozen screen is in use, if the user wants to watch a session from the other Mac.
- Refreshing option 01's frozen screen every few seconds, by fetching the host's history again, is a cheaper middle ground with neither problem.
