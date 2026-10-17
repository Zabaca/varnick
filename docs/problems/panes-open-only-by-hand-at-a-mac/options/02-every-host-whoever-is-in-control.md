---
problem: panes-open-only-by-hand-at-a-mac
title: Option 01 on every host, whoever is in control of the tab
summary: The session's own host adds the pane, whichever Mac or device is in control of the tab, and a headless host's sessions get the tools too (terminal and Claude). The machine in control sees the pane at its next listing. It reaches every session the user runs, at the cost of ADR 0034's rule that only the machine in control changes a tab, and of a headless host starting a session on a session's word.
status: proposed
---

## Solution

Option 01, with two changes:

- **On a Mac, a tab another machine controls.** A call from a session whose tab another Mac or the phone controls is taken, not refused. The host adds the pane where the session asked, labelled for the machine in control, so that machine attaches to it. That machine shows the pane at its next listing of the tab, about every 5 s while it shows, on a Mac and on the phone alike.
- **On a headless host.** The relay's MCP server, which lists `notify` alone today, lists `pane_open` and `pane_close` beside it. The host adds the pane through its own `start`, in the place the session asked, labelled for the machine in control. Only terminal and Claude, since a headless host runs no browser, custom apps or files. The switch is a flag of the host's configuration, off by default, since a headless host has no Settings.

Everything else is option 01's: placement, focus, permissions capped by the caller, closing.

## Trade-offs

- **Every session can open panes,** including those on the always-on host and those the user follows from the phone, which is where long helpers would run.
- **It breaks ADR 0034's rule** that only the machine in control changes a tab's layout. A change the controller has on its way can cross the host's: while one is waiting, the controller believes no listing, so the new pane shows late (inferred from how a viewer follows its host).
- **A headless host would start a session unasked by any machine.** Today it starts nothing by itself; here a session in one of its panes does.
- **Twice the code:** the Mac's model and the headless host's state folder each add the pane, as each answers `start` today.
- **The headless switch is a file the user edits,** not a row in Settings.

## User Stories

1. As the user following a session from the phone, I want it to open a helper beside itself, so that I see both in the tab's switcher.
2. As the user, I want sessions on my always-on host to open panes as sessions on my Mac do.
3. As the user in control of a tab on another machine, I want a pane its session opened to appear in my view without my doing anything.

## Implementation Decisions

- **Labelled for the controller.** The new pane's zmx session names the machine in control, so the tab stays one machine's whole; no take over follows.
- **The host's own change** goes through the same placement as a peer's split: the new pane beside the calling pane.
- **The headless MCP server** answers in its own process, against the host's state folder under its lock, as the relay's `start` does.
- **No protocol change:** the machine in control learns of the pane from `tabs`, as now.

## Testing Decisions

- `make build`, and on a headless host its own build.
- **By hand:** a session in a tab the phone controls opens a terminal; the phone's switcher shows it within about 5 s and opens it. The same on a Mac in control of another Mac's tab. On a headless host, with the flag on, a session opens a Claude helper and the controlling Mac shows it.

## Out of Scope

- Pages, apps and files on a headless host.
- Anything option 01 leaves out.

## Further Notes

- **Verified in the code at 11762e0:** a Mac showing another machine's tab adds the panes the host's listing has and it lacks; the phone asks for a tab every 5 s while the page is visible; a headless host's split needs the asker in control and refuses pages, apps and files.
- **Inferred:** the headless MCP server can reach the host's state folder, since it is the relay's own binary on the host.
- **Not recommended now.** Worth it only once option 01 is in use and sessions on the headless host, or sessions the user follows from the phone, need helpers.
