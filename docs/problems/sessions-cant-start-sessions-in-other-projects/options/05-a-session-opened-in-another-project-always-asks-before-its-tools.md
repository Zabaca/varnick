---
problem: sessions-cant-start-sessions-in-other-projects
title: Option 01, with the new session never skipping permission checks, whatever the setting and the caller
summary: As option 01, but a session `tab_open` starts always asks before its tools as Claude Code's own rules and that project's settings say, even while Skip permissions is on and the caller skips. The user answers each dialog in the new tab, called there by its Needs you notice. Opening a tab in another project then never gives a session the run of a repository the user hasn't watched it in, at the cost of every unattended helper stopping at its first tool that isn't allowed there.
status: proposed
---

## Solution

Everything in option 01 holds but the permission rule.

**Always ask.** A Claude session started by `tab_open` is saved as never skipping permission checks, and starts without skipping them at every start, whatever Settings › Claude › Skip permissions says and whatever the calling session was started with. It asks before each tool the project's own settings and the user's don't allow, in its own tab, and its turn's Needs you notice calls the user there (or on the phone, by Presence, as any notice).

**The rule elsewhere is unchanged.** `pane_open` keeps its rule (skip only while the setting is on and the caller skips), and so does every other way a session starts.

**The description says so,** so a caller does not open a helper it expects to run on its own.

## Trade-offs

- **The user sees every tool before it runs in a repository a lead chose.** The other project's instructions, hooks and settings may be ones the lead never read; nothing runs there that the user didn't allow or that project doesn't already allow.
- **Unattended work stops.** A lead that opens a builder while the user is away finds it waiting at its first command that isn't allowed; `notify_when_idle` does not fire, since a session waiting on a dialog still has a turn (inferred), and the lead waits on it too.
- **Two rules for two tools.** A helper beside the caller skips when the caller does, and one in another project doesn't; the guide says which.
- **No new code beyond the rule:** one fixed value where option 01 applies `pane_open`'s rule.
- **Not proposed: following Skip permissions alone,** as a prompt the user types in the panel does. That would give a caller that doesn't skip a session that does, against the rule where-it-breaks › Panel access sets for every tool that starts a Claude session.

## User Stories

1. As the user, I want a session a lead starts in another project to ask me before its tools, so that nothing runs there that I didn't allow.
2. As the user, I want the dialog to call me in that tab, here or on the phone, so that the helper doesn't sit waiting unseen.
3. As a session, I want the tool's description to say the new session asks before its tools, so that I don't open one to work unattended.

## Implementation Decisions

- **The new pane's record** is saved as never skipping, as `pane_open` saves a helper the rule refuses.
- **Docs** as option 01; the guide's sentence on permissions names the two rules.

## Testing Decisions

- **By hand after a restart,** as option 01, but: with Skip permissions on and a caller that skips, the new session asks before a command, its tab raises Needs you, and after a Restart of the pane and a restart of Varnick it still asks.

## Out of Scope

As option 01. A rule per project or per agent, kept in Settings, which would let the user name the repositories a session may open unattended.

## Further Notes

- **Verified in the code at 29551eb:** `pane_open` saves a helper the rule refuses as never skipping, so a later change of the setting doesn't make it skip; a typed prompt's session follows Skip permissions alone.
- **Combines with** option 01 (it is a change to it), and with options 02, 03 and 04.
