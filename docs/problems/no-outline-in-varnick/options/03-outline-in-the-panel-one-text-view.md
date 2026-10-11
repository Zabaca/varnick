---
problem: no-outline-in-varnick
title: An outline in the panel as one AppKit text view
summary: Option 01's view, file, keys and tree, with the visible outline drawn as one text document. Each visible bullet and note is a paragraph, its depth is an indent, and its dot and triangle are drawn in the margin. Selecting, copying and moving the caret across bullets come from the text view itself. The cost is turning every text edit back into an edit of the tree, mirrors included. It is the largest and riskiest of the three.
status: rejected
reason: The user accepted option 01 on 2026-10-10. Turning every edit of one text document back into an edit of the tree, mirrors included, is the largest and riskiest of the three ways, the one most likely to lose a keystroke or a bullet with no error, and its one gain over option 01 is selecting and copying across bullets.
---

## Solution

Everything is option 01's except how text is edited:
- the view and its wiring, the shortcut and `!outline` / `!wf`;
- the tree, its file, and how it is saved and read;
- zoom, completed bullets, notes, the filter, tags, mirrors and undo.

The rows below the header are one AppKit text view, not a SwiftUI list. Its document is the visible rows: each bullet's text is a paragraph indented by its depth, and its note a paragraph in the note's style under it. Dots, rings and disclosure triangles are drawn in each paragraph's margin by the text system's layout.

Zooming, filtering, collapsing and Show completed rebuild the document from the tree, keeping the caret on the same row path. Each text edit is read back as an edit of the tree, by the paragraphs it touched.

## Trade-offs

- **Selecting across bullets works,** with the mouse or ⇧ and the arrows. So does copying several bullets, and the caret moves through the outline as through any text, with no edge between rows.
- **One first responder,** and input methods work everywhere with no special case. Thousands of rows cost one view.
- **Every edit has to be turned back into the tree.** Typing over a selection that spans bullets at different depths, deleting a paragraph break (a join), pasting lines, and a note's paragraphs among the bullets' are each a rule of their own. A wrong rule loses or misplaces a bullet with no error.
- **A mirror shown twice is two paragraphs.** An edit in one rewrites the other, in the same document, while the user types in the first.
- **The text view's own undo works on text** and fights edits of the structure. It has to be replaced by the tree's stack, as in option 01.
- **Drawing in the margin** means custom drawing in the text system's layout. Per-paragraph dots, the strike for completed bullets and clicks on tags all live there. On macOS 14 that is TextKit 2, which nothing in Varnick uses and which is the least documented of the three approaches.
- **The most work and the most risk** of the three. It is the one most likely to lose a keystroke or a bullet.

## User Stories

Option 01's, plus: as the user, I want to select several bullets and copy them, so that I can move a list out of the outline.

## Implementation Decisions

All of option 01's, except Rows and their text views:
- **One text view.** The visible rows are one text view's document, with a paragraph per bullet's text and per note. Paragraph attributes carry each row's path, depth and kind.
- **Edits go back to the tree.** The text view's edits are read back as edits of the tree, by the paragraphs they touch. An edit the rules can't express is refused and the document rebuilt.
- **Rebuilds.** The document is rebuilt from the tree after every edit of the structure, every zoom, filter and collapse, and every change to a mirror made in another row.
- **Option 01's keys** are taken by the key monitor as there. The caret keys and selection are the text view's own.

## Testing Decisions

As option 01's. The check by hand adds:
- selecting across bullets at different depths, then typing over the selection;
- deleting the break between two bullets;
- typing in one row of a mirror while its other row is on screen.

## Out of Scope

As option 01's, except selecting several bullets, which this option brings.
