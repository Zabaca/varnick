# A session's done mark belongs to its host, and every Mac's Completed is its own marks plus its hosts'

Superseded by [ADR 0032](0032-a-tabs-done-mark-belongs-to-its-host-and-completed-lists-tabs.md): the mark is the tab's, not the session's. The rules below carry over by tab; the protocol is 21.

Done marks were each Mac's own (option 04 of `session-turns-not-visible`): a session marked done on one Mac stayed in Running or Stopped on every other paired Mac, or turned up there as an ended card, until the user marked it again on each. Now a session has one host, the machine its zmx session runs on, and the host is the one place its mark is kept. Every Mac's Completed is its own marks plus the marks its hosts report. The problem and its option are in `docs/problems/done-marks-stay-on-one-mac/`.

The rule is across machines and the protocol encodes it (version 20), so it is hard to undo:
- **A new `done` request** marks a session on its host, or takes the mark off, and ends nothing. Any Mac the host lists may send it, not only the one in control, since a mark is not an end. A device may not.
- **The host keeps the mark** in its Completed if the session has ended there, on the pane's own record if it is still open (so the pane is a Completed card there, "Still open here"), and on the session's record on a headless host.
- **The host's `sessions` listing and its Recent entries carry the mark** (`doneAge`, `done`). A Mac puts what its host marks into Completed, and takes out of Completed the marks it flagged as the host's when the host lists that session, or its conversation, open without one.
- **Opening a session again takes its mark off,** wherever the host keeps it: a resume clears the mark on the conversation's ended records, and a clear (`mark` false) also takes an ended session out of the host's Completed.
- **A Done the host can't take** (asleep, Varnick not running there, no longer listing this Mac) stays on this Mac only, as every mark was, and its card says "Done on this Mac only". Nothing sends it again, and marks made before the upgrade are not sent.

## Considered Options

- **Every Mac sends its marks to every Mac:** rejected. Two Macs would each hold a copy and have to agree, which is the ping-pong that one keeper avoids.
- **The mark in a file in the pane's folder,** which the relay could write with Varnick not running: rejected. An ended session's mark would still be in Completed, so a Mac host's marks would live in two places, and the app would read the file on every board refresh.
- **`end` carrying the mark:** rejected. It covers only a pane in control, and a card with no pane or an ended card needs the request anyway.
- **Sending a Done again once its host answers:** left out. A session opened there meanwhile would be put back in Completed by a late mark, and telling which came first needs both Macs to keep times.

## Consequences

- **A protocol bump.** A Mac left on version 19 is refused, as for any bump, so it neither shares nor receives a mark.
- **A mark on an open session reaches the other boards within about 5 s** while they show, through the listing they already ask for. **A mark on an ended session waits for the next panel show or board open,** since Recent isn't asked every 5 s.
- **Completed is still the newest 20 on each Mac,** so the older end can differ between Macs.
- **A Mac's Done needs its host to answer,** so a sleeping laptop's sessions, marked from another Mac, stay done on that Mac only.
- **A listing or Recent asked before this Mac's own Done or open of a pane id is ignored for it,** or a stale answer would undo the Done at once.
