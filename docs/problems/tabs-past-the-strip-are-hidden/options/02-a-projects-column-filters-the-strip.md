---
problem: tabs-past-the-strip-are-hidden
title: A projects column on the left filters the tab strip to one project's tabs
summary: A column left of the panes lists All, each project with open tabs, then Other, each row with its tab count and an orange mark when one of its tabs waits on the user. ⌘⇧P shows and hides it, as ⌘⇧F does the file tree on the right. ⌃⌘[ and ⌃⌘] choose the previous or next row without it. Choosing a project leaves only its tabs in the strip, and ⌘⇧[ and ⌘⇧] step through those. A tab's project is its first Claude pane's, by the rule the pills use, and other machines' tabs join the same rows. Showing a tab of another project, from search, the board or a new session, moves the choice to that project. Search, the board and the Phone page still cover every tab. Whether the column shows is saved; the choice isn't.
status: shipped
---

## Solution

**The column.** It sits left of the panes, under the header, 160 points wide, in the file tree's colours. Its rows:
- **All:** every open tab, with the count and the waiting mark of all of them.
- **Each project with open tabs,** by name: its `#word`, how many tabs, and an orange mark with the number of tabs waiting on the user.
- **Other:** tabs in no project, such as the home folder. Listed only when there is one.

The chosen row is highlighted, and clicking a row chooses it.

**Choosing a project filters the strip.** Only that project's tabs show, in their order, and ⌘⇧[ and ⌘⇧] step through them. The project's tab last shown comes up, or its first. All shows every tab and leaves the tab on screen as it is.

**Keys.**
- **⌘⇧P** shows and hides the column.
- **⌃⌘[ and ⌃⌘]** choose the previous or next row, All included, wrapping, whether or not the column shows. From search they choose and show the tab, as ⌘⇧[ does.

All three can be rebound, like every shortcut.

**The tab on screen is always in the strip.**
- Showing a tab outside the chosen project moves the choice to that tab's project. That covers search, the board, Recent, a new session and Panel access.
- Closing the last tab of the chosen project moves the choice to All.
- Closing the tab on screen shows its neighbour in the strip, as today.

**A tab's project** is that of its first Claude pane in layout order, or of its first pane when it has no Claude pane. A pane's project follows the rule the pills use: its folder is one of its machine's projects. A tab with none goes under Other. Focus doesn't change it, so a tab doesn't jump between rows as focus moves.

**Other machines' tabs** join their projects' rows by the project's word, so a repo checked out on two Macs is one row. A row's help says how many of its tabs are on each machine. Until a machine has listed its projects, its tabs are under Other.

**When the column isn't showing.** A chip at the strip's left end names the chosen project, unless All is chosen. Clicking it opens the column's rows as a list.

**A narrow panel.** The column shows only while the panes keep 220 points beside it and the file tree. In a narrower panel it stays hidden, and ⌘⇧P opens the chip's list instead.

**What doesn't filter:** search, with its Tabs list, the session board, Recent, the Phone page and Panel access's reads. All of them cover every tab.

**What is saved:** whether the column shows, in UserDefaults. The choice isn't: after a restart the strip shows All.

## Trade-offs

- **A tab of two folders is listed under one project.** Mixed tabs are rare, since a split starts in the focused pane's folder. All always shows it.
- **A pane in a subfolder of a repo, or in a worktree,** has no project by today's rule, so its tab is under Other, just as its pill is missing today. Matching the enclosing repo would change the pills too.
- **Two different repos with the same name on two machines share a row.**
- **The choice moves on its own** when the user opens another project's tab from search or the board. Going to All instead would lose the filter, and staying put would leave the tab on screen out of the strip.
- **It takes 160 points of width while it shows,** beside the file tree's 250.
- **⌘⇧P is taken from web and app panes,** where a page may use it, for a command palette for instance.
- **The choice isn't saved,** so no filter hides tabs after a restart unless the user picks it again. The cost is choosing again.
- **Projects with many tabs still overflow the strip.** Option 01 handles that; alone, this option keeps today's scrolling strip.

## User Stories

1. As the user, I want to see at a glance which projects have open tabs, and how many.
2. As the user, I want to see which project has a session waiting on me.
3. As the user, I want to choose a project and see only its tabs in the strip.
4. As the user, I want ⌘⇧[ and ⌘⇧] to step through that project's tabs.
5. As the user, I want to move to the next project with a key, without showing the column.
6. As the user, I want to show and hide the column with a key, as I do the file tree.
7. As the user, I want All to bring every tab back.
8. As the user, I want another Mac's tabs of a project listed with it.
9. As the user, I want search and the board to keep showing everything.
10. As the user, I want a tab I open from search to show in the strip, even when another project was chosen.
11. As the user, I want to see which project is chosen while the column is hidden.

## Implementation Decisions

**A tab's project**
- **One function gives a tab its row:** the first Claude pane in layout order, else the first pane, then that pane's project word as its pill shows it. No project means Other. It reuses the pills' lookup of this Mac's projects and of other machines' as they listed them.
- **Rows:** All first, then the projects by name, case-insensitive, then Other.
- **Counts come from the strip's tabs only.** A paired machine's open tab that no tab here shows isn't counted: it is in the session list and on the board.

**The choice**
- **Held in memory:** All, a project's word, or Other. Each row remembers the last tab shown under it during this run.
- **Showing a tab moves the choice.** Every way of showing a tab goes through the model's one activation, which moves the choice to the tab's row when the tab isn't in the chosen one.
- **The neighbours are the strip's.** The previous and next tab, and the neighbour shown after a close, are worked out among the strip's tabs.
- **Projects can change under a tab,** after a scan or a machine's new list. When the tab on screen leaves the chosen row that way, the choice follows it.

**The column**
- **Its own view** left of the panes, 160 points wide.
- **When it shows:** the column is on, and the panel leaves the panes 220 points beside it and the file tree, when that shows.
- **The panel's, not a tab's.** Whether it shows is saved in UserDefaults on change. The file tree is a tab's because it shows that tab's folder; the column lists every tab.

**Keys**
- **Three new actions in the Tabs group:** Show / hide projects (⌘⇧P), Previous project (⌃⌘[) and Next project (⌃⌘]).
- **Where they act:** the column's key while a tab shows, as ⌘⇧F does. The project keys also act from search, as ⌘⇧[ does.
- **Hints:** the column's top shows the keys through the usual shortcut hint, so a rebinding shows.

**Waiting marks**
- The once-a-second read of tabs' turns that option 01 adds for hidden tabs, extended to every tab while the column shows. Whichever option ships first builds it.

**Dragging** in a filtered strip: a drop between two of its tabs puts the tab just before the second of them in the full order, or just after the last when dropped at the end. Other projects' tabs keep their places.

**The Phone page** doesn't change. It lists one host's tabs, and grouping them by project could be an option of its own.

**Panel access** doesn't change. Its `show` of a tab goes through the same activation, so the choice follows it.

## Testing Decisions

- **No test target yet.** Where tests would go once there is one:
  - a tab's row, for mixed tabs, tabs with no Claude pane, and other machines' tabs before and after their projects arrive;
  - the rows, their order and their counts;
  - the choice after a tab is shown from elsewhere, after a close, and after projects change;
  - where a drop lands in a filtered strip.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **The column:** ⌘⇧P shows it with All, the projects with open tabs and their counts, and Other for a tab in the home folder. ⌘⇧P again hides it, and it stays hidden after a restart.
  - **Filtering:** choosing a project leaves only its tabs in the strip, and ⌘⇧] steps through them alone.
  - **The project keys:** with the column hidden, ⌃⌘] moves to the next project and shows its tab, and the chip at the strip's left names it.
  - **A waiting tab:** in another project, a session asks a question. That project's row gets the orange mark, and so does All.
  - **Opening from elsewhere:** filtered to one project, ↩ on another project's tab in search shows it, and the choice moves to its project.
  - **Closing the last tab** of the chosen project moves the choice to All.
  - **Another machine:** that machine's tab of a project open here too is counted in the same row, and the row's help names the machine.
  - **A narrow panel:** with the file tree on, ⌘⇧P opens the list from the chip instead of the column.
  - **After a restart** the strip shows All.

## Out of Scope

- The board or search following the chosen project.
- Grouping tabs by project on the Phone page.
- A tab's project by the repo that encloses its folder, for subfolders and worktrees. That would change the pills too.
- Tab groups the user makes, and colours.
- What a project's strip does when its tabs don't fit: that is option 01.

## Further Notes

- **Ships alone.** With option 01, the filtered strip uses its modes. Recommended after option 01, which fixes the cut-off tab for everyone.
- **Records:** CONTEXT.md's **Project** gains "a tab's project is its first Claude pane's". No ADR.
- **where-it-breaks to update:**
  - Focus and keys: the new keys, and the choice following every activation;
  - the turn reads for the column's marks.
- **Verified in the code at 38b6d42:**
  - a pill's project is the one whose folder is exactly the pane's folder, among its machine's projects;
  - a word is `#group/name` when that machine has two projects of the name;
  - other machines' projects are asked for when a pane on them needs them;
  - a tab's panes all run on one machine, and a split starts in the focused pane's folder;
  - the file tree is 250 points, belongs to its tab and is saved with it;
  - a divider keeps a pane at least 220 points wide, and the panel narrows to 480;
  - ⌘⇧P, ⌃⌘[ and ⌃⌘] are bound to nothing, by default or as a fixed key;
  - closing the tab on screen shows its neighbour in the full order;
  - every way of showing a tab goes through one activation.
- **Inferred:** mixed tabs are rare, from how splits pick their folder.
- **Picked:**
  - 160 points wide;
  - rows by name, with Other last;
  - the last tab shown per row;
  - the chip at the strip's left;
  - All after closing the chosen project's last tab.
- **Decided by the user (2026-10-13),** each the recommendation:
  1. **What is a tab's project?** its first Claude pane's, by the pills' rule. It stays put as focus moves, which the header's pills (the focused pane's) don't. Folders in no project go under Other.
  2. **Do other machines' tabs join the same project rows, or get a section of their own?** the same rows. The project is the unit of work, and the machine shows in the row's help, the list's pills and the header.
  3. **Should the session board follow the chosen project?** no. The board is where every waiting session shows. An opt-in could come later, if at all.
  4. **Is the chosen project kept across restarts?** no. Whether the column shows is kept.
  5. **Does search follow it?** no. Search, with its Tabs list, always covers everything.
  6. **Keys?** ⌘⇧P for the column, ⌃⌘[ and ⌃⌘] for the previous and next project. Changed by the user on 2026-10-13: ⌃⌘[ and ⌃⌘] step through projects, in place of ⌘⌥[ and ⌘⌥].
  7. **Anything on the Phone page?** nothing in this option.
  8. **A narrow panel?** the column shows only while the panes keep 220 points beside it and the file tree. Otherwise the chip's list stands in for it.
