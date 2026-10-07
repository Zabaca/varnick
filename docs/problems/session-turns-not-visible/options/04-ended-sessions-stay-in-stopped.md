---
problem: session-turns-not-visible
title: Sessions that end stay in Stopped until marked done
summary: Option 01's board with one change. A Claude session whose pane closes without Done (End session in its tab, closing the tab, `/exit`, claude exiting) stays in Stopped as an ended card, below the live cards. It leaves only when the user marks it done (it moves to Completed) or opens or resumes it. There is no cap, and the cards are kept in `sessions.json`. A paired Mac's session that this Mac listed open and that ends there does the same, with its ^host pill. This Mac remembers the sessions it listed. When their Mac answers without one, this Mac looks for its pane id in that Mac's Recent, whose entries gain their session (a protocol bump). A Mac that stops answering ends nothing.
status: accepted
---

## Solution

The user's report of 2026-10-07: "when I close a session, they disappear from the session board … instead of them going to completed, it should be in stopped. completed is a move I make." Today a pane that closes any way but Done goes to Recent and leaves the board.

This option keeps option 01 as built and changes one rule: **only Done takes a session off the board.** A Claude pane here that closes without Done leaves an **ended card** in Stopped, saying "Ended 4m ago", below the live cards. Done moves the card to Completed, with no question, since there is nothing to end. ↩ resumes it in a new tab, as Recent's ↩ does, and its card is live again. Resuming the session any other way also takes the ended card away.

A paired Mac's session works the same way. The open sessions this Mac lists are remembered. When a session's Mac answers without it, this Mac looks for its pane id in that Mac's Recent. If it is there, its pane closed on that Mac, and the session becomes an ended card with its ^host pill. If it isn't, the Mac restarted and restored the pane (which closes nothing, as quitting closes nothing here), or the session had nothing to resume. Either way it stays off the board, as it is today. A Mac that doesn't answer ends nothing.

## Trade-offs

- **This Mac's part needs no protocol change** and fixes the report for every session closed here. It can ship first (Further Notes).
- **The paired Macs' part bumps the protocol.** Recent's entries carry the conversation, not the session, so nothing a paired Mac sends today can tell which session closed (verified). Both Macs must be built from one commit, and the Ryzen's relay must be reinstalled. Once peers-upgraded-by-hand option 03 ships, the Upgrade button does that.
- **Stopped grows until the user marks cards done** (no cap, decided). Ended cards sit below the live ones, so a session waiting on the user stays on top. `sessions.json` grows by one record per ended session, and the relay decodes that file on every request a peer makes. A file of a few hundred records is still small (inferred).
- **A session ended on one Mac is an ended card on every Mac that listed it,** and each Mac marks it done separately (decided: Done marks stay per Mac).
- **A paired Mac's card leaves the board for a moment.** It goes when its Mac's answer stops listing it, and comes back as an ended card once that Mac's Recent holds the end. That usually takes one more request, about a second. While the board shows it takes at most one 5 s refresh, and otherwise it waits for the next time the panel shows. The highlight moves to a neighbour meanwhile and doesn't come back.
- **Recent is asked more often while the board shows,** but only of a Mac that has just stopped listing a session. Asking every Mac every 5 s would cost too much on the Ryzen, whose Recent reads each ended session's whole transcript for its title (verified).
- **Some ends on a paired Mac are missed,** most of all a session that starts and ends there while this Mac isn't listing that Mac's sessions (What is missed, below).

## User Stories

As option 01's, and:

18. As the user, I want a session I close in its tab, by closing the tab or with `/exit`, or one whose claude exits, to stay in Stopped, so that only my own Done takes it off the board.
19. As the user, I want ended cards kept across restarts with no limit, so that nothing I haven't dealt with disappears.
20. As the user, I want to open an ended card and have it resume in a new tab with its card live again, so that I can go back to it from the board.
21. As the user, I want Done on an ended card to move it to Completed without a question, so that marking it is one press.
22. As the user, I want a paired Mac's session that I saw on the board and that ends there to stay in Stopped with its ^host pill, and to resume on that Mac when I open it.
23. As the user, I want a Mac that goes quiet or restarts not to fill Stopped with sessions that never ended.
24. As the user, I want a session I resume some other way (Recent, search, `/resume`, or at its Mac) to leave the ended cards, so that it never shows twice.
25. As the user, I want ended cards below the live ones, newest first, so that the sessions waiting on me stay on top.

## Implementation Decisions

**Which closes leave an ended card** (decided by the user on 2026-10-07: closed panes only)
- The closes that leave an ended card are the ones that put a session in this Mac's Recent today, and the card is added at the same point: the pane's exit handler, once the pane is out of its tab. Each of these was traced in the code:
  - End session in a tab;
  - the tab's close button, which ends each pane the way End session does;
  - `/exit`, and claude exiting;
  - a session that ended on its host while this Mac was in control of it;
  - a start that failed.
- **One close Recent leaves out:** a pane here showing the card of a paired Mac's session that another Mac controls. When the card's own check finds the session gone, it is an end there, and the pane leaves an ended card. When the user closes that card, the session runs on, so it leaves none and comes back as a live card at its Mac's next answer. The pane's private closed-by-user flag tells the two apart. The user's close sets it and the card's check doesn't (verified). The pane exposes it read-only.
- **Done leaves no ended card:** a pane closed by Done goes to Completed only, as today, at the same point in the exit handler.
- **Only a session that can be resumed:** one with its transcript here, or one on a paired Mac. Recent and Completed have the same rule. A pane closed before its first message leaves nothing, since there is nothing to resume.
- **`/clear` and `/resume` close nothing** (decided). The card follows the pane, and the conversation left behind goes to Recent only, as today.
- **Quitting or restarting Launchy closes nothing** (decided). The exit handler does nothing while Launchy quits, and a restart by signal runs no code at all (verified). The tabs come back as today, with "Resumes when opened" on a pane whose zmx session is gone.
- **A released session:** a pane closed while in control of a paired Mac's session that its host releases instead of ending. Today the release takes the session out of Recent. It takes the ended card away the same way, and the session comes back as a live card.

**The ended card**
- **Placement:** in Stopped, after this Mac's panes and the paired Macs' open sessions, newest end first (picked: the live cards are the ones that need the user).
- **Contents:** option 01's Standard card, with the title, the session list's pills (^host for a paired Mac's session) and the folder when no `#project` pill names it. The turn line says "Ended 4m ago", counted from the end, in the secondary colour, with no mark. A selected ended card says "↩ resumes it in a new tab", as a selected Completed card does. The word is Recent's: CONTEXT.md lists "closed sessions" under Recent's words to avoid.
- **Id:** the card's id is the pane's, as every board card's is, so the highlight follows a session from a live card to its ended card and back. Ended cards are found, replaced and dropped by pane id, never by conversation (where-it-breaks › Focus and keys).
- **Header count:** Stopped's header counts ended cards with the rest. The permission count doesn't change (picked).
- **An unpaired Mac:** an ended card of a Mac that is no longer paired is hidden and kept in the saved state, as Completed's cards are (verified).

**Done and open**
- **Done** (D, the End session key, or a drag onto Completed) moves the card to Completed at once. There is no question, since nothing is left to end, as for a paired Mac's card with no pane here. Completed still keeps the newest 20.
- **Open** (↩ or a double-click) resumes the session as Recent's ↩ does, and the board closes as the tab opens.
  - A session of this Mac resumes in a new tab under the same pane id, since a local resume reuses the record's id (verified). Its card turns live in place.
  - A paired Mac's session resumes there with the `resume` request, into a new pane here with a new id (verified).
  - In both cases the ended card goes at once.

**Leaving without Done** (decided by the user: an ended card stays until Done, open or resume)
- **When it goes:** once the session is open again anywhere. That is either of:
  - its pane id is a pane here or is listed open by a paired Mac: resumed in place, released, or a session that only looked ended;
  - its conversation is open in a pane here or on a paired Mac: resumed from Recent, from search, with `/resume` in another pane, or at its own Mac.
- **Recent's rule, not Completed's:** this is the rule Recent's list follows, which leaves out conversations open here or on a paired Mac (verified). Completed is cleared only of what is open here (verified). Picked so that a session resumed at its Mac doesn't show both live and ended.
- **Where it runs:** where Completed is cleared today, before every save. So a pane id is never a live card and an ended card at once. The board also skips an ended entry whose id already has a card.
- **At load:** an entry of this Mac whose transcript is gone is dropped, as Recent and Completed drop theirs.
- **No other removal:** nothing else takes an ended card away (decided: no cap).

**Saved state**
- **The `ended` list:** the saved state gains an optional list beside `completed`, saved as nil when it is empty. An older file loads, and an older build ignores the list and drops it at its next save (inferred: an unknown key doesn't fail a decode).
- **Records:** the same records Recent holds. That is the pane's record as it closed, or for a paired Mac's session a record built from its Recent entry. The record gains no field. Its last-used date is when it ended, and Done sets its completed date as it moves to Completed.
- **Keyed by pane id:** a new entry for a pane replaces the old one.
- **Never sent:** the marks are this Mac's own (decided). No peer reply includes them.

**A paired Mac's sessions** (decided by the user: the same rule)
- **What a paired Mac says today** (verified):
  - its open sessions (`sessions`), which are the Claude panes in its saved tabs whose zmx session runs;
  - its Recent, as conversation, title, folder, agent and end time.
- **What a missing session can mean.** A session missing from the next answer has ended there, or its Mac restarted (a reboot, or a quit with Keep sessions running off). A restart closes nothing: the Mac restores the pane. Recent tells the two apart. A pane that closed there is in that Mac's Recent, and a restored one isn't.
- **Remembered sessions.**
  - **What is kept:** every successful `sessions` answer adds or refreshes one record for each session the board would show from it, meaning no pane here and not in Completed. The record holds the pane id, the Mac, the title, folder, agent and conversation, and when the session was last listed.
  - **Saved:** in a second optional list in the saved state, so an end that happens while this Launchy restarts is still found.
- **The end.** A remembered session has ended when both of these hold:
  - its Mac's latest `sessions` answer succeeded without it;
  - its Mac's Recent, answered after the session was last listed, has an entry with its pane id.

  It then becomes an ended card built from that entry, and leaves the remembered list. The entry's conversation, title, folder, agent and end time are newer than the remembered ones after a `/clear` there. Requiring a Recent answered after the last listing keeps an old Recent from ending a session that has since been resumed under the same pane id there.
- **Recent's entries name their session** (protocol bump).
  - **The field:** each entry gains an optional session, its zmx session's name.
  - **On a Mac:** the relay fills it from the record's id. For a pane's close that is the pane id. For a conversation left by `/clear` it is a fresh id that no session ever had, so it never matches (verified).
  - **On the headless host:** it fills the field from the record's id, which is always the session's.
  - **The Phone page:** it builds its rows from the fields it names, so it doesn't use this one.
- **A Mac that doesn't answer ends nothing.** With no answer nothing is checked, and its remembered sessions wait. Its live cards leave the board, as they do today.
- **A Mac that restarted:** its sessions aren't listed until they run again, and aren't in its Recent. They stay remembered and off the board, and come back as live cards once they are resumed there.
- **When Recent is asked:**
  - **Today:** when the panel shows, and on going back to search (verified).
  - **Added, when the board opens:** of every Mac that answers, at most once every 5 s.
  - **Added, after an answer that drops a session:** when a Mac's answer leaves out a session it listed within the last minute, that Mac alone is asked at once, then with each 5 s refresh while the board shows. Other Macs' requests aren't cancelled.
  - **Why the repeat:** a close reaches a Mac's Recent a moment after its zmx session goes (the pane's exit check and the save, inferred), so the first request can come too early.
  - **Why it stops:** after a minute, a session still unresolved (its Mac restarted, or the session had nothing to resume) stops triggering requests.
  - **An unchanged reply** still counts as answered at the time it came.
- **Forgetting.** A remembered session is forgotten when it ends (it becomes an ended card), when a pane here takes its id (that pane's close is then this Mac's), when it is marked done, when its Mac is removed, or after 30 days without being listed (picked).
- An ended card of a paired Mac follows every rule above.

**What is missed when this Mac isn't watching.** This Mac lists a paired Mac's sessions only when the panel shows, on going back to search (at most every 5 s), and every 5 s while the board shows (verified). Missed:
- A session that starts and ends there between two listings is never on this board (open question 2).
- An end that has left that Mac's Recent before this Mac asks:
  - a Mac's Recent holds 20 entries, so more than 20 closes and `/clear`s there in the meantime push it out;
  - the conversation was resumed there, which the rule above takes off the board anyway;
  - on the headless host, Recent shows one entry per conversation, so a later end of the same conversation hides an earlier one.
- A pane that was restored there and closed without running again, more than 30 days after this Mac last listed it.
- A session closed before its first message, which no Recent lists.
- An end found late: with the panel hidden, it shows up at the next panel show.

**Protocol**
- **The version:** the next one. Main is at 14 (verified). Peers-upgraded-by-hand's 15 is on a branch now (verified), so this is 16 if that lands first.
- **Rollout:** both Macs on one commit, and the Ryzen's relay reinstalled (ADR 0009), or upgraded with the Upgrade button once that option ships.
- **Builds:** the package must build on Linux, and the Phone page's copy of the version moves with it (its test checks it).
- **A mismatched Mac:** a Mac left on the old protocol is refused as today. Its cards leave the board, and none becomes an ended card.

## Testing Decisions

- No test target yet. The pure parts are where tests would go once there is one:
  - which closes leave an ended card, including the closed-by-user card;
  - the end check (remembered sessions, latest answer, and a Recent answered after the last listing);
  - the rules for leaving without Done;
  - the order of the cards.
- `make build`, `swift build` of the package on the Ryzen, and `bun test` in the Phone page for its protocol constant.
- By hand, after the user restarts Launchy (leave the restart to the user) and reinstalls the Ryzen's relay:
  - **Closes here.** End session in a tab, the tab's close button, `/exit`, and killing claude each move the card to Stopped, below the live cards, saying "Ended just now". The card is still there after a restart.
  - **Not closes.** `/clear` and `/resume` keep the card live on the new conversation. A restart of Launchy ends nothing. A pane closed before its first message leaves no card.
  - **Done.** On an ended card, D, the End session key and a drag onto Completed each move it to Completed without a question. Done on a live card still goes to Completed only, never to Stopped.
  - **Open.** ↩ on an ended card resumes it in a new tab with focus, and its card is live in place.
  - **Resumed another way.** Resuming the conversation from Recent, from search or with `/resume` in another pane takes the ended card away.
  - **A paired Mac's session.** A session on the Air that the Studio's board lists, closed on the Air with End session, appears on the Studio's board as ended, with ^air, within about 5 s. ↩ resumes it on the Air in a new pane here, and Done moves it to Completed. The same holds for a Ryzen session ended with `/exit` while another Mac controls it.
  - **A Mac that stops or restarts.** The Air asleep or unreachable: its cards leave and none becomes ended. The Air rebooted: its sessions leave, none becomes ended, and they come back live once resumed there.
  - **Cards and releases.** On the Air, closing the card of a Studio session the Studio controls leaves no ended card on the Air, and the session shows live again. With the Air in control of a session the Studio started, End session on the Air releases it: no ended card, and it shows live again.
  - **Late and missed ends.** A session closed on the Air while the Studio's panel is hidden shows as ended at the Studio's next panel show. One started and closed on the Air while the Studio's panel stays hidden never shows (expected).
  - **Version mismatch.** A Mac on the old protocol is refused, and its cards leave without becoming ended.

## Out of Scope

- **Syncing marks:** ended or done marks between Macs (decided).
- **Quiet and restarted Macs:** keeping a quiet Mac's sessions on the board as unreachable cards, and showing a restarted Mac's restored sessions, which today leave the board until they run again.
- **Other panes:** ended cards for shells, web, file and app panes.
- **Clearing in bulk:** a cap or a "clear all ended" action (decided: no cap).
- **Unseen ends:** sessions that start and end on a paired Mac between two listings (open question 2).
- **A refactor worth raising, not asked for:** the step that rebuilds Recent now also clears Completed, the ended cards and the remembered sessions. A small value that owns those three lists, with pure rules for clearing them, would make the rules testable once a test target exists.

## Further Notes

- **Why a new option.** Option 01 is accepted, so its status and text are the user's. Options 02 and 03 are already written against option 01. If this option is accepted, option 01 stays the spec except where this one says otherwise: what Running and Stopped hold, and Completed being the only place a closed session goes.
- **Decided by the user on 2026-10-07:**
  1. Which sessions: closed panes only. That is the End session shortcut in a tab, closing the tab, `/exit` and claude exiting. `/clear` and `/resume` keep the pane open, so its card follows the new session and the old one goes to Recent only, as now. Quitting Launchy closes nothing, because panes are restored.
  2. How long: a closed session stays in Stopped until the user marks it Done (it then moves to Completed) or opens or resumes it. There is no cap, and it is saved across restarts.
  3. Paired Macs: the same rule. A paired Mac's session that ends there stays in Stopped on this Mac's board as a closed card with its ^host pill, and is resumed on that Mac. Done marks stay per Mac and aren't synced.
- **Shipping in two steps** suits `/to-tickets`. First this Mac: ended cards, Done, open, the leaving rules and the saved list, with no protocol change. Then the paired Macs: remembered sessions, Recent's session field and the protocol bump, the end check and when Recent is asked.
- **Docs to update with it:**
  - CONTEXT.md's Session board entry: Stopped also holds sessions that ended without Done, and Completed is reached only by Done.
  - where-it-breaks:
    - › Focus and keys: an ended card is added in the exit handler beside Recent, never with Done, and dropped by pane id or conversation before the save.
    - › Peers: Recent's session field; an end is read only from answers newer than the last listing; a quiet Mac ends nothing.
  - No ADR: this extends a mechanism already recorded (ADR 0007's requests) with one field.
- **Considered and not proposed:**
  - **Matching by conversation, with no protocol change.** It fails in two cases:
    - After a `/clear` there, the conversation this Mac remembered is in that Mac's Recent while the session runs on. If that Mac then restarts, the restored session looks ended.
    - With `/clear` and then `/exit` between two listings, the card would resume the conversation `/clear` left behind, not the one the session ended on.
  - **Missing from the answer counts as ended.** A restart there would end every card.
  - **Every pane close in a paired Mac's Recent since this Mac last looked.** Open question 2. It also needs a Mac to tell a pane's close from a conversation `/clear` left, which its saved records don't say.
  - **A list of ends added to `sessions`, or `status` asked for each missing session.** Each is a new shape for what Recent already means.
- **Verified in the code at 651cacf:**
  - where Recent is filled and which closes reach it;
  - the closed-by-user flag and the card's own check;
  - that the tab's close ends each pane;
  - that quitting skips the exit handler;
  - that a local resume reuses the pane id and a resume on a peer makes a new one;
  - Completed's and Recent's clearing rules;
  - when this Mac asks its peers, and that a quiet Mac's rows are dropped;
  - that opening a paired Mac's session takes it out of the last answer;
  - what `sessions` and `recent` hold on a Mac and on the headless host, including the transcript read per title;
  - that a `/clear` gives its Recent entry a fresh id;
  - the protocol at 14 on main and 15 on a branch;
  - the Phone page's protocol constant and its test, and that its Recent rows take only the fields they name.
- **Inferred, not tested:**
  - the delay between a zmx session going and a Mac's Recent holding its close;
  - that an older build ignores the new saved lists;
  - that `sessions.json` stays small enough with an uncapped list.
- **Picked to match existing behaviour (the user can change any of them):**
  - "Ended" as the word;
  - the cards' place and order;
  - the header count;
  - Recent's leaving rule rather than Completed's;
  - 30 days for a remembered session;
  - a minute of extra Recent requests after a session drops out of an answer.
- **Open questions,** both decided by the user on 2026-10-07 as recommended (option accepted the same day):
  1. Paired Macs' ends by pane id, at the cost of a protocol bump, or by conversation with none? **Decided:** by pane id. The bump is one round, or one Upgrade press once peers-upgraded-by-hand ships. By conversation, a `/clear` there makes the card resume the wrong conversation, and a restart there can make it look ended.
  2. Should a paired Mac's session this Mac never listed (started and ended while this Mac wasn't looking) appear in Stopped when it ends? **Decided:** no, which is this option. "Stays in Stopped" implies it was on the board. The alternative would put every session ended on any Mac onto every Mac's board, each to be marked done on each Mac. It would also need each Mac to record which Recent entries are pane closes.
