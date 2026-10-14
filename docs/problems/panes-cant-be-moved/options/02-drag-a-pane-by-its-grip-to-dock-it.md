---
problem: panes-cant-be-moved
title: Drag a pane by a grip and drop it on another pane's edge or middle, or along a side of the tab
summary: In a tab of several panes, hovering a pane shows a grip at its top centre. While a pane is dragged by it, thin bands mark the tab's four sides. The pane under the pointer shows its drop areas: four edge zones and a centre zone, each with a symbol of what a drop there does. The zone that will take the drop is highlighted, and a preview shows the space the pane will take. An edge drop splits that pane on that side, half each. A centre drop swaps the two panes. A band drop puts the pane along that whole side of the tab, at half the tab. The emptied split closes up as on close. With the bands, every arrangement of a tab's panes can be reached. Built with option 01 on one branch.
status: accepted
---

## Solution

**The grip.** While the pointer is over a pane in a tab of more than one pane, a small grip shows at the pane's top centre: a capsule with a six-dot drag symbol. It shows over the pane, as a terminal's × does, and over the middle of the bar on a web, app or file pane. Over the grip the pointer is an open hand.

**Dragging.** Pressing the grip and moving a few points starts a drag.
- The pointer becomes a closed hand, and a dark veil dims the dragged pane.
- Nothing moves until the drop.

**What shows while dragging.** Three layers are drawn over the tab's panes:
1. **The tab's bands.** A band 16 points deep runs along the inside of each of the tab's four sides, over the whole side except where it crosses the dragged pane. It is drawn faintly, as a hairline with a very light fill, for the whole drag.
2. **The drop areas of the pane under the pointer,** for any pane but the dragged one.
   - **The centre zone** is the middle half of the pane's width and height, outlined.
   - **The four edge zones** lie between the centre zone and the pane's sides, separated by lines from each corner of the pane to the matching corner of the centre zone.
   - **Each zone carries a symbol** of what a drop there does: a rectangle with its left, right, top or bottom half filled for the edges, two crossing arrows for the centre.
   - **Where the pane meets a side of the tab,** its areas begin at the band's inner edge, so a band and a pane's edge zone sit side by side and never overlap.
3. **The highlight and the preview.**
   - The zone that will take the drop is outlined in the accent colour, and its symbol turns accent.
   - The preview shows exactly the space the dragged pane will take, as a light accent fill with a 2-point accent border: the half of the target pane on that side, the whole target for a swap, or the half of the whole tab on that side for a band.
   - While a band takes the drop, the band turns accent along its whole length and the pane's drop areas hide. The band's extent and its tab-wide preview set it apart from any pane's edge zone.

**What each drop does**

| Drop | What happens |
|---|---|
| **A pane's edge zone** | That pane splits, and the dragged pane takes its half on that side. Left or right is side by side, top or bottom is stacked. |
| **A pane's centre zone** | The two panes swap places, and the tab's shape stays. |
| **A band** | The dragged pane runs along that whole side of the tab, and the rest of the tab, as it was, takes the other half. |

**What takes the drop.** The first of these rules that applies to the pointer's position decides:
1. Outside the tab's panes (the file tree, the projects column, the strip): nothing.
2. Over the dragged pane, its stretch of band included: nothing.
3. Within 16 points of a side of the tab: that side's band. In a corner where two bands meet, the nearer side wins.
4. Over a divider: nothing.
5. Over a pane: its centre zone if the pointer is within the middle half of its width and height. Otherwise, the edge zone of the side it is nearest, measured as a share of the pane's width or height. Both the drawing and this rule use the pane's rectangle less any band over it.
6. A drop that would leave every pane where it is, sizes aside, takes nothing. One example is A dropped on B's left edge in A | B; another is A dropped on the left band there. Nothing is highlighted for it.

Esc cancels a drag, and so does a drop on the dragged pane.

**After the drop**
- **The dragged pane leaves its place.** Its split closes up, the other side taking the whole space as when a pane closes. Every other split keeps its size.
- **Sizes:** a drop halves what it lands on.
  - An edge drop gives the target pane and the dragged pane half of the target's space each.
  - A band drop gives the dragged pane half the tab, and the rest keeps its own splits and sizes in the other half.
  - A swap keeps every split's size, so the two panes trade sizes.
- **The dragged pane has focus,** as a click in it would give it.
- **The tab saves,** and on another machine's tab sends its layout to the host.

**Examples**, starting from A | (B / C):
- C dropped on the bottom band gives (A | B) / C.
- C dropped on A's bottom edge gives (A / C) | B.
- A dropped in B's centre gives B | (A / C).
- B dropped on A's left edge gives B | A | C.

## Trade-offs

- **Every arrangement can be reached, sizes aside.**
  1. Drop one pane on a band.
  2. Build the arrangement wanted beside it, by dropping each other pane on an edge of a pane already placed.
  3. Taking the last pane from the rest closes the band's split.

  The dividers then set the sizes.
- **Two kinds of edge.** A pane at the side of the tab has a band and its own edge zone next to each other. They are told apart by where they sit (the band is the outer 16 points), by how far they reach (a band runs the whole side) and by the preview (half the tab against half the pane).
- **The bands take 16 points** from the edge zones of the panes along the tab's sides. On a 110-point stacked pane at the top of the tab, the top edge zone keeps about 23 points.
- **More to build than option 01:** the grip, each pane's frame, the drag state, the zone map, the bands, the preview, and the moves to an edge and to a band. The swap and the keying of each pane's view by its session are option 01's.
- **Mouse only.** Option 01's keys are the keyboard's way to swap. A keyboard way to an edge would need a mode of its own (Further Notes).
- **The grip covers a little of the pane while hovered:** the middle of a terminal's top line, or of an address or a file's path.
- **A drop halves its target,** which can leave panes under the 220 by 110 points a divider keeps, as a split can today.
- **Discoverability:** the grip appears only on hover, and only in a tab of several panes.

## User Stories

1. As the user, I want to drag a pane to another place in its tab.
2. As the user, I want to see the drop areas while I drag, so that I can choose whether it splits top, bottom, left or right.
3. As the user, I want to see the space the pane will take before I let go.
4. As the user, I want to stack a side-by-side pair, or the reverse, by dropping one pane on the other's top or bottom edge.
5. As the user, I want to swap two panes by dropping one in the middle of the other.
6. As the user, I want to put a pane along a whole side of the tab, under or beside all the others.
7. As the user, I want the panes to carry on as they were: Claude mid-turn, a shell's running command, a page's state.
8. As the user, I want to change my mind mid-drag by dropping the pane back on itself or pressing esc.
9. As the user, I want the new arrangement back after a restart.
10. As the user in control of another Mac's tab, I want the move made on that Mac, so every Mac shows it.
11. As the user viewing a tab I'm not in control of, I want to be told why I can't move its panes.

## Implementation Decisions

**Build order.** This option is built with option 01 on one branch:
1. Option 01's groundwork: each pane's view keyed by its session, the swap, the lock and `arrange` path, and the projects row.
2. Option 01's keys.
3. This option.

**It copies the tab strip's drag.**
- **A SwiftUI drag gesture** on the grip, in a coordinate space named on the tab's panes, rather than a macOS drag and drop. Terminals and web views take part in macOS drag and drop, and would act on a drop themselves.
- **Each pane reports its frame** through a preference. The frames are kept unpublished, as the strip keeps its tabs', so nothing publishes while the views lay out.
- **The tab's panes area, as laid out, defines the bands.** It excludes the file tree and the projects column.
- **A drag state holds sessions, never tree nodes:** the dragged pane, the target pane or band, and the zone. A host's listing can lay the tab out again mid-drag, and a pane can close; a drop whose pane is gone does nothing, and a pane leaving the screen mid-drag clears the state.
- **One overlay on the tab's panes draws the bands, the drop areas and the preview,** beside the split picker's overlay, with no hit testing. It uses the Theme's accent and hairline, and the symbols are SF Symbols.
- **The zone rules are one pure function.** It takes the pointer, the tab's panes area, the panes' frames and the dragged pane, and returns what takes the drop. The overlay draws from the same function's geometry, so what is drawn and what takes the drop can't disagree.
- **The dragged pane is dimmed by a veil over it,** not by opacity, which may not reach a hosted AppKit view (inferred).
- **Esc is taken by the key monitor** while a drag is on. Inferred: key events still reach it while a drag gesture runs. If they don't, dropping on the pane itself is the way to cancel.
- **No drag starts** while the split picker shows.

**The moves.** Each is one main-actor step, so the tree is rebuilt once and each terminal gets at most one resize.
- **A swap** is option 01's swap.
- **An edge drop:**
  1. Take the dragged pane out; its split collapses into the other side, as a close does.
  2. Find the target again by its session.
  3. Split the target on the dropped side at half. The dragged pane goes first for left or top, second for right or bottom.
- **A band drop:**
  1. Take the dragged pane out, as above.
  2. The tab's root becomes a split, along the band's axis at half, of the dragged pane and the rest of the tab. The dragged pane goes first for the left or top band. The rest moves under the root unchanged, and the tab keeps its root, as a split keeps it today.
- **The "no effect" test** compares the result with the current layout, ignoring fractions.

**Sizes: a drop halves what it lands on.** The same rule covers a pane and the whole tab, and the preview shows the result before the drop. Two other rules were considered:
- **Keeping the moved pane's own size** has nothing to keep when the pane changes axis.
- **A smaller fixed share for a band,** such as a third, would be a second rule to learn.

Either way, the divider is one drag away.

**Keeping the panes alive:** option 01's decision. Each pane's SwiftUI view is keyed by its session, and no session is made, ended or started again.

**Locks and other machines** (ADR 0034)
- **The divider's lock is checked when a drag starts.** On a tab this Mac can't change, no bands or drop areas show, and the dragged pane shows the reason.
- **On another machine's tab this Mac controls,** the move is applied here, saved and sent to the host as `arrange`. The host checks control and that the panes are the same, which every move meets. If the host refuses, the dragged pane shows its reason, and the next listing puts the host's layout back.
- **Other Macs viewing the tab** see the move within about 5 s, and the Phone page's switcher follows the new order.
- **No protocol change.**

**The projects row:** option 01's decision. The tab keeps its row through a move.

## Testing Decisions

- **No test target yet.** Two pure functions are where tests would go.
  - **The zone rules:**
    - each of the five zones;
    - the four bands and a corner;
    - the dragged pane under a band;
    - a divider;
    - a pane narrowed by a band;
    - a drop with no effect.
  - **The moves:**
    - each of the four sides of a pane;
    - each band;
    - the target being the dragged pane's own sibling;
    - a nested source;
    - the last pane taken from the rest;
    - fractions untouched elsewhere.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **The grip** shows on hover only in a tab of several panes, on every kind of pane.
  - **Drop areas:** while dragging, the bands show faintly along the tab's sides, and the pane under the pointer shows its five zones with their symbols. Each edge previews the right half and the centre the whole pane.
  - **Where band and pane meet:** a pane at the side of the tab, approached from inside, gives its own edge zone, then the band in the last 16 points. Each previews its own extent.
  - **No effect:** nothing is highlighted over the dragged pane, its stretch of band or a divider, or for a drop with no effect.
  - **Reshape:** a side-by-side pair becomes stacked by a drop on the bottom edge.
  - **Bands:** in A | (B / C), dropping C on the bottom band gives (A | B) / C, with C across the whole width at half the height.
  - **Panes alive:** as option 01's checks (Claude mid-turn, a page with a form filled in, `top`, an app, a file, the Transcript). Each is moved once by an edge drop, once by a band drop and once by a swap.
  - **Focus:** after a drop, typing goes to the dragged pane.
  - **Cancel:** esc mid-drag and a drop on itself both change nothing.
  - **Restart:** the new layout comes back.
  - **Another Mac's tab, in control:** the move shows on the host at once, and on a third Mac viewing within about 5 s. The cards there each pause on scroll and take the keyboard for their own pane.
  - **Locked:** on a viewer not in control, and on the host while another Mac is in control, a drag shows the reason and no drop areas.
  - **Projects column on:** moving the first Claude pane of a two-project tab keeps the tab in its row.

## Out of Scope

- Dragging a pane to another tab or out of the panel.
- Dropping a file from the file tree into the panes.
- Undo.
- An image of the pane following the pointer.
- Settings for the band's depth, the zones' sizes or the grip's place.

## Further Notes

- **The user's decisions of 2026-10-14, relayed by the coordinator:**
  - options 01 and 02 together, on one branch;
  - the grip at the top centre on hover, which the user may adjust after trying it;
  - drop areas shown while dragging, so the user chooses top, bottom, left or right;
  - bands along the tab's sides, so every arrangement can be reached;
  - sizes as recommended: a swap trades sizes, and a drop halves what it lands on.
- **Sizes the user may tune after trying:** the band's 16 points, the centre zone's middle half, and the grip's place.
- **A keyboard way to an edge could follow.** A key would lift the focused pane, arrows would pick the target and the side, ↩ would drop and esc cancel, all with this option's drop areas. It would be a mode like the split picker, which the key monitor and Panel access already treat as a modal state.
- **No ADR.** ADR 0034 already names `arrange` as the way the machine in control re-places panes.
- **where-it-breaks to update:**
  - option 01's list;
  - Focus and keys: the drag's esc;
  - Sessions and tabs: the zone rules drive both the drawing and the drop.
- **Verified in the code at b762537:**
  - the strip's drag is a SwiftUI gesture with reported frames and an overlay marker;
  - SwiftUI overlays already draw over terminals: the focus ring, and the corner's ×;
  - the tab's panes already carry the split picker's overlay;
  - a close collapses the split into its other side;
  - a split changes its pane in place, so the tab keeps its root;
  - a split doesn't check the minimum sizes.
- **Inferred, not tried:**
  - a drag gesture keeps tracking over terminals and web views;
  - esc reaches the key monitor mid-drag;
  - opacity may not dim a hosted AppKit view.
