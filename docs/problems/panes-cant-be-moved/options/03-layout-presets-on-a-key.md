---
problem: panes-cant-be-moved
title: A key that lays the whole tab out again in one of four even arrangements
summary: ⌃⌘⇧A lays the tab out again in the next of four arrangements, with the panes in their current order and all sizes even. The four are Side by side, Stacked, Main (the focused pane on the left at half width, the rest stacked on the right) and Grid (two columns). Option 01's swap keys choose which pane goes where. Cheaper than dragging, and quick for tidying a tab after many splits, but each press throws away the tab's own shape and sizes.
status: proposed
---

## Solution

**One new shortcut,** Arrange panes, defaulting to ⌃⌘⇧A and able to be rebound, in Settings › Shortcuts › Splits. Each press lays the tab out again in the next arrangement, wrapping round:

| Arrangement | Layout |
|---|---|
| **Side by side** | Every pane in one row, equal widths. |
| **Stacked** | Every pane in one column, equal heights. |
| **Main** | The focused pane on the left at half the width; the others stacked on the right, equal heights. |
| **Grid** | Two columns, filled left to right and top to bottom, equal sizes. With an odd count, the last pane spans the bottom row. |

**Order and focus.** The panes keep their layout order, left to right and top to bottom, and focus stays where it is. Option 01's swap keys are how a pane changes its place in that order.

**Arrangements that don't fit are skipped:** an arrangement that would leave a pane under 220 by 110 points (the divider's minimum) at the tab's current size. If none fits, the key does nothing.

## Trade-offs

- **Cheaper than dragging.** No grip, frames or highlight: a pure function from the ordered panes to a tree, applied the way a host's listing is applied.
- **One key tidies a tab** after many splits have halved panes over and over.
- **The tab's own shape and sizes are lost** at each press. A custom arrangement can only be built again by splitting and dragging dividers.
- **Four arrangements may not hold the one the user wants.** A pane can't be put exactly where they want it.
- **Needs option 01** to change the order. Alone, it only reshapes.
- **Cycling is blind:** the user presses until the arrangement they want comes round.

## User Stories

1. As the user, I want one key to lay my tab's panes out evenly.
2. As the user, I want to switch a tab between a row, a column, a main pane with the rest beside it, and a grid.
3. As the user, I want the panes to carry on as they were.
4. As the user, I want the arrangement back after a restart.
5. As the user in control of another Mac's tab, I want the arrangement made on that Mac.

## Implementation Decisions

- **One pure function makes each arrangement** from the panes in order, the focused pane and the arrangement's name. The tab is laid out from the result keeping each pane by its id, as a viewer takes its host's layout.
- **The next arrangement** is the one after the last one this key chose for the tab in this run, starting at Side by side. Nothing new is saved: the tree is what is saved.
- **Even sizes** come from the fractions: a chain of n panes gives its splits 1/n, 1/(n−1) and so on.
- **The fit check** uses the tab's panes' size as the views last reported it.
- **Keeping the panes alive, locks and other machines, and the projects row:** option 01's decisions. Each pane's view is keyed by its session; the divider's lock applies; on another machine's tab the result is sent as `arrange`, which the host takes since the panes are the same; the tab keeps its project row.

## Testing Decisions

- **No test target yet.** The arrangement function is where tests would go: each arrangement for one to six panes, an odd count in Grid, and Main with the focused pane last.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **Cycling:** a tab of four panes built by uneven splits cycles through the four arrangements, all even.
  - **Panes alive:** as option 01's checks.
  - **Fit:** a narrow panel skips Side by side for four panes.
  - **Restart:** the arrangement comes back.
  - **Another Mac's tab, in control:** the host shows the arrangement, and a viewer shows it within about 5 s.

## Out of Scope

- Arrangements the user defines or saves.
- A menu or picker of arrangements.
- Moving a single pane to a chosen place (options 01 and 02).

## Further Notes

- **It's tmux's model:** `select-layout`'s even rows, even columns, main pane and tiled, plus `swap-pane` for order.
- **No ADR.**
- **where-it-breaks to update:** as option 01's list.
- **Verified in the code at b762537:** a viewer lays a tab out from a layout by pane id, keeping its sessions; the host takes a re-placed layout. ⌃⌘⇧A is bound to nothing by default.
- **Inferred:** no macOS shortcut takes ⌃⌘⇧A.
