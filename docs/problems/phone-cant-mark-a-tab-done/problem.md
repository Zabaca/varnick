---
title: The phone can't mark a tab Done
description: Done is how a tab leaves the session board. On a Mac it closes every pane of the tab and puts it in Completed, and every paired Mac's board follows through the tab's host. The Phone page has End but no Done, and the relay refuses a `done` request from a device. A tab the user finished from the phone stays on every board as Running or Stopped until the user marks it Done at a Mac.
impact: Finished work stays on the boards. A tab the phone started and then ended becomes an ended card in Stopped on every Mac. A tab started at a Mac and ended from the phone is handed back and keeps running on its host, with its Claude sessions and terminals. Either way the user has to mark it again at a Mac, and on a headless host a handed-back tab runs on with nobody attached.
severity: low
evidence: The user's words of 2026-10-20, relayed by the coordinator ("can we allow completion of a tab from the phone"). Code read at 7019dd6 (main).
status: closed
---

## What the user asked (2026-10-20)

"can we allow completion of a tab from the phone". This problem reads it as Done from the Phone page, the same Done a Mac gives a tab: the tab goes to the board's Completed column and its panes close. The other reading, completion with the Tab key in a terminal, already works: the phone's key row has a Tab key.

## Today

Verified in the code at 7019dd6 unless marked.

**Done on a Mac** (ADR 0032)
- **On a tab of that Mac:** Done closes every pane of the tab: Claude sessions, terminals, pages, apps and files. The tab goes to Completed once its last pane has closed, and to Recent. Done asks first only while a Claude session of the tab is working or has background work.
- **On another machine's tab that the Mac shows:** the Mac closes its own copy. If it is in control, it sends one `end` for the tab, and then a `done` to the host, which marks the tab. If it isn't in control it sends only the `done`.
- **On a board card of another machine's tab with no copy on this Mac:** only the `done`.
- **On the host:** a marked tab that has ended goes to Completed. A marked tab that is still open is a Completed card there ("Still open here") and keeps running. Other Macs show it as Completed, "Still open on" the host.

**The `done` request**
- It names a tab, marks it or takes the mark off, and ends nothing.
- Any Mac the host lists may send it. A device may not, and two places refuse it: the relay, on both kinds of host, and on a Mac host the running Varnick as well. A headless host's own handler doesn't check who asked.
- The device rule came from `done-marks-stay-on-one-mac` option 01, which gave "the Phone page has no board" as its reason.

**What `end` does to a tab** (ADR 0034)
- The host takes `end` for a tab only from the machine in control of it.
- If every running pane's origin is the asker, the host ends the tab. Otherwise it hands every pane back.
- A pane started at a Mac by the user there has no origin. Only a pane started for another machine names it, and Take over changes who is in control, not the origin. So the phone's End ends a tab only if the phone made it: a New session from the phone, or a tab it reopened from Recent. Every other tab is handed back.
- On a Mac host a handed-back tab goes live there again. On a headless host it keeps running with its clients detached, still labelled for the phone.
- Closing one pane (× on the phone, ⌘W in a tab a Mac controls) ends that pane on the host, whoever started it. Closing the tab's last pane is handled as `end` for the tab.

**The Phone page**
- The tab view's header bar holds ←, the title (cut short with an ellipsis), Redraw, Restart (over a Claude pane the phone controls) and End.
- End shows only while the phone controls the tab, over a terminal or a note. It always asks first in the page's own dialog, and so do Close and Restart. Afterwards the page goes home and shows what the host did: "Ended", or "Handed back to …, still running".
- The page never sees a mark. The relay leaves the tab's mark out of `tabs`, and the marks out of Recent, for a device.
- The page doesn't know a session's turn: the page server leaves it out of what it sends the page.

**How a Mac learns of a mark made at the host**
- **An open tab:** from the `tabs` listing it already asks for, about every 5 s while the tab or the board shows.
- **A closed tab:** from the host's Recent. A Mac asks for Recent when the board opens or the panel shows. A Mac that showed the tab asks at once when the tab's panes go.

## Where it fails

- **There is no Done on the phone.** The board's Completed column can only be reached from a Mac.
- **End from the phone takes nothing off the board.** A tab the phone made, once ended, is an ended card in Stopped on every Mac: only Done takes a tab off the board. A tab made at a Mac is handed back and stays in Running or Stopped.
- **A finished tab on a headless host runs on.** If a Mac started it and the phone ended it, it keeps its Claude sessions and terminals running with nobody attached, until someone takes it over from that Mac and closes it.
