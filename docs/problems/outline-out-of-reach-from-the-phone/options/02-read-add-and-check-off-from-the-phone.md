---
problem: outline-out-of-reach-from-the-phone
title: Read a Mac's Outline on its Phone page, add to it and check bullets off
summary: Option 01's view plus the two edits a phone is used for most. Add puts in new bullets, typed one after another, below a bullet, inside it or at the end of the zoom. Complete checks a bullet off or back on. Both go through the Outline's own edit for callers outside the panel, the one Panel access uses, so each is one step on the Mac's undo stack and the Mac's caret is left alone. The phone never changes or removes anything already written, so it can't overwrite what the user typed on the Mac and needs no check for changes made there. It adds two relay requests, in one protocol bump.
status: rejected
reason: The user chose option 03, full editing, on 2026-10-20 (relayed by the coordinator). Adding and checking off only leaves the phone unable to fix a typo, reword, move, indent or delete, which falls short of the outliner the user asked for. This option's add and complete are part of option 03's spec and are built there.
---

## Solution

This is option 01's view with two edits added.

**Choosing a row.** Tapping a row's text chooses it, and the foot of the view then shows **Add below**, **Add inside** and **Complete** (or **Not completed** when the row is already completed). With no row chosen, the foot shows a **+** that adds at the end of the zoom.

**Add** opens a one-line field in place, and the phone's keyboard comes up.
- The keyboard's Enter saves the bullet and opens the next field below it, so a list is typed as it is on the Mac.
- Enter on an empty field, or Done, closes the field.
- Lines pasted into the field become bullets, with indented lines nested, by the Mac's paste rules.

**Complete** checks the chosen bullet off, or back on. With Show completed off, a completed bullet leaves the view.

**Every edit is one request to the Mac's app,** and the reply lists the view's rows again, so an edit never needs a second read.

## Trade-offs

- **The phone can't fix a typo, reword, move, indent or delete.** Option 03 can.
- **It never overwrites.** An add makes new bullets and Complete sets a mark; neither replaces any text. So no check for changes made on the Mac is needed, and what the user typed on the Mac between the phone's read and its edit is never lost.
- **Adds go on the Mac's undo stack.** ⌘Z on the Mac takes back a phone's bullets, one step per Enter. Like a session's edit, an add ends the Mac user's typing run.
- **The phone has no undo.** A wrong bullet is completed from the phone, or deleted on the Mac.
- **A bullet typed but not yet saved is lost** if the page is killed first. The field also saves when the page goes out of view, which covers leaving the app.
- **Everything else is option 01's:** the Outline's text reaches the phone, the view is out of date until it reads again, each Mac shows its own Outline, and the protocol is bumped once.

## User Stories

1. As the user, I want everything option 01 gives (its stories 1 to 9).
2. As the user, I want to add a bullet from my phone at the end of a list, so that a thought had away from the desk lands in my Outline.
3. As the user, I want Enter to save the bullet and start the next one, so that I can type a list on my phone as fast as on my Mac.
4. As the user, I want to add bullets below a bullet or inside it, so that a new thing goes where it belongs.
5. As the user, I want to paste several lines and get one bullet each, nested as indented, so that a list copied from another app keeps its shape.
6. As the user, I want to check a bullet off from my phone, and undo that by checking it again, so that I can work through a list where I am.
7. As the user, I want what I add on the phone to leave my Mac's caret and typing alone, so that the phone never gets in the way of the desk.
8. As the user, I want ⌘Z on my Mac to take back what the phone added, so that a slip on the phone costs nothing.

## Implementation Decisions

Everything in option 01's Implementation Decisions holds. This option adds the following.

### The request

- **One more relay request, `outlineEdit`,** beside `outlineRead`, so both arrive in one protocol bump. It is forwarded, checked and refused exactly as the read is: listed devices only, the Outline's own refusals, and a headless host refuses it.
- **Two actions:**
  - **add**: the lines, and where they go: after a row (as its next siblings, after whatever is nested under it, where a paste goes on the Mac), inside a row (as its last nested bullets), or at the end of the zoom;
  - **complete**: a row, and whether it ends up completed or not. It sets the state rather than toggling it, so a request sent twice, or a bullet completed on the Mac meanwhile, can't flip it the wrong way.
- **Add goes through the tree's insert,** which the Mac's paste and a session's `add` already use, and its lines are read by the paste rules. A bullet's text has the same limits as a session's. The page checks that an encoded request is under the relay's argument cap, as it already does for a new session's prompt, and refuses one that isn't before sending it.
- **Inside a row goes at the end,** because lists grow at the end. On the Mac, ↩ on an expanded bullet adds a first nested bullet instead; this is the planner's choice for the phone.
- **The reply** lists the view's rows as `outlineRead` would, using the view parameters the edit sent, and names the new rows, so the next Enter adds after the bullet just added.

### Through the Mac's model

- **Each edit goes through the Outline's edit for callers outside the panel,** the one Panel access's `outline_act` uses:
  - one step on the Outline's undo stack;
  - the Mac's caret moved only where the same key would move it (for example, when its row is completed and leaves the view);
  - the Mac's panel never shown, raised or focused.
- **What may stop it** is checked right before the edit: the Outline switch, and a row that has left the tree ("gone: read again"). The page then reads again and says that bullet moved or was removed on the Mac.
- **No check for changed text.** Neither action replaces text, so the phone sends no record of what it read.

### The page

- **One field at a time,** in place in the row it adds after, using the page's existing keyboard handling. Enter is read from the field's input event, since a phone's keyboard may send no key code for it. That is inferred, and is to be tried by hand.
- **When a field saves:** on Enter, on Done, on tapping elsewhere, on Back, and when the page goes out of view. A field that hasn't been saved lives in memory only.
- **The page's rules** live in a rules module with no DOM, which `bun test` runs as it does the page's other rules modules: what Enter does in an empty or a filled field, when a field saves, and which row the next add follows.

### Privacy and documents

- **Option 01's privacy, plus the phone's typing,** which travels to the Mac the same way and is logged nowhere, never in a log line or in the page's storage.
- **The new ADR** also records that the phone adds and completes through the app's model. This amends ADR 0030's "edited by its own keys alone", as ADR 0031 already did for sessions.
- **`docs/privacy-and-security.md`** says the phone can add bullets and complete them.
- **`docs/agents/where-it-breaks.md` › The outline** names the phone as a caller of the session edit.

## Testing Decisions

- **`bun test`** covers option 01's checks, plus the edit's body (each action, the caps, the encoded size under the argument cap) and the page's rules module.
- **`--outline-check`** covers, on a throwaway file:
  - an add after a row, inside a row and at the end of a zoom;
  - pasted indented lines;
  - complete set to on twice and to off twice, which must leave the same tree;
  - a row that has left the tree, which must be refused.
- **By hand, on the phone (the user's):**
  - type a list with Enter;
  - add while the Mac shows the Outline with the caret in another bullet: the Mac's caret and typing must be untouched;
  - ⌘Z on the Mac removes the phone's bullet;
  - complete with Show completed off;
  - the switch off refuses the edit;
  - leaving the app in the middle of a line saves it.

## Out of Scope

- Changing or deleting text or notes, indenting, outdenting and moving (option 03).
- Mirrors, selecting several bullets, and undo on the phone.
- Everything option 01 leaves out.

## Further Notes

- **Sibling:** option 01's (Voice mode on the phone). For the edit, the sibling is Panel access's `outline_act` (ADR 0031), which puts a caller that isn't the keyboard through the same edit and the same undo stack.
- **Why it is its own option:** of the three, it is the only one in which the phone can write without being able to overwrite anything. That is what makes it simple: there is no check for changed text, no keyboard row, and no question about the bullet the Mac user is typing in.
