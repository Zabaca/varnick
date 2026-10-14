---
problem: panes-cant-be-moved
title: Drag a pane by a grip and drop it on another pane's edge or middle
summary: In a tab of several panes, hovering a pane shows a grip at its top centre. Dragging the grip over another pane shows where the pane would land. Near an edge, the half of that pane it would take is highlighted, and the drop splits that pane on that side. In the middle, the whole pane is highlighted, and the drop swaps the two. The emptied split closes up as it does when a pane closes. Mouse only. It covers both swapping and reshaping, and needs option 01's groundwork.
status: proposed
---

## Solution

**The grip.** While the pointer is over a pane in a tab of more than one pane, a small grip shows at the pane's top centre: a capsule with a six-dot drag symbol. It shows over the pane, as a terminal's × does, and over the middle of the bar on a web, app or file pane. Over the grip the pointer is an open hand.

**Dragging.** Pressing the grip and moving a few points starts a drag.
- The pointer becomes a closed hand, and a dark veil dims the dragged pane.
- Nothing moves until the drop.

**Drop zones.** Over another pane of the tab, the pointer's position picks one of two zones. The middle zone is the central half of the pane's width and height. The rest is four edge zones, each going to the side the pointer is nearest.

| Zone | Highlight | Drop |
|---|---|---|
| **Edge** | The half of the pane on that side: a light accent fill and a 2-point accent border | That pane splits: the dragged pane takes that half. Left or right is side by side, top or bottom is stacked. |
| **Middle** | The whole pane, with a swap symbol at its centre | The two panes swap places, and the tab's shape stays. |

A drop with no effect shows no highlight and does nothing. That covers the dragged pane itself, a divider, anywhere outside the panes, and a drop that would leave every pane where it is (in A | B, dropping A on B's left edge). Esc cancels a drag.

**After the drop**
- **The dragged pane leaves its place.** Its split closes up, the other side taking the whole space as when a pane closes. Every other split keeps its size.
- **An edge drop halves the target's space** between it and the dragged pane. A swap keeps every split's size, so the two panes trade sizes.
- **The dragged pane has focus,** as a click in it would give it.
- **The tab saves,** and on another machine's tab sends its layout to the host.

**Examples**, starting from A | (B / C):
- C dropped on A's bottom edge gives (A / C) | B.
- A dropped on B's middle gives B | (A / C).
- B dropped on A's left edge gives B | A | C.

## Trade-offs

- **Swaps and reshapes alike.** A pair can be turned from side by side to stacked, and a pane can leave its group.
- **Not every shape can be reached.** A drop splits one pane, never the whole tab, so nothing makes a pane span the full width under two others: (A | B) / C can't be reached from A | (B / C). Bands along the tab's own edges would allow it (Out of Scope).
- **More to build than option 01:** the grip, each pane's frame, the drag state, the highlight, and the move to an edge. The swap and the keying of each pane's view by its session are option 01's, and needed here whether or not 01 is built.
- **Mouse only.** A keyboard path to an edge would need a mode of its own (Further Notes).
- **The grip covers a little of the pane while hovered:** the middle of a terminal's top line, or of an address or a file's path.
- **An edge drop halves the target,** which can leave panes under the 220 by 110 points a divider keeps, as a split can today.
- **Discoverability:** the grip appears only on hover, and only in a tab of several panes.

## User Stories

1. As the user, I want to drag a pane to another place in its tab.
2. As the user, I want to see where it will land before I let go.
3. As the user, I want to stack a side-by-side pair, or the reverse, by dropping one pane on the other's top or bottom edge.
4. As the user, I want to swap two panes by dropping one in the middle of the other.
5. As the user, I want the panes to carry on as they were: Claude mid-turn, a shell's running command, a page's state.
6. As the user, I want to change my mind mid-drag by dropping the pane back on itself or pressing esc.
7. As the user, I want the new arrangement back after a restart.
8. As the user in control of another Mac's tab, I want the move made on that Mac, so every Mac shows it.
9. As the user viewing a tab I'm not in control of, I want to be told why I can't move its panes.

## Implementation Decisions

**It copies the tab strip's drag.**
- **A SwiftUI drag gesture** on the grip, in a coordinate space named on the tab's panes, rather than a macOS drag and drop. Terminals and web views take part in macOS drag and drop, and would act on a drop themselves.
- **Each pane reports its frame** through a preference. The frames are kept unpublished, as the strip keeps its tabs', so nothing publishes while the views lay out.
- **A drag state holds sessions, never tree nodes:** the dragged pane, the target and the zone. A host's listing can lay the tab out again mid-drag, and a pane can close; a drop whose pane is gone does nothing, and a pane leaving the screen mid-drag clears the state.
- **One overlay on the tab's panes draws the highlight,** beside the split picker's overlay.
- **The dragged pane is dimmed by a veil over it,** not by opacity, which may not reach a hosted AppKit view (inferred).
- **Esc is taken by the key monitor** while a drag is on. Inferred: key events still reach it while a drag gesture runs. If they don't, dropping on the pane itself is the way to cancel.
- **No drag starts** while the split picker shows.

**The move**
- **A swap is option 01's swap.**
- **An edge drop, in one main-actor step:**
  1. Take the dragged pane out; its split collapses into the other side, as a close does.
  2. Find the target again by its session.
  3. Split the target on the dropped side at half: the dragged pane goes first for left or top, second for right or bottom.

  The tree is rebuilt once, and each terminal gets at most one resize.
- **The "no effect" test** compares the result with the current layout, ignoring fractions.

**Keeping the panes alive:** option 01's decision. Each pane's SwiftUI view is keyed by its session, and no session is made, ended or started again.

**Locks and other machines** (ADR 0034)
- **The divider's lock is checked when a drag starts.** On a tab this Mac can't change, no highlight shows, and the dragged pane shows the reason.
- **On another machine's tab this Mac controls,** the move is applied here, saved and sent to the host as `arrange`. The host checks control and that the panes are the same, which a move always meets. If the host refuses, the dragged pane shows its reason, and the next listing puts the host's layout back.
- **Other Macs viewing the tab** see the move within about 5 s, and the Phone page's switcher follows the new order.
- **No protocol change.**

**The projects row:** option 01's decision. The tab keeps its row through a move.

## Testing Decisions

- **No test target yet.** The move to an edge is a pure change to the tree, and that is where tests would go:
  - each of the four sides;
  - the target being the dragged pane's own sibling;
  - a nested source;
  - a drop with no effect;
  - fractions untouched elsewhere.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **The grip** shows on hover only in a tab of several panes, on every kind of pane.
  - **Zones:** each edge highlights the right half, and the middle highlights the whole pane with the swap symbol. There is no highlight over the dragged pane, a divider or a drop with no effect.
  - **Reshape:** a side-by-side pair becomes stacked by a drop on the bottom edge.
  - **A nested pane:** in A | (B / C), moving C to A's bottom edge gives (A / C) | B, and B fills the right side.
  - **Panes alive:** as option 01's checks (Claude mid-turn, a page with a form filled in, `top`, an app, a file, the Transcript), each moved once by an edge drop and once by a swap.
  - **Focus:** after a drop, typing goes to the dragged pane.
  - **Cancel:** esc mid-drag and a drop on itself both change nothing.
  - **Restart:** the new layout comes back.
  - **Another Mac's tab, in control:** the move shows on the host at once, and on a third Mac viewing within about 5 s. The cards there each pause on scroll and take the keyboard for their own pane.
  - **Locked:** on a viewer not in control, and on the host while another Mac is in control, a drag shows the reason and no highlight.
  - **Projects column on:** moving the first Claude pane of a two-project tab keeps the tab in its row.

## Out of Scope

- **Bands along the tab's own edges** that dock a pane against the whole tab (making C span the bottom of (A | B) / C).
- Dragging a pane to another tab or out of the panel.
- Dropping a file from the file tree into the panes.
- Undo.
- An image of the pane following the pointer.

## Further Notes

- **A keyboard path to docking could follow:** a key lifts the focused pane, arrows pick the target and the side, ↩ drops, esc cancels, with this option's highlight. It would be a mode like the split picker, which the key monitor and Panel access already treat as a modal state.
- **A Scratch prototype would settle the feel before building.** A page with a mock tab of three or four panes, implementing the grip, the zones, the highlight, the swap, the edge drop and the collapse, would let the user try:
  - the grip's place;
  - the size of the middle zone;
  - whether the half-pane highlight reads well.

  It wouldn't test AppKit's part, which the shipped divider and tab drags already cover.
- **No ADR.** ADR 0034 already names `arrange` as the way the machine in control re-places panes.
- **where-it-breaks to update:** as option 01's list, plus Focus and keys for the drag's esc.
- **Verified in the code at b762537:**
  - the strip's drag is a SwiftUI gesture with reported frames and an overlay marker;
  - SwiftUI overlays already draw over terminals: the focus ring, and the corner's ×;
  - the tab's panes already carry the split picker's overlay;
  - a close collapses the split into its other side;
  - a split doesn't check the minimum sizes.
- **Inferred, not tried:**
  - a drag gesture keeps tracking over terminals and web views;
  - esc reaches the key monitor mid-drag;
  - opacity may not dim a hosted AppKit view.
