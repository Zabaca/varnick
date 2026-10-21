---
title: The Outline can't be reached from the phone
description: The user wants the Outline on the Phone page. Today the Outline lives on one Mac and shows only in that Mac's panel, so away from the desk the user can't read a list in it, add a thought to it or check a bullet off. Its rules also keep its text off the phone on purpose, so reaching it from the phone is a privacy change as well as a new view.
impact: A thought the user has away from the Mac goes into another app or is lost, and a list kept in the Outline can't be checked where it is used. The Outline stays a desk-only tool while sessions, tabs, Recent and Voice mode are already on the phone.
severity: low
evidence: The user's request of 2026-10-20, relayed by the coordinator ("the outliner app, could we make that available in phone app", then "proceed" once the coordinator had laid out the decisions below). Code and docs read at 605dd22 (main).
status: closed
---

## What the user wants

The **Outline** (`CONTEXT.md` › Outline) in the phone app, the **Phone page** (`CONTEXT.md` › Phone page).

## Decided by the user

Nothing yet beyond wanting it. The coordinator put these decisions to the user, who said to go ahead with planning. Each option answers them, and the choice is the user's:

- Reading only, or editing as well, and which edits.
- Which outline a page shows: each Mac's page shows its own, or one Mac's outline shows on every page.
- Whether the Outline's text may reach the phone at all, over the tailnet. The shipped Outline says it never does.

## Today

Everything below was checked in the code and docs at 605dd22.

**The Outline.**
- **One tree on one Mac.** It is kept in `outline.json` in that Mac's support folder (ADR 0030). It sits behind Settings › Experimental › Outline, which is off by default on every install. Each Mac has its own tree, and nothing syncs them.
- **When the file is read.** The first time the Outline shows in a launch, or the first time a session reads it; nothing reads it at launch. A file that can't be read, or comes from a newer Varnick, is never written over, and every reader is told why.
- **Panel access already reads and edits the Outline from outside the panel, through the running app's model** (ADR 0031).
  - A session's read lists rows by path, within bounds: 400 rows and 60,000 characters a call, then a call that continues.
  - A session's edit goes through the Outline's one edit for callers outside the panel. That edit is one step on the Outline's undo stack. It leaves the user's caret alone, or moves it where the same key would.
  - An edit to the bullet the user is typing in goes into that text view as a key would, and waits while an input method is composing.
  - A text or note edit is refused when the field differs from what that session last read. Every edit is refused while the Outline switch is off.
  - All of this works with the Outline hidden, and the save follows as it does for any edit.
- **The tree is a value, and its rules live in it alone:** the visible rows for a zoom, for Show completed and for collapse, and the rule that no bullet goes inside itself.
- **The view's state is saved in the file.** The zoom, Show completed and each placement's collapse are the Mac's view of the Outline.
- **Commit 42fabc6** changed the id of the Mac view's title row only. It has no bearing on the phone.

**Its privacy rules.** Each of these says the Outline's text stays off the phone:
- ADR 0030, Consequences: "Local only. Nothing reaches a paired Mac or the phone." Its amendment of 2026-10-11 says local only "holds for the file and for every Mac and device".
- ADR 0031, where `outline_read` amends ADR 0030: "Nothing reaches a paired Mac, the phone or TypeSafe."
- The shipped option, `no-outline-in-varnick/01`.
  - Its Privacy section: the text is "never sent anywhere: no paired Mac, phone, model, search store or reranker", and "The relay doesn't read the file".
  - Its Out of Scope: "Syncing with paired Macs or the phone".
- `CONTEXT.md` › Outline: "kept in a file on this Mac and nowhere else".
- `docs/privacy-and-security.md` and the README: the Outline is "otherwise kept in a file on this Mac and nowhere else", and "kept on this Mac only".
- In the app:
  - the `!outline` row's detail, "Your bullets, kept on this Mac (also !wf)";
  - the Outline switch's detail in Settings, which says "kept on this Mac".

**The Phone page.**
- **Each host serves its own page,** on port 8444 of its tailnet name, through `tailscale serve` (ADR 0011).
  - Every list and every action is a request to that host's own relay, run as one short process with the device as the asker. A page's server never asks another host. Other hosts appear as links to their own pages.
  - ADR 0011 considered a hub page that reaches every host through one Mac (its option 03) and didn't choose it.
- **Requests only a Mac's app can answer.** Voice mode's three requests (ADR 0043) are the sibling for this work:
  - a Mac's relay forwards them to the running app over its socket;
  - the app checks that the asker is a listed device or Mac, and answers on the main actor;
  - a headless host's relay refuses them, saying they need a Mac;
  - the page hides Voice mode's button on a headless host, going by the hello it already reads.
- **Size limits.**
  - A request is one base64 argument of at most 120,000 bytes. It is JSON inside base64 inside base64, so the argument is about 1.8 times what it carries.
  - A reply line is at most 1,000,000 bytes.
- **When the page reads.** Home reads the host when it opens, when the page comes back into view, and on Refresh. Nothing on the page polls, except Voice mode's status while a request is out.
- **What it keeps.**
  - The page's worker caches nothing from the server, and the server's replies are `no-store`.
  - The page keeps a few preferences in its own storage, per host: the last project chosen, and whether the install offer was dismissed.
  - The server's access line holds the method, the path without its query, the status, the device and the time.
- **Typing on the page.** The terminal has a row of the keys a phone's keyboard lacks: Esc, Tab, ⇧Tab, the arrows and a sticky Ctrl. A new session's prompt is the only text the page edits that anything keeps.
- **The protocol.** Every new request so far has raised the protocol version: `hosts` took it to 14, and Voice mode to 30. It is 32 now.
  - `phone-cant-mark-a-tab-done`'s option 03 takes 33. The user accepted it on 2026-10-20 and it is not yet built.
  - That option also takes the next free ADR number.

**A headless host has no Outline.** It runs Varnick's relay alone. All of the Outline's code is in the Mac app, and none of it is in the relay's package.
