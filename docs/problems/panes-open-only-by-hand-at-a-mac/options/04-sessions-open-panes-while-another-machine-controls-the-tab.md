---
problem: panes-open-only-by-hand-at-a-mac
title: A session opens and closes panes in its own tab on this Mac while the phone or another machine controls the tab
summary: Accepted by the user on 2026-10-17 (relayed by the coordinator), after a session restarted from the phone was refused `pane_open`. `pane_open` and `pane_close` work in the calling session's own tab on this Mac when the phone or another Mac controls it, as they do when nobody does. The Mac adds the pane beside the caller, labelled for the machine in control and with the tab's origin, so the tab stays one machine's whole; the controller sees the new pane at its next listing of the tab, unfocused. No protocol change: only the Mac that hosts the tab needs the build. Covers the Mac half of option 02, which stays proposed.
status: accepted
---

## Solution

**Where it works.** Option 01's tools, unchanged for the session, in one more case: the calling session's tab is this Mac's own and another machine is in control of it, the phone or another Mac. That machine is the one every running Claude and terminal pane of the tab names, the host's own test for a split. A tab whose panes name different machines (mid take over) is refused with "try again in a moment". A headless host's sessions, and a session in another machine's tab, stay as they are (option 02). The voice session's and a run's hidden tabs are refused as now.

**`pane_open`.** The Mac adds the pane the way it adds one for the controller's own split of the tab:
- Beside the calling pane, half its place, focus left where it was on this Mac.
- A Claude or terminal pane is started at once and labelled for the machine in control, so it is that machine's to attach. This Mac's own client lets go once it sees the label, and the pane shows the card here as the tab's other panes do.
- Every pane takes the tab's origin, so the controller's End still ends a tab made for it, rather than handing it back.
- A page, an app or a file has no label. The controller shows it from the listing, as it shows one the host already has.
- The rest is option 01's: the kinds and their fields, the folder rule, permissions capped by the caller, no cap on panes.

The reply says the pane is in the tab for the machine in control, by name, and shows there within about 5 s.

**What the controller sees.**
- **The phone** gains a switcher button for the new pane at its next ask of the tab, within 5 s while the page is visible, and keeps showing the pane it showed. A Claude or terminal pane opens at a tap, labelled for the phone. A page or an app is framed through the host's port proxy once the page server has looked at it; a file shows its text.
- **A Mac in control** adds the pane to its layout at its next listing, attaching a Claude or terminal pane because the label names it, with focus left where it was. A tab not shown there is brought up to date when it is shown.

**`pane_close`.** It closes a pane the session opened and the user hasn't used on this Mac, as now, and ends it the way the controller's close of one pane does here: with no question on this Mac's card. A pane the controller has open right now, with a client attached to its session, is refused: the user is looking at it there. This is the recommended rule; see Further Notes.

**Who else closes it.**
- A Mac in control closes it with its close key, as any pane of the tab (ADR 0034's rule).
- The user at this Mac closes it once they take the tab back, when it is an ordinary pane.
- The phone has End for the whole tab and no close of one pane (option 03 left that out).

## Trade-offs

- **What the user asked:** a session works the same whether the user follows it at the Mac or from the phone.
- **Small:** the Mac's model only. The controller learns from `tabs` as now, and the tools' request is unchanged, so no protocol change and no session restart: a session already lists both tools.
- **It amends ADR 0034's rule** that only the machine in control changes the tab. A session in the tab now adds panes for that machine, labelled for it, so control and the one-machine-whole rule hold.
- **The controller's own change can cross it.** A split from the controller and an open from the session both land, since the host makes each in turn. A divider the controlling Mac drags before it has seen the new pane is refused by the host, whose layout has one pane more, and snaps back at the next listing.
- **The user's use on the controller can't be seen on the host.** Only a client attached right now holds a pane against `pane_close`. A terminal the user typed into on the phone and then left can be closed by the session.
- **The phone can't close one pane,** so panes a session opens there accumulate until the session closes them, the tab ends, or the user takes the tab back on a Mac.

## User Stories

1. As the user following a session from the phone, I want it to open Scratch, a page, a file, a shell or a helper beside itself, so that its work comes to me in the tab's switcher.
2. As the user on the phone, I want a Claude or terminal pane the session opened to be mine to open and type into, with no Take over.
3. As the user on the phone, I want the pane I'm looking at to stay on screen when the session opens another.
4. As the user, I want End from the phone to end a tab it made, panes the session added included, as before.
5. As the user, I want the session never to close a pane I have open on the phone right now.
6. As the user controlling a tab from another Mac, I want the session's panes to appear in my layout without moving my focus.
7. As the user back at the Mac, I want the panes the session opened in their place when I take the tab back.

## Implementation Decisions

- **The sibling** is the Mac's answer to a split from the machine in control: the label for that machine, the tab's origin, the start at once, the control test over the tab's running panes. The rest is option 01's opening and closing.
- **The router** lets the pane tools past the calling-pane rule when the caller's only fault is being controlled from elsewhere, on this Mac's own tab. Screen access and Panel access's other tools keep the rule they share, unchanged (ADR 0031: shared, not copied).
- **The control test** reads the labels of the tab's running panes off the main actor, as the host's split check does. That puts an await between the checks and the change, which option 01 had none of. After the read, the calling pane, the tab, the hidden tab and the labels' answer are checked again on the main actor before anything is added.
- **The tab's lock** stays for the user's own changes on this Mac (split keys, dividers, renames). The tools skip it only after the control test names one machine.
- **Closing** ends the pane as the controller's close does. A Claude or terminal pane's client count comes from its session's status at the call.
- **No saved state** beyond option 01's: `openedBy` and the record's origin are saved as now.
- **The log** as option 01's, plus whether the tab was controlled from elsewhere; never the controller's name or id.
- **Docs:**
  - ADR 0034: a dated amendment to "only the machine in control changes the layout": a session in the tab adds and closes panes for that machine, labelled for it.
  - ADR 0031: its amendment's "this Mac's own tabs only" line.
  - where-it-breaks: Panel access (the router's exception, the await and the re-check) and The tab view on the phone (panes appear from the session).
  - The tool descriptions: a pane opened in a tab another machine controls shows there.

## Testing Decisions

- **No test target yet.** Where tests would go: the control test (one machine, mixed, none) and `pane_close`'s rule with a client attached.
- **Build:** `make build`.
- **By hand, after the user restarts Varnick:**
  - Take a tab over on the phone. In its Claude session, open each kind: the phone's switcher gains each within about 5 s and keeps the pane shown. A terminal and a helper open at a tap with no Take over; Scratch and a local page are framed once the proxy has looked; a file shows its text. On the Mac the tab shows cards for the new Claude and terminal panes.
  - End from the phone on a tab the phone made ends it whole, opened panes included.
  - `pane_close` closes an opened pane the phone isn't showing, and is refused for the one it shows.
  - With another Mac in control: the panes appear in its layout, focus unchanged; a divider dragged there afterwards holds.
  - Take the tab back on the Mac: every pane is there and live. `pane_close` still works there for an opened pane not used since.

## Out of Scope

- A headless host's sessions, and a session in a tab of another machine shown here (option 02).
- Closing one pane from the phone.
- Lifting the refusal for Panel access's other tools in a controlled tab (`panel`, `board_read` and `pane_read` are lifted, see the decision below; `show`, `keys` and the Outline stay refused).
- Telling the controller at once rather than at its next listing: it would need a request the host sends, which it never does.

## Further Notes

- **Verified in the code at b3e7356:**
  - The refusal comes from the calling-pane rule Screen access and Panel access share, before the pane tools are reached. The pane tools also check the tab's lock, which on this Mac's own tab is "Take over to change this tab." while any pane shows the card.
  - The Mac's answer to a split from the controller labels the new pane for it, gives it the tab's origin, starts it at once and adds it without moving focus. The host's client lets go about 1.5 s after the label names another machine.
  - A listed tab's control is empty when its running panes name different machines. The phone's Add pane, Restart and End then go, so an unlabelled new pane would cost the phone the tab.
  - The host's End of a tab ends it only if every running pane's origin names the asker, else it hands every pane back.
  - The phone asks for the tab every 5 s while visible and keeps the pane shown unless it is gone. A Mac in control adds listed panes and keeps its focus. While a change of its own is pending, the Mac in control believes no listing.
  - The host refuses an arrangement that doesn't hold the tab's panes.
  - Closing a card on the host asks on the card first; the controller's close ends it with no question.
  - `skippedAtStart` is set by every real start, a restart from the phone included, so the permission cap holds for a session restarted there.
- **Inferred, not tested:**
  - A helper labelled for the phone sends its notices to the phone, as pushes go to the machine in control.
  - The divider that snaps back.
  - A session already running needs no restart, since the refusal is the app's and the tools' request is unchanged.
- **Unverified race:** a Take over by another machine at the moment a pane is made can leave the new pane labelled for the old controller. The tab then has no control, and a second Take over mends it, since it relabels every running pane.
- **Covers part of option 02:** that option's first bullet, a tab another machine controls on a Mac. Option 02 stays proposed for the headless host.
- **Open decisions, each with the recommendation first:**
  - **`pane_close` while the controller has the pane open.** Recommended: refused while a client is attached to its session. On the phone that is the pane shown. A Mac in control attaches every Claude and terminal pane of the tab once it takes it (ADR 0034), so there those are closed by the user's own close key, and pages, apps and files by the session. Else: option 01's rule alone, so a session may close the pane the user is looking at on the phone. **Decided 2026-10-17: the recommendation.**
  - **`pane_read` and `board_read` in a controlled tab.** Recommended: leave them refused in this option, as the user asked about opening. Lifting them is a small follow-up, and would let a session read the helper it opened while the phone controls the tab. `panel`, `show`, `keys` and the Outline act on or describe the Mac's screen, which nobody at the phone sees, and stay refused either way. **Decided 2026-10-17, against the recommendation (the user wants sessions unlimited): the refusal is lifted for `pane_read`, `board_read` and `panel` in a tab of this Mac that another machine controls. `show`, `keys`, the Outline's tools and the screen tools keep it; nothing that sends keys to a pane changes.**
