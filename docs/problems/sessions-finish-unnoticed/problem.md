---
title: Launchy never says when a Claude session finishes or needs the user
description: Launchy knows each Claude session's turn on this Mac and on paired Macs, and shows it only on the session board. Nothing tells the user when a turn ends, when Claude stops on a permission dialog, a question, a plan or an MCP request, or when a turn dies on an API error. To find out, the user opens the panel and looks at the board or at each tab.
impact: A session that finished, or that is blocked on a dialog, sits idle until the user happens to look. The more sessions run at once, across more Macs, the longer each one waits, and a session blocked on a permission dialog does no work at all meanwhile. A turn that ended on a rate limit or an outage looks the same as one that finished.
severity: mid
evidence: The user's request of 2026-10-08, relayed by the coordinator. Code read at bf053d3 (main) on 2026-10-08. Claude Code 2.1.295, installed here, read from the strings in its binary for its notification channels, its Notification types and StopFailure's input; nothing was run. The shape of an API-error entry checked in this Mac's transcripts, field names only. cmux read at 7acf579 by an earlier research pass the same day. No notification was posted and no probe was built or run.
status: open
---

## What the user wants

To be told, without opening Launchy, when a Claude session finishes its turn or waits on them, and to get to that session in one click.

## Today

Verified in the code at bf053d3 unless marked.

### Nothing notifies

- No UserNotifications, NSUserNotification or Dock badge anywhere in `Sources/` or `Packages/`.
- Launchy has no Dock icon: it runs with the accessory policy (main.swift:676), so a Dock badge has nowhere to go. It does have a menu bar item, a magnifying glass or a waveform while Listening (main.swift:187-198, 316).
- Its only sounds are a beep on a refused key and "Tink" when the wake phrase is heard.
- The turn shows only on the session board. The Phone page lists a host's sessions with who is in control and no turn (PhonePage/home.ts:10-20). The Phone page's own problem left "notifications when a session wants an answer" out of scope (sessions-out-of-reach-from-the-phone).

### Where the turn is read, and how often

The turn (ADR 0010) is a word in the pane folder, written by Claude Code's hooks and corrected by the reader for Esc and background work (PaneFolder.swift:74-87).

| Session | Read by | How often |
|---|---|---|
| A started pane here | the pane's own timer (ClaudeSession.swift:306-318, `checkTurn` at 1057) | every 0.5 s |
| A pane here not started since a restart, whose zmx session may still run Claude | only the board (SessionBoard.swift:171-192, 222-230) | each second while the board is on screen in a visible panel |
| A pane here on a session hosted on a paired Mac or the headless host | `follow`, from the host's `status` reply (LauncherModel.swift:1365-1415; ClaudeSession.swift:1147-1149) | every 5 s while any such pane exists; a host that doesn't answer leaves the turn unknown |
| A paired Mac's open session with no pane here | the board, from `sessions` | when the panel shows, and every 5 s while the board shows |

- A pane's `turn` is a plain property. Nothing is told when it changes; the board reads it each second while it shows.
- A peer's turn date is worked out from an age in whole seconds and the time the reply came (`Turn.began`), so it moves by up to a second from one reply to the next.

### What each word means

`Turn` (Turn.swift) has working, waiting, permission, question, plan, input, and background, which the reader derives (the turn ended with agents, busy teammates, workflows or shells still running). The board's Running column is working and background; everything else is Stopped, with a mark for the four dialogs (SessionBoard.swift:6-31).

A waiting turn can come from:
- `Stop`, the turn's normal end;
- `StopFailure`, a turn ended by an API error;
- `idle_prompt`, the nag Claude Code sends after about a minute of waiting, which writes only when the word differs;
- `/clear` and a resume;
- the reader, when the transcript shows the user pressed Esc or a plain Deny (no hook fires).

### The turn file can't tell a failed turn from a finished one

- `StopFailure` writes waiting, as `Stop` does, and re-dates the stop file without writing its input (ClaudeCommand.swift:23-24, 70-74). Nothing in the pane folder says the turn failed.
- In 2.1.295, `StopFailure` "fires instead of Stop when an API error (rate limit, auth failure, etc.) ended the turn". Its input has `error` (`rate_limit`, `overloaded`, `authentication_failed`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens` and others, or `unknown`), `error_details` and `last_assistant_message`.
- The transcript can tell. An API error leaves an assistant entry whose model is `<synthetic>`, with `isApiErrorMessage: true` and `error` set to the same kinds. Seen in this Mac's transcripts. That every `StopFailure` leaves one is inferred.

### Which Mac knows a session's turn

- **The host's own pane** reads the file. A session another Mac started on this one gets a background tab here (`hostStart`), so its host has a pane for it too.
- **A pane showing a card** (another Mac or a Device in control, the host lost or unreachable, a resume under way) holds no client. For another Mac in control, the card keeps only that Mac's name (ClaudeSession.swift:436, 518, 790).
- **The Mac in control of a session on another host** reads the turn from `status` every 5 s.
- **A headless host** has no app, only the relay, which answers `status` and `sessions` from the same reader.
- **The phone** gets no turn and no push.

So for any session there is at most one Mac in control and reading its turn, and possibly other Macs holding a card for it.

### The pane on screen

- The panel hides when it loses key unless pinned (main.swift:39-42).
- `showsTerminal` is off while Settings or the board shows (LauncherModel.swift:325).
- `activeSession` is the focused pane of the tab on screen (LauncherModel.swift:39).
- So "the user is looking at this pane" is: the panel is key, it shows a tab, and that pane is the tab's focused one.

### Claude Code's own notifications

Read in 2.1.295's code. These are minified names, so this is a reading of the code, not a run.

- **The channel.** `preferredNotifChannel` defaults to `auto`.
  - `auto` picks a channel from the terminal: Apple Terminal's bell, iTerm2, kitty or Ghostty, found from `TERM_PROGRAM` and `TERM`.
  - Any other terminal gets `no_method_available`, and nothing is sent.
  - `notifications_disabled` sends nothing either.
- **The Notification hook doesn't depend on the channel.** It runs before the channel is chosen. So turning the channel off wouldn't stop Launchy's `idle_prompt` hook.
- **A Launchy pane's environment** is SwiftTerm's minimal one: `TERM=xterm-256color` and no `TERM_PROGRAM` (ClaudeSession.swift:478-481). So `auto` should send nothing in a Launchy pane (inferred). The login shell's startup files could set more, which isn't checked. A zmx session attached from another terminal is a case of its own.
- **SwiftTerm** passes OSC 777 notifications to a delegate method that does nothing by default, and beeps on BEL.
- **The cost of changing it.** The setting would go in the `--settings` value, so changing it changes the claude command line. That means a rebuild on every Mac and a reinstall of the headless relay (ADR 0009, ADR 0010), for sessions started after.
- **Notification types.** 2.1.295's are `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`, `agent_completed`, `worker_permission_prompt`, `push_notification` and others. Launchy's Notification hook matches only `idle_prompt` (ClaudeCommand.swift:25), so a finished subagent (`agent_completed`) can't mark a pane waiting.

### Posting a notification from a bare executable

- **What Launchy is.** Launchy is a bare executable, signed ad hoc, with its Info.plist (bundle id `com.zabaca.launchy`) linked into the binary (Package.swift:5-8, 40).
- **UNUserNotificationCenter** is Apple's API for posting notifications. It works from an app bundle. In a process without one, it is reported to raise an Objective-C exception at first use ("bundleProxyForCurrentProcess is nil"). Unverified for this binary: nothing was run. Swift can't catch that exception, so it would end Launchy.
- **NSUserNotificationCenter**, the older API, has been deprecated since macOS 11 (SDK header).
- **`osascript`'s `display notification`** posts under Script Editor's name, and a click opens Script Editor.
- **The app bundle question.** runs-only-from-a-checkout's options 02 to 04 put Launchy in a Launchy.app. All of them keep the checkout build (`make build`, `make run`, ADR 0013's Upgrade) a bare executable. None is accepted yet.

### Settings

Settings has sections Claude, Search, Listening, Peers, Models and Shortcuts (Settings.swift:890-891). Session settings (Skip permissions, Keep sessions running, Session titles) are under Claude.

## What cmux does

cmux (manaflow-ai/cmux), "a Ghostty-based macOS terminal with … notifications for AI coding agents", read at [7acf579](https://github.com/manaflow-ai/cmux/tree/7acf57977523cc2a1e7a59b201ae2ec5559739f5) on 2026-10-08. Not re-read for this problem.

- **Notification types.** It classifies Claude Code's Notification hook by `notification_type`. `permission_prompt` always notifies. `idle_prompt` is muted while background work is pending. `agent_completed` is progress, not done.
- **Done only when work drains.** Its "done" setting, `whenIdle` by default, drops the ping while background tasks run. The ping comes once, at the turn that ends with none ([AgentNotificationGate.swift](https://github.com/manaflow-ai/cmux/blob/7acf57977523cc2a1e7a59b201ae2ec5559739f5/Sources/AgentNotificationGate.swift)).
- **One per turn, withdrawn when answered.** It sends one completion per turn, and a new prompt or an answered approval withdraws what was delivered ([AgentNotificationReconciler.swift](https://github.com/manaflow-ai/cmux/blob/7acf57977523cc2a1e7a59b201ae2ec5559739f5/Packages/macOS/CmuxAgentJournal/Sources/CmuxAgentJournal/AgentNotificationReconciler.swift)).
- **The focused pane stays quiet.** There is no banner or sound for the focused pane while the app is frontmost. Opt-in, it can also stay quiet for every pane while frontmost.
- **Settings and muting.** It has a setting per category and a per-workspace mute. Nested agents are muted by default.
- **No ping on errors.** A turn that dies on capacity, quota or timeout sends no notification. That is an open issue ([#10127](https://github.com/manaflow-ai/cmux/issues/10127)).
- **Claude's own channel off.** It sets `preferredNotifChannel: notifications_disabled` in the settings it injects, so Claude's own notifications don't double its own.

Launchy already covers part of this:
- its `background` turn is cmux's `whenIdle` gate, with idle teammates handled;
- it recovers Esc from the transcript, which cmux has open (#4389).

## Unverified

- Whether UNUserNotificationCenter can be used from Launchy's bare executable with its linked-in Info.plist, and whether NSUserNotificationCenter still posts on macOS 26 from one.
- That macOS keeps a notification permission by bundle id across ad-hoc rebuilds. Keychain access isn't kept (Keychain.swift:4-5).
- That every `StopFailure` leaves an API-error entry in the transcript.
- That `auto` sends nothing in a Launchy pane whatever the account's shell startup files set.
