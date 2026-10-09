---
problem: sessions-cant-see-or-act-on-the-screen
title: Keep zmx granted Accessibility and Screen Recording, so sessions act directly
summary: The baseline, to accept or reject. The interim grant stays, so every session zmx hosts sees and controls the screen with any tool it likes (screencapture, osascript, bigarrow, its own scripts), and Launchy builds nothing. That is every Claude pane while Keep sessions running is on, Skip-permissions sessions included. Nothing asks, nothing shows it happening, and nothing records it. ADR 0019 and 0021's rule that zmx is never granted is reversed. Recommended: reject.
status: proposed
---

## Solution

zmx keeps the Accessibility and Screen Recording grants the user gave it on 2026-10-09. Launchy changes nothing beyond writing the reversal down: an ADR, SECURITY.md and a line in Settings. Sessions use whatever tools reach the screen: macOS's own `screencapture` and `osascript`, bigarrow for arrows, and anything Claude writes.

## Trade-offs

- **Works today, for every tool.**
  - No Launchy code, no MCP server, no restart of a session.
  - A session can drag, scroll and script anything the system allows, beyond option 01's four verbs.
  - Other agents in panes get it too.
- **All or nothing, for every session in zmx.**
  - The grant is zmx's, and every pane's zmx session runs the one zmx binary. So it can't be given to one session.
  - A session started with Skip permissions clicks and types in any app without a single prompt.
  - So does anything such a session runs, and any process that gets into a zmx session.
- **Invisible.** Launchy sees none of it. No indicator, no record, no refusal of Launchy's own windows or of a password manager.
- **Screenshots without bounds.** A session can capture the whole display, every window and any password shown in clear. All of it can go to Anthropic with its context.
- **It outlives the reason for it.** The grant names zmx's code hash, and `make build` doesn't change zmx. It holds until the zmx pin changes or the user removes it.
- **It reverses a rule written for this risk.** ADR 0019 and 0021 kept zmx ungranted because a grant reaches every hosted session.

## User Stories

1. As a Launchy user, I want any session to use any screen tool without Launchy in the way.

## Implementation Decisions

- An ADR reversing ADR 0019 and 0021's zmx rule, and naming the risk.
- SECURITY.md and Settings say that zmx holds these grants, and what that gives every session.
- The `where-it-breaks.md` entry "zmx never granted" is removed.

## Testing Decisions

None beyond a check that a pane's process is trusted (`AXIsProcessTrusted()` true in a zmx pane).

## Out of Scope

Everything a broker adds: per-pane choice, approval, refusals, indicator, record.

## Further Notes

- **Recommended: reject.** Its reason, if rejected: a grant to zmx reaches every hosted session, Skip-permissions ones included, with no approval, indicator or record. Options 01 and 02 give the same reach to the sessions the user picks, with those checks.
- **Until another option ships,** this is the interim state. The problem's "The interim state, and its risk" covers it.
