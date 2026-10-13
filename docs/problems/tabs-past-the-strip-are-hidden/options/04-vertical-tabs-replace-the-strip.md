---
problem: tabs-past-the-strip-are-hidden
title: A column of tabs on the left replaces the strip
summary: Recommended against. The header loses its tab strip, and every open tab becomes a row in a column left of the panes, as in browsers with vertical tabs, with its name, pills, sessions and waiting mark. Rows scroll when they don't fit. It shows every tab with room for long titles, but it takes width all the time from a panel that is often narrow, and moves renaming, dragging and closing out of the header. The reason to reject it, should the user agree, is ready in Further Notes.
status: proposed
---

## Solution

- **The header keeps its pills and pin,** and drags the window. The tab strip goes.
- **A column left of the panes lists every open tab,** one row each, in the strip's order, drawn as the search's Tabs rows: icon, name, pills, sessions, waiting and panes.
- **The column scrolls** when its rows don't fit. The row of the tab on screen is highlighted and scrolled into view.
- **Rows can be dragged** to reorder, renamed in place with ⌘⇧R and closed from their ×.
- **A key shows and hides the column.** While it is hidden, ⌘⇧[ and ⌘⇧] still step through the tabs, and the header names the tab on screen.

## Trade-offs

- **Every tab shows, with room for its title and pills,** and a waiting session is marked on its own row.
- **It takes width all the time.** A row that shows a title and pills needs about 220 points. The panel opens tabs at 760 points, can be narrowed to 480, and the file tree takes 250 more. With both shown, the panes keep under 300 points at the default width.
- **Hiding it brings the problem back.** With the column hidden, nothing shows which tabs are open.
- **It moves every tab control:** renaming, dragging, closing and the new-session button all change place. It is the largest change of the options.
- **Grouping by project, the user's own idea (option 02),** gets the overview from a narrower column that lists projects rather than tabs.

## User Stories

1. As the user, I want to see every open tab with its full title.
2. As the user, I want each tab's row to say when its session waits on me.

## Implementation Decisions

- The rows are the session list's tab rows, with the drag and rename the strip has today.
- Whether the column shows is saved in UserDefaults.

## Testing Decisions

- `make build`, then by hand: with twenty tabs, every one is listed, and the column scrolls to the tab on screen.

## Out of Scope

- Grouping the rows by project (option 02).

## Further Notes

- **Verified in the code at 38b6d42:** the panel's default width for a tab is 760 points and it narrows to 480; the file tree is 250 points; a divider keeps a pane at least 220 points wide.
- **Inferred:** about 220 points for a row with a title and pills, from the session list's rows.
- **Reason, if rejected:** it takes width all the time from a panel that is often narrow, beside the file tree, and moves every tab control. A projects column (option 02) gives the overview from less width.
