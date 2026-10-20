---
problem: phone-cant-mark-a-tab-done
title: The phone's Done closes the tab on its host, as Done there would
summary: Recommended. In a tab the phone controls, Done sits in the tab view's header bar beside End and always asks first. Then the host closes the whole tab as its own Done does, whoever started it. Every pane ends, terminals and pages included, and the tab goes to Completed and Recent there, so every paired Mac's board shows it Completed. It is one request, `end` for the tab carrying the mark, and the host takes it only from the machine in control. That gives `end` a new meaning, so it needs protocol 33. Without the mark, `end` and the phone's End are unchanged, and so is a Mac's Done. The Macs learn of it through the listing and Recent they already ask for.
status: proposed
---

## Solution

**The button.** Done goes in the tab view's header bar, just left of End, and shows exactly when End shows: over a terminal or a note, in a tab the phone controls. It always asks first, in the page's own dialog: "Done with “<tab>”? Every pane of it ends on <host>, terminals and pages included, and it goes to Completed." The dialog's buttons are Cancel and Done.

**The route.** `POST /api/done` takes the tab and nothing else. The page server does three things:
- It checks the tab is listed and that this phone controls it, the gate Add pane and Restart use.
- It sends the host's relay `end` naming the tab, with the mark, as this device.
- It answers "Done", or the host's refusal.

The page then leaves the tab and shows the answer on Home, as End does.

**The request.** `end` naming a tab, with the mark set, means "Done, from the machine in control":
- **The check:** the host refuses it unless every running Claude and terminal pane of the tab names the asker as in control. This is the check `end` makes today.
- **On a Mac host:** the tab closes as Done on that Mac closes it, whoever started it. Every pane ends, and the tab goes to Completed once the last pane has closed, and to Recent. The Mac doesn't ask its own question, even while a session works: the phone asked.
- **On a headless host:** every record of the tab is ended and its session killed, with the mark set on each, in one write. Recent lists the tab closed and marked.
- **Without the mark,** `end` is unchanged. End on the phone still ends what the phone made and hands back the rest.

**Who may.** Only the device in control of the tab, and the host checks it. A device's `done` stays refused: its Done reaches the host as this `end`.

**How the Macs find out.** Nothing new is needed:
- **The host Mac:** at once, from its own Done.
- **Another Mac showing the tab:** its panes' sessions go, and it asks the host's Recent at once. Recent lists the tab closed and marked, so it goes into Completed, not Stopped.
- **A Mac with only a board card:** at its next board open or panel show, from the host's Recent.
- **A headless host's tab** reaches every Mac the same way.

**Undo.** Resume in the phone's Recent reopens the tab whole for the phone. The host takes the mark off, as it does for any reopen.

## Trade-offs

- **It does what was asked, whoever started the tab.** The tab leaves every board for Completed, and its panes close. This is the usual case: a tab started at a Mac and finished from the phone.
- **One request.** The host marks the tab only if it closes it, so a refusal leaves nothing changed, and a lost answer can be asked again. A second ask finds the tab gone and succeeds.
- **No finished tab runs on, on a headless host.**
- **It follows the user's ⌘W ruling of 2026-10-12** (ADR 0034): in a tab the machine in control holds, closing a pane acts as it would on the host. Done is the tab's own action, and here it acts as Done on the host.
- **Protocol 33.** Every Mac, the headless host and each Phone page must run one commit, through Upgrade all. Without the bump, a page server started from new files in front of a Varnick not yet restarted would hand the tab back and mark nothing.
- **The phone's Done ends more than a Mac's.** A Mac in control of another machine's tab still hands back, on Done, whatever it didn't start (see the open decisions).
- **It ends work started at the Mac,** terminals and dev servers included, as Done on the Mac does. The switcher lists every pane, and the question says so.
- **It amends a cross-machine rule.** ADR 0034's `end` for a tab gains the case with the mark. The change is narrow: without the mark nothing differs.

## User Stories

1. As the user on my phone, I want to mark a tab I've finished Done, so that it leaves Running and Stopped on every Mac's board.
2. As the user on my phone, I want Done to close the tab on its host even when I started it at the Mac, so that nothing of it keeps running there.
3. As the user on my phone, I want Done to ask first and say that every pane ends, since a tap is easy to make by mistake.
4. As the user at a Mac, I want a tab I marked Done from the phone to be in Completed when I'm back, not in Stopped.
5. As the user on my phone, I want to get a tab back from Recent if I marked it Done by mistake.
6. As the user with a headless host, I want a tab I mark Done from the phone to stop running there.

## Implementation Decisions

- **The siblings.** On the host, Done on the Mac's own tab: the tab is kept as it was, marked as a Done, its panes close and it goes to Completed at the last close. Also the host's `end` for a tab, for the control check and for ending every pane without asking. On the page, the phone's Restart: the gates of Add pane, a question in the page's dialog, and a failure told in the page's alert when the bar is too narrow for it.
- **The mark is the `mark` field the `done` request already carries.** `end` hasn't read it until now. No new field is added.
- **The question is always asked,** whatever the turn, as End, Close and Restart ask on the page. The page doesn't know the turn, and the host's own question is skipped.
- **The headless write is one.** The records end and take the mark in one write under the state lock, so a reconcile in between can't list the tab closed without its mark.
- **The protocol goes to 33** in the shared package and in the page server's copy.
- **No saved state changes.** `sessions.json`, the headless host's records and UserDefaults keep their shape.
- **Docs, once accepted:**
  - An amendment to ADR 0034: `end` for a tab with the mark.
  - ADR 0032: Done reaches a host from a device in control this way, and a device's `done` is still refused.
  - CONTEXT.md: the Phone page entry, and Completed in the Session board entry.
  - where-it-breaks › The tab view on the phone, and › Peers for `end`.
  - The guide's Phone page section.

## Testing Decisions

- **`bun test`:** the route's parser, and the flow against a fake relay: refused when the phone doesn't control the tab, one `end` with the mark, and the host's refusal passed on. The protocol constant.
- **Build:** `make build` for the Mac. The headless host builds with its installer's flags on Linux.
- **By hand, after the user restarts Varnick** on each Mac and reinstalls the headless host with its page, with a second Mac's board open:
  - **A tab made at the Mac, taken over on the phone, with a Claude pane and a terminal:** Done. On the host both panes end and the tab is in Completed and Recent, with no ended card. On the other Mac it is in Completed once it asks the host's Recent, at once if it showed the tab. It leaves Open tabs on the phone and is in its Recent.
  - **A tab the phone made:** the same.
  - **On the headless host:** the same, read from a Mac's board, and its sessions are gone from zmx there.
  - **A Mac takes the tab over just before Done:** refused, and nothing is marked.
  - **Resume from the phone's Recent:** the tab comes back for the phone and leaves Completed on the Macs.
  - **End on a tab made at the Mac:** still handed back.

## Out of Scope

- A Mac in control sending the same Done (see the open decisions).
- Done on Home's rows. The tab view is where a push lands and where control shows.
- Done when the phone isn't in control.
- Done in the single-session view (`#s=`), which has no tab.
- Showing marks on the phone, or a Completed list there.

## Further Notes

- **Verified in the code at 7019dd6:**
  - `end` for a tab is refused unless the asker controls every running pane, on both kinds of host, and the relay already passes it from a device.
  - Today a Mac host ends such a tab without asking, through every pane, Claude or not.
  - A Mac's Done keeps the tab as it was, marked, so its last close puts it in Completed and Recent.
  - The headless `done` marks ended records too. A Mac that showed a tab whose panes went asks the host's Recent at once. A reopen takes the mark off.
  - `PeerProtocol.version` is 32 on main.
- **Inferred, not tried:** the title would be cut to a few characters at 360 px with four buttons in the bar. A Mac's page server can restart from newer files while the running Varnick is older, since the runner compares the files' digest; that is the misread the bump turns into a refusal.
- **Open decisions, each with the recommendation first:**
  - **Whether Done ends a tab the phone didn't start.** Recommended: yes, this option. Else option 01, which keeps the rule that a machine ends only what it started and hands back the rest.
  - **A Mac in control doing the same.** Recommended: not in this option. It would change what a Mac's Done does to another Mac's tab, which `done-marks-stay-on-one-mac` option 01 left out of scope. If wanted, it rides on the same request and bump.
  - **Where it goes.** Recommended: the header bar, left of End, with Redraw shown as an icon (its label kept for VoiceOver) so the title keeps some room at 360 px. Else, at the end of the pane switcher beside × and +, which costs the bar nothing but sits next to the × that closes one pane.
  - **Who may press Done.** Recommended: only a phone in control of the tab, which the host requires for an end anyway. A mark alone from a phone watching someone else's tab would put a tab the user is driving at a Mac into Completed under them.
