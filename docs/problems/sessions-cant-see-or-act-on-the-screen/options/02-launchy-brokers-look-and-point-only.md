---
problem: sessions-cant-see-or-act-on-the-screen
title: Option 01 with look and point only; sessions never click or type
summary: Option 01's broker, MCP server, per-pane switch, refusals, deny list, indicator and record, with two tools instead of four. `look` lets a session see a window's elements, its recognised text or a picture of it. `point` lets it draw the Arrow. There is no `click` or `type`, so there is no approval to build and nothing a session can do to an app. The user acts on what the session shows them. What a session sees still goes to Anthropic. zmx is never granted, and the interim grant is removed.
status: proposed
---

## Solution

Everything in option 01, without `click`, `type` and the approval prompt. A session can look at a window and point at something in it. Acting stays with the user, who now gets told exactly where.

## Trade-offs

- **No new power over apps.** A session can't change anything on the screen, so a misread request or a confused session costs, at worst, an Arrow in the wrong place.
- **Most of the value for setup and checking.** "Click the switch I'm pointing at" covers permission dialogs, settings panes and checking a build's window. The user's click is the approval.
- **Less to build.** No approval panel, no synthetic events, no 10-minute grants.
- **Still a privacy step.** Element lists, recognised text and pictures go to Anthropic with the session (option 01's Trade-offs), so the per-pane switch, the deny list and the indicator stay.
- **It can grow into option 01.** The channel, the server and the switch are the same, so adding `click` and `type` later is the approval and two tools.
- **The user's two other asks go unmet:** "control apps" is not done.

## User Stories

1. As a Launchy user, I want a session with Screen access to see the window it is working on and point at what I should click, signed with its name.
2. As a Launchy user, I want no session ever to click or type in my apps, so that turning Screen access on is only ever about what it sees.
3. As a Launchy user, I want everything else in option 01: the per-pane switch, the deny list, the indicator and the record.

## Implementation Decisions

- **As option 01:** the settings, the per-pane switch, the server, the channel and its ancestry check, `look` and `point`, the refusals, the indicator, the record and the state. The zmx warning is kept too.
- **Not built:** `click`, `type`, the approval prompt and its grants. Option 01's checks that refuse acting on Launchy's own windows aren't needed. `look` and `point` still refuse Launchy's windows and denied apps.
- **The tool descriptions** tell Claude it can't act and should ask the user, pointing with the Arrow.

## Testing Decisions

Option 01's seams and hand checks for `look` and `point`. Also: no tool named `click` or `type` is listed by the server.

## Out of Scope

Acting on apps (option 01). Everything in option 01's Out of Scope.

## Further Notes

- **Accept alone, or as the first step of option 01.**
- **ADR:** as option 01's, with "sessions see and point, never act".
