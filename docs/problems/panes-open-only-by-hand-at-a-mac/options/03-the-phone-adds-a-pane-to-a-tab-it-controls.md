---
problem: panes-open-only-by-hand-at-a-mac
title: The phone adds a Claude session or a terminal beside the pane it shows, in a tab it controls
summary: An Add pane button at the end of the tab's switcher, there while the phone is in control of the tab, opens a small form: Claude, with the folder's agents and a prompt as New session has them, or Terminal. The page server sends the host the `start` a Mac sends for a split, naming the tab, the pane shown and side by side. Protocol 30 has every field, and Mac and headless hosts already take it from a device in control, so there is no bump and no change to either host. The new pane becomes a switcher button and shows at once; on the host it sits beside that pane.
status: proposed
---

## Solution

**The button.** A + at the end of the tab view's switcher, also on a tab of one pane, which today has no switcher. It shows only while the phone is in control of the tab. On a tab the phone doesn't control, the page offers Take over as now, and the + appears once it has taken over.

**The form.** Two choices:
- **Claude:** the agents of the shown pane's folder as chips, and a prompt box with New session's limits. An empty prompt is allowed, as on a Mac.
- **Terminal:** nothing to fill in.

**The request.** A new `POST /api/split` carrying the tab, the pane shown, the kind, and for Claude the agent and the prompt. It has its own parser, so New session's keeps reading only its three fields. The server:
- picks the session id, and never sends `skipPermissions`, so the host's setting applies as for New session;
- asks the host for the tab, and refuses unless the tab is listed, the phone is in control of it, and the pane is one of its panes;
- checks an agent against the agents of that pane's folder;
- sends `start` with the tab, the pane, side by side and the kind, and no folder: the host takes the split pane's;
- waits and checks as a start does: the same timeout, and before it reports a failure it asks whether the session is running, so a second tap makes no duplicate.

**Showing it.** The page opens the new pane with take, once, as after a start, and the switcher gains its button. On a narrow screen nothing changes shape: the tab still shows one pane at a time.

**On the host.** A Mac host adds the pane beside the pane the phone showed, side by side, labelled for the phone; the Mac shows it as a card controlled by the phone until it takes the tab back. A headless host does the same for Claude and terminals.

## Trade-offs

- **Cheap:** the page and its server only. Both hosts already split a tab for a device in control, so neither changes, and no protocol bump.
- **Keeps ADR 0034:** only the machine in control changes the tab, and Take over stays its own press, since it takes the tab from the Mac.
- **The phone must be in control first.** A tab the user left on the Mac needs Take over before Add pane, which detaches the Mac.
- **No choice of place.** The Mac's layout gets the new pane beside the one the phone showed, halving it.
- **Claude and terminals only.** A page or an app needs `apps` opened to devices and the port proxy; a file needs the tree.
- **A terminal on a phone** has the soft keyboard's limits, as any terminal on the page does.

## User Stories

1. As the user on my phone, I want to add a Claude session to a tab I'm working in, with an agent and a prompt, so that related work stays in one tab.
2. As the user on my phone, I want to add a terminal beside a session, so that I can run something next to it.
3. As the user, I want the new pane to open at once in the tab's switcher, so that I can use it straight away.
4. As the user, I want Add pane only where my phone is in control, so that I never change a tab under someone at the Mac.
5. As the user back at the Mac, I want the pane my phone added beside the one I was looking at, so that the layout makes sense when I take the tab back.
6. As the user, I want this to work on my headless host as on a Mac.

## Implementation Decisions

- **The sibling** is New session's start (the server picks the id, sends no `skipPermissions`, checks before it sends, and asks `status` after a failed or slow answer) with a Mac's split of another machine's tab (`start` naming the tab, the pane and the axis).
- **The agents** of a pane's folder: New session asks only for a listed project's, and a pane's folder may be a worktree or Home, which isn't one. The server takes the folder from the tab's listing, never from the page, and asks the host for its agents.
- **The control check** is the page server's for the button and the error; the host's check, which every split already has, is the one that holds.
- **No saved state.** The page keeps no new value; the host saves the pane as any split.
- **Docs:** where-it-breaks › The tab view on the phone and › Starting and resuming on the phone, ADR 0034's bullet on the phone (the phone splits a tab it controls), and the guide.

## Testing Decisions

- **`bun test`:** the new parser (what it reads, what it refuses), the flow against a fake relay (a tab not listed, not in control, a pane not of the tab, an unknown agent, a lost answer with the session running), and the tab rules for the button.
- **Build:** `make build` for the page server's copy in the app.
- **By hand, after the user restarts Varnick:** on a Mac host, take over a tab on the phone, add Claude with a prompt and a terminal; each opens on the phone and works; on the Mac they sit beside the pane the phone showed. On a tab the phone doesn't control there is no +. The same on a headless host.

## Out of Scope

- Pages, custom apps and files from the phone.
- Closing one pane of a tab from the phone: End closes the tab or hands it back, though both hosts take an `end` of one pane.
- Showing panes side by side on the phone.

## Further Notes

- **Verified in the code at 11762e0:** the relay forwards `start` from a listed device, and the Mac and the headless host each take one naming a tab, a pane and an axis when every running pane of the tab names the asker; the phone's tab listing carries each pane's folder and agent; `apps` and `arrange` are refused to devices; End names a tab or a session.
- **Verified on a Mac host, inferred on a headless one:** the reply to a split names the tab, as for a start, so the page opens the new pane from it.
- **Open questions,** the recommendation first:
  1. **Kinds.** Recommended: Claude and terminal. Otherwise also a page and a custom app on a Mac host, which needs `apps` for devices (a rule of the relay's, not a change of shape) and frames them through the port proxy as the tab view does now.
  2. **Control.** Recommended: only on a tab the phone controls, Take over its own press. Otherwise a + on every tab that takes the tab over first, after a sentence saying it does.
  3. **Placement on the host.** Recommended: side by side beside the pane the phone showed. Otherwise stacked, or chosen by that pane's shape.
  4. **Protocol.** Recommended: no bump; protocol 30 has every field. A page or an app later would stay protocol 30 too (inferred).
  5. **Headless host.** Recommended: yes, for Claude and terminals, as it splits for a Mac.
