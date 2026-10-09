---
problem: sessions-finish-unnoticed
title: Stopped cards the user hasn't looked at since their turn ended get a dot (later)
summary: For later, on top of option 01, 02 or 03. A pane remembers when it was last on screen, saved with it so a restart keeps it. A Stopped board card whose turn changed after that gets a dot, as does its tab in the header. The dot goes when the pane comes on screen. The board then separates "done, not looked at" from "done, seen", as cmux's blue dot and gray check do, and the notices of options 01 to 03 can lapse without the user losing track. Rough effort is a day.
status: proposed
---

## Solution

**Last seen.** Each Claude pane keeps the date it was last on screen, with option 01's meaning of "on screen". It is saved with the pane's record, so it outlasts a restart.

**Unseen.** A pane is unseen when its card is in Stopped, its turn is not working or background, and the turn's date is after its last-seen date. A pane never seen since this field existed counts as seen, so the first launch marks nothing.

**Where it shows.**
- A dot on the board card, beside the turn text.
- A dot on the pane's tab in the header.
- The count in option 01's menu bar mark: unseen panes, not only standing notices.

**When it goes.** The pane comes on screen. Marking a session done or closing its pane drops it with the card.

**Only panes here.** A paired Mac's open session with no pane here has no last-seen date on this Mac and never gets the dot.

## Trade-offs

- **The board answers "what haven't I looked at"** after a restart or a dismissed notification, which notices alone don't.
- **One more saved field** in each pane's record. It is optional, so older saved state still loads and an older build ignores it.
- **The tab header gets busier,** with a dot beside its other marks.
- **Per Mac.** Looking at a session on one Mac doesn't clear its dot on another.

## User Stories

1. As the user, I want Stopped cards I haven't looked at since they stopped to stand out, so that I can work through them.
2. As the user, I want the dot gone once I've opened the pane.
3. As the user, I want the dots to survive a restart of Launchy.
4. As the user, I want a tab in the header to show the dot when one of its panes is unseen.

## Implementation Decisions

- **The last-seen date** is a new optional field of the pane's saved record. A missing one decodes as "seen", so state saved by earlier builds loads unchanged.
- **Updating it.** The notifier of option 01 updates it on its once-a-second tick for the pane on screen, and saves only when it changes by more than a few seconds, so saving doesn't run each second.
- **The rule** is a pure function of the card's turn, its date and the last-seen date, beside option 01's.

## Testing Decisions

- The rule, over made-up turns and dates, once a test target exists.
- **By hand, after a restart:**
  - a pane that finishes while hidden shows the dot on its card and tab;
  - opening it clears the dot;
  - restarting Launchy keeps an unopened dot.

## Out of Scope

- Sharing last-seen between Macs.
- A shortcut to jump to the next unseen card.
