---
title: Tabs past the end of the tab strip are hidden
description: When more tabs are open than fit across the tab strip at the top of the panel, the last one shown is cut off mid-title and the rest don't show at all. Nothing says they are there. The user finds them only by stepping through the tabs with ⌘⇧[ and ⌘⇧]. The user keeps many tabs open at once, across several projects, most with long titles.
impact: Work in a hidden tab is forgotten. A hidden session waiting on a permission, a question or a plan sits unseen unless the session board is opened. Reaching a hidden tab means stepping through the tabs before it, one at a time. Each project the user works on at once makes it worse.
severity: mid
evidence: The user's words and screenshot of 2026-10-13, relayed by the coordinator. The screenshot is not committed. Code read at 38b6d42 (main is 52a5191, and the tab strip, the pills, the settings and the key bindings are the same on both). Nothing was run.
status: open
---

## What the user asked for (2026-10-13)

1. **What the strip does with tabs that don't fit is a setting.** The choices:
   - by default, tabs shrink to a minimum width of about 140 points, then the rest go behind a "+N" chip at the strip's right end;
   - tabs keep a fixed width, then "+N";
   - tabs wrap onto more rows.

   The coordinator suggested shaping these as three modes, and the user didn't object. It is still to be confirmed. The chip opens a list of the hidden tabs, made of the search's Tabs rows, which already say "N sessions · M waiting". The chip is tinted while a hidden tab has a session waiting on the user. ⌘⇧[ and ⌘⇧] always bring the tab they show into view.
2. **A projects column, the user's idea.**
   - A column on the left lists the projects that have open tabs. It is shown and hidden like the file tree, which stays on the right.
   - Choosing a project filters the tab strip to that project's tabs. An All row shows every tab.
   - One key shows and hides the column. Another key, or a pair, moves between projects without opening it.
   - Each row shows its tab count, and a mark when a tab waits on the user.

## Today

Verified in the code at 38b6d42 unless marked.

**The tab strip**
- **The strip is one row in the panel's header,** left of the focused pane's pills and the pin. A tab is as wide as its title needs, up to 170 points of title. Beside the title are its icon, a pane count when it has several panes, and a close button that is always laid out.
- **When the tabs don't fit, the strip becomes a sideways scroll view with no scroll bar.** Its edge is what cuts the last tab off. Nothing marks that more tabs lie past it. A trackpad's sideways swipe scrolls it (inferred, not tried).
- **Nothing scrolls the tab on screen into view.** ⌘⇧[ and ⌘⇧] show the previous or next tab, wrapping, and its place in the strip can stay out of sight.
- **Tabs are reordered by dragging,** in the strip and in the search's Tabs list. The order is saved.
- **The pills in the header belong to the focused pane,** not to each tab: `^host`, `#project` and `@agent`, with the folder's name standing in for a missing project.

**Projects**
- **A pane's project** is the project whose folder is exactly the pane's folder, among its machine's projects:
  - this Mac's are scanned in the background at launch, when the project folders change, and when a prompt is begun;
  - another machine's are as it last listed them, asked of it when a pane there needs them.

  A pane in a subfolder of a repo, in a worktree or in the home folder has none.
- **A project's word** is `#name`, or `#group/name` when another of that machine's projects has the same name.
- **The board's card for a tab** takes its pills from the focused pane if that is a Claude pane, else from the first Claude pane.
- **A tab belongs to one machine:** every pane in it runs on the same host. A split starts in the focused pane's folder.

**Waiting on the user**
- **A session waits on the user** when Claude shows a permission dialog, asks a question, has a plan to approve, or an MCP server asks for input. The board marks such a card in orange. Waiting for the next prompt doesn't count.
- **How often turns are read.**
  - A Claude pane that runs here reads its own turn twice a second.
  - A pane restored after a restart, and not opened since, is read once a second only while the board shows, or while the session list shows and its tab has more than one Claude session.
  - A pane on another machine gets its turn from its host every few seconds, whether its tab is on screen or not.
- **The session list's tab rows** say "N sessions · M waiting" only for a tab with more than one Claude session. A one-session tab's row doesn't say that it waits.

**Sizes**
- A tab opens in a panel 760 points wide by default, which can be narrowed to 480.
- The file tree is 250 points wide. It belongs to its tab and is saved with it.
- A divider keeps a pane at least 220 points wide.

**Keys**
- **Bound by default** (Settings › Shortcuts): ⌘, ⌘⇧Y ⌘N ⌘⇧T ⌘⇧R ⌘W ⌘⇧D ⌘⌥R ⌘V ⌘⇧[ ⌘⇧] ⌘⇧F ⌘⇧B ⌘⇧E ⌘⇧O ⌃⌘⇧E ⌃⌘⇧O ⌘⇧H ⌘⇧J ⌘⇧K ⌘⇧L ⌘L ⌘R ⌘= ⌘- ⌘0. ⌃Space, ⌃⇧Space and ⌃⌥L work anywhere.
- **Fixed keys:** the Outline's own keys, ⌘[ and ⌘] among them, apply only while it shows. The board takes esc, the arrows, ↩, D and R while it shows.
- **Free:** ⌘⇧P, ⌘⌥[ and ⌘⌥] are bound to nothing.
- **Every shortcut can be rebound.** A key Varnick binds never reaches the pane, so a web or app pane's page loses it.

**The Phone page** lists a host's open tabs as rows, one under another. It has no strip.

## Overlap with other problems

- **`sessions-finish-unnoticed`** (all proposed). Its option 04 puts a dot on a tab in the header whose turn changed while the user wasn't looking. A hidden tab's dot would be out of sight too, so whatever marks hidden tabs would have to carry it.
- **`work-is-tracked-by-session-not-tab`** (options 01 to 04 shipped). Option 03 opens other machines' tabs whole in this Mac's strip, so the strip holds those too.
