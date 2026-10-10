---
problem: sessions-cant-see-or-act-on-the-screen
title: Grant Launchy Accessibility and Screen Recording, and let every pane's session inherit them
summary: The baseline, and today's real state whenever Point at the screen is granted. macOS attributes every pane process to Launchy, zmx-hosted ones included (measured from its privacy service's log on 2026-10-09). So while Launchy holds Accessibility and Screen Recording, every session sees and controls the screen directly, with any tool: screencapture, osascript, the user's helper, bigarrow or its own code. Launchy builds nothing. Nothing asks, nothing shows it and nothing records it, Skip-permissions sessions included, and any of them can click Allow in Launchy's own prompts. Recommended: reject as the lasting answer. This option was first "grant zmx" and then "keep a granted helper"; neither grant is consulted.
status: rejected
reason: It is today's state, not an answer. While option 01's permissioning is deferred, pane processes keep Launchy's grants, as this option describes. The planned end is that they stop getting them (panes-share-launchys-permissions option 01, a disclaimed spawn measured on 2026-10-09), leaving Launchy's tools as the only way to the screen.
---

## Solution

Launchy keeps the Accessibility and Screen Recording grants Point at the screen asks for, and its panes' processes keep being attributed to it. Sessions reach the screen with whatever tool they run. The user's helper (`com.zabaca.screenhand`, outside this repository, with subcommands `displays`, `shot`, `tree`, `activate`, `click`, `type`, `key`, `press` and `point`) works through Launchy's grants, not its own. Launchy changes nothing beyond writing the choice down.

## Trade-offs

- **Works whenever Launchy is granted, for every tool.** No MCP server and no restart. It covers more than option 01's four verbs: drag, scroll, scripts.
- **All panes, all sessions, no exceptions.**
  - Every pane process inherits, zmx-hosted or not, whatever Keep sessions running says.
  - A session started with Skip permissions clicks and types in any app without a prompt, and so does anything it runs.
  - It can't be narrowed to one session.
- **Invisible to Launchy.** Launchy sees none of it: no indicator, no record, no deny list, no refusal of its own windows.
- **It defeats any broker.** A pane process holds Accessibility, so it can click Allow in Launchy's prompts and act around options 01, 02 and 04.
- **Screenshots without bounds.** A session can capture the display, every window and any password shown in clear. All of it can go to Anthropic with the session's context.
- **It comes with Point at the screen.** Granting Launchy for Hey Launchy grants every session too. Taking the grant away takes Point at the screen with it.
- **A rebuild no longer drops it.** With ad-hoc builds, a rebuild after the grant stopped it applying (the pane's denial on 2026-10-09). Builds are now signed with Developer ID (ADR 0022), and both grants were measured to survive a rebuild, read true from a pane. Only the user removing them turns them off.

## User Stories

1. As a Launchy user, I want every session to see and act on my screen with any tool, as long as Launchy is granted.

## Implementation Decisions

- An ADR that records that pane processes share Launchy's grants on purpose, and names what that gives every session.
- SECURITY.md, the README and the Point at the screen detail text say plainly that granting Launchy grants every session in its panes.
- `where-it-breaks.md` says that any pane process can answer Launchy's prompts.

## Testing Decisions

Once Launchy holds a grant that matches the build on disk: from a zmx pane, a fresh binary's `AXIsProcessTrusted()` is true and `screencapture` works. The privacy service's log names Launchy as responsible.

## Out of Scope

Everything a broker adds: per-pane choice, approval, refusals, indicator, record.

## Further Notes

- **Recommended: reject as the lasting answer.** Its reason, if rejected: a grant to Launchy reaches every pane process, Skip-permissions sessions included, with no approval, indicator or record, and they can answer Launchy's own prompts. Options 01 and 02, with `panes-share-launchys-permissions` fixed, give the same reach to the sessions the user picks.
- **It is the interim** until another option ships. The problem's "The interim state, and its risk" covers it.
- **Earlier versions, both measured not to work on 2026-10-09:**
  - "grant zmx permanently": a zmx grant is never consulted;
  - "keep a granted helper binary": the helper's own grant is never consulted, because the privacy service asks about Launchy.
