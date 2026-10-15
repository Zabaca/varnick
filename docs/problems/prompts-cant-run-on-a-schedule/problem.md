---
title: A Claude prompt can't be set to run by itself on a schedule
description: The user wants automations, work that runs on its own on a cadence. Each one is a saved prompt that Varnick starts as a Claude session in a chosen folder, on this Mac or on the always-on headless host. It runs quietly and tells the user when it finishes or gets stuck. In Varnick today, every session starts because someone typed a prompt, opened a pane or asked from another machine. Nothing starts one by the clock.
impact: Recurring work is started by hand each time, or moved to schedulers that miss part of what the user needs. Examples are a morning summary, a nightly check of a repo, or triage every few hours. Claude Code's cloud routines can't reach the Mac, the headless host or their folders. `/loop` ends with its session. Claude Desktop's scheduled tasks run only on a Mac that is awake with the app open, and report nowhere Varnick shows: the menu bar, the phone's push, the board.
severity: mid
evidence: The user's request of 2026-10-15 and three decisions, relayed by the coordinator (below). Claude Code's scheduling limits, checked by the coordinator the same day against Claude Code's docs on routines, scheduled tasks and Desktop scheduled tasks. The permission modes from `claude --help` of Claude Code 2.1.301 on this Mac. Code and docs read at d70f766. Nothing was run, scheduled or installed, and launchd wasn't touched.
status: open
---

## What the user wants (2026-10-15)

**Automations:** work that runs on its own on a cadence. The user has decided three things. Options differ on how these are done, not on whether:

1. **What runs is a Claude prompt.** Each run starts a Claude session with a saved prompt in a chosen folder, as if the user had opened a Claude pane and typed it. Shell commands are not automations.
2. **Where it runs is chosen per automation:** this Mac, or the always-on headless host (the relay-only host of ADR 0009). Each option has to say what happens to a run that falls due while this Mac is asleep or Varnick is quit.
3. **Quiet, then tell me.** By default a run opens nothing. A list of runs, their history, lets the user open any run as a pane. A run raises a notice when it finishes or gets stuck, on the Mac and on the phone. These are the existing notices: Done, Needs you, errors, and the Message that `phone-page-is-only-a-browser-tab` option 04 shipped.

## Why this is its own problem

- **`tasks-cant-be-handed-to-varnick`** is a different thing: a Task is the website loop in a Task pane. One runs at a time, the user starts it, and it ends at a restart. `CONTEXT.md` lists "automation" under Avoid for **Task** and for **Panel access**, so this problem would take the word (see Left to decide). Scheduling a Task is out of scope here.
- **`orchestration-lives-in-one-session`** is about workflows of agents with gates, run by a lead session. Two of its options need a piece this problem also needs:
  - its option 04 needs Varnick to open a Claude pane with a prompt, an agent and a folder when something other than the user asks;
  - its option 01 needs a runner that records the sessions it starts.

  A run here is that same pane, started by a clock instead of by a lead. Whichever is built first, the other should reuse the way it opens the pane. Its open question 7, how a waiting gate reaches an absent user, is now answered by the notices.
- **`sessions-hosted-only-on-macs`** (option 01, accepted, built) is where the headless host comes from. Two of its rules stand in the way here: nothing runs on that host between requests, and every session there is started by a request from a Mac or a device and labelled for it. Automations change both rules.
- **`closed-lid-pauses-sessions`** is why a sleeping Mac runs nothing. Its option 01 (Stay awake on AC, proposed) would let a closed Mac on power keep firing runs. This problem doesn't repeat that one. Here the question is what happens to a run that falls due while the Mac sleeps.
- **`sessions-finish-unnoticed`** (option 01, shipped) and **`phone-page-is-only-a-browser-tab`** (options 02 and 04, shipped) give the notices and the push a run uses. The notice table needs no change for a run.
- **`panes-share-launchys-permissions`** matters for safety here. On a Mac, every pane gets Varnick's macOS grants: Accessibility and Screen Recording once Point at the screen is granted. So a run with a shell can read and drive the screen through those grants, without Screen access's tools. The user's rule is that agents don't drive the screen without approval each time (recorded in `tasks-cant-be-handed-to-varnick`). An unattended run is where that rule is easiest to break.

## What Claude Code already has

The table below gives the coordinator's check of Claude Code's docs, 2026-10-15. Varnick's notices reach none of these three schedulers.

| | Routines (`/schedule`) | `/loop`, CronCreate | Claude Desktop scheduled tasks |
|---|---|---|---|
| Runs on | Anthropic's cloud, or an organisation's own environment, in a fresh clone each time | the one session that set it, while that session is open and idle | the user's Mac, while the app is open and awake |
| Reaches | GitHub repos only, plus claude.ai connectors or a committed `.mcp.json`. Not the Mac, its files, or local MCP servers | that session's folder | the Mac's folders |
| Shortest interval | one hour | one minute | one minute |
| Missed runs | — | not caught up; recurring tasks expire after 7 days; up to 30 minutes of jitter | caught up once on wake |
| Permissions | none to pick: runs are autonomous, and every included connector is allowed | the session's own | not checked here |
| Result | a session at claude.ai/code. Nothing in the docs about notifications (unverified) | in the session | in the app |
| Limits | 100 scheduled runs an hour per account, 30 run-now or API fires an hour per routine, drawn from subscription usage | — | — |

**The closest is Claude Desktop's.** Varnick's version differs in three ways:

- **Where it runs.** A run can run on the headless host, which is always on and never sleeps with a lid. On this Mac it runs where the user's own folders, agents, hooks and MCP servers are.
- **How the user is told.** Varnick's own notices tell the user, on the Mac they are at or pushed to the phone when they are away (**Presence**), from either host.
- **What the run is.** A run is a Varnick session. It opens as a pane, on a Mac or on the phone, live while it runs and resumed after it ends. Session search finds its conversation like any other.

## Today

Verified in the code at d70f766 unless marked.

### Every session is started by someone

- **On a Mac,** these start a session:
  - a typed **Prompt**;
  - a split;
  - a reopen from Recent, Completed or an ended card;
  - a peer's or a device's `start` or `resume`. This is `LauncherModel.hostStart`: "a background tab with a pane of its own, started at once without being shown", labelled for the asker. It is refused while Keep sessions running is off, since the asker attaches to a zmx session.
- **On the headless host,** sessions start only through `start` from a listed Mac or device, and the session is labelled for that asker.
  - The relay's own header says "Nothing here ends a session by itself, or starts one unasked" (`HeadlessHosting.swift`).
  - The Peers rules add that "nothing is ever started behind the user's back".
- **Nothing on the headless host stays running** except the Phone page's systemd user unit, installed with `--page`. Each request is one SSH command (ADR 0009). The installer already writes a user unit and warns when linger is off.
- **Varnick starts nothing by the clock.** Its timers watch:
  - each pane, every 0.5 s;
  - the turns, once a second (`SessionNotifier`);
  - a few Settings rows.

  Nothing starts work when the Mac wakes: `PresenceReader` watches the screens sleeping and waking, for **Presence** only. Open at login is in Settings › Claude, for the installed app only.

### How claude is started

- **One command line for both hosts** (`ClaudeCommand.arguments`), in this order:
  - the MCP config;
  - the hooks' `--settings`, which also allows `notify`;
  - `--dangerously-skip-permissions` when skipping;
  - `--agent`;
  - `--session-id`, then the prompt after `--`.

  It is the interactive terminal UI in zmx. The prompt is the first message, and the first turn word is working.
- **Skip permissions** is a setting in Settings › Claude. It is on for installs that existed before it was added (`Settings.storeSkipPermissionsIfAbsent`). It is stored on each record (`record.skipPermissions ?? Settings.shared.skipPermissions`). A headless host takes the asking Mac's choice, or else its own config.
- **A Mac pane's MCP config** follows Screen access and Panel access at each start (`ScreenMCP.configuration`), and `notify` is always in it. The headless host lists `notify` alone.
- **Claude Code 2.1.301** has these permission flags (`claude --help`):
  - `--permission-mode`, which takes `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk` and `plan`;
  - `--allowedTools` and `--disallowedTools`;
  - `--permission-prompts none`, with `--print`;
  - `--no-session-persistence`, which suggests print-mode sessions are saved and can be resumed by default (inferred from that flag's help).

  The help lists only the modes' names. What `dontAsk` and `auto` do in an interactive session is unverified.
- **Print mode refuses a tool allowed nowhere, with no dialog.** In `phone-page-is-only-a-browser-tab` option 04's check (Claude Code 2.1.300), a tool allowed in neither the user's settings nor `--settings` was refused this way. Allow entries in `--settings` add to the user's own. In that check, hooks fired in a `claude -p` run.

### How the user is told

- **The table.** `NoticeRule` and its copy in the page server raise Done, Needs you, errors and Message from a pane's turn and message files.
- **Panes nobody opened still raise notices.** On a Mac, `SessionNotifier` reads such panes once a second: a pane in a tab nobody opened raises notices like any other.
- **Who gets the push.** The host's page server routes by the pane's controller (`controllerOf`, `decideRoute`):

  | Controller | Route |
  |---|---|
  | none, so the host itself | the host's own presence, which on a Mac is the user at that Mac |
  | a device | a push |
  | a Mac with no client attached | a push after the settle ("detached") |
  | a Mac with a client | that Mac's presence |
- **Labels on the headless host.** A headless session always carries a control label that names a Mac or a device.

### Where a run would show

- **Every tab shows everywhere.** A tab on a Mac appears in:
  - the strip, the session list and the board;
  - the host's `tabs` listing, which other Macs and the phone read.

  `SavedTab` and `PeerTab` have no field that would keep a tab out of sight.
- **Recent** is the newest 20 closed tabs. ↩ reopens one whole with `claude --resume`.
- **Session search** reads the transcripts and shows each conversation under the tab that holds it.
- **The launch sweep** (`cleanUpAfterLastRun`) kills Varnick's zmx sessions that no restored pane points to. A run kept outside the saved tabs would therefore die at the next launch.

### Sleep and quit

- **A sleeping Mac runs nothing**, its zmx sessions included (`closed-lid-pauses-sessions`).
- **A quit Varnick:** its zmx sessions go on, but nothing of the app runs.
- **The headless host** is always on, with linger.

## Left to decide

- **Who fires a run on each host:** the running Varnick on a Mac, a systemd timer or the page server on the headless host, or a Mac firing everything. And launchd: the user's rules keep it out of sessions, and XProtect once killed a Claude process that ran `launchctl` (ADR 0013).
- **Missed runs:** caught up once, skipped, or something in between, and over what window.
- **How a run is hosted:**
  - an interactive Claude pane in zmx, where a dialog becomes Needs you and the run waits;
  - print mode, where a dialog becomes a refusal and the run ends.
- **Permissions:**
  - which choices an automation offers;
  - its default;
  - whether the global Skip permissions ever applies to a run;
  - how Screen access, Panel access and the macOS grants panes inherit are kept away from a run nobody watches.
- **Overlap:** what happens when a run is due while the last one still works or waits on the user. Also the limits on how long a run works or waits.
- **Where automations are defined and kept:**
  - Settings;
  - a file;
  - written by a Claude session, through a tool or a file;
  - which host keeps each one.
- **How a cadence is written:** presets, cron, or both, the shortest interval, and whose time zone a headless host uses.
- **Where runs show:**
  - out of the strip, the board and Recent until opened;
  - where the history lives;
  - what the phone lists;
  - how a run ends once it is done, so finished runs don't pile up as processes.
- **The words.** **Automation** and **Run** for `CONTEXT.md`, which today lists "automation" under Avoid for Task and Panel access.
