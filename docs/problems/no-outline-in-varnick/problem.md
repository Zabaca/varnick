---
title: Varnick has no place to keep an outline of bullets
description: The user wants a WorkFlowy-style outline in the panel, one shortcut away like the Session board. It means nested bullets edited from the keyboard, zoom, completed bullets, notes, a live filter, tags and mirrors. Varnick has nowhere to write anything of the user's own. Every view it has shows sessions, terminals, pages, files, problems or search.
impact: Lists and plans that belong beside the sessions live in another app, or nowhere. Either way they are a context switch away from the panel the user works in all day.
severity: low
evidence: The user's request of 2026-10-07, with the decisions below, relayed by the coordinator. Code read at 4c7f344 (main), before the rename, and re-checked against 79ac676 (main) on 2026-10-10.
status: open
---

## What the user wants

1. **An outline view in the panel,** switched like the Session board, and opened from a `!` command as `!kanban` opens the board.
2. **Nested bullets with collapse and expand, edited from the keyboard:** ↩ for a new sibling, ⇥ and ⇧⇥ to indent and outdent, and moving bullets.
3. **Zoom into a bullet,** with breadcrumbs back up.
4. **Complete a bullet,** shown struck through, with completed bullets shown or hidden.
5. **A note under a bullet.**
6. **A live filter** that keeps each match's ancestors visible.
7. **`#tag` and `@tag`,** clicked to filter.
8. **Mirrors:** the same bullet live in several places.

## Decided by the user

- **Shortcut:** ⌘⇧Y, a new shortcut, rebindable like the rest. ⌘⇧L stays Focus pane right.
- **Data:** local and owned by Varnick. One tree, saved as a file in Varnick's support folder. No WorkFlowy account, no network, and no syncing with paired Macs in v1. OPML export can come later.
- **Scope of v1:** everything under What the user wants.
- **Wiring:** copied from the Session board.

## Today

Verified in the code at 4c7f344 and again at 79ac676 unless marked otherwise.

**The sibling: the Session board.**
- The board is an object of its own, owned by the launcher's model beside a flag that says whether it shows.
  - ⌘⇧B, `!kanban` and `!tabs` show it in place of the panel's content. `!problems` shows it on its Problems tab, while Settings › Experimental › Problems board is on.
  - The same key, or esc, goes back to the tab or search underneath.
  - From Settings, ⌘⇧B closes Settings and shows the board. Settings opens over the board.
- Its size is fixed, like Settings: the panel's 760 wide by 600 high.
- While the board shows, no terminal is on screen, so the tab shortcuts don't act.
- The panel's key monitor gives the board its keys before the shortcuts: esc, the arrows, ↩, D, R, Tab and ⇧Tab, and the End session, Mark session done and Restart session keys, so none of the three reaches the tab underneath. Every other key goes on.
- The Restart Varnick card shows over every view, the board included, and takes every key before the board does.
- Showing any tab closes the board, with one exception: a tab that became the one underneath because the tab on screen ended.
- A session on a paired Mac that finishes starting while the board shows opens in the background.
- The board publishes on its own object, so its changes don't redraw the launcher. The panel resizes on every change the launcher's model publishes.
- The board stays up when the panel hides and shows again.

**Shortcuts.**
- ⌘⇧Y is no shortcut's default, and the user has no overrides: the defaults had no `shortcuts` key when read on 2026-10-07, before the rename, nor on 2026-10-10.
- Binding a combo to one action unbinds any other action that had it.
- ⌘, is Settings.
- In the panel, ⌘⇧T, ⌘⇧[ and ⌘⇧] act wherever they are pressed (a new terminal tab, the previous or next tab), and so do ⌘=, ⌘- and ⌘0 (the terminal's font). The rest act only with a tab on screen.

**Commands.** `!listen`, `!transcript`, `!kanban` (also `!tabs`) and `!problems`, which is listed only while the Problems board switch is on. A typed word ranks a command by any of its names: an exact name first, then a name it begins, then one it is inside.

**Text editing in the panel.**
- SwiftUI text fields only: the search field, the tab rename field, a web pane's address and Settings' fields.
- One AppKit text view, read-only, in the file viewer.
- No outline view anywhere.
- The package's floor is macOS 14.

**The user's saved files.**
- `sessions.json` decodes as one value. On any failure it falls back to empty, silently dropping every tab.
- `devices.json` refuses to be replaced. A file that doesn't read as a list throws, "so a write never replaces something the user may want to repair". Its writer opens a temporary file with mode 0600 and renames it over the old one.
- Both live in the support folder, which on a Mac is `~/Library/Application Support/Varnick`. The rename moved it there once; it doesn't move again.
- Both are written whole and atomically, on every change. A restart (`make run`, Restart Varnick, a paired Mac's) stops the app with a signal, so nothing runs then. Quit from the menu bar does run code: it saves `sessions.json` once more.

**Words already taken** (CONTEXT.md):
- Card (a pane's), board card, and Completed: the board's column, reached by Done.
- Transcript, Session, Pane and Tab.
- In a Prompt, `#name` names a Project and `@name` an Agent.
- Relevance filter: search's last pass.
- A Work link lists "Tag" as a word to avoid.
- The Live screen and the Frozen screen list "Mirror" as a word to avoid.
