---
title: Nothing shows which Claude sessions are working, which wait on the user, and which are done
description: Claude sessions sit in tabs on this Mac and on paired Macs, and the only way to learn whether Claude is still working on a turn or has finished and is waiting for an answer is to open each tab and look. Launchy keeps no notion of a turn, and has no place for a session the user considers finished other than closing it, after which it is just one of Recent's ended sessions.
impact: A session that finished its turn waits, unnoticed, until the user happens to cycle to its tab or Mac. Finished sessions either stay open as tabs, crowding the header and the session list, or are closed and lose any mark that they were done. The more sessions run at once, across more Macs, the worse both get.
severity: mid
evidence: The user's request of 2026-10-06. Code read at 76150b9 (main). Claude Code 2.1.291, installed here, checked for its hook events and notification types from the strings in its binary; nothing was run. The user's shortcut overrides in UserDefaults are empty, so every shortcut is at its default.
status: open
---

## What the user wants

1. **A board with three columns:** Running, Stopped, Completed.
2. **The user moves a card to Completed, and opens a card.**
3. **A new keyboard shortcut toggles the board,** and commands in the launcher's input open it.

## Decided by the user

- **Columns are turn state.**
  - Running: Claude is working on a turn.
  - Stopped: Claude finished its turn and is waiting on the user.
  - Completed: the user marked it done.
- **The commands are `!kanban` and `!tabs`,** added to the existing `!` command list. No new prefix.
- **Moving to Completed closes the pane.** The card stays in Completed. Opening a completed card resumes the session in a new tab and moves it out of Completed.
- **Paired Macs' sessions are on the board,** badged with their Mac, as search results and session rows are.

## Today

Verified in the code at 76150b9 unless marked otherwise.

**Turn state.** Launchy doesn't know whether Claude is working or waiting.
- The one signal it holds is Claude Code's terminal title, which a pane keeps as it arrives. The pane's label drops a leading status glyph from it, which the code describes as "spinner / ✳". Nothing reads the glyph. Which glyphs Claude Code 2.1.291 writes, and whether they change during a permission prompt, is unverified: its title code is minified, and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` turns the title off.
- The title arrives only through a client attached here. Tabs restored after a Launchy restart are dormant: a pane starts, and attaches, only when it is first shown. A card (another Mac in control) has no client. A paired Mac's open session has no pane here at all.
- The only hook Launchy passes to claude is SessionStart (ADR 0001), in the `--settings` it starts every Claude pane with, on a Mac and on the headless host alike. It writes the hook's JSON to a file in the pane's folder. The pane reads that file every half second, and the relay reads it too, to tell a peer which conversation a session is on.
- Claude Code 2.1.291 offers `UserPromptSubmit`, `Stop` ("Right before Claude concludes its response"), `StopFailure` ("When the turn ends due to an API error"), `PermissionRequest`, `SessionStart`, `SessionEnd`, and `Notification` with the types `idle_prompt`, `permission_prompt` and `elicitation_dialog`, among others. Two things below come from Claude Code's hooks documentation and were not checked against 2.1.291: `Stop` doesn't run when the user interrupts a turn, and `idle_prompt` fires after about a minute of waiting for input.

**Peers.**
- A paired Mac reports, for each open session (`sessions`): its zmx name, title, folder, agent, conversation, the Mac in control and how many clients are attached. `status` adds whether the session runs. Titles come from the saved record on a Mac, where the glyph is already dropped, and from the transcript on the headless host. **No peer reports turn state,** only that a session is open, who controls it and whether a client is attached.
- The protocol is version 11. Any change to a reply's shape bumps it, both Macs then have to be built from the same commit, and the headless relay is reinstalled at every bump (ADR 0009). The relay answers `sessions` and `status` from saved state, zmx and the pane folder alone, with Launchy not running.
- **Opening** a paired Mac's open session, from the session list or from ↩ on a search or Recent row that is open there, opens a pane on its card with Take over. It never takes control. A peer's ended session is resumed there with the `resume` request.
- **Closing** a pane that is in control of a session on a peer sends `end`. The host kills the session if its origin label names the Mac that closed it, and otherwise releases it: it keeps running there. Closing a card ends nothing. The host accepts `end` only from the Mac its control label names, and no request closes the host's own pane for a session the asker doesn't control.

**Siblings for the board itself.**
- **Settings** replaces the panel's whole content, toggles with ⌘,, closes with esc, and has a fixed size: the panel's 760 width and a 600 height. While it shows, the tab shortcuts (⌘W, splits, focus moves) don't act on the tab underneath.
- **The session list** (empty search field) lists this Mac's Tabs, each paired Mac's open sessions under its name, then 5 of Recent's 20. Its rows show `^host`, `#project` and `@agent` pills (merged in bcd91d6).
- **The live transcript** (`!transcript`) is a pane kind in a tab of its own, brought back if already open.
- **The split picker** is a keyboard surface with no text field. Its keys go through the panel's key monitor.
- **`!` commands** are `listen` and `transcript`, ranked by how well their name matches what's typed.

**Shortcuts.** Every one is rebindable in Settings › Shortcuts, from its default:
- Global, registered system-wide: ⌃Space (show or hide), ⌃⇧Space (pin).
- In the panel, matched before a terminal or web view sees the key: ⌘, ⌘N ⌘⇧T ⌘⇧R ⌘W ⌘V ⌘⇧[ ⌘⇧] ⌘⇧F ⌘⇧E ⌘⇧O ⌘⌃⇧E ⌘⌃⇧O ⌘⇧H ⌘⇧J ⌘⇧K ⌘⇧L ⌘L ⌘R ⌘= ⌘- ⌘0.
- The Edit menu's ⌘Z ⌘⇧Z ⌘X ⌘C ⌘V ⌘A, and Quit's ⌘Q in the menu bar item.
- The search field's own ↑ ↓ ⇥ ↩ ⌘↩ esc, and the split picker's arrows, ⇥, ↩, esc and tile letters.
- ⌘⇧B is free. ⌘B alone would be caught before a web pane, where page editors use it for bold.

**Saved state.**
- `sessions.json` holds the open tabs, with each pane's record, and Recent (20 records). It decodes as one value: a field that fails to decode drops every tab and Recent, so a new field has to be optional.
- The search database holds session rows built from transcripts, for search. UserDefaults holds settings and shortcut overrides. Neither holds per-session UI state.
