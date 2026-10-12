---
problem: done-marks-stay-on-one-mac
title: The session's host keeps its done mark, and every Mac reads it from there
summary: A session's done mark belongs to its host, the machine its zmx session runs on. Done on another Mac's session sends a new `done` request to that host, which marks the session without ending anything: in Completed if it has ended there, on the pane's own record if it is still open. The host's `sessions` listing and its Recent entries carry the mark (a protocol bump), and every paired Mac puts a session its host marks in Completed, with "Still open on…" while it runs. Opening a still-open session from Completed clears the mark on its host. A headless host keeps the mark on its own session records. A Done the host can't take stays on that Mac only, as today, and its card says so.
status: shipped
---

## Solution

Every session has one host, which never changes. This option makes the host the one place its done mark is kept, and every Mac's Completed a reading of the hosts' marks plus its own.

**On the host.** A session that has ended there is marked as it is today, in the host's Completed. A session still open there is marked on its pane's own record. That is new: today a pane here is never in Completed, and a mark kept in Completed would be dropped at the next save, since every session a host lists open is a pane in its own tabs. The host's board shows such a pane in Completed with "Still open here". Closing that pane any way puts the session in Completed, never in Stopped. ↩ on its board card shows the pane and takes the mark off.

**Telling the host.** Done on a session whose host is another machine (a pane here that closes with Done, a paired Mac's card with no pane here, an ended card) moves it to this Mac's Completed at once, as today, and then sends that host a `done` request. The host marks the session and ends nothing. Only the Mac in control may end a session, and a mark is not an end.

**Reading the marks.** The host's `sessions` listing says, for each open session, whether it is marked and since when. Its Recent entries say the same for ended ones. Each Mac takes in what its hosts say:
- A session its host marks is in Completed, with "Still open on <Mac>" while the host lists it open. It is never a Running or Stopped card, and an ended card of it moves to Completed.
- A mark that came from its host leaves Completed when the host lists that pane, or a pane on the same conversation, open without the mark. That is how an open or a resume on any Mac reaches the rest.

**Clearing.** ↩ on a Completed card of a session still open on its host opens it on its card, as today, and sends `done` to clear the mark there. Resuming an ended one needs no clear: the host's own rule already drops a conversation that is open again from its Completed.

**A Done the host can't take.** Its host is asleep, Varnick isn't running there, or it no longer lists this Mac. The mark stays on this Mac only, as every mark does today, and the card says "Done on this Mac only". Nothing sends it again.

## Trade-offs

- **It reverses a decision.** Option 04 of session-turns-not-visible decided that Done marks stay per Mac. That option stays shipped. This one replaces that one rule.
- **A protocol bump.** Every Mac is built from one commit and the headless host is upgraded with its Upgrade button. A Mac left on the old version is refused, as for any bump, so it never shares or receives a mark.
- **The host's board changes too.** A pane open on the host can now sit in Completed there, because another Mac marked it. The user may keep working in that tab while its card says done (open question 1).
- **A mark on an open session reaches the other boards within about 5 s while they show,** through the listing they already ask for every 5 s. **A mark on an ended session waits for the next panel show or board open,** since Recent isn't asked every 5 s (a headless host reads each ended transcript to answer it).
- **A Mac's Done needs its host to answer.** A sleeping laptop's sessions, marked from another Mac, stay done on that Mac only. The same holds for a Mac host whose relay answers but whose Varnick isn't running, since the relay never writes a Mac's saved state.
- **Marks made before the upgrade stay on the Mac that made them,** each with "Done on this Mac only" (open question 4).
- **Completed is still the newest 20 on each Mac.** A host reports only what its listing and Recent (20 conversations) hold, so the older end of Completed can differ between Macs.
- **No ping-pong.** Only a user's action changes a host's mark (a Done or an open, each sent once), and a Mac follows its host's word only for marks that came from that host. Nothing re-sends a mark the host has dropped.

## User Stories

1. As the user, I want a session I mark done on any Mac to be in Completed on every paired Mac's board, so that I mark it once.
2. As the user, I want a session closed with Done on its own Mac to go to Completed on the other Macs, not to an ended card in Stopped.
3. As the user, I want Done on another Mac's session that I'm not in control of to mark it on its host without ending it there, so that a Mac that isn't in control never ends a session.
4. As the user, I want a session marked done while it is still open to show "Still open on <Mac>" on the other Macs and "Still open here" on its host.
5. As the user, I want Done on an ended card of another Mac's session to move it to Completed on that Mac and the rest, so that ended cards don't pile up elsewhere.
6. As the user, I want Done in the Mac in control of a session to reach its host, so that the host's own board shows Completed, not an ended card.
7. As the user, I want opening a Completed session on any Mac to take it out of Completed everywhere, so that no Mac shows live work as done.
8. As the user, I want a Done that couldn't reach its host to stay on the Mac I pressed it on and say so, so that I know why the boards differ.
9. As the user, I want sessions on a headless host to share their done marks too, though it has no board of its own.
10. As the user, I want a Mac no longer paired to neither send nor receive marks, so that removing a Mac cuts it off from my boards.

## Implementation Decisions

**Where a host keeps a mark**
- **An ended session of a Mac host:** its Completed list, as today, by pane id.
- **An open session of a Mac host:** the completed date on its pane's record, kept in the saved tabs. Only a Claude pane that runs on this Mac (not one on a peer) carries one. Restoring tabs at launch keeps it.
- **A session of a headless host:** an optional done date on its session record, written by the relay under the state folder's lock. Running or ended, the record is the one place.
- **Recent's copies carry no mark.** The relay reads an ended session's mark from Completed by pane id, never from the Recent record. A Done on an ended card changes only Completed's copy, and the Recent copy of a pane closed with a mark would keep a stale one.
- **A session opened again in a new pane here starts unmarked:** a resume from Recent or search reuses the Recent record, so the mark is taken off any record a pane is started from, except a restored tab's.

**The host's board**
- A pane whose record is marked is a Completed card, dated by its mark, with "Still open here". Completed shows marked panes and the Completed list together, newest first. Done, R and dragging do nothing on it, as on every Completed card.
- ↩ on it shows the pane and takes the mark off.
- A marked pane that closes, by any close, goes to Completed with its mark's date and to Recent, never to Stopped. That is the Done rule at the pane's exit, with "marked" meaning a Done pressed here or a mark on its record.

**The `done` request** (new)
- **Asks:** a session by its zmx name, and whether to mark it or clear the mark.
- **Who may ask:** any Mac the host lists, not only the one in control, since a mark ends nothing. A device may not, as for `rows` and `pages`: the Phone page has no board.
- **On a Mac host:** answered by the running Varnick, like `end`, and refused with "Varnick isn't running" without it.
  - A Claude pane here with that id: its record is marked or cleared, and the state saved before the reply.
  - Otherwise, to mark: an ended card with that id moves to Completed, and a Recent entry with that id goes into Completed. One already in Completed is left as it is.
  - Otherwise, to clear: nothing changes. Clears are sent only for sessions still open.
  - No pane, ended card, Completed or Recent entry with that id: a failure saying the session isn't on that Mac.
- **On a headless host:** the relay sets or clears the record's done date. A failure when there is no record.
- **The order with `end`:** a pane in control that closes with Done sends `end` first, then `done` once it has closed. The host may get `done` before its own pane has closed (the mark is on the pane's record, so the close goes to Completed) or after (the ended card it left moves to Completed). Both end in Completed. `end` itself is unchanged.

**What the host reports** (protocol bump)
- **`sessions`:** each open session gains an optional time it was marked, as seconds ago by the host's clock like the turn's age, with explicit coding keys like the turn. A device isn't sent it, as it isn't sent work links.
- **`recent`:** each entry gains an optional time it was marked, in unix seconds like the entry's end. A Mac fills it from Completed by the entry's pane id; a headless host from the record.
- **`status`** is unchanged. A pane here on a peer reads its mark from that host's last `sessions` listing, by pane id.
- **The version:** the next one, 20 on main at the time of writing (verified), and the Phone page's copy of it with it.

**What every Mac does with its hosts' marks**
- **Kept as:** this Mac's Completed list, as for its own marks. A record of another host's session gains an optional flag saying its host holds the mark. Without it (a mark from before this option, or a Done the host didn't take) the mark is this Mac's only, the card's note is "Done on this Mac only", and nothing a host says removes it.
- **From a `sessions` answer:**
  - A listed session the host marks, with no pane here, goes into Completed if it isn't there, dated by the host's mark and flagged. One already there keeps its date and is flagged, so an answer that changes nothing saves nothing.
  - A listed session the host doesn't mark takes out of Completed every flagged mark of that host with its pane id or its conversation.
  - A listed session the host marks is never a Running or Stopped card, even once Completed's cap has dropped it, and is never remembered for an end.
- **From a `recent` answer:**
  - An entry the host marks goes into Completed, as above. An ended card or a remembered session with that pane id becomes that Completed entry, not an ended card.
  - An entry without a mark changes nothing in Completed, so a mark that left the host's Completed by its cap, or its Recent by age, doesn't leave this Mac's.
- **Answers asked too early:** a listing or Recent whose ask was sent before this Mac's own Done or open of a pane id is ignored for that pane id, as a listing asked before a close here already is. Otherwise a stale answer would undo the Done at once.
- **Order and cap:** Completed is kept newest first by its marks' dates, and keeps the newest 20. A host's mark older than the 20th isn't added, so answers don't evict and re-add each other.
- **A pane here on another host's session** (in control, or showing its card): a Completed card with "Still open here" while that host's last listing marks it. ↩ on it shows the pane and sends `done` to clear the mark there. When it closes, it goes to Completed, flagged, and nothing is sent.

**Done here, sent to the host**
- Every Done on another host's session sends `done` once, after this Mac has put it in Completed: a pane here that closes with Done (once it has closed), Done on a paired Mac's card with no pane here, and Done on an ended card.
- An `ok` reply flags the mark. Any failure leaves it this Mac's only. Nothing is queued.
- A session on this Mac (no host) sends nothing: the other Macs read its mark from this Mac's listing and Recent.

**Open from Completed**
- A session still open on its host: opened on its card, as today, and `done` is sent to clear the mark there. If that fails, the host's next listing still marks it, and the pane here shows it in Completed with "Still open here" until ↩ again.
- An ended session: resumed as today. Its host's own rule takes it out of the host's Completed once the conversation is open there, and every other Mac's flagged mark goes when the host lists the conversation open.
- On the host, a marked pane: shown, and the mark is taken off (above).

**Unpaired and mismatched Macs**
- A Mac no longer paired: its sessions' marks here are hidden and kept, as its ended and Completed cards are today. Nothing is sent to it, and it is never told a mark.
- A Mac that removed this one answers `done` with a refusal, and the mark stays this Mac's only.
- A Mac on another protocol is refused before any request, as today.

## Testing Decisions

- No test target yet. The pure parts are where tests would go once there is one:
  - what one `sessions` or `recent` answer does to Completed, the ended cards and the remembered sessions, flagged and unflagged marks included;
  - the rule for answers asked before a Done or an open here;
  - Completed's order and cap, and that an unchanged answer changes nothing;
  - what a host does with `done` for a pane, an ended card, a Completed entry, a Recent entry and an unknown id.
- `make build`, the package's build on Linux for the headless host, and `bun test` in the Phone page for its protocol constant.
- By hand, after the user restarts Varnick on each Mac and upgrades the headless host (leave the restarts to the user). Mac A and Mac B are paired, both with the board open:
  - **Done on the host.** Done on a session of Mac A, on Mac A: it is in Completed on Mac B within about 5 s (Mac B asks Mac A's Recent again when a session it listed drops out), not an ended card.
  - **Done from the Mac in control.** Mac B in control of a session Mac A started for it, Done on Mac B: Completed on both, and Mac A's Stopped holds no ended card of it.
  - **Done with no pane.** Done on Mac B on a session open on Mac A that Mac B has no pane for: Completed on Mac B, Completed with "Still open here" on Mac A within about 5 s, and its tab on Mac A still open and running.
  - **Done on an ended card.** A session of Mac A ended without Done, an ended card on both: Done on Mac B moves it to Completed on Mac A at once and on Mac B; Done on Mac A instead reaches Mac B at its next board open.
  - **Open from Completed.** ↩ on Mac B on a marked session still open on Mac A: it opens on its card on Mac B, and leaves Completed on Mac A. ↩ on Mac A on the same: its tab shows, and it leaves Completed on Mac B within about 5 s. Resuming a marked ended session on either Mac takes it out of Completed on both.
  - **A marked tab closed on its host.** Close a Completed "Still open here" tab on Mac A with ⌘W in the tab: still in Completed on both, never an ended card.
  - **The headless host.** Done on Mac A on a headless host's open session with no pane on Mac A: Completed with "Still open on <host>" on Mac B. A session there ended and marked on Mac A is in Completed on Mac B.
  - **A host that can't take it.** Mac A asleep, Done on Mac B on an ended card of Mac A: Completed on Mac B with "Done on this Mac only". Once Mac A wakes, Mac A still shows it in Stopped, and Mac B's card keeps its note. Marks made before the upgrade show the same note.
  - **Restart.** Restart Varnick on Mac A with a "Still open here" card: it is still in Completed after the restart, on both Macs.

## Out of Scope

- **Sending a mark again** once its host answers, after a Done it couldn't take (open question 3).
- **A new turn clearing a mark** on a session still open (open question 1).
- **Ending the host's pane** on a paired Mac's Done when the host is in control: only the Mac in control ends a session.
- **Marks on the Phone page:** a device neither sends nor sees them.
- **Ended cards themselves:** whether a session ended on one Mac is an ended card on another is option 04's rule and doesn't change. Only Completed is shared.
- **A refactor worth raising, not asked for:** Completed, the ended cards and the remembered sessions are now changed by this Mac's closes, by `sessions` answers and by `recent` answers, in several places. A value that owns the three lists, with pure rules for each kind of event, would make the rules above testable once a test target exists. Option 04 raised the same.

## Further Notes

- **Why a new problem, not option 05 of session-turns-not-visible.** That problem is closed, and its status is the user's. An option under a closed problem sits in the Problems tab's Closed column, where a proposed option is never seen. Sharing marks is its own problem: the board works, but the Macs disagree.
- **Corrections to the first sketch,** each checked in the code at 0b289b0:
  - **"The host adds it to its Completed"** doesn't hold for a session still open there. The step that rebuilds Recent drops any Completed entry whose pane is open on that Mac, and every session a host lists open is one of its own panes. So an open session's mark goes on its pane's record.
  - **"Older peers keep today's behaviour"** can't happen. A Mac on another protocol version is refused before any request is read. What does keep today's per-Mac behaviour is a mark made before the upgrade, or one its host couldn't take.
  - **Recent's entries** are built in the relay's Recent list from the saved Recent, which holds no Done mark for a session marked on its ended card. So the relay reads the mark from Completed by pane id.
  - **The listing needs the mark too,** for "Still open on…" on every Mac. `status` doesn't, since a Mac with a pane on another host already holds that host's listing.
  - **A headless host** has no Completed to add to, so its session records gain the date.
- **An ADR once accepted:** a session's done mark belongs to its host, and a Mac's Completed is its own marks plus its hosts'. It is a rule across machines that the protocol encodes, and hard to undo.
- **Docs to update with it:**
  - CONTEXT.md's Session board entry: Completed is shared, and Done on a paired Mac's session marks it on its host.
  - where-it-breaks › Focus and keys: a pane here can be in Completed when its record is marked; a marked pane's close goes to Completed.
  - where-it-breaks › Peers: the `done` request and who may send it; where each host keeps a mark; the rules for taking in a host's answer, the flag, and answers asked before a Done here.
- **Considered and not proposed:**
  - **Every Mac sends its marks to every Mac.** Two Macs would each hold a copy and have to agree, which is the ping-pong the host avoids by being the only keeper.
  - **The mark in a file in the pane's folder,** which the relay could write with Varnick not running. An ended session's mark would still be in Completed, so a Mac host's marks would live in two places, and the app would read the file on every board refresh.
  - **`end` carrying the mark.** It covers only a pane in control. A card, a paired Mac's card with no pane and an ended card need the request anyway, so `end` stays as it is.
- **Verified in the code at 0b289b0:**
  - where Completed, the ended cards and the remembered sessions are kept, filled and cleared, and that a pane here drops a session from Completed;
  - that a pane's record, with its completed date, is what the saved tabs hold, and so what the relay lists;
  - that a close with Done puts the session in Recent as well as Completed, and how a paired Mac makes it an ended card from that;
  - that the host's pane closed by a paired Mac's `end` closes without Done and leaves an ended card there;
  - that Done on a paired Mac's card with no pane, and on an ended card, sends nothing;
  - how the relay answers `sessions`, `recent` and `end` on a Mac and on a headless host, which requests it forwards to the app, and which it answers only for a Mac;
  - that a version mismatch is refused by the relay and by the app before any request is read;
  - when `sessions` and `recent` are asked, and that a listing asked before a close here is ignored for that pane;
  - the protocol at 19, and the Phone page's copy of it.
- **Inferred, not tested:**
  - that an older build reads a saved tab record with a completed date and a Completed record with the new flag without failing (an unknown key is ignored, and the date is a field it already has);
  - how often a laptop host is asleep when its sessions are marked from another Mac, which decides how much open question 3 matters.
- **Picked to match existing behaviour (the user can change any of them):**
  - "Still open here" and "Done on this Mac only" as the notes;
  - marks cleared only by an open or a resume, never by a turn;
  - every Mac taking in every mark its hosts report, not only sessions it had on its board;
  - a device neither sending nor seeing marks.
- **Open questions,** each with a recommendation:
  1. Should a new turn in a session still open on its host take it out of Completed everywhere, when the user goes on working in a tab another Mac marked done? **Recommended: not in this option.** Marks today leave only by an open, and "Still open on…" marks already outlive new turns. A turn caused by a background task ending would clear marks the user made on purpose. Revisit if "Still open here" cards on the host confuse.
  2. Should a Mac take in marks for sessions it never had on its board (a host's marked Recent entries, its marked open sessions)? **Recommended: yes,** so Completed reads the same on every Mac. They are done already, so they ask nothing of the user. The alternative needs each Mac to remember which sessions it listed, as ended cards do.
  3. Should a Done its host couldn't take be sent again the next time that host answers? **Recommended: no, for now.** If the session was opened there meanwhile, a late mark would put live work back in Completed, and telling which came first needs both Macs to keep times for it. The card's note says the mark is this Mac's only.
  4. Should marks made before the upgrade be sent to their hosts once? **Recommended: no,** for the same reason as 3. There are at most 20, each says "Done on this Mac only", and ↩ then Done marks one on its host.

## Decided by the user, 2026-10-10

This option is accepted. The four open questions are answered with the recommendations above:

1. **A new turn in a session still open on its host does not clear the mark,** for now. Marks leave only by an open or a resume.
2. **A Mac takes in marks for sessions it never had on its board:** a host's marked Recent entries and its marked open sessions both go into Completed.
3. **A Done its host couldn't take is not sent again** when the host answers later. The card keeps "Done on this Mac only".
4. **Marks made before the upgrade are not sent to their hosts.** Each shows "Done on this Mac only".
