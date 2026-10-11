---
problem: no-outline-in-varnick
title: An outline in the panel, each bullet edited in a SwiftUI text field
summary: Option 01's view, file, keys and tree, with SwiftUI's own text field in place of each AppKit text view. It is the least new code, with nothing AppKit in the rows. The cost is every keyboard rule that needs the caret: on macOS 14, ↩ never splits a bullet, ⌫ never joins one, and ↑ and ↓ always leave a wrapped bullet. An input method's ↩ can make a bullet.
status: rejected
reason: The user accepted option 01 on 2026-10-10. On macOS 14, the package's floor, a SwiftUI field can't tell where the caret is, which wrapped line it is on, or whether an input method is composing, so ↩ couldn't split a bullet, ⌫ couldn't join one, ↑ and ↓ would leave a wrapped bullet from any line, and an input method's ↩ could make a bullet. Worth proposing again only if the floor moves to macOS 15 and a SwiftUI field reports all three.
---

## Solution

Everything is option 01's except how a bullet's text and note are edited:
- the view and its wiring, the shortcut and `!outline` / `!wf`;
- the tree, its file, and how it is saved and read;
- zoom, completed bullets, notes, the filter, tags, mirrors and undo.

A row that isn't being edited draws its text and note as SwiftUI text, with tags clickable and a completed bullet struck through. The row with the caret swaps in a SwiftUI text field that grows down as it wraps, one for the text and one for the note.

## Trade-offs

- **Nothing AppKit in the rows,** and the same kind of field as the rest of the panel's. It is the least new code of the three options.
- **The caret's position can't be read on macOS 14,** the package's floor. A text field's selection binding arrived in macOS 15: inferred from SwiftUI's availability notes, not checked in this repo. So:
  - ↩ always adds an empty bullet below and never splits a bullet's text.
  - ⌫ deletes an empty bullet and never joins one onto the bullet above.
  - Raising the floor to macOS 15 would bring both back.
- **Nor which wrapped line the caret is on,** so ↑ and ↓ always leave the bullet, even from the middle of a long wrapped one.
- **Nor whether an input method is composing.** The key monitor takes ↩ before the field. A Japanese or Chinese composition confirmed with ↩ would make a new bullet as well. Taking ↩ in the field's own key handler instead might leave composition to SwiftUI, which is unverified.
- **A click on a row lands the caret at the end,** not where the user clicked, since the text drawn before the click isn't the field.
- **Focus across a lazy list.** A row that isn't on screen has no field to focus. It is scrolled to first and focused a tick later, as in option 01.

## User Stories

Option 01's, except story 4: ↩ adds a bullet below without splitting. ↑ and ↓ move by bullet, not by line.

## Implementation Decisions

All of option 01's, except Rows and their text views:
- **Not being edited:** each row draws its text and note as SwiftUI text, with tags and the strike as attributed runs.
- **Being edited:** the row with the caret shows a vertical-axis text field for its text, and another for its note while the caret is there.
- **Keys change** under option 01's Keys:
  - ↩ always adds a bullet below.
  - ⌫ at the start isn't detectable, so an empty bullet is deleted by ⌫ on an empty field, and joining is dropped.
  - ↑ and ↓ always go to the next row.
  - The input-method rule is dropped.

## Testing Decisions

As option 01's. The check by hand drops splitting and the input method, and adds one check: a click in the middle of a bullet edits it with the caret at the end.

## Out of Scope

As option 01's, plus splitting at the caret and joining, unless the floor moves to macOS 15.

## Further Notes

Raising the package's floor to macOS 15 is a decision of its own, since it would touch every Mac Varnick runs on. It isn't proposed here.
