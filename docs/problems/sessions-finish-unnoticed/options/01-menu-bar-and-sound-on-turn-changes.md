---
problem: sessions-finish-unnoticed
title: Turn changes mark the menu bar and play a sound
summary: Launchy watches the turns it already reads, and for each session this Mac is in control of it raises a notice when the turn is done (working or background to waiting), needs the user (a permission dialog, a question, a plan or an MCP request) or stopped on an API error. That last one is a new turn word, failed, which the reader takes from the transcript as it takes Esc. A notice puts a dot on the menu bar icon, plays a sound and lists the session at the top of the menu, where choosing it opens the pane. Background work stays silent until it drains. The pane on screen stays silent. A pane has one notice at most, cleared when its turn moves on or the pane comes on screen. Settings › Claude gets a switch per category. There are no macOS notifications, so nothing needs a permission or an app bundle, and every build has it. Rough effort is two and a half days.
status: accepted
---

## Solution

**A notice per turn change.** A notice is Launchy's word for "this session needs a look". Each Claude pane reports when its turn's word changes, whether from its own file or from its host's reply. Launchy then decides from the old word and the new one:

| From | To | Notice |
|---|---|---|
| working or background | waiting | **Done** |
| any other word | permission, question, plan or input | **Needs you**, saying which |
| working or background | failed | **Stopped on an error**, with the kind when known |
| anything | working or background | none; clears the pane's notice |
| permission, question, plan or input | waiting | none; clears the pane's notice (the user answered, denied or pressed Esc) |

The cases that never raise a notice:
- **The first word this run reads for a pane is its starting point.** That covers a launch, a pane restored, and a host that answers again after not answering.
- **A waiting the reader made from the user's Esc.** The user stopped Claude themselves.
- **Background.** It is the "done only when work drains" gate. The notice comes when the last of the work ends and the turn reaches waiting.

**One Mac per session: the one in control.**

- A session hosted on this Mac is this Mac's, unless its pane here shows a card. A card means another Mac or a Device is in control, the host can't be reached, or a resume is under way.
- A session hosted on a paired Mac or the headless host is this Mac's when its pane here is in control. The turn then comes from the host's reply every 5 s.
- A pane showing a card is silent: the Mac in control notifies.
- A paired Mac's open session with no pane here is silent.

So a session raises a notice on one Mac at most.

**When Launchy stays quiet.** The user is looking when the panel is key and either:
- it shows the pane's tab with that pane focused, or
- it shows the session board.

Then no notice is raised. Launchy is an accessory app, so "frontmost" means the panel is the key window. A pinned panel behind another app isn't key.

**One notice per pane.** A pane holds its latest notice only, and a new one replaces the old. A notice is cleared when:
- the turn moves on, per the table;
- the pane comes on screen, as above;
- the pane closes;
- its category is switched off.

**The menu bar.**
- While any notice stands, the menu bar icon carries a small dot, orange if any notice is Needs you or Stopped on an error.
- The menu lists the notices above its usual items, newest first. Each item shows the session's title as the board shows it, its Mac when it runs on another one, and what the notice says: "Needs permission", "Question", "Plan to approve", "MCP input", "Done" or "Stopped on an error (rate limit)".
- Choosing one shows the panel on that pane, closing the board or Settings if either is open.

**The sound.** One system sound when a notice is raised: one for Needs you and Stopped on an error, a softer one for Done. Never a sound for a pane on screen.

**Settings › Claude, "Notify me when a session…".** Three switches, all on by default:
- needs me (dialogs);
- is done;
- stops on an error.

**The failed word.**
- **What makes it.** The reader turns a waiting turn into failed when two things hold:
  - the transcript's last conversation entry is Claude Code's API-error entry, dated at or after the turn's start;
  - no background work is still running.

  The reader already corrects for Esc and derives background this way. Background wins, because that work starts Claude's next turn by itself.
- **How it travels.** Like background, failed is never written to the file and travels to peers as text.
- **On the board** it sits in Stopped with the mark "API error".
- **No hook changes.** The claude command line stays as it is, and sessions already running get the word.

## Trade-offs

- **Works today, on every build.** No macOS notification, no permission prompt, no new process, and no change to the claude command line or the protocol.
- **Easy to miss.**
  - A dot and a sound don't say which session until the menu is opened.
  - A full-screen app hides the menu bar, and a muted Mac plays no sound.
  - Nothing reaches Notification Center, and notices don't survive a restart.
- **One Mac per session.** A session whose Mac in control is asleep raises no notice anywhere. Neither does one a Device controls, nor one whose host doesn't answer. A Mac showing a card for a session stays silent even when the user is at that Mac and not at the one in control.
- **A peer's turn is read every 5 s.** A turn that starts and ends between two replies raises nothing, and Done can come up to 5 s late.
- **The failed word rests on an undocumented transcript field,** as Esc already does. If Claude Code renames it, those turns read as waiting and raise Done instead, with no error.
- **Builds disagree for a while.** A paired Mac on an older build shows "Turn not known" for a failed session. Until the headless relay is reinstalled, its sessions raise Done for a failed turn.

## User Stories

1. As the user, I want a sound and a mark in the menu bar when a session on any of my Macs finishes its turn, so that I know without opening Launchy.
2. As the user, I want a louder cue when Claude waits on a permission dialog, a question, a plan or an MCP request, so that a blocked session doesn't sit idle.
3. As the user, I want to know when a turn stopped on an API error, and which kind, so that I don't mistake a rate limit for a finished task.
4. As the user, I want no cue while background agents, teammates, workflows or shells still run, and one when they have all ended, so that "done" means done.
5. As the user, I want no cue for the pane I'm looking at, so that Launchy doesn't tell me what I can see.
6. As the user, I want one cue per session per change, never repeated by Claude's minute-long idle reminder or by Launchy reading the turn again.
7. As the user, I want a session's notice gone once I've looked at it or its turn has moved on, so that the menu lists only what still needs me.
8. As the user, I want to choose a session in the menu bar menu and land on its pane, so that I get there in one step.
9. As the user with several Macs, I want a session to raise its notice on one Mac only, the one I control it from, so that I don't hear it twice.
10. As the user, I want to switch off each kind of notice in Settings, so that I can keep only the ones I care about.
11. As the user, I want no notices from sessions that were already waiting when Launchy started, or from a Mac that comes back after not answering.
12. As the user, I want to see "API error" on a Stopped board card whose turn failed, so that the board and the notice agree.

## Implementation Decisions

- **The pane reports a change of word.**
  - A Claude pane calls a closure, like its other change callbacks, when its turn's word changes, giving the old turn and the new one.
  - Both its own file read and a host's reply go through it.
  - A change of date or background counts alone isn't reported. A peer's date moves with each reply, so only the word counts there.
- **A notifier owned by the model holds the notices.**
  - It reads, once a second, the turn files of this Mac's panes that aren't started since a restart, as the board does. Those are dormant tabs whose zmx session can still be running Claude.
  - On that tick it also clears the notice of any pane now on screen.
  - Started panes and panes on peers already read their own turn.
- **The decision is one pure rule.** Its inputs:
  - the old and new words;
  - whether the new waiting came from Esc;
  - whether this Mac is in control;
  - whether the pane is on screen;
  - the three switches.

  It returns a notice, a clear, or nothing. This is the first seam for a test.
- **What the reader adds.**
  - Its result gains a flag for "made from the user's Esc", local only. Peers get the word alone, as with background counts.
  - Its result gains the failure's kind, read from the API-error entry's error field. "rate limit", "overloaded", "server error" and "authentication failed" get their own words. Any other kind reads as "API error".
  - The failure check shares the transcript tail read that background already does for a waiting turn.
- **Whether this Mac is in control** comes from the pane: a pane on a card isn't. A host's pane for a session a Device took over shows a card too, so it stays silent, and the phone gets nothing (Out of Scope).
- **"On screen"** is the panel key and visible, with either the session board shown, or a tab shown (not Settings) whose focused pane is this one.
- **The menu bar icon** keeps its two images (search, and Listening's waveform) and gains the dot as an overlay, so Listening's state still shows.
- **Settings keys** are three booleans in UserDefaults, one per category, defaulting to on when absent. Nothing new goes in the saved sessions.
- **Nothing is logged** about a notice's session: titles are never logged.
- **Documents.**
  - In CONTEXT.md, **Turn** gains failed, and a **Notice** entry says what raises one and where it shows.
  - ADR 0010 gets an amendment for the failed word.
  - where-it-breaks gets two entries: the API-error entry the reader relies on, and that the Notification hook must keep matching only `idle_prompt`, so a finished subagent (`agent_completed`) never marks a pane waiting.

## Testing Decisions

- There is no test target. The first tests, when there is one:
  - the decision rule, over each row of the table, the Esc flag, on screen, not in control and each switch;
  - the failure reader, over made-up transcript tails: an API-error entry last, one followed by a prompt, one older than the turn, and one with background work still running.
- `make build` passes.
- **By hand, after the user restarts Launchy:**
  - **Done:** a prompt in a pane, with the panel hidden, gives Done. The same in the pane on screen gives nothing.
  - **Needs you:** a dialog in a pane gives Needs you. Answering it clears the notice.
  - **Background:** a turn that leaves a background agent running gives nothing until the agent ends and the turn reaches waiting.
  - **Esc** mid-turn gives nothing.
  - **Opening the pane:** choosing the menu item opens the pane and clears the notice.
  - **Peers:** a session hosted on a paired Mac and controlled here raises its notice here only. The same session shown on a card here raises it on the other Mac.
  - **The headless host:** a session on it, controlled here, raises its notice here.
  - **After a restart:** nothing for sessions that were already waiting.
  - **An API error:** a prompt sent after switching the session to a model that doesn't exist is expected to end on an API error (unverified). The card then shows "API error" and the notice says so.

## Out of Scope

- **macOS notifications.** Options 02 and 03 add them on top of this one.
- **A push to the phone,** and notifying for a session a Device controls: `phone-page-is-only-a-browser-tab` option 02. It routes each notice by the pane's controller and whether that Mac's user is present. This option is the Mac half of that rule.
- **Claude Code's own notification channel.** Setting `notifications_disabled` would change the claude command line, and with it every Mac's build and the relay install. `auto` already finds no channel in a Launchy pane (problem, Today). Revisit only if doubled notifications are seen, as when a zmx session is attached from another terminal.
- **An idle reminder** like `idle_prompt`'s minute-later nag.
- **A mute per session or per project.**
- **Notices for sessions with no pane here,** and for agents other than Claude Code.
- **Finer Running states** from a hook on every tool call, and cmux's event journal, prompt detection and per-agent installers.
- **The unseen mark on board cards** (option 04).

## Further Notes

- The table above is shared with `phone-page-is-only-a-browser-tab` option 02, whose page server keeps a copy for the phone. A change to one is a change to both.
- Asked for by the user on 2026-10-08, relayed by the coordinator, after a research pass on cmux. The table's first four rows, the focused-pane rule and the switches per category follow cmux (problem, What cmux does). The failed word answers cmux's open complaint about errors.
- A teammate's permission prompt is Claude Code's `worker_permission_prompt` notification. Whether it also fires the lead session's `PermissionRequest` hook is unknown. If it doesn't, it raises nothing here.
