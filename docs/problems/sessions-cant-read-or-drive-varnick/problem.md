---
title: A Claude session in a Varnick pane can't read or drive Varnick itself, except through a picture of the screen
description: Screen access gives a session generic tools for any app's window, and leaves Varnick's own process out on purpose. `look` lists no Varnick window. `click` and `drag` refuse a point under its panel. `type` refuses its shortcuts, and stops whenever its panel has the keyboard. Only a picture of the whole screen shows the panel. So a session can't tell what the panel shows, open a view, read or write the Outline, or hand-test a Varnick feature for the user. The user wants tools that speak Varnick's own model, as the screen tools speak the screen's.
impact: Every hand check of a Varnick feature falls to the user. The session that built the Outline could not check it. Agents can't use Varnick's features as tools either, such as the Outline as a shared working document or the board as the list of sessions. Today a session can only read the pixels of a screen picture, which shows everything and can act on nothing.
severity: mid
evidence: The user's words of 2026-10-11, relayed by the coordinator, after an agent tried and failed to hand-test the Outline for the user (built on its own branch, at 596c761, not merged at the time of writing). Code read at d24ce5b (main) and 596c761 (the Outline). The exclusion's history comes from git (19c4faf, db973f1, 5028afa).
status: open
---

## What the user asked (2026-10-11)

"I'm talking about a more tighter integration. You should have tools for it specifically like you have generic screen tools."

Two uses matter:
1. **An agent hand-testing a Varnick feature for the user,** such as the Outline, the board or a Command, and checking what the user would see.
2. **Agents using Varnick's features directly,** such as the Outline as a working document, or the board as the list of sessions.

The tools should speak Varnick's model, its structured state and its own actions, not pixels and synthetic events.

## Today

Verified in the code at d24ce5b unless marked.

**What the screen tools do with Varnick**
- **`look`.** `ScreenReader.focusedApplication` and `application(named:)` skip Varnick's pid. So `look` reads the app behind the panel, and `app: "Varnick"` finds nothing. With only Varnick in front, `look` refuses ("nothing but Varnick is in front"). Hey Varnick's panel-first read (`ScreenReader.panel()`) isn't used for sessions.
- **Ids.** An id in Varnick's process is refused (`ScreenReader.isVarnick`).
- **`click` and `drag`.** A point under a visible Varnick window is refused (`ScreenAccess.varnickCovers`). The check goes by frame, and the Arrow's panel doesn't count.
- **`type`.** Varnick's anywhere-shortcuts are refused (`ScreenKeys.refusal`). Typing stops when any Varnick window has the keyboard (`varnickKey`): the panel is nonactivating, so it can hold the keyboard while another app is in front.
- **`window`.** Varnick's own windows are refused.
- **Pictures.** A picture of one window never shows Varnick's. A picture of the screen (`look` with `screen` or `display`, `sessions-cant-see-or-act-on-the-screen` option 08) shows the panel, by the user's choice of 2026-10-10. That is the only way a session sees Varnick.

**Why the exclusion is there**

Nothing in the code, ADR 0023 or `docs/privacy-and-security.md` gives the reason. They only state the rule. Git has the rest:
- **The recorded reason (19c4faf, 2026-10-09):** the reason belonged to option 01 as first written. Each click and type was to be approved in a prompt in Varnick's own panel, "and why `click` and `type` refuse Launchy's own windows". A session that could click the panel could approve its own actions.
  - Settings is in the panel too. It holds the Screen access switch (the one stop for running sessions), Skip permissions for new sessions, and the Grant buttons.
- **The reason was lost when the option narrowed (db973f1):** approval was deferred along with all permissioning, but the refusal stayed. ADR 0023 says "Never Varnick's own window" and nothing more. Reading the panel was put Out of Scope with no reason given.
- **`type`'s own reason (option 06):** Varnick's anywhere-shortcuts "would act on Varnick, and showing the panel would send the rest of the call into it".
  - The key-window check has the same root. While the user talks to a session, the panel is usually key, so keys meant for the app behind would land in the panel's focused pane. That pane is the session's own prompt, or another session's.
- **Inferred, for `look`:** the session lives in the panel, so the panel usually has focus when the session is asked to look. Skipping it makes `look` with no `app` read the app the user means.
- **Not the reason: Accessibility on Varnick's own main thread.**
  - Hey Varnick has read its own panel since 2026-10-09 (`spoken-requests-cant-see-the-screen`, option 05). The read runs detached while the main actor only awaits it, so the main thread is free to answer.
  - It is a constraint on any design that reads Varnick through Accessibility, since a main thread that waits on that read hangs. It didn't cause the rule.
- **Not the reason: other panes' privacy.** The panel shows other sessions' names, folders and turns, and the user let a screen picture include it, other sessions' text and all ("don't need to leave varnick's own window out", 2026-10-10).
- **Not a boundary today.** Every pane process has Varnick's grants (`panes-share-launchys-permissions`). It can click the panel with its own code, or write Varnick's preferences, as any process of the user can. The refusal keeps the tools Varnick offers off Varnick's controls, until permissioning makes those tools the only way in.

**What Varnick holds that a session could be given**
- **The panel's state lives on `LauncherModel`, on the main actor:**
  - what replaces search: Settings, the board or a tab (`showingSettings`, `showingBoard`, `activeTab`);
  - the query's `Mode`;
  - the Restart Varnick card, the split picker and the pinned state.

  Focus is the panel's first responder; the search field takes it through `focusToken`.
- **The `!` Commands are `LauncherCommand`:** listen, transcript, kanban and problems, plus outline on the Outline's branch. `LauncherModel.runCommand` runs the selected row. `!problems` is listed only while the Problems board switch is on, and `!listen` turns on the microphone.
- **The board is `SessionBoard`.**
  - Each card holds the pane's id, its title, pills, folder, standing (the turn and since when), background work, a note and work links. The board also has its own tab and selection.
  - It refreshes once a second only while shown, and asks paired Macs only on its Sessions tab.
- **The Outline** (596c761) **is held by `Outline`.**
  - It holds the tree (`OutlineTree`, pure: edits take dates and ids), the rows the user sees (`visibleRows`, under the filter), the zoom's crumbs, the filter, the caret, one undo stack and the saver.
  - Every edit is an `OutlineEdit` applied by `Outline.apply`. `apply` records an undo step, saves, and moves the caret into the edit's result.
  - A row is a path of placement ids.
  - The file is read the first time the Outline shows in a launch.
  - The Outline never sets the text of the view that has the caret (`updateNSView`, `syncFromModel`), and the user's next key writes that view's text back into the tree.
- **The panel's key monitor** hands keys out first to the Restart Varnick card, the split picker, Settings' esc, a pane's question, the board (`SessionBoard.key`) and, on the Outline's branch, the Outline (`Outline.key`), then to the shortcuts. Every other key goes to the first responder.

**How a session reaches Varnick**
- **The server.** `Varnick --mcp --pane <id>` is the `varnick` MCP server. A Claude pane on this Mac gets it when Screen access is on at the pane's start.
- **The socket.** The server relays each tool call as one line, with no `op`, on the user-only socket. `PeerManager.handle` passes the line to `ScreenAccess`, which checks the switch and Accessibility before anything else.
- **The tools** are a fixed list in the binary.
- **The pane id is a label, not a credential:** any process of the user can send any pane's id.

## Left to decide

- **The approach:** tools on Varnick's model, keys sent through its own key path, or the screen tools let into the panel.
- **Which server and switch:** one MCP server or two, and whether the tools come under Screen access's switch or one of their own.
- **What a session may read about other sessions.**
- **The user's typing:** how an edit keeps out of the user's way, and whose undo stack it goes on.
- **How a view exposes itself,** so that the next view gets tools cheaply.
- **The Outline's part waits for the Outline to merge.** Everything else can be built on main as it is.
