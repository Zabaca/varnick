---
problem: sessions-cant-start-sessions-in-other-projects
title: Option 01, with the new tab brought up as a typed `#project` prompt's is, whenever `show`'s rules allow it
summary: As option 01, but the new tab comes forward by default, through the one way Varnick shows a tab, as when the user types `#project` and a prompt in the panel. It is brought up only when `show` could bring it up (the panel visible, nothing of the user's over it, no key of theirs in the panel in the last 2 s, the caller's tab not controlled by another machine); otherwise it opens behind as in option 01 and the reply says why. The panel is never shown, hidden, pinned or made key. `behind` lets the caller keep it out of sight.
status: proposed
---

## Solution

Everything in option 01 holds but where the tab goes.

**Forward by default.** After the tab is made and its session started, Varnick brings it up as it brings up the tab of a prompt the user typed: through the one function every way of showing a tab ends in, so a board, the Outline or the search over it closes, the tab comes up with its pane focused, and the strip's projects column follows it to its project's row. With the panel key, the keyboard goes to the new session, as it would for the user's own prompt.

**Only when `show` could.** The tab is brought up only while all of these hold, and opens behind (option 01) when any fails, the reply saying which:

- the panel is visible (a tab swapped under a hidden panel is not proven to leave every terminal's size alone, so `show` refuses it there);
- Settings, the Restart Varnick card, the split picker and the strip's lists are not showing;
- the user has not pressed a key in the panel in the last 2 s;
- the caller's tab is not controlled by another Mac or the phone, where the user is looking at that device.

**Never the panel itself.** The panel is never shown, hidden, pinned or made key, as `show` never does: with the panel pinned behind another app, the tab changes inside it and the keyboard stays in that app.

**`behind: true`** keeps the tab out of sight, as in option 01, for helpers the user did not ask to watch.

The reply says which happened: "Opened a new tab in kestrel and brought it up: s7 …", or "… not brought up: the panel is hidden" (made-up values).

## Trade-offs

- **The user sees what started at once,** as with a session they typed, and reads its first turn without looking for the tab.
- **A session changes the user's screen when it decides.** The tab the user was watching, the caller's included, goes behind; the 2 s rule keeps it off a user who is typing in the panel, not off one who is reading. A lead that opens several in a row moves the panel each time unless it passes `behind`.
- **The keyboard can move.** With the panel key, the new pane takes the keyboard, so a key meant for the caller after the 2 s window lands in the new session.
- **Two outcomes for one call.** Whether the tab came up depends on the panel's state at that moment; the reply says which, and the caller can tell the user.
- **Little new code.** It is option 01 plus the call `show` makes for a pane, with `show`'s refusals shared, not copied.
- **Option 01 already reaches this** with a second call, `show` with the reply's id. The difference is the default: here a session must ask to stay behind; there it must ask to come forward.

## User Stories

1. As the user, I want a session I asked to start another to bring that tab up when I'm at the panel, so that I see it start as if I had typed it.
2. As the user, I want it never to bring the panel up over the app I'm in, hide it or take the keyboard from another app, so that a session can't interrupt what I'm doing outside Varnick.
3. As the user, I want it not to move my panel while I'm typing in it, so that my keys don't land in the new session.
4. As a session, I want the reply to say whether the tab came up and why not, so that I can tell the user where to find it.
5. As a session, I want to open a helper behind on purpose, so that I don't move the user's screen for work they didn't ask to watch.

## Implementation Decisions

- **The sibling** is `show` with a pane's id, which shows that pane's tab through the model's own function, with its refusals shared (the panel visible, the overlays, the 2 s key rule). `show`'s refusals are reused, not copied; a failing one turns into the reply's reason, never into a refusal of the call.
- **The check comes after the session has started,** right before the tab is shown, with nothing awaited between, since the wait for the name (option 01) can take seconds in which the user may start typing.
- **`behind`** is one optional boolean argument; the log adds whether the tab came up.
- **Docs** as option 01; the guide says the tab comes up when the panel is up and the user isn't typing in it.

## Testing Decisions

- **By hand after a restart,** as option 01, plus: with the panel up on the caller's tab, the new tab comes up with its pane focused and the strip's projects column on its project; with the board or the Outline showing, they close; with the panel hidden, with Settings or the split picker showing, within 2 s of a key in the panel, and from a tab the phone controls, the tab opens behind and the reply names the reason; with the panel pinned and another app in front, the keyboard stays in that app; `behind: true` leaves everything as option 01 does.

## Out of Scope

As option 01. Bringing up the panel itself (never, as for `show`).

## Further Notes

- **Verified in the code at 29551eb:** every way of showing a tab ends in one function, which a new way must use; a typed prompt's tab is added and shown through it; `show` refuses a pane while the panel is hidden, and while Settings, the Restart Varnick card, the split picker or a strip list shows, and for 2 s after a key in the panel.
- **Combines with** option 01 (it is a change to it), and with options 02, 04 and 05.
- **The choice this option puts to the user** is the default, not the ability: with option 01 a session brings the tab up with a second call, and here it keeps it behind with `behind`. A lead running builders mostly wants behind; a session the user asked to "start one in kestrel" wants forward. Whichever default is chosen, the argument is named for the other.
