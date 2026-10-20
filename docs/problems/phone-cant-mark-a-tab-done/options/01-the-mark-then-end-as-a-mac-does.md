---
problem: phone-cant-mark-a-tab-done
title: The phone's Done is a Mac's Done on another machine's tab, the mark and then End
summary: In a tab the phone controls, Done sits in the tab view's header bar beside End and always asks first. The host marks the tab done, and then the tab is ended as End ends it. A tab the phone made ends and goes to Completed. Any other tab is handed back to its host, keeps running there and shows in Completed as still open. The relay and a Mac's Varnick start letting a listed device send `done`, which they refuse today. The request itself is unchanged, so there is no protocol bump and only the host serving the page needs the new build. The phone's Home says Done on a marked tab that still runs. The Macs learn of it as they learn of any mark.
status: rejected
reason: On 2026-10-20 the user chose Done that closes the tab on its host whoever started it, from any device (option 03), relayed by the coordinator, in his words “just provide done globally … i control all these devices, im the one that opens, creates, marks done. there is no someone else today.” This option keeps handing back a tab the asker didn't start.
---

## Solution

**The button.** Done goes in the tab view's header bar, just left of End, and shows exactly when End shows: over a terminal or a note, in a tab the phone controls. It always asks first, in the page's own dialog: "Done with “<tab>”? It goes to Completed. A tab this phone started ends. Any other is handed back to <host> and keeps running there." The dialog's buttons are Cancel and Done.

**The route.** `POST /api/done` takes the tab and nothing else. The page server does four things:
- It checks the tab is listed and that this phone controls it, the gate Add pane and Restart use.
- It sends the host's relay `done` for the tab, as this device.
- It then sends `end` for the tab, as End does.
- It answers with what the host did. If the tab ended, the answer is "Done". If it was handed back, the answer is "Done. Handed back to <host>, still running". If the host refuses the `done`, nothing more is sent and the page says why. If the `end` is refused after the mark, the page says "Marked done, but it couldn't be ended: <the host's words>".

The page then leaves the tab and shows the answer on Home, as End does.

**On a Mac host.**
- The `done` marks the open tab.
- If the phone made the tab, the `end` ends it. Because the tab is marked as its panes close, it goes to Completed and Recent, not to an ended card.
- If the tab was made at the Mac, the `end` hands it back. Its panes go live on the Mac again, and the board there shows it as a Completed card, "Still open here". Closing it later on the Mac keeps it in Completed.

**On a headless host.**
- The `done` marks the tab's records.
- If the phone made the tab, the `end` ends it, and the ended records keep their mark, so Recent lists the tab closed and marked.
- Otherwise the tab is handed back. It runs on with its clients detached, still labelled for the phone, and stays marked.

**Who may send `done`.** A listed device may now send it, as a listed Mac can. Two places change: the relay on both kinds of host, and a Mac's Varnick. The page server sends it only for a tab the phone controls, as it does with `apps` and `files` for Add pane, and it never sends a clear.

**What the phone shows.** The relay stops leaving out a tab's mark for a device in `tabs`. Home's row for a marked tab that still runs says "Done" under its control line, and the tab opens as before.

**How the Macs find out.** Nothing new is needed:
- **The host Mac:** at once, from its own `done` and `end`.
- **Another Mac showing the tab:** if the tab ended, its panes' sessions go, and it asks the host's Recent at once. Recent lists the tab closed and marked, so it goes into Completed, not Stopped. If the tab was handed back, the host's next listing marks it, within about 5 s, and the Mac shows a Completed card, "Still open on <host>".
- **A Mac with only a board card:** an ended tab reaches Completed at that Mac's next board open or panel show. A handed-back one reaches it through the listing while the board shows.

## Trade-offs

- **It is the rule Macs already follow.** The phone's Done does to a host's tab exactly what a Mac in control does to another machine's tab. ADR 0032 changes in one line, and ADR 0034 not at all.
- **No protocol bump.** No request or reply changes shape. An older host refuses a device's `done` as unlisted, so a mismatch shows as an error rather than a misread. The page server only ever asks its own host, which runs the same commit.
- **It doesn't close a tab started at a Mac, which is the usual case.** Done there is End plus the mark. The tab leaves Running and Stopped, but its Claude sessions and terminals run on until the user closes it at the Mac. On a headless host they run on with nobody attached. Only the Mac that started the tab can end it, after taking it over. The phone's End and Done just hand it back again.
- **Two requests, not one.** If the `end` fails after the mark, the tab is marked and still the phone's. The page says so, and a second Done sends both again. Marking twice changes nothing.
- **It lets a device send a mark.** A mark ends nothing, and a device could already end its own tabs and close panes.
- **The header bar gets crowded.** Over a Claude pane the phone controls it would hold four text buttons (see the open decisions).

## User Stories

1. As the user on my phone, I want to mark a tab I've finished Done, so that it leaves Running and Stopped on every Mac's board.
2. As the user on my phone, I want a tab I started from the phone to close when I mark it Done.
3. As the user on my phone, I want Done to ask first, since a tap can't be undone from the phone.
4. As the user on my phone, I want to be told whether the tab ended or is still running on its host.
5. As the user at a Mac, I want a tab I marked Done from the phone to be in Completed when I'm back.
6. As the user on my phone, I want Home to show which open tabs I've already marked Done.

## Implementation Decisions

- **The sibling** is a Mac's Done on another machine's tab it controls: one `end` for the tab and one `done`. The route and button copy the phone's Restart: the gates of Add pane, a question in the page's dialog, and a failure told in the page's alert when the bar is too narrow for it.
- **The order is `done` first, then `end`.** On a Mac host a tab already marked as its panes close goes straight to Completed. In the other order its panes close unmarked and it would be an ended card in Stopped until the `done` arrives, about a second later (read in the code, not tried). On a headless host both orders end the same, since the mark stays on ended records.
- **The question is always asked,** whatever the turn, as End, Close and Restart ask on the page. The page doesn't know the turn, and a Mac's Done asks only while a session works.
- **The relay** keeps leaving out work links and other controllers' ids for a device. It stops leaving out only the tab's mark in `tabs`. Recent's marks stay hidden, since the page draws no Completed.
- **No saved state changes.** `sessions.json`, the headless host's records and UserDefaults keep their shape.
- **Docs, once accepted:**
  - ADR 0032: a listed device may send `done`, and the page server sends it only for a tab the phone controls.
  - where-it-breaks › Peers: drop `done` from the list of requests for Macs alone. › The tab view on the phone: Done.
  - CONTEXT.md: the Phone page entry, and Completed in the Session board entry.
  - The guide's Phone page section.

## Testing Decisions

- **`bun test`:**
  - The route's parser.
  - The flow against a fake relay: refused when the phone doesn't control the tab; `done` sent before `end`; no `end` after a refused `done`; the text after a refused `end`; the text for a tab handed back.
  - The shaped tab carries the mark.
- **Build:** `make build` for the Mac. The headless host builds the shared package with its installer's flags on Linux, since the relay's rule lives there.
- **By hand, after the user restarts Varnick** and reinstalls the headless host with its page, with a second Mac's board open:
  - **A tab the phone made, on a Mac host:** Done. It leaves Open tabs and is in Recent on the phone. It is in Completed on the host and, by the next board open, on the other Mac, with no ended card on either.
  - **A tab made at the Mac, taken over on the phone:** Done says it was handed back. On the host the panes are live again and the tab is a Completed card, "Still open here". On the other Mac it shows "Still open on" the host within about 5 s. Home's row says Done.
  - **The same two on the headless host,** read from a Mac's board.
  - **A tab the phone doesn't control:** no Done.
  - **Cancel in the question:** nothing changes.

## Out of Scope

- Done on Home's rows. The tab view is where a push lands and where control shows.
- Done when the phone isn't in control, as a mark alone (see the open decisions).
- Done in the single-session view (`#s=`), which has no tab.
- Taking a mark off from the phone, or a Completed list on the phone.
- A new turn taking a mark off a tab that still runs, left out by ADR 0028 as well.

## Further Notes

- **Verified in the code at 7019dd6:**
  - The relay and a Mac's Varnick refuse a device's `done`. A headless host's handler doesn't check who asked.
  - A Mac host's `done` marks an open tab on the tab itself, and the tab's close reads that mark, so the tab goes to Completed.
  - `end` for a tab ends it only when every running pane's origin is the asker. A pane started at the Mac by the user there has no origin, and Take over leaves the origin alone.
  - A headless release keeps the control label. Its ended records keep their mark, and `done` reaches ended records.
  - A Mac that showed a tab whose panes went asks the host's Recent at once.
- **Inferred, not tried:** in the opposite order (`end`, then `done`), an ended card would show on the host Mac's board for a moment. The title would be cut to a few characters at 360 px with four buttons in the bar.
- **Open decisions, each with the recommendation first:**
  - **Who may press Done.** Recommended: only a phone in control of the tab, as for End, + and Restart. Else, a Done over the live screen of a tab someone else controls, sending the mark alone, as any Mac may. That would put a tab the user is driving at a Mac into Completed under them.
  - **Where it goes.** Recommended: the header bar, left of End, with Redraw shown as an icon (its label kept for VoiceOver) so the title keeps some room at 360 px. Else, at the end of the pane switcher beside × and +, which costs the bar nothing but sits next to the × that closes one pane.
