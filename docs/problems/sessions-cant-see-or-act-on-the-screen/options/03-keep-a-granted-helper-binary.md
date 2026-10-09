---
problem: sessions-cant-see-or-act-on-the-screen
title: Keep the interim helper binary granted Accessibility and Screen Recording, so sessions act through it directly
summary: The baseline, to accept or reject. The helper binary the user granted on 2026-10-09 stays granted, and Launchy builds nothing. Its subcommands are displays, shot, tree, activate, click, type, key, press and point. Any process of the user can run it and get its powers, which includes every pane's session, Skip-permissions ones too, and anything they start. Nothing asks and Launchy shows nothing. The helper can also click Allow in any prompt of Launchy's. This option first read "grant zmx permanently", which was measured not to work: macOS checks each executable in a pane as itself. Recommended: reject as the lasting answer.
status: proposed
---

## Solution

The helper keeps its grants. It is a small executable of the user's, outside this repository, ad-hoc signed with the identifier `com.zabaca.screenhand`. Sessions run it from Bash: `shot` for a picture, `tree` for a window's elements, `click`, `type`, `key` and `press` to act, and `point` to mark. Launchy changes nothing beyond writing the choice down.

## Trade-offs

- **Works today, with no Launchy code.** No MCP server and no restart. It covers more than option 01's four verbs: activate and key, as well as whatever the helper gains later.
- **The grant goes to whoever runs it.** macOS checks the helper as itself whichever process runs it (the problem's Today), so:
  - every session in every pane can run it;
  - a session with Skip permissions clicks and types in any app without a prompt;
  - so can any script or process of the user.
- **Invisible to Launchy.** Launchy has no indicator, no record, no deny list and no refusal of its own windows, beyond what the helper does itself.
- **It defeats a broker's approval.** With Accessibility it can click Allow in a prompt of Launchy's, so options 01 and 04 can't rely on their approval while it is granted.
- **Screenshots without bounds.** `shot` can capture any window or the display, passwords shown in clear included. All of it can go to Anthropic with a session's context.
- **Outside the repository.** Nothing here reviews what it does or how it changes. Its grant names its code hash, so a rebuild probably drops the grant (inferred), and Settings can't see it.
- **Granting zmx instead does nothing** (measured 2026-10-09), so this, or a helper like it, is the only direct route.

## User Stories

1. As a Launchy user, I want any session to see and act on my screen through one tool I granted, without Launchy in the way.

## Implementation Decisions

- An ADR that records the helper as the way sessions reach the screen, and names the risk: any same-user process holds its powers.
- SECURITY.md and Settings say a helper with these grants exists, and what it lends to every session.
- `where-it-breaks.md` says that any executable granted Accessibility can answer Launchy's prompts.

## Testing Decisions

None beyond the helper's own checks: from a pane, `tree` lists a window and `shot` writes a picture.

## Out of Scope

Everything a broker adds: per-pane choice, approval, refusals, indicator, record.

## Further Notes

- **Recommended: reject as the lasting answer.** Its reason, if rejected: a granted executable lends its powers to every process of the user, Skip-permissions sessions included, with no approval, indicator or record, and it can answer Launchy's own prompts. Options 01 and 02 give the same reach to the sessions the user picks, with those checks.
- **It is the interim** until another option ships. The problem's "The interim state, and its risk" covers it.
- **First version:** "grant zmx permanently", written before the measurement of 2026-10-09 showed that a zmx grant reaches no pane process.
