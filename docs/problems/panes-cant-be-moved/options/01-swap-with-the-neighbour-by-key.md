---
problem: panes-cant-be-moved
title: Swap the focused pane with its neighbour by key
summary: ⌃⌘⇧H/J/K/L swap the focused pane with the pane that ⌘⇧H/J/K/L would focus. The tab's shape and dividers stay as they are, the two panes trade places and sizes, and focus moves with the pane. This is the smallest change, but it can't change a tab's shape. It carries the groundwork every option needs, and is built with option 02 on one branch.
status: accepted
---

## Solution

**Four new shortcuts** go in Settings › Shortcuts › Splits, under the focus keys: Swap with pane left, Swap with pane below, Swap with pane above and Swap with pane right. They default to ⌃⌘⇧H/J/K/L and can be rebound.

**What a swap does.** The focused pane trades places with its neighbour in that direction, the same pane the focus key would go to.
- Every split and divider stays where it is, so the two panes trade sizes too.
- Focus stays on the moved pane, at its new place.
- With no neighbour in that direction, nothing happens.

Pressing the key again walks the pane along a row or a column.

For example, in A | (B / C) with A focused, Swap with pane right gives B | (A / C) and leaves A focused.

## Trade-offs

- **Smallest change.** One change to the tree, four shortcuts, no new view.
- **The shape never changes.**
  - A side-by-side pair stays side by side.
  - A pane can't leave its group. In A | (B / C), A can trade with B or C, but nothing makes C span the bottom of the tab.
- **The panes trade sizes.** A narrow pane swapped into a wide place becomes wide.
- **Keyboard only.** Settings › Shortcuts is where the keys can be found.
- **Four more keys are kept from the panes.** A web page or a terminal program never sees ⌃⌘⇧H/J/K/L.

## User Stories

1. As the user, I want to swap the pane I'm in with the one beside it, without the mouse.
2. As the user, I want both panes to carry on as they were: Claude mid-turn, a shell's running command, a page's state.
3. As the user, I want the keyboard to stay with the pane I moved.
4. As the user, I want the new arrangement back after a restart.
5. As the user in control of another Mac's tab, I want the swap made on that Mac, so every Mac shows it.
6. As the user viewing a tab I'm not in control of, I want to be told why the swap didn't happen.

## Implementation Decisions

**Built with option 02 on one branch.** This option's groundwork comes first: each pane's view keyed by its session, the swap, the lock and `arrange` path, and the projects row. Then its keys, then option 02, which uses all four.

**The swap**
- **The neighbour** is the focus keys' own: the nearest pane past the focused pane's edge that overlaps it on the other axis. A tie goes to the pane most in line with it.
- **The two panes exchange places in the tree.** No split, axis or fraction changes.
- **One change in one main-actor step.** Each pane's view is rebuilt once, and each terminal gets at most one resize.
- **Focus stays on the moved pane.**
- **The tab saves,** and on another machine's tab sends its layout to the host, both as a divider move does.

**Keeping the panes alive** (the problem's "Does a pane survive being moved?")
- **Each pane's SwiftUI view is keyed by its session,** so a place that shows another session gets a new view throughout: the card's frozen screen and the address bar as well as the terminal's container. The keying also protects the machines that only take the new layout from the host.
- **No session is made, ended or started again.**

**Locks and other machines** (ADR 0034)
- **The divider's lock applies.** On a tab this Mac can't change, the swap does nothing and the focused pane shows the reason: "Take over to change this tab.", or "Only ‹host› changes this tab."
- **On another machine's tab this Mac controls,** the swap is applied here, saved and sent to the host as `arrange`.
  - The host checks control, and that the panes are the same, which a swap always meets.
  - If the host refuses, the moved pane shows the host's reason, and the next listing puts the host's layout back.
- **Other Macs viewing the tab** see the swap within about 5 s, and the Phone page's switcher follows the new order.
- **No protocol change.**

**Shortcuts**
- **Four actions in the Splits group,** acting only while a tab is on screen, as the focus keys do.
- **The defaults use ⌃ as the variant modifier,** as the picker's split keys do (⌃⌘⇧E, ⌃⌘⇧O). ⌃⌘⇧H/J/K/L are free among Varnick's defaults.

**The projects row**
- **A swap can change which Claude pane comes first, but the tab keeps its row.** The row's pane stays the one it was while it is still a Claude pane in the tab, as focus and a shell's `cd` don't move a tab either. A Claude pane added to a tab with none still takes the row over. After a restart, the row follows the first Claude pane in layout order again.

## Testing Decisions

- **No test target yet.** The swap is a pure change to the tree, and that is where tests would go:
  - a swap in a row and in nested splits;
  - no neighbour at an edge;
  - a swap back that restores the tree;
  - fractions untouched.
- **Build:** `make build`.
- **By hand,** after the user restarts Varnick:
  - **Claude mid-turn:** two Claude panes side by side, one working. Swap them. Both carry on with their scrollback intact, and typing goes to the moved pane.
  - **Page and terminal:** a web pane with text typed into a form on the page, swapped with a terminal running `top`. The page doesn't reload, the text is still there, and `top` keeps running.
  - **App, file and Transcript panes:** an app's server doesn't restart, and a file pane and the Transcript keep their place in the text.
  - **Uneven split:** at 70/30, the two panes trade sizes.
  - **Restart:** the swapped layout comes back.
  - **Another Mac's tab, in control:** after a swap, the host shows it at once. A third Mac viewing the tab shows it within about 5 s, and each of its swapped cards pauses on scroll and takes the keyboard for its own pane.
  - **Locked:** a viewer not in control, and the host while another Mac is in control, both show the reason.
  - **Headless host,** in control: the swap survives a fresh listing.
  - **Projects column on:** a tab holding Claude panes of two projects. Swap them, and the tab stays in its row.

## Out of Scope

- Changing a tab's shape by key (option 02 does it by drag).
- Whole-tab presets (option 03).
- Moving a pane to another tab.
- Undo.

## Further Notes

- **The user's decisions of 2026-10-14, relayed by the coordinator:** options 01 and 02 together, on one branch. The swap trades sizes, as recommended. The rest of the decisions are option 02's.
- **No ADR.** ADR 0034 already names `arrange` as the way the machine in control re-places panes. No change to CONTEXT.md.
- **where-it-breaks to update:**
  - **Sessions and tabs:** a pane's view is keyed by its session, and why;
  - **Focus and keys:** the projects row keeps its pane through a move;
  - **Peers:** a move is `arrange`, like a divider.
- **Verified in the code at b762537:**
  - the focus keys' neighbour rule;
  - ⌃⌘⇧H/J/K/L are bound to nothing by default;
  - a divider's end saves and sends `arrange`;
  - the host takes a re-placed layout, and has since protocol 24;
  - a card's frozen screen isn't keyed by its session;
  - the projects row reads the first Claude pane in layout order.
- **Inferred, not tried:**
  - a web view keeps its page when it moves to another container (splitting a web pane does this today);
  - the Phone page's switcher follows layout order.
