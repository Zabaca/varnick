---
problem: session-turns-not-visible
title: A board in the panel, with turns read from Claude's terminal title
summary: The same board as option 01, but the turn comes from the status glyph Claude Code puts at the start of its terminal title, which every pane with a client here already receives. Nothing changes in the claude command line or the peer protocol. Where no client is attached here (tabs not opened since a restart, cards, and sessions open on paired Macs), the turn isn't known.
status: proposed
---

## Solution

Every Claude pane with a client here already receives Claude Code's terminal title. Launchy's code drops a leading status glyph from it for the pane's label, a spinner while Claude works and ✳ while it waits (as the code describes it; not confirmed in 2.1.291). This option reads that glyph instead of dropping it: a spinner glyph is working, ✳ is waiting.

The board, its keys and commands, opening a card, Done and the Completed list are option 01's, unchanged. Paired Macs' open sessions are on the board as in option 01, but their turn isn't known.

## Trade-offs

- **Nothing outside the app changes:** not the claude command line, the relay or the protocol. It ships in one step with no rebuild of the other Macs and no reinstall on the Ryzen. Sessions already running have a turn at once.
- **An interrupt shows at once,** if the title stops spinning when Claude stops (unverified).
- **The turn is known only where a client is attached here.** After a Launchy restart every tab is dormant until it is opened, so every tab but the one on screen is not known, which is when the board is most needed. Cards and paired Macs' sessions are never known.
- **Paired Macs' sessions are on the board without a turn.** Giving them one later still needs a protocol change, and more: the title lives only in the running app's memory, where the relay, which reads from disk, can't see it.
- **It reads an undocumented detail of how Claude Code draws.** The glyphs weren't confirmed in 2.1.291, its minified title code wasn't found, and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` turns the title off; a login shell that exports it would leave every card not known. A Claude Code release can change the glyphs with no error, only a wrong board.
- **It can't show the "Needs permission" mark the user decided on (option 01, Permission dialogs),** nor the proposed marks for a question, a plan or an MCP request. Whether the title shows a permission dialog at all is unknown. The glyph follows Claude's own activity, and 2.1.291's minified code doesn't show whether a waiting dialog counts as active or idle. So a permission wait reads either as Running or as a plain Stopped, never as marked. The one status in 2.1.291 with a "needs you" state comes from a "Show status in terminal tab" setting. That setting is off by default, offered only behind a feature flag, and where it writes wasn't found. Untested.

## User Stories

As option 01's, with three limits. Story 3 isn't met: a tab not opened since a restart has no client here, so its turn isn't known. In story 1 the paired Macs' sessions have no turn. Story 14 is met at once, but only for a pane with a client here, and only if the glyph stops when Claude does.

## Implementation Decisions

- A pane's turn is read from its title as it arrives: a leading glyph of the spinner's set is working, ✳ is waiting, and any other title, or none, is not known. The two sets are named constants beside the label code that drops the glyph today.
- Before building, check the glyphs by hand in 2.1.291: during a turn, at rest, during a permission dialog, and after esc. If the title shows nothing distinct during a dialog, permission waits go unmarked in this option.
- Not known: a pane not started, a pane showing a card, and every paired Mac's open session. Those cards go in Stopped marked "Turn not known" (option 01, open question 2).
- A pane on a peer that this Mac controls has its ssh client attached here, so its title carries the glyph and its turn is known.
- The board, keys, commands, opening, Done, Completed and saved state: as option 01. The peers part of option 01 is limited to listing their open sessions, with no protocol change: no turn field, no version bump.

## Testing Decisions

- As option 01, without the Linux build, the protocol mismatch check and the reinstall. Also check that every not-known case shows as such rather than as a wrong turn.

## Out of Scope

As option 01, and turn state for any session with no client here.

## Further Notes

- **It can be the first step of option 01:** the board, Done and Completed are the same, and option 01's hooks can replace the title reading later. The title code would then go.
- Recommended against as the whole answer: the board would be blank exactly where it has to work, in background tabs after a restart and on the other Macs.
