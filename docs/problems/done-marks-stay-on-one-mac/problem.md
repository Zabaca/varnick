---
title: A session marked done on one Mac isn't done on the others
description: The session board's Completed column is each Mac's own. A session the user marks done on one Mac stays in Running or Stopped on every other paired Mac's board, or turns up there as an ended card in Stopped, until the user marks it done again on each Mac.
impact: The boards disagree about what is finished, so the user can't trust any one of them. Every Done has to be repeated on every Mac. Ended cards, which have no cap, pile up in Stopped on the Macs where the session wasn't marked.
severity: mid
evidence: The user's report of 2026-10-10, "the session board on other paired machines doesn't seem to share the completed state". Code read at 0b289b0 (main), protocol 19. Option 04 of session-turns-not-visible, shipped, decided "Done marks stay per Mac".
status: open
---

## What the user wants

Completed is shared. A session marked done on any paired Mac is in Completed on every paired Mac's board, and opening it from Completed anywhere takes it out everywhere.

This reverses a decision. When ended cards were designed (session-turns-not-visible, option 04), the user decided that Done marks stay per Mac and aren't synced, and option 01 of that problem left "syncing done marks between Macs" out of scope.

## Today

Verified in the code at 0b289b0.

**Where the mark lives.**
- Completed is a list in this Mac's `sessions.json`: the newest 20 records, by pane id, each with when it was marked done. No request or reply carries it.
- A session open in a pane on this Mac is never in Completed. The step that rebuilds Recent drops any Completed entry whose pane id or conversation is open in a pane here, before every save.
- The record already has an optional completed date, set only on Completed's copies.

**Done on each kind of board card.**
- **A pane here** (this Mac's own session, a pane in control of a paired Mac's session, or a pane showing its card): Done ends the pane as ⌘W does, and it goes into Completed once it has closed. A pane in control of a paired Mac's session sends `end`, and that Mac kills or releases the session.
- **A paired Mac's open session with no pane here:** Done only adds it to this Mac's Completed, with "Still open on <Mac>". Nothing is sent. The board leaves that Mac's listing of it out of Running and Stopped by this Mac's own Completed.
- **An ended card:** Done moves it to this Mac's Completed. Nothing is sent.

**What the other Macs see.**
- A session closed with Done on its host goes into that host's Recent as well as its Completed. A Mac that had it on its board sees it leave the host's `sessions` listing, finds its pane id in the host's `recent`, and makes it an ended card in Stopped. Recent's entries carry no mark, so it never reaches Completed there.
- On the host itself, a session that a paired Mac in control ended with Done closes as an ordinary close: the host's pane closes without Done, so it becomes an ended card in the host's Stopped.
- A session marked done on a paired Mac with no pane there stays Running or Stopped on its host and on every other Mac.
- A headless host keeps no Completed at all. Its records hold when a session ended, nothing more.

**The protocol.**
- Version 19. Any change to a request or reply's shape bumps it. A Mac on another version is refused outright, by the relay and by the app, before any reply is read, so there are never mixed versions to fall back for.
- `sessions` and `recent` are answered by the relay from the host's saved state, with Varnick not running. On a Mac the relay never writes that state. `start`, `resume` and `end` go to the running app, and fail with "Varnick isn't running" without it. On a headless host the relay is all there is, and it writes its own state folder under a lock.
- A paired Mac's `recent` is asked when the panel shows, on going back to search, and when the board opens, at most every 5 s. It is never asked of every Mac every 5 s, since a headless host's Recent reads each ended session's transcript. `sessions` is asked every 5 s while the board shows.
