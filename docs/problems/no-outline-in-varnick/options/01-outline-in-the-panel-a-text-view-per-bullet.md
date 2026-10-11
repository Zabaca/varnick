---
problem: no-outline-in-varnick
title: An outline in the panel, each bullet edited in its own text view
summary: The Outline replaces the panel's content the way the Session board does. ⌘⇧Y, `!outline` or `!wf` shows it. One tree of bullets lives in `outline.json` in the support folder, stored as bullets and placements, so a mirror is one bullet placed twice. SwiftUI draws the rows. Each bullet's text and note are edited in a small AppKit text view, which tells the outline where the caret is, which wrapped line it is on, and whether an input method is composing. The keyboard rules need all three.
status: accepted
---

## Solution

The **Outline** is a view of the panel, like the Session board. ⌘⇧Y (Show / hide outline, in Settings › Shortcuts), `!outline` or `!wf` shows it in place of whatever the panel shows. The same key, or esc, goes back.

It holds one tree of **bullets** the user writes. A header carries the breadcrumbs, a filter field, Show completed and Close. Below it the bullets are indented under one another. Each has a dot, its text, its note when it has one, and a disclosure triangle when bullets are nested under it.

Everything can be done from the keyboard (Keys, below):
- ↩ adds a bullet, splitting the text at the caret.
- ⇥ and ⇧⇥ indent and outdent.
- ⌘⇧↑ and ⌘⇧↓ move a bullet.
- ⌘↑ and ⌘↓ collapse and expand.
- ⌘] and ⌘[ zoom in and out.
- ⌘↩ completes a bullet, and ⇧↩ opens its note.
- ⌘F filters.
- ⌘Z and ⌘⇧Z undo and redo.

With the mouse, clicking a dot zooms into its bullet, a breadcrumb zooms out to it, and a tag filters to it.

The tree is saved in `outline.json` in Varnick's support folder, on this Mac only, half a second after each change, atomically. It is stored as bullets and placements:
- A bullet's text, note and completion are kept once.
- Each spot where the bullet shows is a placement in its parent's list.
- A mirror is a bullet with two or more placements, so the same bullet is live in each. Every placement is equal: deleting one removes only that spot, and the bullet goes when its last placement goes.

A file Varnick can't read is never written over.

The rows are SwiftUI. Each row's text and note are edited in a small AppKit text view. That view tells the outline three things a SwiftUI field can't on macOS 14: where the caret is, which wrapped line it is on, and whether an input method is composing. Splitting at the caret, ↑ and ↓ through wrapped bullets, and ↩ under a Japanese or Chinese input method all need them.

## Trade-offs

- **The keyboard behaves like an outliner's.** ↩ splits a bullet at the caret, and ⌫ at the start joins it onto the bullet above. ↑ and ↓ leave a wrapped bullet only from its first or last line. An ↩ that confirms an input method's composition is the input method's, never a new bullet. Option 02 can do none of these on macOS 14.
- **Text can't be selected across bullets,** since each bullet is its own text view. Copying several bullets at once isn't in v1. Option 03 is the one that can.
- **An AppKit view inside SwiftUI rows is new for Varnick,** which has one read-only text view and no editable one. The view's height has to follow its wrapped text, and nothing in its update may publish to the outline (where-it-breaks, Sessions and tabs).
- **The panel's fixed size,** as the board has: 760 by 600, about 22 rows at once. The board's resizable alternative was not chosen, and the outline follows the board.
- **Mirrors are symmetric,** as the user decided. No placement is the original, so deleting any placement removes that one only, and the bullet goes with its last placement. A delete never loses a bullet that still shows elsewhere. This differs from outliners where the original is special.
- **Local only.** Nothing reaches a paired Mac or the phone. Ids and placements would let a later sync merge by bullet, but v1 doesn't plan for one.
- **The outline's own keys are fixed,** as the board's are, and only ⌘⇧Y can be rebound. While the outline shows, a Varnick shortcut the user has rebound onto one of its keys doesn't act.

## User Stories

1. As the user, I want one shortcut to show my outline and the same one to go back where I was, so that a note is a glance away from my sessions.
2. As the user, I want `!outline` and `!wf` to open it from the search field, so that I can reach it without remembering the shortcut.
3. As the user, I want to type as soon as the outline shows, with the caret where I left it, so that writing a thought down takes no clicks.
4. As the user, I want ↩ to add a bullet below, splitting the text at the caret, so that I write a list as fast as I think it.
5. As the user, I want ⇥ and ⇧⇥ to nest a bullet under the one above and back out, so that I can structure while I type.
6. As the user, I want to move a bullet up and down among its siblings, with what's nested under it, so that I can reorder without retyping.
7. As the user, I want to collapse and expand a bullet, and find it as I left it after a restart, so that a long branch stays out of the way.
8. As the user, I want to zoom into a bullet and see only what's under it, with breadcrumbs back up, so that I can work inside one part of a big outline.
9. As the user, I want to complete a bullet, see it struck through, and hide or show completed bullets, so that done work leaves my view without being deleted.
10. As the user, I want a note under a bullet, so that details don't clutter the bullet's line.
11. As the user, I want to type in a filter and see only the matching bullets with their ancestors, so that I find a bullet and still know where it sits.
12. As the user, I want `#tag` and `@tag` in a bullet to filter the outline when clicked, so that I can gather everything about one topic or person.
13. As the user, I want to place the same bullet in a second spot and edit it in either, so that one item can live in two lists.
14. As the user, I want deleting a bullet in one spot to leave it in its other spots, so that tidying one list never loses an item another list holds.
15. As the user, I want every change saved without a save command and kept across a restart, so that I never lose what I typed.
16. As the user, I want a file Varnick can't read left alone and shown to me, so that I can repair it instead of losing my outline.
17. As the user, I want my outline to stay on this Mac, so that private notes go nowhere.
18. As the user, I want ⌘Z to undo any change, a delete or a move included, so that a slip costs nothing.

## Implementation Decisions

### Language

These go in CONTEXT.md, in a new **Outline** section:

- **Outline**: The panel's view of one tree of **Bullets** the user writes, kept in a file on this Mac and nowhere else. It replaces the panel's content as Settings and the **Session board** do. _Avoid_: WorkFlowy (the app it copies), notes, outliner, document.
- **Bullet**: One line of the **Outline**: its text, an optional note under it, whether it is completed, and the bullets nested under it. A completed bullet is struck through, and hidden unless Show completed is on. (Not the board's Completed column, which holds sessions marked Done.) _Avoid_: item, node, row, entry, task, card.
- **Zoom**: Showing one **Bullet** as the top of the **Outline**: its text as the title, the bullets nested under it below, and breadcrumbs back up the way the user came in. _Avoid_: focus (a pane's), open, drill down.
- **Filter**: Words typed at the top of the **Outline** that hide every **Bullet** that doesn't match, while keeping each match's ancestors. It looks only inside the bullet zoomed into. Not the **Relevance filter**, which is search's last pass. _Avoid_: search (a `?` query searches **History**), find.
- **Tag**: A `#word` or `@word` in a **Bullet**'s text or note. Clicking it filters the **Outline** to it. Not a **Project** or an **Agent**, which `#name` and `@name` name in a **Prompt**. _Avoid_: label, hashtag, mention.
- **Mirror**: A **Bullet** placed in more than one spot in the **Outline**. Each spot has the same text, note, completion and nested bullets, so an edit in one shows in all. Each spot is a placement. None is the original, and the bullet is gone only when its last placement is deleted. (The **Live screen** is never a mirror, which is why that term avoids the word.) _Avoid_: copy, clone, link, reference, original.

### The view, copied from the Session board

- **Its own object.** The outline is an observable object of its own, owned by the launcher's model as the board is. It holds the tree, the caret's row, the zoom, the filter, the undo stack and the saving. Typing never publishes the launcher's model, which resizes the panel on every change it publishes.
- **Showing and hiding.** A flag on the launcher's model says whether the outline shows; it is read-only outside the model. Show, close and toggle work as the board's do.
  - ⌘⇧Y from Settings closes Settings and shows the outline, as ⌘⇧B does for the board.
  - The board and the outline never show together. Showing either one closes the other, whichever tab the board shows (`!problems` too).
  - Settings opens over the outline.
  - The Restart Varnick card shows over the outline, as over the board.
- **Size.** The panel's height for the outline is fixed at 600, a branch of its own in the panel's height (where-it-breaks, Panel size).
- **No terminal while it shows.** The tab shortcuts don't act while the outline shows, as with the board.
- **Tabs close it.** Showing a tab closes the outline, as it closes the board. The exception is also the board's: a tab that only became the one underneath, because the tab on screen ended.
- **Peer starts.** A session started on a paired Mac that finishes starting while the outline shows opens in the background, as it does under the board.
- **Focus.** The caret goes back into its bullet, a tick later, in three cases: the panel shows again, Settings closes over the outline, or the outline itself shows. The board needs no focus, since it reads every key from the key monitor. The outline needs a first responder for typing.
- **Hiding the panel.** The outline stays up when the panel hides and shows again, as the board does.
- **The shortcut** is a new rebindable action. Its title is "Show / hide outline", it sits in the Varnick group with Settings (the board's is under Tabs), and its default is ⌘⇧Y. Its hints use the shortcut's own label, never a written "⌘⇧Y".
- **No switch.** The outline is a feature the user asked for one shortcut away, not an experimental one, so it gets no switch in Settings › Experimental.
- **The command** is `outline`, with `wf` as its second name, as `tabs` is for `kanban`.
  - Its row reads "Show outline", with the detail "Your bullets, kept on this Mac (also !wf)" and the list symbol for indented bullets.
  - `!w` finds only it. `!o` lists it first, and Show problems board after it while the Problems board switch is on, since `problems` has an o inside.

### Keys

The outline's own keys are fixed, like the board's. The panel's key monitor gives them to the outline before the shortcuts, only while the outline shows and Settings doesn't. The Restart Varnick card, while it shows, takes every key before the outline, as it does before the board. Keys the outline doesn't act on go on, as the board's do.

- **↩** in a bullet's text adds a bullet below, and the text after the caret moves into it.
  - At the start of a non-empty bullet, ↩ adds an empty bullet above instead.
  - On an expanded bullet with bullets nested under it, the new bullet becomes its first nested bullet.
  - In a note, ↩ is a new line.
- **⌫ at the start of a bullet:**
  - An empty bullet with nothing nested is deleted, and the caret goes to the end of the row above.
  - A non-empty bullet with nothing nested and one placement joins its text onto the row above.
  - Anything else does nothing.
- **⇥** nests the bullet as the last bullet under the sibling above, opening that sibling if it was collapsed.
- **⇧⇥** makes the bullet the next sibling of its parent. The bullets after it stay where they were. At the top of a zoom it stops.
- **↑ and ↓** go to the row above or below when the caret is on the bullet's first or last wrapped line. Otherwise they move the caret within the bullet.
- **⌘⇧↑ and ⌘⇧↓** move the bullet, with what's nested under it, among its siblings, and stop at the first or last sibling.
- **⌘↑ and ⌘↓** collapse and expand. Clicking the disclosure triangle does the same.
- **⌘] and ⌘[** zoom into the bullet with the caret, and out one level. ⌘, is Settings, so no outline key uses it.
- **⌘↩** completes a bullet, or makes a completed one not completed.
- **⇧↩** goes into the bullet's note, made when there is none, and from the note back to the text.
- **⌘⇧⌫** deletes the bullet here, with what's nested under it (Mirrors).
- **⌘F** goes to the filter field. There, ↓ or ↩ goes to the first match.
- **⌘⇧C** turns Show completed on or off.
- **⌥⌘C** copies the bullet as a mirror, and **⌥⌘V** places that mirror below the bullet with the caret.
- **⌘Z and ⌘⇧Z** undo and redo (Undo).
- **esc** steps back one level: out of the note, else it clears the filter, else it closes the outline.
- **The End session, Mark session done and Restart session keys** (⌘W, ⌘⇧D and ⌘⌥R by default, matched through the user's bindings) are taken and do nothing, as on the board, so none reaches the tab underneath.
- **While an input method is composing,** the text view gets ↩, ⇥, ↑, ↓ and esc untouched.
- **Every other key goes on,** first to Varnick's shortcuts and then to the text view.
  - The shortcuts that act here are ⌘⇧Y itself, ⌘, ⌘⇧B, ⌘⇧T, ⌘⇧[ and ⌘⇧], and the font keys.
  - The text view gets typing, the caret keys, and ⌘C, ⌘V, ⌘X and ⌘A through the Edit menu.
- **Pasting several lines** into a bullet's text puts the first line at the caret and each further line in a new bullet below, at the same depth. Blank lines are skipped. A note keeps its line breaks.

None of the outline's own keys is a Varnick default: checked on 2026-10-10 against every default combo, with the user's overrides empty.

### The tree and its file

The file is one JSON object:
- `version`: 1.
- `root`: the id of the top bullet. It has no text of its own and is never shown as a row.
- `bullets`: each bullet by its id.
- The outline's own view state: `zoom` (the placements the user last zoomed through) and `showsCompleted`.

A bullet has:
- `text`: one paragraph, with no line breaks.
- `note`: optional, and may have line breaks.
- `completed`: when it was completed, optional.
- `created` and `changed`.
- `children`: its placements, in order.

A placement has:
- `id`: its own id.
- `bullet`: the id of the bullet placed.
- `collapsed`: present and true when collapsed. Collapse belongs to a placement, because it is about where a bullet shows, not what the bullet is.

A mirror is a bullet named by more than one placement. Nothing else marks it.

Tags aren't stored: they are read from the text. Ids are lowercase UUIDs. The file is encoded with sorted keys and ISO 8601 dates, like `sessions.json`.

The format is final from the first ticket, so mirrors arrive later with no change of version. This prototype encodes the decision. The bullet `77ab…` is placed twice, under the top bullet and under `9d2e…`:

```json
{
  "version": 1,
  "root": "00a1…",
  "showsCompleted": false,
  "zoom": ["a3f0…"],
  "bullets": {
    "00a1…": { "text": "", "created": "…", "changed": "…",
               "children": [ { "id": "a3f0…", "bullet": "9d2e…" },
                             { "id": "c4b8…", "bullet": "77ab…", "collapsed": true } ] },
    "9d2e…": { "text": "Varnick #work", "note": "ideas for the outline", "created": "…", "changed": "…",
               "children": [ { "id": "b7e1…", "bullet": "77ab…" } ] },
    "77ab…": { "text": "Ship the tracer bullet", "completed": "2026-10-07T17:00:00Z", "created": "…", "changed": "…",
               "children": [] }
  }
}
```

**Rows are paths.** A row on screen is the path of placements from the top bullet, or from the bullet zoomed into, down to it.
- A bullet nested under a mirror shows once for each placement of that mirror, and each showing is its own row.
- The caret's row, the zoom and the filter's matches all name paths, never bullet ids.
- Breadcrumbs therefore follow the way the user zoomed in.

**The tree's rules** live in one module, the tree's value type. Everything else edits the tree through it.
- **Its interface:**
  - Apply an edit at a row: add, split, join, set the text or note, indent, outdent, move up or down, delete, complete, collapse, or place a mirror. The result is the new tree with where the caret goes, or a refusal.
  - List the visible rows for a zoom, a filter and Show completed.
- **It takes no clock, file or view,** so `--outline-check` (Testing Decisions) can run its rules on throwaway files, and undo is a stack of its values.
- **No bullet is ever placed inside itself,** however deep and through any placement. Only indenting and placing a mirror can break this; outdenting and moving among siblings can't. A refused edit beeps, and the header says "A bullet can't go inside itself".
- **A bullet is kept while a placement of it can be reached from the top bullet.** Anything else is dropped when the tree is saved, so deleting a placement drops whatever was only under it.
- **There is always a line to type in.** An outline with no bullets gets one empty bullet when it shows.

The file is a second small module, `read` and `write`:
- Read takes a URL and returns a tree, or why it couldn't.
- Write takes a tree and a URL.
- It has one adapter, the file, so there is no protocol for it.

### Saving and reading

- **When it is read.** The file is read the first time the outline shows in a launch, off the main actor. "Loading…" shows until then. Nothing reads it at launch, so a large or broken file costs nothing until it is opened.
- **No file.** An empty outline. The file is written at the first edit.
- **Can't be read.** This covers a file that isn't JSON, doesn't decode, or names a top bullet that isn't there.
  - The outline shows "outline.json couldn't be read" with Reveal in Finder and Start a new outline, and nothing is written while it shows.
  - Start a new outline renames the file to `outline.unreadable-<date and time>.json` beside it, then starts empty.
  - The rule is the device file's: what the user may want to repair is never replaced.
- **A newer version.** A file whose version is above this build's shows "outline.json is from a newer Varnick" with Reveal in Finder only, and nothing is written. An older build decodes a newer file, drops the fields it doesn't know and would write the rest back, so any new field raises the version.
- **A file that reads but breaks a rule,** such as one edited by hand:
  - A placement that names a missing bullet is dropped.
  - A placement that would put a bullet inside itself is dropped.
  - A bullet left with no placement goes under a "Recovered" bullet at the end of the top level.
  - The file itself changes only at the next edit. The log gives how many of each, never any text.
- **When it is written.**
  - Half a second after the last change.
  - At once when the outline closes: esc, ⌘⇧Y, or another view taking the panel.
  - At Quit from the menu bar, where `sessions.json` gets its last save: a change not yet written is written then, after any write under way, so an older copy never lands over a newer one.
  - A restart (`make run`, Restart Varnick, a paired Mac's) stops the app with a signal, so nothing runs: it loses at most the last half second of typing.
- **How it is written.**
  - Encoded and written off the main actor, from a copy of the tree, one write at a time. A newer copy replaces one whose write hasn't started.
  - Atomically: a temporary file in the same folder, opened with mode 0600 and renamed over the old one, as the device file's writer does.
- **A backup each launch.** Before the first write of each launch, the file as read is copied to `outline.previous.json`, so one launch's mistakes can be undone by hand.
- **The path is passed in.** The file's path comes from the support folder as a URL passed in, so a check never touches the user's file.

### Rows and their text views

- **Laying out rows.**
  - The rows are a lazy SwiftUI stack in a scroll view, built from the tree's visible rows.
  - Each level indents 18 points.
  - A collapsed bullet with bullets under it has a ring around its dot.
  - Text is 13 points and notes 11.5, secondary, with `Theme` tokens.
- **The text views.**
  - Each row on screen edits its text, and its note when it has one, in a small AppKit text view: no scroll view, no border, wrapping at the row's width, with its height reported to SwiftUI.
  - The row with the caret is the panel's first responder.
- **Edits flow one way.**
  - A text view hands every edit to the outline as it is typed.
  - The outline never sets the text of a text view that has the caret. A mirror's other rows take the new text when they update.
- **Nothing publishes during an update.** Nothing in a row's update publishes to the outline or moves the first responder.
  - The caret is moved by the outline, after the update, a tick later, as focusing search waits.
  - A row the caret goes to that isn't on screen is scrolled to first.
- **Tags and completed bullets.** Tags and the strike through a completed bullet are attributes of the text view's text. A click on a tag filters instead of placing the caret.
- **Text views keep no undo of their own.** Typing and structure undo in one order (Undo).

### Zoom

- **Zooming in.** ⌘], or a click on a dot, zooms into a bullet.
  - Its text becomes the title under the header, editable, and the bullets nested under it are the rows.
  - ↩ at the end of the title adds the first nested bullet.
  - A bullet with nothing nested shows only its title.
- **Breadcrumbs.** The header shows Home and each bullet zoomed through, each clickable. Long paths drop middle crumbs to "…".
- **Zooming out.** ⌘[ zooms out one level, and the caret lands on the bullet it came from.
- **Remembered.** The zoom is saved in the file. A zoom whose path no longer exists, such as one into a deleted bullet, opens at Home.

### Completed bullets and notes

- **Completing.** ⌘↩ stamps `completed`, and ⌘↩ again clears it.
  - A completed bullet is struck through and dimmed, and so is everything under it.
  - With Show completed off, it is hidden at once, and the caret goes to the next row shown.
- **Show completed** is a button in the header ("Show completed" or "Hide completed"), saved in the file, and switched by ⌘⇧C.
- **Notes.** A note shows under its bullet's text, at most two lines, cut with "…" unless the caret is in it.
  - ⇧↩ goes into the note and back.
  - A note left empty is removed.

### Filter

- **The field** sits in the header and is reached with ⌘F. The filter is live as the user types.
- **Matching.**
  - It is split into words, and a bullet matches when its text or note contains every word, ignoring case and accents.
  - A word that starts with `#` or `@` matches a tag exactly: `#work` matches `#work` and `#Work`, not `#workshop`.
- **What shows.**
  - Matches show with their ancestors, up to the bullet zoomed into.
  - Collapsed ancestors are shown open while the filter has text. Their saved state is untouched.
  - A match's nested bullets show only if they match too.
  - Matching words are highlighted.
- **Completed bullets** follow Show completed while filtered too.
- **The caret's bullet stays.** A bullet the caret is in stays shown while the user edits it, even when it stops matching, until the filter changes. Rows never vanish under the caret.
- **Clearing.** esc in the field clears it and puts the caret back where it was.

### Tags

- **What counts as a tag:** `#` or `@`, then letters, digits, `_` or `-`, at the start of the text or after a space or `(`. An email address or a URL's `#fragment` is no tag.
- **How tags look.** Tags show in the outline's accent colour, in text and notes.
- **Clicking a tag** adds it to the filter, or removes it when the filter has it already.

### Mirrors

- **Making one.** ⌥⌘C on a bullet remembers it, and the header says "Copied as a mirror" for a moment. ⌥⌘V in another bullet places a mirror of it as the next sibling there.
  - Placing it inside itself is refused (The tree and its file).
  - The copy lasts until the next ⌥⌘C or the end of the launch, and never reaches the system clipboard.
- **How they look.** Every placement of a bullet with more than one placement has a ringed dot. Its tooltip lists the breadcrumbs of the other placements.
- **What is shared.** The text, the note, the completion and the nested bullets are shared, live, by every placement. Collapse is each placement's own.
- **What acts on the placement.** Indenting, outdenting and moving act on the placement under the caret.
- **Every placement is equal,** as the user decided. No placement is the original, so none is special when it is deleted.
- **Deleting** (⌘⇧⌫, ⌫ on an empty bullet) removes only the placement under the caret.
  - The bullet stays wherever else it is placed, with everything nested under it.
  - When its last placement goes, the bullet goes, and with it any nested bullet that has no other placement.
  - Deleting the first placement made and deleting a later one are the same act.
- **Joining.** ⌫ at the start doesn't join a mirror's text onto the row above.

### Undo

- **In v1,** in ticket 02, as the user decided. Without it, ⌘⇧⌫ on a bullet with a hundred nested bullets is lost for good, and `outline.previous.json` only reaches back to the launch.
- **One stack.** One stack of the tree's values, with the caret's row, for the launch. ⌘Z and ⌘⇧Z are taken by the outline before the Edit menu.
- **Typing in one bullet is one step** until a second's pause, or until the caret leaves the bullet.
- **200 steps at most.** The tree is a value, so a step costs a copy of the bullets' dictionary. At outline sizes that is small.

### Privacy

The outline's text and notes are never logged, and never sent anywhere: no paired Mac, phone, model, search store or reranker. Logs give the kind of failure and counts. The relay doesn't read the file, and the launch snapshot doesn't copy it.

### ADR

The decision gets ADR 0030, written by ticket 01: the outline is one JSON file that Varnick owns, of bullets and placements, never written over when unreadable, and versioned against older builds. 0029 is held by text-generation-ignores-the-claude-subscription's option 01 for when it is built. If another ADR has taken 0030 by the time ticket 01 is built, use the next free number.

## Testing Decisions

- **No test target.** Verification is `make build`, then checking by hand after the user restarts Varnick.
- **`Varnick --outline-check <file> [<out>]`,** a check like `--embed-check`.
  - It is a command-line mode among the others, and exits before anything of the app starts. It touches only the paths it is given: never the support folder, `Settings.shared` or the database (where-it-breaks, The rename).
  - It reads a file through the one reader and prints whether it loads, or why not; its version; how many bullets, placements and mirrors it has; and what the rules dropped or recovered.
  - With `<out>`, it writes the tree there through the one writer.
  - It prints no text of any bullet.
  - The builder runs it on throwaway files: a missing file, broken JSON, a newer version, a missing bullet, a placement inside itself, a bullet left with no placement, and a mirror whose delete leaves its other placement. It checks that a write and a read give the same counts back.
- **Checks by hand, after a restart.** Each ticket lists its own. Together they cover:
  - the shortcut, both command names, and esc;
  - the board and Settings over and beside the outline;
  - the caret coming back after the panel hides and shows;
  - every key;
  - a restart losing nothing;
  - an unreadable file shown and left alone;
  - a Japanese input method's ↩ confirming text rather than splitting the bullet.

## Out of Scope

- Syncing with paired Macs or the phone, and OPML import and export.
- `?` search finding bullets. It would touch the search store's rules.
- Placing a mirror by typing to pick its bullet (WorkFlowy's `((`).
- Dragging bullets with the mouse, and selecting several bullets at once.
- Formatting (bold, links), dates, and boards made of bullets.
- "Delete everywhere" for a mirror.
- Opening the outline from another app with a global hotkey.
- Watching the file for edits made elsewhere. A hand edit made while Varnick runs is overwritten at the next save.
- A resizable outline.

## Further Notes

**AppKit's outline view was considered.** It gives row reuse, disclosure and dragging, but:
- it needs one object per row, while a mirror's nested bullets show in several rows;
- its editing ends a cell at ↩, where an outliner keeps typing into the next bullet;
- nothing in Varnick uses it.

**A refactor worth raising, not done here.** Settings, the board and the outline would be three flags for "what replaces the panel's content", which every branch has to keep exclusive. One value would hold them all. The outline adds a flag as the board did.

**Where it breaks.** These are the items of `docs/agents/where-it-breaks.md` this option touches, and what ticket 01 adds:
- **Saved state:** the outline never goes in `sessions.json`, whose decode drops everything on a failure. Its own file follows the device file's rule instead, and gets its own section.
- **Panel size:** a fixed branch for the outline in the panel's height, like the board's.
- **Focus and keys:**
  - The outline takes its keys before the shortcuts, after the Restart Varnick card, and lets every other key through.
  - The End session, Mark session done and Restart session keys never reach the tab underneath.
  - A tab under the outline is activated without focus, so a frozen card can't take ⇧↩ as Take over.
  - Focus moved into a row waits a tick.
- **Sessions and tabs:** nothing in a row's text view update publishes or moves focus.
- **The rename:** `--outline-check` is a command-line mode, so it touches only the paths it is given. A read of the support folder before the migration would make the folder step skip.
- **A new section, The outline**, holding:
  - the file's one reader and writer, and that a file it can't read, or a newer version, is never written over;
  - that a new field raises the version;
  - saving on change and at Quit, never relying on a restart to save;
  - rows as paths of placements, never bullet ids;
  - the tree's rules living only in its value type;
  - that its text is never logged.

## Decided by the user, 2026-10-10

This option is accepted, and options 02 and 03 are rejected. The open questions are answered:

1. **How text is edited:** this option, an AppKit text view per bullet.
2. **Deleting mirrors:** every placement is equal. Deleting one removes only that spot, and the bullet goes when its last placement goes (Mirrors). Ticket 07 builds it.
3. **Undo (⌘Z) is in v1,** in ticket 02 (Undo).
