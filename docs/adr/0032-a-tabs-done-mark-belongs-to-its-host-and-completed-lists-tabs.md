# A tab's done mark belongs to its host, and Completed lists tabs

Supersedes the done-mark ADR 0028 ([a session's done mark belongs to its host](0028-a-sessions-done-mark-belongs-to-its-host-and-every-macs-completed-is-its-own-marks-plus-its-hosts.md)). The user works in tabs, and a Claude session is one kind of pane in one. Done, Completed and the board were a session's; now they are the tab's. The problem and its option are in `docs/problems/work-is-tracked-by-session-not-tab/`.

The rule is across machines and the protocol encodes it (version 22), so it is hard to undo:
- **A tab has an id and a host.** The id is saved with the tab and kept across launches; a tab saved without one takes its first pane's id, and the app and the relay both apply that rule. A tab's panes all run on one machine, its host. A tab here that shows another machine's sessions takes that machine's tab id, from the host's listing or its reply to `start` or `resume`.
- **Done is the tab's.** It closes every pane of the tab, and the tab goes to Completed once its last pane has closed. Nothing marks a session any more. Closing one pane marks nothing.
- **A `done` request names a tab.** It marks the host's tab, or with `mark` false takes the mark off, and ends nothing. Any Mac the host lists may send it, not only the one in control, since a mark is not an end. A device may not.
- **The host keeps the mark** in its Completed if the tab has closed there, on the saved tab if it is still open (so its card is a Completed card there, "Still open here"), and on the record of a headless host, whose records are tabs under the record's id unless a `resume` named another (a record in a named tab carries that tab's id, and `done` marks every record of it).
- **The host's `sessions` listing and its Recent entries carry the tab** (`tab`, `tabName`) **and the tab's mark** (`doneAge`, `done`). A Mac puts what its host marks into Completed, and takes out of Completed the marks it flagged as the host's when the host lists that tab, open, without one. `start` and `resume` reply with the tab the host put the session in, which the asking Mac's tab takes the id of.
- **Reopening a tab of another machine names the tab in each `resume`** (`tab`, `tabName`; protocol 22), so its sessions land in one tab on the host as they do here, and one Done marks all of it. The host puts the session in that tab if it is open there, else makes the tab under that id; a headless host records the id on the session. The name goes on once the tab holds two sessions, since a tab of one is named after its conversation. The host takes no mark from the asker's tab: the asker clears it with `done` as the tab opens. A resume from Recent or search names no tab, and gets a tab of its own.
- **Opening a Completed tab on the Mac that holds it takes the mark off** at the host, and brings the tab back whole. Resuming one of its conversations from Recent or search is a new tab and leaves the Completed one where it is.
- **A Done the host can't take** (asleep, Varnick not running there, no longer listing this Mac) stays on this Mac only, as every mark was, and its card says "Done on this Mac only". Nothing sends it again, and marks made before the upgrade are not sent.
- **Splitting a pane that runs on another machine is refused,** since a tab is one machine's and a new pane would be a session on this Mac in a folder that may not exist here. Whole remote tabs, with splits on the host, are option 03 of the problem.

## Considered Options

- **Keeping the session mark beside the tab's:** rejected by the user (decision 1 of 2026-10-12). Marks on sessions go away; the old ones migrate (a mark on one pane of a split tab marks the tab only if all its Claude panes are marked).
- **Every Mac sends its marks to every Mac:** rejected, as in ADR 0028. Two Macs would each hold a copy and have to agree, which is the ping-pong that one keeper avoids.
- **Naming the tab by its first pane's id at all times, with no saved id:** rejected. The first pane can close while the tab stays.
- **Sending a Done again once its host answers:** left out, as in ADR 0028. A tab opened there meanwhile would be put back in Completed by a late mark.

## Consequences

- **A protocol bump to 22** (21 for the tab's id, 22 for `resume` naming a tab). A Mac left on version 21 is refused, as for any bump, so it neither shares nor receives a mark; the headless host is upgraded from a Mac with the installer.
- **The saved file gains keys** for Completed and the ended and remembered tabs, beside the old keys, which are read once and saved absent. A build before this one reads the open tabs (it ignores the new keys) and shows Completed and the ended cards empty.
- **A mark on an open tab reaches the other boards within about 5 s** while they show, through the listing they already ask for. **A mark on a closed tab waits for the next panel show or board open,** since Recent isn't asked every 5 s.
- **Completed is still the newest 20 on each Mac,** so the older end can differ between Macs.
- **A listing or Recent asked before this Mac's own Done, clear or open of a tab id is ignored for it,** or a stale answer would undo it.
- **Done closes the whole tab,** terminals and dev servers included. A user who wants a terminal kept closes the Claude panes one by one.
- **Another machine's tab opens here with only its Claude panes,** side by side in this Mac's own layout, until option 03.
