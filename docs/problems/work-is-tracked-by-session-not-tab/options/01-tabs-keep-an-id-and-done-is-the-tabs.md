---
problem: work-is-tracked-by-session-not-tab
title: Tabs keep an id, and Done, Completed and the board are the tab's
summary: Every tab keeps an id, saved with it, and belongs to one machine, its host. Done is the tab's. It closes every pane of the tab, and the tab goes to Completed, which lists tabs and reopens them whole. Done on a session goes away. The board shows one card per tab, listing its sessions, in the column of its most urgent session. ADR 0028's rule that the host keeps the mark carries on, keyed by tab. `done` names a tab, and the host's listings give each session's tab and the tab's mark (protocol 21). A tab here that shows another machine's sessions takes that machine's tab id. Splitting one of its panes is refused until option 03. Existing marks, ended cards and remembered sessions become one-pane tabs. It ships alone. Recent and search stay per session until option 02.
status: shipped
---

## Solution

**A tab has an id and a host.** The id is saved with the tab and kept across launches. It is how Completed, the board and other machines name the tab. A tab's panes all run on one machine, its host. A tab on this Mac whose panes run on another machine is that machine's tab, seen from here, and it takes that tab's id.

**Done is the tab's.** Done closes every pane of the tab, as its × does, and the tab goes to Completed once its last pane has closed. It is saved as it was: its layout, and each pane's folder, conversation, address, app or file. It asks first while any of its sessions is working, as Done does for a session today. Closing one pane never marks anything. Nothing marks a session any more.

**Completed and the ended cards hold tabs.** A tab closed without Done that held a Claude pane stays in Stopped as an ended card, as a session does today. ↩ on a Completed or ended card reopens the tab whole, the way a launch restores the tabs left open.

**The board has one card per tab.** The card lists the tab's Claude sessions, each with its turn. It sits in the column of its most urgent session.

**Other machines keep their own tabs' marks,** by ADR 0028's rules with a tab where it says a session. The host's listing says which of its tabs each session is in. `done` marks a tab.

**What the board shows today carries over** as one-pane tabs: Completed, the ended cards and the remembered sessions of paired machines.

## Trade-offs

- **Ships alone, and only part of the way.** Recent and search still list sessions (option 02). Another machine's tab opens with only its Claude panes, side by side in this Mac's own layout, and can't be split (option 03).
- **Done closes the whole tab,** terminals and dev servers included. A user who wanted a terminal kept closes the Claude panes one by one, as today, and marks nothing.
- **A pane's session left alone in a tab can't be marked by itself.** That is decision 1: the tab is the unit.
- **A tab with one working session and one waiting on a permission is one card, in Stopped,** with the mark. The working session shows only in the card's list.
- **Splitting a pane that runs on another machine is refused.** Today it makes a local session in that machine's folder path, in the same tab. Option 03 starts it on the host instead.
- **A protocol bump to 21.** Every Mac and the headless host run one commit, as for any bump, and a machine on another version is refused before any request.
- **Going back to an older build** keeps the open tabs. It shows Completed and the ended cards empty, since they are saved under new keys.
- **Migrating a mark on one pane of a split tab** is lossy: the tab is marked only if all its Claude panes were.

## User Stories

1. As the user, I want Done to mark the tab I worked in, not one session of it, so that one Done finishes the work.
2. As the user, I want Done to close every pane of the tab, so that its terminals and pages don't stay open behind a finished piece of work.
3. As the user, I want Done to ask first while any session in the tab is working, so that I never close running work by accident.
4. As the user, I want Completed to list tabs, and ↩ on one to bring the whole tab back with its splits, so that I can pick the work up as I left it.
5. As the user, I want a tab I closed without Done to wait in Stopped, as a session does today, so that nothing unfinished drops off the board.
6. As the user, I want one board card per tab, listing its sessions with their turns, so that the board looks like my tabs.
7. As the user, I want a tab's card in the column of its most urgent session, a session waiting on me first, so that the board shows where I'm needed.
8. As the user, I want ↩ on a card to show the tab with that most urgent session's pane focused.
9. As the user, I want a tab marked done on another Mac to be done here too, and the other way round, as sessions are today.
10. As the user, I want a session started on the Ryzen or another Mac to open here in the tab that machine keeps it in, so that its done mark is that tab's.
11. As the user, I want a second session of a tab I already have open from another machine to open in that tab, not in a new one.
12. As the user, I want Completed, the ended cards and the remembered sessions I have now to carry over as one-pane tabs.
13. As the user, I want a split of a pane that runs on another machine refused with a reason, not turned into a local session in a folder that may not exist here.
14. As the user, I want the Problems tab's chips to stay one per session, and to open its tab.

## Implementation Decisions

**The tab's id**
- Saved with the tab, and new for each new tab.
- **A tab saved without one takes its first pane's id, in layout order.** The app and the relay apply this one rule, so a relay reading a file the app hasn't saved since gives the same ids. A one-pane tab's id then equals its session's pane id, which is what ADR 0028's marks and the remembered sessions are keyed by.
- Tab ids and pane ids are never compared: a board card's id is now a tab's, never a pane's.

**The tab's host**
- **A tab's host is the machine its panes run on.** A tab here whose panes run on another machine takes that machine's tab id, from:
  - the host's listing;
  - its reply to `start` (a prompt sent there);
  - its reply to `resume` (Recent or search).
- **Opening a session whose tab is already shown here adds it to that tab,** beside its last pane, instead of making a new tab. Until option 03 that layout is this Mac's own.
- **Splitting a pane that runs on another machine is refused** in the pane, with the reason: splits on another machine come with whole remote tabs. The split picker isn't shown for it.
- **A saved tab with panes on more than one machine** (made by such a split before this option) is split at load into one tab per machine, in place. Its layout is pruned per machine, and the first keeps the id.
- **A tab with no Claude pane** stays in the search's Tabs list and gets no board card, since the board shows turns. Picked to match today's board.

**Done on a tab**
- **Every Done marks the tab:**
  - the board's D and its End session and Mark session done keys;
  - a drag to Completed;
  - a pane's Done button;
  - the Mark session done key in a pane.

  The key's label becomes Mark tab done. Its stored name stays, so a user's own binding is kept.
- **Done closes every pane** as the tab's × does, and the tab goes to Completed once its last pane has closed. A close that doesn't happen clears the request for the whole tab. An example is the card's question on the host, answered by keeping the session.
- **It asks first while any Claude session in the tab is working or background,** with today's question. The question shows on the card on the board, and in the focused pane otherwise.
- **A pane closed alone marks nothing,** whether by ⌘W, its × or `/exit`. Its session goes to Recent as today, and the tab stays.
- **A tab marked by another machine while open stays open here.** Its card is in Completed with "Still open here". ↩ shows it and takes the mark off, and closing it in any way puts it in Completed. This is ADR 0028's rule for a pane, now for a tab.

**Completed and the ended cards**
- **Completed holds the newest 20 tabs.** Each is a saved tab, its panes' records included, with:
  - when it was marked;
  - for another machine's tab, its host and whether the host holds the mark.
- **An ended card is a tab closed without Done that held a Claude pane.** Ended cards have no cap, and are dropped by Done or by opening, as today. A pane of a tab that stays open leaves no ended card.
- **↩ on one of this Mac's tabs reopens it whole,** as the launch restores tabs:
  - Claude panes resume when first shown;
  - terminals start fresh in their folder;
  - web panes load their address;
  - app panes run their app;
  - file panes open their file;
  - the Transcript follows today's file.

  A pane that couldn't be restored at launch is left out, and so is a Claude pane whose conversation is open in another pane here. If none is left, the tab that holds that conversation is shown instead. The reopened tab keeps its id, and leaves Completed or the ended cards.
- **↩ on another machine's tab** depends on whether it is still open there:
  - still open: its listed sessions open in one tab here, on their cards, and `done` clears the mark there;
  - closed there: each Claude session it held is resumed there, as Recent resumes one, into one tab here. Option 02 makes this the host reopening the whole tab.
- **Resuming one of a Completed tab's conversations from Recent or search opens a new tab,** with its own id, and leaves the Completed tab where it is.

**The board**
- **One card per tab with a Claude pane, in this order:**
  1. this Mac's tabs;
  2. each paired machine's tabs that have no tab here;
  3. the ended tabs;
  4. Completed.

  The card's id is the tab's.
- **The title** is the tab's name, else its focused Claude pane's title, as a one-pane tab's card is named today.
- **The card lists the tab's Claude sessions,** each with its title, turn and age, in layout order. The pills and host are the tab's.
- **Its column comes from the most urgent session,** in this order:
  1. waiting on the user mid-turn (Stopped, marked);
  2. working (Running);
  3. background (Running);
  4. waiting for the next prompt (Stopped).

  The card's turn text is that session's.
- **Keys on a card:**
  - ↩ shows the tab, with the most urgent session's pane focused.
  - D, its keys and a drag do Done on the tab.
  - R restarts only when the tab has one Claude pane that can restart. With several it does nothing, and each pane restarts from itself (picked).
- **The Problems tab's chips stay one per session,** since a work link is a session's. A chip opens its tab with that pane focused.
- **Panel access** gives a card's id from the tab, never a pane. Its board read lists each card's sessions. Its refusals for Done and ↩ follow the board's rules above.

**Other machines' marks (ADR 0028, by tab)**
- **`done` names the host's tab by id,** instead of a session. It marks or clears and ends nothing. Any Mac the host lists may send it. A device may not.
- **On a Mac host:**
  - an open tab is marked on its saved tab;
  - an ended tab moves to Completed;
  - a tab already in Completed is left as it is;
  - an unknown id is a failure, so the Done stays "Done on this Mac only".

  A clear unmarks an open tab, and takes a closed one out of Completed.
- **On the headless host each session record is a one-pane tab, with the record's id.** The record's done date is that tab's mark, so nothing changes on disk.
- **What the host sends:**
  - `sessions`: each open session gains its tab's id and name, and the mark it carries is the tab's;
  - `recent`: each entry gains the id of the tab it was in when it ended, and the mark is that tab's, read from Completed by tab id;
  - `start` and `resume`: the reply gains the tab the host put the session in.

  A new optional field goes in the explicit coding keys, as the turn's do.
- **A Mac takes in what its hosts say by tab, with ADR 0028's rules:**
  - the flag saying the host holds the mark;
  - an answer asked before this Mac's own Done, clear or open of that tab is ignored;
  - the cap of 20;
  - a tab its host marks is never a Running or Stopped card.
- **A paired machine's tab becomes an ended card** when this Mac listed it and remembered it by tab id, its host's next listing doesn't have it, and its Recent, asked after the last listing, has an entry naming that tab. This is today's rule for a remembered session, by tab id.
- **The protocol goes to 21** (20 on main at 0d1d161, verified), with the Phone page's constant. A device neither sends nor sees marks. The page lists sessions as today and ignores the new fields.

**Migration** (the first launch of this build; the relay applies the id rule to whatever it reads)
- **Completed's session records become one-pane Completed tabs** with the record's id, date and host flag. A host's mark made before keeps naming the same tab on both machines.
- **Ended cards become one-pane ended tabs,** and remembered sessions become remembered tabs, each with the same id.
  - A paired Mac's tab of several panes is known by its first pane's id.
  - A remembered session that wasn't its tab's first pane matches nothing, so an end it had while this Mac was off is missed once.
- **An open Claude pane marked on its record** marks its tab only when all the tab's Claude panes are marked, at the newest date. Otherwise the marks are dropped.
- **The saved file gains new keys** for Completed and the ended and remembered tabs, beside the old keys. The old ones are read once and then saved absent. A changed type under an old key would make the whole file unreadable, and every open tab would go with it.

## Testing Decisions

- **No test target yet.** The pure parts are where tests would go once there is one:
  - the id rule for a tab saved without one;
  - the migration of a saved state:
    - Completed and the ended and remembered records;
    - a marked pane in a split tab;
    - a tab with panes on two machines;
  - a tab card's column from its sessions' turns;
  - what one `sessions` or `recent` answer does to Completed, the ended tabs and the remembered tabs.
- **Builds:** `make build`, the package's build on Linux for the headless host, and `bun test` in the Phone page for its protocol constant.
- **By hand,** after the user restarts Varnick on each Mac and upgrades the headless host. Leave the restarts to the user.
  - **Migration.** The Completed, ended and Stopped cards from before the restart are there, one card each.
  - **Done on a split tab.** A tab with two Claude panes and a terminal: ⌘⇧D in one pane while the other works asks first. Confirming it closes all three, and the tab is one Completed card.
  - **Reopen.** ↩ on that card brings back the split, the terminal fresh in its folder, both conversations resuming when shown.
  - **Most urgent.** A tab with one session working and one on a permission dialog is one card, in Stopped, marked.
  - **Closed without Done.** The tab's × leaves one ended card in Stopped. ⌘W on one pane of a two-pane tab leaves none.
  - **Another Mac.** Mac A and Mac B paired:
    - a session of Mac A opened on Mac B is one tab there, and a second session of the same tab of Mac A opens into it;
    - Done on Mac B marks the tab on both boards within about 5 s;
    - the split keys in that tab on Mac B are refused with the reason.
  - **The headless host.** Done on a Ryzen session's card marks it on both Macs.
  - **Restart.** A "Still open here" tab is still in Completed after Restart Varnick.

## Out of Scope

- Recent listing closed tabs, search grouped by tab, and the tab row's summary of turns (option 02).
- Another machine's tab opened whole, in its own layout, with its terminals, take over by tab, and splits on another machine (option 03).
- Web and app panes of another machine's tab (option 04).
- Marks on the Phone page: a device neither sends nor sees them, as with ADR 0028.
- Marking one session of a tab done (decision 1).
- **A refactor worth raising, not asked for:** Completed, the ended cards and the remembered entries are changed in many places, by this Mac's closes and by each answer from a host. A value that owns the three lists, with pure rules per event, would make them testable. ADR 0028's option and option 04 of `session-turns-not-visible` raised it too.

## Further Notes

- **An ADR once accepted:** "A tab's done mark belongs to its host, and Completed lists tabs". It supersedes the done-mark ADR 0028, and takes the next free number, 0032 at the time of writing.
- **Docs to update with it:**
  - **CONTEXT.md:** **Tab** gains its id, its host and its done mark. **Session board** becomes a card per tab, and Completed lists tabs.
  - **where-it-breaks:**
    - Focus and keys: the Done and ended-card bullets become per tab, a card's id is a tab's, and the Problems chips open a tab;
    - Peers: the done-mark bullet is keyed by tab;
    - Sessions and tabs: a tab's id and the first-pane rule, and one host per tab;
    - Panel access: card ids.
- **Verified in the code at 0d1d161:**
  - a tab's id is made new at each launch and isn't saved;
  - panes never move between tabs;
  - every way of opening work adds a tab;
  - a host puts a session started or resumed for another machine in a tab of its own;
  - a split copies the folder and never the host;
  - the board makes a card per Claude pane, whose id is the pane's, and the Problems chips and Panel access rely on that;
  - Done closes one pane;
  - Completed, the ended cards and the remembered sessions are session records;
  - `done`, `sessions` and `recent` carry marks by session, and the headless host keeps the mark on its record;
  - the protocol is 20.
- **Inferred, not tested:**
  - an older build reads a saved tab with the new keys and ignores them;
  - what a local pane started in another machine's folder path does when that folder doesn't exist here.
- **Picked to match existing behaviour** (the user can change any of them):
  - Done closes the tab, as it closes a pane today;
  - a tab with no Claude pane isn't on the board;
  - R restarts only a tab with one Claude pane;
  - resuming a Completed tab's conversation elsewhere leaves the tab in Completed.
- **Decided by the user (2026-10-12),** when accepting this option:
  1. **Splitting a pane that runs on another machine is refused** until option 03, which starts it on the host.
  2. **A session waiting on the user outranks a working one** for the tab's column.
  3. **A mark on one pane of a split tab, at migration:** the tab takes it only if all its Claude panes are marked (the recommendation, taken with the acceptance).
