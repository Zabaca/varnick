---
problem: sessions-cant-see-or-act-on-the-screen
title: Start a chosen session outside zmx, as Launchy's own child, so it shares Launchy's grants directly
summary: No broker. The user starts a pane "with screen access", and Launchy runs its claude as a direct child rather than in zmx, the way every pane runs with Keep sessions running off. macOS then very probably gives that session Launchy's Accessibility and Screen Recording, so it uses any tool directly, and zmx stays ungranted for every other session. It is cheap and per pane, but it depends on an inheritance nobody has measured yet. Such a pane has no approval, indicator or record, and it ends when Launchy restarts. It also gets Launchy's microphone and system audio.
status: proposed
---

## Solution

A pane can be started with **screen access**, from a pane's menu item that starts it again in place. Launchy runs that pane's claude directly, through SwiftTerm, never in zmx, whatever Keep sessions running says. Its processes are Launchy's descendants, so macOS very probably attributes them to Launchy and gives them Launchy's grants. The session then uses `screencapture`, `osascript`, bigarrow or its own code.

## Trade-offs

- **Per pane, and no broker.** Only that session gets the grants; zmx stays ungranted, so every other session stays without them. Launchy builds a start path and a badge, nothing else.
- **It rests on an inference.**
  - That a direct child shares Launchy's grants is unmeasured.
  - `spoken-requests-cant-see-the-screen` option 01's hand check 2 and `panes-share-launchys-permissions` measure it.
  - If macOS doesn't pass the grants down, this option does nothing.
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

- **The measurement first:** in a pane started this way, after granting Launchy only, `AXIsProcessTrusted()` is true. If it isn't, reject this option.
- **By hand:** the badge shows; `screencapture` of a window works from the pane; a pane without the flag is still refused; restarting Launchy ends the pane, as the item said it would.

## Out of Scope

Any check on what the session does. Options 01 and 02 have them.

## Further Notes

- **Recommended only as a stopgap better than option 03,** until option 01 or 02 ships. It narrows the grant to the panes the user picks, at the cost of those panes ending at every restart.
- **ADR, on acceptance:** that Launchy deliberately starts some panes outside zmx so that they share its grants. It conflicts with any fix `panes-share-launchys-permissions` makes.
