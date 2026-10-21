---
problem: phone-cant-mark-a-tab-done
title: Done from any device or Mac closes the tab on its host, whoever controls it or started it
summary: Accepted by the user on 2026-10-20 (relayed by the coordinator). It takes option 02's shape and makes Done global. Any of the user's devices or paired Macs can mark any tab Done. The host then closes the tab as its own Done does, so every pane ends, and the tab goes to Completed and Recent there and on every board. There is no control gate and no origin rule. A `done` request now closes an open tab instead of marking it, and devices may send it. A Mac's Done on another machine's tab becomes the same one request, replacing today's end-then-done that hands the tab back as "Still open here", and the mark on an open tab goes. On the phone the tab view's header bar shows the title, a menu button and End, and Done, Redraw and Restart move into the menu. Protocol 33, with every Mac and the headless host updated together.
status: accepted
---

## Solution

**The user's choice (2026-10-20, relayed by the coordinator).** "just provide done globally. before i thought there would be contention over owner but its all me, one user. i control all these devices, im the one that opens, creates, marks done. there is no someone else today." On placement: "i think we need a hamburger. we can show hamburger, and end. done, redraw, restart in the hamburger."

**What Done does.** Done names a tab. The tab's host closes it as Done on that host closes it:
- Every pane of the tab ends: Claude sessions, terminals, pages, apps and files.
- The tab goes to Completed once its last pane has closed, and to Recent.
- The host doesn't ask its own question: the device that pressed Done asked.
- This holds whoever controls the tab, whoever started it, and whether the asker is in control or not.

**The `done` request.**
- **Who may send it:** any Mac or device the host lists.
- **On a Mac host:**
  - An open tab of the host that has a Claude pane is closed as above.
  - A closed tab is marked, as today: from its ended card or Recent into Completed.
- **On a headless host:**
  - The open records of the tab are ended, their sessions killed and their mark set, in one write.
  - Closed records are marked, as today.
- **The clear** (the mark taken off) keeps its meaning, for closed tabs. An open tab carries no mark any more.
- **A tab the host doesn't have** is refused, as today.

**On the phone.**
- **The header bar** of the tab view holds ←, the title, a menu button and End.
  - The menu button shows whenever its menu has an item.
  - End stays in the bar, shown as today: in a tab the phone controls, over a terminal or a note.
- **The menu** holds Done, Redraw and Restart, each shown on the rule it has today or below:
  - **Done** acts on the whole tab. It is offered in the tab view of any tab that has a Claude pane, in control or not.
  - **Redraw** acts on the screen shown. It is offered over a terminal or a live screen, as now.
  - **Restart** stays per pane: it restarts the Claude pane shown. It is offered while that pane is a Claude session that runs in a tab the phone controls, as now.
- **Done always asks first,** in the page's own dialog: "Done with “<tab>”? Every pane of it ends on <host>, terminals and pages included, and it goes to Completed." The dialog's buttons are Cancel and Done.
- **The route** is `POST /api/done` with the tab. The page server sends `done` for it as this device, with the mark. It answers "Done", or the host's refusal, which the page shows in its alert dialog, since the bar is too narrow.
- **After Done** the page leaves the tab and Home shows "Done".
- **The single-session view** (`#s=`) has no tab. Its menu holds Redraw only.

**On a Mac, Done on another machine's tab.** This covers a copy of the tab here (in control or showing cards) and a board card with no copy here.
- It asks first by the Mac's own rule: while a Claude session of the tab works. A board card with no copy here asks by the same rule, from the host's listing. Today such a card doesn't ask, because it only marks.
- It sends `done` to the host and waits. While it waits, the card says it is marking the tab done on the host.
- If the host takes it, the copy here closes as a Done, sending no `end`, and the tab goes into Completed, flagged as the host's mark.
- If the host refuses, or can't be reached, nothing closes, and the card says why for a few seconds, as a failed reopen does.

**On a Mac, Done on a tab of this Mac, and on an ended card of another machine:** unchanged.

**Panes closed under another machine.** On a Mac whose copy of the tab is in control, the host ends the sessions when another device marks the tab Done. A pane on another machine whose session ends without this Mac's own close then waits for the host's Recent, as a view's pane does today. So the tab goes into Completed rather than Stopped. Today a pane in control adds its ended card at once.

**How the other Macs find out.**
- **A Mac showing the tab:** its panes' sessions go, and it asks the host's Recent at once. Recent lists the tab closed and marked, so it goes into Completed.
- **A Mac with only a board card:** at its next board open or panel show, from the host's Recent.
- **A phone showing the tab:** its next ask finds the tab gone, and it goes home saying the tab was closed on the host.

## Trade-offs

- **One rule everywhere.** Done means the same on every Mac and device: the tab is finished, and it closes where it runs.
- **It fits one user.** No device can mark a tab Done under someone else, because there is no one else. If the user ever shares a host, this is the rule to revisit.
- **A Done can end work the device can't see running,** such as a terminal, a dev server or a session mid-turn on the Mac, as Done on the Mac does. The question says every pane ends. The Mac asks while a session works, and the phone always asks.
- **A Done that can't reach its host does nothing.** Today a Mac's Done on another machine's open tab stays on that Mac as "Done on this Mac only". Now the tab stays on the board, since it still runs. An ended card's Done still falls back to this Mac only.
- **Protocol 33.** Every Mac and the headless host move together.
- **Less code.** The mark on an open tab, its listing and its "Still open here" card go.

## User Stories

1. As the user on my phone, I want to mark any tab of a host Done, whether or not the phone controls it and whoever started it, so that it closes there and leaves every board for Completed.
2. As the user at a Mac, I want Done on another Mac's or the headless host's tab to close it there, not hand it back still open.
3. As the user, I want Done to ask first and say that every pane ends.
4. As the user on my phone, I want End and a menu in the bar, with Done, Redraw and Restart in the menu, so that the title stays readable.
5. As the user on my phone, I want Restart to act on the session I'm looking at, as now.
6. As the user at a Mac, I want a tab marked Done elsewhere to land in my Completed, not in Stopped.
7. As the user, I want a Done that can't reach its host to say so and leave the tab as it was.
8. As the user, I want to get a tab back from Recent or Completed if I marked it Done by mistake.

## Implementation Decisions

- **The siblings.**
  - On a Mac host, Done on its own tab: the tab is kept as it was, marked as a Done, its panes close and it goes to Completed at the last close. Also the host's `end` for a tab, which ends every pane without asking.
  - On the phone, Restart: a route, a question in the page's dialog, and a failure told in the page's alert.
  - The menu is the page's own element, never the browser's. It closes on a choice, on a tap outside and on Escape.
- **The protocol goes to 33,** in the shared package and in the page server's copy. Two things change: `done`'s meaning, and `tabs`, which no longer carries a tab's mark.
- **Rollout.** Every Mac and the headless host run one commit. Use Upgrade all from a Mac, with the headless host reinstalled from that commit by the installer, its page included. A Mac left on 32 is refused, as at any bump. Each host's page server comes with its host's build.
- **What goes, removed in the build since nothing else uses it:**
  - **The mark on an open tab,** on a Mac host: the tab's own mark, its saved key, the "Still open here" Completed card, ↩'s branch for a marked open tab, and the read of that mark as the tab closes.
  - **The mark in `tabs`,** on both kinds of host, with everything that reads it on a Mac:
    - the host's mark on a copy of its tab;
    - the listing's rule that puts a marked open tab into Completed;
    - the board's rule that a marked listed tab is on no card;
    - the per-session copy of the mark;
    - the relay's removal of it for a device.
  - **End-then-done on another machine's tab:** Done's close of a copy through one `end` for the tab, the `done` sent after that close, and the mark alone that a board card with no copy sends. All three become the one `done` above.
  - **The device bans on `done`,** in the relay on both kinds of host and in a Mac's Varnick.
- **What stays, and what still uses it:**
  - **The clear:** ↩ on a Completed card or a Recent row of another machine's closed tab sends it before the reopen. A failed reopen then stays in Stopped, and the host's next Recent doesn't put it back in Completed.
  - **The mark on a closed tab:** Recent's marks, the host's Completed, and "Done on this Mac only" for an ended card whose host can't be reached, along with the pending and flagged marks behind that note.
  - **"Still open on <Mac>":** a Completed tab of this Mac only whose host still lists it open. This can be a mark made before this change, or a tab reopened on its host while this Mac's mark was its own.
  - **One `end` for a tab:** closing another machine's tab here with its ×, which is not Done. End on the phone, and its origin rule, are unchanged.
  - **The listing's rule that a tab listed open removes a flagged mark:** this is how a reopen on the host reaches the other Macs. It no longer needs the mark in `tabs`.
- **Saved state.**
  - A Mac's `sessions.json` keeps its shape. The mark on a saved open tab is read once and saved absent: the tab stays open, unmarked, in Running or Stopped. Marks on open panes from older files migrate to nothing, and marks in the closed lists migrate as today.
  - A headless host's records keep their shape. An open record marked before the upgrade keeps its mark and takes it to Recent when it closes. Nothing reads it while it is open.
  - No UserDefaults key changes.
- **ADRs, in the build, as ADRs 0032 and 0034 were:** a new ADR, the next free number, superseding these parts:
  - **From ADR 0032:**
    - "A `done` request … ends nothing. Any Mac the host lists may send it … A device may not."
    - The open-tab mark and its "Still open here" card.
    - The mark in the listing.
    - "A Done the host can't take … stays on this Mac only", for an open tab.
    - The consequence that a mark on an open tab reaches the boards within about 5 s.
  - **Amending ADR 0034:**
    - "only the machine in control changes it": Done from any listed Mac or device closes a tab whoever controls it.
    - `tabs` listing a tab's mark.
  - ADR 0034's `end` rule is unchanged.
- **Other docs, in the build:**
  - CONTEXT.md: Tab ("only the machine in control of it changes it"), the Session board's Completed, and Phone page.
  - where-it-breaks: Done is a tab's; the Done-marks gotchas under Peers; the device list of requests for Macs alone; The tab view on the phone.
  - The guide's Phone page section, for Done and the menu, Redraw and Restart.
  - The privacy doc's list of what a listed device can do: it can now end any tab of the host by Done.

## Testing Decisions

- **`bun test`:**
  - The route's parser.
  - The flow against a fake relay: one `done` with the mark, and the host's refusal passed on.
  - The menu's rules: which of Done, Redraw and Restart show for a tab in control, a tab not in control, a pane that isn't Claude, a tab with no Claude pane, and the single-session view.
  - The protocol constant.
- **Build:** `make build` for the Mac. The headless host builds with its installer's flags on Linux.
- **By hand, after the user upgrades every Mac and reinstalls the headless host,** with two Macs' boards open and the phone:
  - **From the phone, not in control,** on a Mac's tab started at that Mac, with a Claude pane and a terminal: Done from the menu asks, then every pane ends on the host. The tab is in Completed and Recent there with no ended card, in Completed on the other Mac, and gone from the phone's Open tabs.
  - **From the phone, in control:** the same.
  - **From a Mac, on another Mac's tab shown here in control:** both Macs show it in Completed. Neither shows "Still open here" or an ended card.
  - **From a Mac board card with no copy here,** while a session works: it asks first, then closes on the host.
  - **The headless host:** Done from the phone and from a Mac. Its sessions are gone from zmx there, and the Macs show the tab in Completed.
  - **Host asleep:** Done from a Mac on its open tab says it couldn't reach it, and nothing changes. Done on an ended card says "Done on this Mac only", as now.
  - **A Mac that saved a "Still open here" tab before the upgrade:** after the restart the tab is open and unmarked.
  - **The phone's bar** at a 360 px width shows ←, the title, the menu button and End. Redraw and Restart work from the menu, and Restart restarts the pane shown.
  - **Undo:** Resume from the phone's Recent, or ↩ on a Completed card on a Mac, reopens the tab and takes it out of Completed everywhere.

## Out of Scope

- Done on the phone's Home rows. The tab view is where a push lands.
- A Completed list on the phone, or taking a mark off from the phone.
- Sending a Done again once its host answers, as ADR 0032 left out.
- Any change to End, Take over, Close or Restart beyond moving Redraw and Restart into the menu.

## Further Notes

- **Verified in the code at 7019dd6:**
  - The mark on an open tab is set only by the host's `done` and read back from saved tabs. An older file's pane marks also migrate onto it.
  - The listing's mark is read by the host's mark on a copy, the listing's Completed rule and the board's no-card rule.
  - The clear is sent by ↩ on a marked open tab, by ↩ on a Completed card of another machine's closed tab, and by ↩ on a Recent row that carries the host's mark.
  - "Done on this Mac only" is shown for any Completed tab of another machine whose host didn't take the mark.
  - One `end` for a tab is also sent when the × closes another machine's tab here.
  - A Mac host's `end` for a tab ends every pane without asking. A headless `done` reaches ended records, and its ended records keep their mark.
  - A pane in control on another machine that ends adds its ended card at once. Only a view's pane, or a card's, waits for Recent.
  - The page's Restart acts on the pane shown, and Redraw on the screen shown.
- **Inferred, not tried:** the bar fits ←, a usable title, the menu button and End at 360 px.
- **Decided by the user on 2026-10-20 (relayed by the coordinator when the build began), each taking the recommendation:**
  - **A Done that can't reach its host:** it refuses and says why. Nothing closes and nothing is marked locally, since the tab still runs there: no "Done on this Mac only" for an open tab. An ended card's Done keeps its local fallback, as above.
  - **Done on a tab with no Claude pane** (terminals or pages only): not offered, as on the Mac today, and refused by the host if asked.
