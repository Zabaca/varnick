---
problem: tabs-past-the-strip-are-hidden
title: A setting for tabs that don't fit (shrink, fixed width or wrap), and a +N chip that lists the hidden ones
summary: Settings › Claude gains "Tabs that don't fit", with three choices. Shrink, the default, narrows the tabs together down to 140 points, then puts the ones that still don't fit behind a "+N" chip at the strip's right end. Fixed width makes every tab 180 points, then "+N". Wrap lets tabs flow onto up to three rows, then "+N". The chip opens a list of the hidden tabs, drawn as the search's Tabs rows, and turns orange while a hidden tab has a session waiting on the user. The strip always shows a run of neighbouring tabs that holds the tab on screen, so ⌘⇧[ and ⌘⇧] never land on a tab out of sight. The sideways scrolling goes.
status: shipped
---

## Solution

**A setting.** Settings › Claude › Tabs that don't fit offers Shrink, Fixed width or Wrap. Shrink is the default, and a change applies at once.

- **Shrink.** With room to spare, tabs are as wide as today. When they no longer fit, the widest narrow first: every tab is held to one widest width, which is lowered until they fit, down to 140 points. A tab whose title needs less keeps its own width. Once every tab is at 140 points, the ones that still don't fit go behind the chip.
- **Fixed width.** Every tab is 180 points wide, whatever its title, so tabs don't move as Claude retitles its sessions. The ones that don't fit go behind the chip.
- **Wrap.** Tabs keep today's widths and flow onto a second and a third row. The header grows by a row each time, and the panes below give up that height. Past three rows, the rest go behind the chip.

**The strip shows a run of tabs.** In every mode the strip shows neighbouring tabs in their order, and the tab on screen is always among them. Showing a tab outside the run moves the run as little as it takes to bring that tab in. That covers ⌘⇧[ or ⌘⇧], the chip's list, search, the board and a new tab. A new tab is the last, so the run moves to the end.

**The chip.** "+N" sits right after the last tab shown, before the new-session button. It counts every hidden tab, before the run and after it. While any hidden tab has a session waiting on the user, the chip is orange, the board's colour for that, and its help says how many.

**The list.** Clicking the chip opens a list under it:
- one row per hidden tab, in strip order, drawn as the search's Tabs list draws it: icon, name, pills, sessions, waiting and panes;
- a line between the tabs before the run and those after it;
- the board's orange mark on any tab with a session waiting on the user, a one-session tab included.

Click or ↩ shows the tab, ↑ and ↓ move, and esc closes. The list shows up to 8 rows, then scrolls.

## Trade-offs

- **Few tabs show at a time.** At the panel's default width about three tabs fit at 140 points beside the pills (inferred from the sizes in the code, not measured). Most of a busy day's tabs live behind the chip. Option 02 is what cuts the strip down to one project's tabs.
- **Shrink cuts titles short.** At 140 points a title keeps about a dozen characters (inferred).
- **Wrap takes height from the panes.** They resize each time a row comes or goes as tabs open and close, so every Claude and terminal pane redraws then. A tab of another machine that this Mac controls is resized on its host too (inferred).
- **The run moves when the tab on screen leaves it,** so the tabs shown change as the user steps past the edge. Keeping the first tabs still and swapping the tab on screen into the last place, as some editors do, would keep the strip steadier. But then the tab to the left of the one on screen isn't always the one ⌘⇧[ goes to.
- **A tab can't be dragged into or out of the hidden ones.** Dragging reorders the tabs shown.
- **Everyone's strip changes,** since Shrink is the default for every install, and sideways scrolling is gone.
- **One more read a second while a tab shows:** the turn files of hidden tabs' panes that run here and don't read their own, the same stat the board makes.

## User Stories

1. As the user, I want to see that more tabs are open than the strip shows, and how many.
2. As the user, I want the chip to tell me when a hidden tab has a session waiting on me, so that a permission dialog doesn't sit unseen.
3. As the user, I want to pick a hidden tab from a list that names it as search does, with its project and its sessions.
4. As the user, I want ⌘⇧[ and ⌘⇧] to always land on a tab I can see in the strip.
5. As the user, I want to choose whether tabs shrink, keep one width, or wrap onto more rows.
6. As the user, I want no tab cut off mid-title at the strip's edge.
7. As the user, I want my choice kept across restarts.

## Implementation Decisions

**The setting**
- A three-way setting saved in UserDefaults under its choice's name, read as Shrink when absent. It sits in Settings › Claude next to Text size, as a segmented picker like those of Settings › Models.

**Which tabs show**
- **One pure function decides.** It takes the tabs' widths in order, the room, the mode, the run as it was and the tab on screen. It returns the new run and the hidden count.
- **A tab's width is measured from its title** with the strip's font, plus its icon, count and close button, never read back from the layout. So nothing is published while the views lay out. The views report only the strip's width.
- **The room** is the header's width less the pills, the pin, the new-session button, and the chip's own width while it shows.
- **The run is kept between changes.** It moves only to bring the tab on screen in, and is worked out again when tabs open or close, a title changes, or the width changes.
- **A tab being renamed** (⌘⇧R) counts at the rename field's width.

**The strip**
- **The sideways scroll view goes.** The strip is one row, or up to three in Wrap, and the header's empty part still drags the window.
- **In Wrap,** each row is today's height, and the header's height follows the number of rows.

**Turns of hidden tabs**
- **Read once a second.** While a tab shows and some tabs are hidden, the model reads the turn of each hidden Claude pane that runs here once a second, as the board does. It publishes which tabs wait only when that changes.
- **No pane is read twice:** a pane that reads its own turn already isn't read again.
- **Panes on another machine** use the turn their host sends every few seconds.
- **"Waiting on the user" is the board's:** a permission dialog, a question, a plan to approve or an MCP server's request. Waiting for the next prompt doesn't count.

**The list**
- A popover from the chip. Its rows are the session list's tab rows, which follow their tab, plus the board's orange mark on a tab that waits.
- It takes ↑, ↓, ↩ and esc while open, so the panes don't get them. When it closes, the keyboard goes back to the focused pane of the tab on screen.

**Dragging**
- A drop between two tabs shown puts the tab there in the order. The hidden tabs keep their places.
- In Wrap, the drop place follows the row as well as the position along it.

**The Phone page** doesn't change. It lists tabs one under another.

## Testing Decisions

- **No test target yet.** The function that picks the run is where tests would go once there is one, for each mode:
  - the tab on screen at either end of the run, and outside it;
  - one tab wider than the room, and no room at all;
  - a tab opened or closed.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **Shrink:** with twelve tabs at the default width, tabs narrow, then "+N" shows, and no tab is cut off.
  - **Past the edge:** ⌘⇧] past the last tab shown moves the run by one and shows the tab. From the last tab, ⌘⇧] shows the first tab and moves the run to the start.
  - **A waiting hidden tab:** a hidden tab's session asks for a permission. The chip turns orange and the list marks that tab. Choosing it shows it, and the chip goes plain.
  - **A restored tab:** a tab restored after a restart and not opened since asks a question while hidden. The chip turns orange.
  - **Another machine's tab:** hidden and waiting, the chip turns orange within a few seconds.
  - **Fixed width:** a title changing doesn't move the tabs.
  - **Wrap:** tabs flow onto a second row and the panes shrink. Past three rows, "+N" shows.
  - **Dragging:** a tab dragged within the run keeps its new place after a restart.
  - **The setting:** the choice survives a restart.

## Out of Scope

- Filtering the strip by project (option 02).
- A key that opens the chip's list.
- Dragging tabs into or out of the list.
- A mark on a tab in view whose session waits (`sessions-finish-unnoticed` option 04 has a dot for that).
- Narrower pills in the header to give the strip more room.

## Further Notes

- **No ADR.** CONTEXT.md has no entry for the strip and needs none.
- **where-it-breaks to update:**
  - Focus and keys: the list's keys, and the keyboard back to the pane when it closes;
  - Panel size: the header's height in Wrap;
  - beside the board's reads, the turn reads of hidden tabs.
- **Verified in the code at 38b6d42:**
  - the strip falls back to a sideways scroll view with no scroll bar when its tabs don't fit;
  - nothing scrolls the tab on screen into view;
  - a title is cut at 170 points, and the close button is always laid out;
  - a Claude pane that runs here reads its own turn twice a second, and one restored and not opened since is read only by the board and, in a tab of several sessions, by the session list;
  - panes on another machine get their turns every few seconds, shown or not;
  - the session list's rows say "waiting" only for tabs of several sessions;
  - Settings › Models' choices are segmented pickers over a saved name.
- **Inferred, not measured:**
  - about three tabs fit at 140 points at the default width;
  - a trackpad swipe scrolls today's strip;
  - Wrap's resize reaches a tab of another machine's when this Mac controls it.
- **Picked:**
  - 140 points as the narrowest (the user's figure) and 180 points for Fixed width;
  - three rows in Wrap, and 8 rows in the list;
  - one chip for both sides of the run, after the last tab shown and before the new-session button.
- **Decided by the user (2026-10-13),** each the recommendation:
  1. **Three modes, as the coordinator shaped them?** yes, with Shrink the default.
  2. **Does Fixed width mean one width for every tab, or each tab at today's width, never shrinking?** one width (180 points), so tabs don't jump as Claude retitles sessions.
  3. **Does Wrap stop at three rows and use "+N" after?** yes. Rows without a limit would squeeze the panes out of a small panel.
