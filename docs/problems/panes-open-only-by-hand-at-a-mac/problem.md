---
title: Only the user at a Mac adds a pane to a tab; a Claude session and the phone can't
description: A pane joins a tab only by the user's hand on a Mac (a split key, the split picker or the file tree), or by another machine in control of the tab. A Claude session in a Varnick pane can't open a terminal, a helper Claude session, Scratch, a page or a file beside itself, so it asks the user to. The Phone page starts sessions in new tabs and reopens closed ones, but can't add a pane to a tab, even one it controls.
impact: Whatever a session could lay out beside itself falls to the user, down to the Scratch skill, whose steps end by asking the user to split the pane and pick Scratch. A helper Claude session runs as a subagent or a background shell, which the user can't watch, type into or close. Away from the Mac, a second session or a terminal for the same work goes into a tab of its own.
severity: mid
evidence: The user's words of 2026-10-17, relayed by the coordinator. Code read at 11762e0 (main). The Scratch skill shipped with the catalog app, its step 4.
status: open
---

## What the user asked (2026-10-17)

1. "within a tab, i wish you had the ability to create additional panes yourself": a Claude session in a Varnick pane splits its own tab and opens a new pane in it.
2. "i wish i had the ability to create them from the phone": the Phone page adds a pane to an existing tab.

## Today

Verified in the code at 11762e0 unless marked.

**How a tab gains a pane on a Mac**
- ⌘⇧E and ⌘⇧O split the focused pane into a fresh pane of its kind, in its folder. With ⌃ the split picker asks first: Claude, Terminal, Browser, Website (while the Tasks switch is on) and the custom apps found from the focused pane's folder, Scratch among them once it is on. The file tree adds file panes. All of these act on the user's keys alone.
- A split gives the new pane half of the split pane and focuses it. A second way in adds a pane beside a given one without moving focus: a file pane stacking under the file column, and a split another machine asks of this Mac's tab.
- No limit holds on panes per tab. The minimum pane size, 220 by 110 points, applies only while a divider is dragged.
- A new Claude pane follows Varnick's Skip permissions setting unless its record says otherwise. A pane a peer asked for follows the peer's.

**What a session can do to Varnick** (ADR 0031, ADR 0023)
- Behind Panel access: `panel`, `show`, `keys`, `board_read`, `pane_read`, `outline_read` and `outline_act`. They read the panel, the board and the panes' screens, change the view and edit the Outline. None adds or closes a pane, and `show` is refused while the split picker shows.
- `keys` refuses ↩ on a prompt in the search because it would start a session, and types into no tab.
- The tools that start Claude sessions today start them out of sight. `task_run` starts a Run whose Claude steps are hidden panes; the automation tools make automations whose runs are. Both follow Varnick's Skip permissions setting. A session may not choose Skip for an automation, and a Task's Skip covers only contents the user has seen.
- In a session that doesn't skip permissions, Claude Code asks before a call to an MCP tool that isn't allowed. Varnick allows `notify` in every session for that reason.
- A pane's tools answer only a Claude pane on this Mac that no other Mac or device controls. A session on a headless host gets `notify` alone.
- The voice session is a hidden Claude pane in Home, started with permissions skipped, with a pane's full set of tools plus `search` (ADR 0042).
- Scratch serves the area of the pane it was split from. Its skill tells Claude to ask the user to split from the picker and choose Scratch.

**How another machine adds a pane** (ADR 0034)
- A tab lives on its host. Only the machine in control of it, the one every running Claude and terminal pane of it names, changes its layout, and the host checks that.
- A split from another Mac is a `start` naming the tab, the pane split and the axis. A Mac host starts Claude, a terminal, a page or a custom app; a headless host starts Claude and terminals. The new pane starts beside the split pane, in its folder, labelled for the asker, with the tab's origin.
- The relay, a Mac host and a headless host already take that `start` from a listed device in control, as from a Mac: protocol 30 has every field, and nothing in it is for Macs alone. `apps` (what the picker lists for another machine's tab) and `arrange` (dividers and the name) are for Macs alone.
- The Phone page's New session sends a folder, an agent and a prompt, which makes a new tab. The page server never sends `skipPermissions`, so the host's own setting applies. The page can't start a terminal.
- The phone shows a tab one pane at a time with a switcher, and asks for it every 5 s. It offers Take over on a tab it doesn't control, and End for the whole tab. A Mac showing another machine's tab picks up a pane the host added at its next listing.

## Where it fails

- **A session lays nothing out for the user.** To show a page, a file, Scratch or a shell beside itself, Claude has to ask the user to split and pick.
- **Helpers are invisible.** A session that wants a second Claude working beside it starts a subagent or a background shell. `orchestration-lives-in-one-session` option 04 needs a session to open a Claude pane with a prompt, and names a "scriptable panes" problem that was never written. This problem is its first half: opening the pane. Learning when the helper is waiting or done is option 04's.
- **The phone only makes tabs.** Away from the Mac, related work spreads over tabs, and Take over moves each one separately.
