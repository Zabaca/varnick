---
problem: outline-out-of-reach-from-the-phone
title: Edit a Mac's Outline from its Phone page
summary: Accepted by the user on 2026-10-20 (relayed by the coordinator). Option 01's view, editable as the Outline is on the Mac. Tapping a bullet puts the caret in it. Enter splits the bullet at the caret by the tree's own rule, and ⌫ in an empty bullet deletes it. A row of keys above the keyboard, like the terminal's, indents, outdents, moves, completes, opens the note and deletes. Text is saved when the user leaves the bullet, uses a key, pauses or leaves the page, never letter by letter. Every edit goes through the Outline's edit for callers outside the panel, as Panel access's edits do: one step on the Mac's undo stack, with the Mac's caret respected. A text save is refused if the bullet changed on the Mac since the phone read it, and what the phone typed is kept. Mirrors show, and editing one edits every placement. Placing new mirrors, selecting several bullets and undo stay on the Mac. It adds two relay requests, in one protocol bump.
status: accepted
---

## Solution

This is option 01's view, made editable.

- **Tap a bullet's text** to put the phone's caret there and bring up its keyboard. Only one bullet is edited at a time. The title of a zoom is edited the same way.
- **The keyboard's Enter** works as ↩ does on the Mac, by the tree's own rule:
  - it splits the bullet at the caret, and the text after the caret moves into a new bullet below;
  - at the start of a bullet that has text, it adds an empty bullet above instead;
  - on an expanded bullet with bullets nested under it, the new bullet becomes the first nested one;
  - in the title, it adds the first nested bullet.

  The caret then goes into the new bullet.
- **⌫ at the start of an empty bullet** that has nothing nested under it deletes that bullet, and the caret goes to the end of the row above. This works only where the phone's keyboard reports the key (Trade-offs).
- **A row of keys sits above the keyboard** while a bullet is being edited, as the terminal has one: **Outdent**, **Indent**, **Move up**, **Move down**, **Complete**, **Note**, **Delete** and **Done**.
  - Each key acts on the bullet being edited, saving its text first.
  - Delete removes only this placement, as on the Mac. If bullets are nested under it, it asks first, since the phone has no undo.
- **Notes.** Note, or a tap on a note, edits the note in a field that takes several lines. Enter in a note is a new line.
- **Adding with no bullet to type in.** A **+** at the foot of the view adds a bullet at the end of the zoom, for an empty zoom or a quick addition.
- **Pasted lines** become bullets below, with indented lines nested, by the Mac's paste rules.
- **Mirrors** show with their ring, and an edit to one shows in every place it appears, as on the Mac.
- **When text is saved:**
  - when the caret leaves the bullet;
  - on Enter, on a key of the row, on Done and on Back;
  - after two seconds without typing;
  - when the page goes out of view.

  Each save is one request, and its reply lists the view's rows again.
- **If the bullet changed on the Mac** between the phone's read and its save, the save is refused. The phone keeps what it typed in the field and shows the Mac's version beside it. **Use mine** saves the phone's text over it, and **Use the Mac's** drops the phone's.

As in option 01, zooming, collapsing and Show completed belong to the phone and are never saved.

## Trade-offs

- **This is the page's first editor, and the phone's keyboard is the riskiest part.** On a phone, Enter and ⌫ reach a web page as input events, not as keys, and Android keyboards differ. ⌫ at the start of an empty field in particular may not be reported at all. The key row's Delete always works. All of this is unverified until the user tries it on the phone.
- **Saved at pauses, not letter by letter.** Each save is one relay process and one step on the Mac's undo stack. A page killed between saves loses at most the last two seconds of typing. A bullet typed with pauses becomes several undo steps on the Mac.
- **The Mac's ⌘Z takes back phone edits,** one step each. Like a session's edit, a phone edit ends the Mac user's typing run.
- **The phone has no undo.** That is why Delete asks before removing nested bullets, and why ⌫ deletes only an empty bullet with nothing nested.
- **The phone can't overwrite what was typed on the Mac.** A text or note save is refused when the field has changed since the phone read it. If the Mac's caret is in the bullet the phone saves, the phone's text goes into that text view as a key would, around the caret.
- **No join on the phone.** On the Mac, ⌫ at the start of a bullet that has text joins it onto the row above. "The row above" is worked out from the rows the Mac shows, under the Mac's zoom and filter, which aren't the phone's, so the phone leaves join out.
- **The bullet the Mac is zoomed into is treated as the Mac's title,** for the phone as it already is for a session's edit. Enter in it adds a first nested bullet, and it can't be moved or deleted until the Mac zooms out. The refusal says why.
- **Everything else is option 01's:** the Outline's text reaches the phone, the view is out of date until it reads again, each Mac shows its own Outline, and the protocol is bumped once.

## User Stories

1. As the user, I want everything option 01 gives (its stories 1 to 9).
2. As the user, I want to tap a bullet on my phone and edit its text, so that I can fix a typo or reword a line away from my desk.
3. As the user, I want Enter to start the next bullet, split at the caret as on my Mac, so that I can type a list on my phone.
4. As the user, I want ⌫ in an empty bullet to remove it, so that a stray Enter costs nothing.
5. As the user, I want keys above the phone's keyboard to indent, outdent and move a bullet, so that I can structure on the phone without a Tab key.
6. As the user, I want to complete and delete bullets from the phone, with a question before a delete takes nested bullets with it, so that I can tidy a list safely.
7. As the user, I want to read and edit a bullet's note on the phone, so that details go where they belong.
8. As the user, I want what I type saved without a save button, and saved when I leave the app, so that I don't lose it.
9. As the user, I want an edit made on my Mac never to be overwritten by the phone without my say, so that the two can't clobber each other.
10. As the user, I want the phone's edits to leave my Mac's caret and typing alone, and ⌘Z on the Mac to take them back, so that the phone never gets in the way of the desk.
11. As the user, I want a mirror edited on the phone to change everywhere it is placed, as on my Mac.

## Implementation Decisions

Everything in option 01's Implementation Decisions holds. So does option 02's request: add, and complete set to a state rather than toggled. Options 01 and 02 are rejected, but the parts this option takes from them are part of this spec. This option adds the following.

### The request

- **`outlineEdit`, beside `outlineRead`, in one protocol bump.** It is forwarded, checked and refused as the read is: listed devices only, the Outline's own refusals, and a headless host refuses it.
- **The actions:**
  - add and complete, as in option 02;
  - set text, and set note;
  - enter at a UTF-16 offset: the tree's split, or its first-nested-bullet edit for the phone's title;
  - delete;
  - indent and outdent;
  - move up and move down.

  A text save and the action after it (Enter, or a key of the row) travel in one request and are applied in order, as two steps on the Mac's undo stack.
- **Stamps.**
  - Each row of a read carries a stamp of its text and a stamp of its note.
  - A set text, a set note, or an Enter that carries text, sends the stamp it started from.
  - The app refuses the save when the field's stamp differs now ("Changed on the Mac"), and replies with the field as it is.
  - Use mine sends the phone's text again with the new stamp.
  - The app makes every stamp; the page never computes one.
- **The stamp must be the same across launches.** Swift's own hashing is seeded per launch, so a stamp made with it would refuse every save after a restart. A short cryptographic digest of the field's text works.
- **No state kept per phone.** A session's knowledge of what it has read is kept per pane in the app's memory. A phone has no pane, and each request is its own process, so the stamp travels with the request instead.
- **Limits.**
  - A bullet's text has a session's limit (10,000 characters).
  - A note has a limit the planner sets in the build so that the request fits under the relay's argument cap. The page checks the encoded size before sending, as it does for a new session's prompt.
  - A note longer than that is shown, and the page says it is too long to edit there.

### Through the Mac's model

- **Each action goes through the Outline's edit for callers outside the panel,** the one Panel access's `outline_act` uses:
  - one step on the Outline's undo stack;
  - the Mac's caret is moved only where the same key would move it;
  - a change to the bullet the Mac's caret is in goes into that text view around the caret, and waits while an input method is composing;
  - the panel is never shown, raised or focused.
- **What may stop it** is checked right before the edit: the Outline switch, then the stamp. A row that has left the tree is "gone: read again", and the page reads again and says the bullet moved or was removed on the Mac.
- **Indent, outdent and moves go by the whole tree,** as a session's do: siblings are siblings whatever is collapsed. Completed bullets count as the phone shows them, not as the Mac does. That is a small change to that edit, which today reads Show completed from the tree, that is, the Mac's. This change is inferred, not yet tried.
- **The page keeps edits inside its own zoom:**
  - no outdent for a row at the top of the phone's zoom;
  - no move, indent, outdent or delete for the phone's title.

  The tree itself only knows the Mac's zoom.

### The page

- **One field at a time,** placed in the row being edited. The other rows are drawn as in option 01.
- **Enter and ⌫ are read from the field's input events,** not from key codes, which phone keyboards often don't send. This is inferred, and is the first thing to try by hand.
- **The key row** shows only while a bullet or note is being edited, and sits above the keyboard, as the terminal's row does.
- **What the phone has typed but not saved** is held in memory only, never in the page's storage.
- **Reads never replace the field being edited.** A read that arrives while the user is typing updates the other rows only.
- **The page's rules** live in a rules module with no DOM, which `bun test` runs:
  - what Enter and ⌫ do for a given text and caret;
  - when a save is due;
  - which actions a row allows (title, top of the zoom);
  - where the caret goes after each action;
  - what a refusal shows.

### Privacy and documents

- **Option 01's privacy, plus the phone's typing,** which travels to the Mac the same way and is logged nowhere: never in a log line, never in the page's storage.
- **The phone can change and delete the Outline.** The new ADR records it, amending ADR 0030's "edited by its own keys alone" as ADR 0031 did for sessions. `docs/privacy-and-security.md` says so.
- **`docs/agents/where-it-breaks.md` › The outline:**
  - the phone is a caller of the session edit;
  - the stamp rule, a digest that is the same across launches;
  - structure edits go by the phone's Show completed;
  - the page keeps edits inside its zoom.

## Testing Decisions

- **`bun test`** covers option 01's checks, plus each action's body, the caps, the encoded size under the argument cap, and the page's rules module.
- **`--outline-check`** runs each phone action on a throwaway file, and checks that:
  - a save with an old stamp is refused, and one with the current stamp is taken;
  - a stamp made in one run matches in the next;
  - a row that has left the tree is refused;
  - no bullet can be placed inside itself;
  - Enter at the start, middle and end of a bullet, and in a title, gives the Mac's result.
- **By hand, on the phone (the user's, after a restart on every Mac and the headless host):**
  - type a list with Enter; split a bullet mid-text;
  - ⌫ in an empty bullet, noting whether the keyboard reports it;
  - every key of the row, a note, and the +;
  - edit a bullet whose caret is on the Mac: the phone's text goes in around the Mac's caret;
  - change the same bullet on both: the phone's save is refused and its text kept, then Use mine and Use the Mac's;
  - ⌘Z on the Mac;
  - delete a bullet with nested bullets: it asks first;
  - edit a mirror on the phone, and see it change in its other places;
  - leave the app mid-typing: the text is saved;
  - restart the Mac: nothing saved is lost.

## Out of Scope

- Placing new mirrors from the phone (⌥⌘C and ⌥⌘V on the Mac).
- Selecting several bullets, and copying them as Varnick's own copy.
- Undo and redo on the phone.
- Joining a bullet onto the row above with ⌫.
- The filter and tapping a tag, as in option 01.
- Saving the phone's collapse to the file (Decided by the user).
- Editing while the Mac can't be reached, and a queue of edits for later.
- Dragging bullets.

## Further Notes

- **Siblings:** Voice mode on the phone (ADR 0043) for the request, the headless refusal and the page's view; Panel access's `outline_act` (ADR 0031) for the edit, its undo step, its caret rules and its refusal of a field that changed; the terminal's key row for the keys the phone lacks.
- **Build order:** option 01's read first, then the edits, in tickets of one option merged once, so the protocol is bumped once. A merge of the read alone would take one bump and the edits another.
- **The protocol and ADR numbers are the next free ones when this merges.** On 2026-10-20, `phone-cant-mark-a-tab-done`'s option 03 is built on its branch with protocol 33 and ADR 0045, and not yet merged. If it merges first, this option takes protocol 34 and ADR 0046.

## Decided by the user, 2026-10-20

The user chose this option ("03 Full editing (Recommended)"), and options 01 and 02 are rejected. The answers were given through the coordinator's question form:

1. **Full editing from the phone,** as this option describes.
2. **Privacy: "Yes, allow it."** The Outline's text may reach the listed phone over the tailnet. It is held in the page's memory only, and never cached, logged or pushed. The new ADR amending ADRs 0030, 0031 and 0011, the documents and the in-app wording (Privacy and documents) are part of the build.
3. **The planner's defaults stand ("Yes, all defaults"):**
   - **A collapse on the phone is not saved to the Mac.** It stays the phone's own, never a step on the Mac's undo stack, as in option 01.
   - **No placing mirrors from the phone.** The phone shows mirrors and edits them.
   - **No undo on the phone.** Delete asks before removing nested bullets, and ⌘Z on the Mac takes back phone edits.
   - **Listed devices only.** A paired Mac is refused.
   - **Each Mac's page shows that Mac's own Outline,** and a headless host's page shows none.
