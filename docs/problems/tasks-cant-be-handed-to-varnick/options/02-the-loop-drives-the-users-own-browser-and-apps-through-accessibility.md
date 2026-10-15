---
problem: tasks-cant-be-handed-to-varnick
title: The same loop acts on the user's own browser, or any app, through Accessibility, under an exception the user approves for each task
summary: Option 01's harness, Jev and Claude, but the surface is the user's real screen. The page or window is read through Varnick's Accessibility walk, the one Screen access uses, and acted on with its click and type, with the Arrow shown first and the app brought to the front. The user's rule that agents never drive their screen gets an explicit exception: each task asks once at its start, naming the app and the task, and moving the mouse or pressing a key stops it. It works in the user's own logged-in browser and in native apps, which no other option reaches. But Chrome often leaves a page's content out of its tree, each step takes the pointer, keyboard and front window from the user, a peek can't use the browser's cookies, and it needs Accessibility and Screen Recording, which today reach every pane too. Not recommended for websites. Possibly later for native apps, after option 01 and after `panes-share-launchys-permissions`.
status: proposed
---

## Solution

- **Starting.** As option 01, but the task names an app or the front window ("in Safari, find the price of …"). A sheet in the panel asks: "Let Varnick use Safari for this task? It will click and type there until the task ends." Allow, or Cancel.
- **Reading.** The focused window's Accessibility tree through `ScreenReader`'s walk, as Screen access's `look` reads it: labels, kinds, frames and the text beside them, never a field's value. Where a browser hides its page from the tree, the text in a picture of the window is used, as ADR 0021 does.
- **Acting.** Screen access's click, type, drag and window, with their checks:
  - the Arrow on the target for a second;
  - one action at a time across Varnick;
  - the switch and the request's age read again before acting.
  
  The app comes to the front for each click and each piece of typing.
- **Peeks.** A browser's cookies aren't reachable, so a peek is a plain fetch with no login, or the link opened in a background tab of the user's browser, which shows on their screen.
- **Gates.** As option 01. A secure text field is never typed into, and Screen access's `type` already refuses one that has focus.
- **Stopping.** A mouse move or a key from the user ends the task, as well as Stop.

## Trade-offs

- **For:**
  - **the user's own logins and cookies,** so "check my order on a site I use" works;
  - **any app, not only websites,** the only option that reaches native apps;
  - **most of the code exists:** Screen access's reading and acting, the Arrow, the queue.
- **It takes the screen.** Each step brings the app forward and moves the pointer or types, so the user can't work while a task runs. The pilots' 40-turn budgets would be minutes of the user watching.
- **An exception to the user's rule,** for each task. Granted once at the start, then each step acts without asking, which is weaker than "approval each time".
- **Chrome's pages are mostly text from a picture.** Chrome often leaves page content out of its Accessibility tree (recorded in `spoken-requests-cant-see-the-screen` and handled by ADR 0021's text step). Recognised lines carry no link targets, so the frontier and its peeks can't run on them.
- **Slow by construction.** Each click waits a second for the Arrow (Screen access's lead). A 30-step task spends 30 s on leads alone.
- **Grants that reach every pane.** It needs Accessibility and Screen Recording. Until `panes-share-launchys-permissions` is solved, those grants reach every process in every pane.
- **A picture shows everything.** Claude, steering, would want the window's picture, as Screen access's `look` can give it. That picture shows typed text, with only password fields painted black.

## User Stories

1. As the user, I want a task to use my own logged-in browser, so that it can reach my accounts.
2. As the user, I want to approve each task once before it touches my screen, so that the exception is mine to give.
3. As the user, I want any move of mine to stop it at once, so that I'm never fighting it for the pointer.
4. As the user, I want tasks in native apps (System Settings, a mail app), so that computer use isn't only websites.

## Implementation Decisions

- The harness core, Jev and Claude are option 01's, behind its seams. Only the page seam changes: a reader and actor built on Screen access's code, never through a pane or helper.
- The exception is the user's to give. It is recorded as an ADR beside ADR 0023, which routes sessions' screen actions through Varnick, and said in the switch's row.
- One task at a time. The Screen access queue is shared, so a session's actions wait behind the task's.

## Testing Decisions

- A by-hand run in Safari and in one native app. Not runnable by an agent: it drives the screen.
- An agent-lab measure of how many real pages give a usable tree in Safari and in Chrome, before anything is built.

## Out of Scope

- The browser's cookies read from its files.
- Driving a browser through its own automation (AppleScript's page scripting, an extension). That would be another option.

## Further Notes

- Not recommended for websites: option 01 does the same without the screen, the grants or the exception.
- For native apps it may be the only way. It should wait for option 01 to show the loop on real sites, and for `panes-share-launchys-permissions` to make Varnick the only way to the screen.
