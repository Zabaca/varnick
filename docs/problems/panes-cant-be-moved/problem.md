---
title: Panes can't be moved within a tab
description: Each pane stays where it was split off. The user can drag a divider to resize panes, but can't move a pane to another place in the tab, swap two panes, or turn a side-by-side pair into a stacked one. The only way to change the arrangement is to close panes and split again.
impact: The layout stays as it grew, split by split. Rearranging means closing panes and splitting again. Closing ends a terminal's shell. It ends a Claude pane's session too, leaving its conversation in the tab's history to resume. The user works in several panes per tab, so a layout that no longer fits the work is either kept as it is or rebuilt by hand.
severity: low
evidence: The user's words of 2026-10-14, relayed by the coordinator. The code was read at b762537 (main). Nothing was run.
status: open
---

## What the user asked (2026-10-14)

> I'd love to be able to adjust my tab pane layout to move panes around. I can resize but not move them.

The user chose the scope: **within a tab only**. Moving a pane to another tab is out. A tab belongs to one machine (ADR 0034), so a move between tabs could also be a move between machines.

## Today

Verified in the code at b762537 unless marked.

**The layout**
- **A tab's panes form a tree of splits.** Each split is side by side or stacked, and gives its first part a share of the space (its fraction). Each end of the tree is a pane. `sessions.json` saves that tree, so any arrangement a move could make is one the file can already hold.
- **A split** (⌘⇧E, ⌘⇧O, or the picker with ⌃) turns the focused pane into a split in place. The old pane goes first (left or top) and the new one second, half each. Focus goes to the new pane.
- **Closing a pane collapses its split.** The other side takes the split's whole space, and focus goes to the pane that grows into it.
- **A divider drag** changes one split's fraction. It keeps each side at least 220 points wide or 110 high, and a double click puts it back at half. A split doesn't check those minimums.
- **⌘⇧H/J/K/L move focus** to the nearest pane in that direction, worked out from each pane's rectangle in the tab. Nothing moves a pane.
- **Nothing in Varnick undoes a layout change.**
- **Panes have no common header.**
  - A Claude, terminal or Transcript pane has no bar. On hover, its Restart, Done and × show over its top-right corner.
  - A web or app pane has its address bar, and a file pane its file bar, each with a ×.
  - The card of a pane that stays on another machine has its × in the corner.

**Tabs of another machine** (ADR 0034)
- **Only the machine in control changes a tab's layout,** and the host checks.
  - On the host, the tab is locked while a card shows another machine in control.
  - A divider drag on a locked tab does nothing, and when it ends the pane says why: "Take over to change this tab.", or "Only ‹host› changes this tab."
- **A divider move or a rename on another machine's tab,** made by the Mac in control, is applied there, saved, then sent to the host as `arrange` with the whole layout. Until the host answers, listings older than the change are ignored. If the host refuses, its next listing puts its own layout back.
- **The host already takes a re-placed layout.** Both a Mac host and a headless host take `arrange` when the layout holds the tab's panes, each once, "however they are placed". That rule came with the tabs listing (protocol 24; protocol is now 26), so every paired machine accepts a move as it stands, and no protocol change is needed.
- **Other Macs viewing the tab** ask its host about every 5 s while the tab shows. When the shape differs, they lay the tab out again, keeping each pane by its id.
- **The Phone page** shows a tab one pane at a time. Its switcher lists the panes in the host's layout order (inferred from the listing's code, not read in the page).

**Drags today**
- **Tabs are reordered by dragging** in the strip and in the search's Tabs list. This is a SwiftUI drag gesture, not a macOS drag and drop: each tab reports its frame, the dragged tab dims, a 2-point accent bar marks where it would land, and a drop that changes nothing does nothing.
- **The divider uses the same kind of gesture.** A drag that starts on it keeps working while the pointer crosses a terminal or a page. Inferred: AppKit sends a drag's events to the view the mouse went down in.

**Which pane comes first**
- **The projects column** files a tab under the project of its first Claude pane in layout order, or of its first pane if it has no Claude pane. It keeps the folder that pane had when first seen, so neither focus nor a shell's `cd` moves the tab between rows. Another pane becoming first does.
- **A board card** takes its pills from the focused pane if that is a Claude pane, else from the first Claude pane.

## Does a pane survive being moved?

Every option depends on the answer: is a pane's live state tied to its place in the tree?

**The state survives (verified).** It belongs to the pane's session object, not to SwiftUI:
- **The content is made once,** when the session is: a terminal (Claude, terminal, Transcript), a web view (web and app panes) or a file viewer. The process also starts once: the shell, Claude's client, the zmx client or the app's server.
- **SwiftUI identifies a pane by its place.** A split's two sides are nested by position, with no ids, so a pane that moves gets a new SwiftUI view.
- **That view only holds the content.** Each place makes its own container (`TerminalHost`), and the container adopts the session's content view: out of its old superview, into this one. The container is keyed by the session's id, so a place that shows another session gets a new container. The newest container claims the content, and an old one on its way out can't take it back.
- **Splits, closes and hosts' listings already rely on this.**
  - A split turns the pane into a split in place, so the old pane's content moves into a new view in the first half.
  - A viewer's tab laid out again from its host's listing rebuilds the whole tree the same way.
  - A web pane keeps its page when it is split. That behaviour has shipped, though moving a web view between containers has not been tested on its own.
- **The keyboard comes back.** A new container for the focused pane gives it the keyboard a turn later.

**What a move costs a pane (verified unless marked).**
- **One resize of its terminal** if its size changes, a main-queue turn after its container gets the new size. Two panes of the same size swapped get none.
- **A card's frozen screen gets a new view.** Scrolling back had paused the screen; after a move it follows live again.
- **An address being typed** in a web pane's bar is lost, since the field's text belongs to the view.

**The gap (verified in the code; its effect inferred).**
- **The frozen screen binds its session when it is made.** On a card (another machine in control), the frozen screen (`FrozenScreenView`) binds the session's focus target, its pause on scroll and its "card shown" signal. Neither the frozen screen nor the card is keyed by the session.
- **It goes wrong when a place shows another frozen session,** as when A | B becomes B | A. The frozen screen is updated rather than made again, and keeps the first session's bindings. The keyboard goes to the container that now shows the other pane, and scrolling one pane pauses the other's live screen.
- **Today only a host's listing can cause this,** by bringing two changes in one 5 s interval (A | B becoming B | C).
- **Moves would make it common,** on exactly the machines that show cards: those viewing another machine's tab, and the host while another machine is in control.
- **The fix is the same in every option.** Each pane's SwiftUI view is keyed by its session, so a place that shows another session gets a whole new view. That also covers the address bar's text.

## Left to decide

- **How a move is asked for:** a key, a drag, or a key that reshapes the whole tab.
- **What a drag holds the pane by,** since panes have no common header.
- **What a move does to sizes:** whether the panes keep the sizes of the places they land in, or the space is halved afresh.
- **Whether a move may change a tab's project row,** which today follows the first Claude pane.
