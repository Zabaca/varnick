---
problem: sessions-cant-see-or-act-on-the-screen
title: Start a chosen session outside zmx, as Launchy's own child, so it shares Launchy's grants directly
summary: Moot since 2026-10-09. macOS attributes every pane process to Launchy, zmx-hosted ones included, so starting a pane outside zmx gives it nothing other panes lack. Recommended: reject. As first written: no broker. The user starts a pane "with screen access", and Launchy runs its claude as a direct child rather than in zmx, the way every pane runs with Keep sessions running off. macOS then very probably gives that session Launchy's Accessibility and Screen Recording, so it uses any tool directly, and zmx stays ungranted for every other session. It was meant to be cheap and per pane. Such a pane has no approval, indicator or record, and it ends when Launchy restarts. It also gets Launchy's microphone and system audio.
status: rejected
reason: macOS attributes every pane process to Launchy, zmx-hosted ones included (measured 2026-10-09, b16ad85), so starting a pane outside zmx gives it nothing other panes lack and narrows nothing.
---

## Solution

A pane can be started with **screen access**, from a pane's menu item that starts it again in place. Launchy runs that pane's claude directly, through SwiftTerm, never in zmx, whatever Keep sessions running says. Its processes are Launchy's descendants, so macOS attributes them to Launchy and gives them Launchy's grants. So does every zmx pane (Trade-offs). The session then uses `screencapture`, `osascript`, bigarrow or its own code.

## Trade-offs

- **Moot: it isn't per pane.** macOS's privacy service attributes a zmx-hosted pane's process to Launchy too (measured from its log on 2026-10-09, the problem's Today). Every pane already gets Launchy's grants, and this option adds nothing but a pane that ends at every restart.
- **What would make it per pane** is the reverse: start every other pane so that macOS doesn't hold Launchy responsible, and leave the chosen one as it is. That is `panes-share-launchys-permissions`' fix with an exception, and it belongs there.
- **Everything, unsupervised, inside that pane.**
  - No approval, refusals, deny list, indicator or record.
  - A Skip-permissions session started this way acts without a prompt.
  - Its subprocesses get the grants too.
  - It also gets Launchy's microphone and system audio grants.
- **It doesn't survive a restart.** Outside zmx, the session ends when Launchy restarts or quits (ADR 0004). A restart of Launchy, which other work asks for often, ends it.
- **It leans on a gap another problem may close.** `panes-share-launchys-permissions` may stop direct children from sharing Launchy's grants. This option would need that to stay open for chosen panes.

## User Stories

1. As a Launchy user, I want to start one session that can see and act on my screen with any tool, while every other session can't.
2. As a Launchy user, I want that pane marked, so that I know which one has the power.

## Implementation Decisions

- **Starting a pane with screen access.** A start flag on the pane's record (optional field) makes `startInTerminal` skip zmx for that pane.
  - Set from a pane-menu item that restarts the pane in place without zmx. Typed text starting with `!` is a Command, so the prompt line gets no word for it.
  - The item asks first, and names what the pane gets and that a restart of Launchy ends it.
- **A badge** on the pane's header and board card while it runs this way.
- **Nothing else.** The session finds its own tools.

## Testing Decisions

- **Already measured** for zmx panes: the privacy service's log names Launchy as responsible. The private responsibility lookup, tried first, misled. For a pane outside zmx, the same log entry would show the same, which is inferred.
- **By hand:** the badge shows; `screencapture` of a window works from the pane; a pane without the flag is still refused; restarting Launchy ends the pane, as the item said it would.

## Out of Scope

Any check on what the session does. Options 01 and 02 have them.

## Further Notes

- **Recommended: reject, as moot.** Its reason: every pane already gets Launchy's grants (measured 2026-10-09), so starting one outside zmx narrows nothing. A per-pane exception to the pane fix is `panes-share-launchys-permissions`' to design.
- **First written** as "a stopgap better than option 03", while the measurements of 2026-10-09 still read each process as its own.
- **ADR, on acceptance:** that Launchy deliberately starts some panes outside zmx so that they share its grants. It conflicts with any fix `panes-share-launchys-permissions` makes.
