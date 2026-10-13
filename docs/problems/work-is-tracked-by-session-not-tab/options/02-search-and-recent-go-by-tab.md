---
problem: work-is-tracked-by-session-not-tab
title: Search groups sessions under their tab, and Recent lists closed tabs
summary: On top of option 01. A tab keeps the history of the conversations it has held, the ones left behind by /clear and /resume included. Recent lists closed tabs, and ↩ reopens one whole, on this Mac or on its host. Search still matches sessions, since that is where the text is, but shows them grouped under their tab, and opening any of them opens that tab. The session list's tab rows say how many sessions a tab has and how many wait ("3 sessions · 1 waiting"), and other machines' open sessions are listed by tab. The search database keeps which tab each conversation belongs to, and other machines send it with their rows. Reopening a closed tab on another machine is one `resume` per Claude session, each carrying the tab, which the host gathers into one tab (protocol 23). A session with no tab, such as one from before the change, gets a one-pane tab when it is opened.
status: shipped
---

## Solution

**A tab has a history.** Each tab keeps the conversations it has held, newest first:
- every Claude pane's conversation;
- the ones a `/clear` or `/resume` left behind;
- those of panes closed while the tab stayed open.

A conversation belongs to the latest tab that held it. Resuming it into a new tab moves it there.

**Recent lists closed tabs.** A tab that closes, with Done or without, goes to the top of Recent with its layout and history. ↩ reopens it whole, as option 01 reopens a Completed tab. Another machine's closed tabs are listed with this Mac's, marked with their machine. ↩ asks that machine to reopen the tab there, and it opens here as that machine's tab.

**Search shows sessions under their tab.** A search still matches sessions, by their prompts and replies, here and on paired machines. The matches are grouped under a row for their tab, which names the tab and says whether it is open, closed or done, and where. ↩ on the tab's row or on any of its sessions opens the tab:
- shown, if it is open here;
- reopened, if it is closed;
- opened as another machine's tab, if it is that machine's.

A session that belongs to no tab is listed alone, as today. Opening it resumes it in a new one-pane tab, which becomes its tab.

**The session list says what is in a tab.** Each row under Tabs gives its Claude sessions and how many wait on the user or work ("3 sessions · 1 waiting"). Each paired machine's open sessions are listed by its tabs, one row per tab, under the machine's name.

## Trade-offs

- **↩ on an old conversation opens its tab, not that conversation** (decision 3). A conversation that no pane of the tab is on now, say one a `/clear` left, is reached with `/resume` inside the tab.
- **Recent drops the conversations a `/clear` left in a tab that is still open.** They stay in the tab's history and in search, under the open tab.
- **Recent holds 20 tabs rather than 20 sessions.** It reaches more conversations, but a single old session falls off with its tab.
- **A protocol bump to 23:**
  - `recent` lists tabs;
  - `rows` carries the tab of each session.

  There is no `reopen` request: the `resume` that option 01 made carry the tab does it.

  The headless host's `rows` isn't built yet (`sessions-hosted-only-on-macs`, ticket 4). Until it is, the Ryzen's sessions are matched only through Recent, and have a tab only once listed there.
- **The search database gains a table** in its archive half, as the session names and the work history did.
- **A reopened tab on another machine opens with only its Claude panes** until option 03, here and on the host. The host keeps the closed tab whole (a tab it reopened for a peer remembers the record it came from and closes back into Recent with its terminals and splits), so option 03 can restore it.

## User Stories

1. As the user, I want a session I find in search shown under the tab it belongs to, so that I see the work it was part of.
2. As the user, I want ↩ on a search match to open its tab: shown if open, reopened if closed, wherever it lives.
3. As the user, I want Recent to list the tabs I closed, and ↩ on one to bring the whole tab back.
4. As the user, I want another Mac's and the Ryzen's closed tabs in my Recent, marked with their machine, and reopened there.
5. As the user, I want a conversation that `/clear` left behind to stay with its tab, in search and in the tab's history.
6. As the user, I want a session from before this change, which belongs to no tab, to still be found and opened, and to have a tab from then on.
7. As the user, I want a tab's row in the session list to say how many sessions it has and how many wait on me.
8. As the user, I want another machine's open work listed by tab, so that I open it as a tab.
9. As the user, I want the phone's page to list each host's sessions under their tabs, and its Recent to be closed tabs, so that a tab means the same thing on the phone.

## Implementation Decisions

**A tab's history**
- **Saved with the tab:** conversation ids, newest first, each with its title as last known. Cap 50 (picked); the oldest falls off the tab, though search still finds the session.
- **When a conversation is added:**
  - a Claude pane starts on it;
  - a pane moves to it by `/clear` or `/resume`;
  - a tab is reopened.
- **A conversation is in one tab's history.** Opening it in another tab, here or by a reopen, removes it from the first.
- **A phone-started session** is already a one-pane tab on a Mac host (verified). On the headless host each record is a one-pane tab (option 01), whose history is that conversation and the ones `/clear` moved it to.

**Recent**
- **The newest 20 closed tabs, Done or not,** as Done sessions are in Recent today. Each is a saved tab with its history and when it closed.
- **A tab reopened leaves Recent.** One of its conversations resumed elsewhere moves that conversation out of its history.
- **↩ on a closed tab of this Mac reopens it whole,** by option 01's rules for a Completed tab.
- **↩ on another machine's closed tab sends a `resume` for each of its Claude sessions, naming the tab and its name:**
  - **a Mac host** starts each pane in a background tab of that id, labelled for the asker, as `resume` starts one, and replies with the tab. The first makes the tab and the others join it;
  - **the headless host** records the tab on each session it starts.

  The tab opens here as the host's tab, its sessions in control here, as a resume is today.
- **The host refuses a tab whose conversation is open there.** The asker opens the open tab instead, as a refused resume does today.
- **Saved under a new key,** and also under the old one. Today's Recent sessions are read once as closed tabs: the sessions that ended in one tab are one closed tab, its newest session the pane and the others its history, since they never ran together. One whose tab is open is not closed: its sessions go into that tab's history. The old key is saved from then on as a session per pane and per past conversation, each naming its tab, so a build before this one still lists them and the next migrates them again.

**Search**
- **The search database keeps each conversation's tab:** the tab's id, name and machine.
  - It is a new table in the archive half, made if it isn't there and changed by no migration, like the session names and the work history.
  - The sync writes it from the saved state: the open tabs, Recent and Completed, all with their histories.
  - Naming or closing a tab writes it at once, as naming does for the session names now, so a tab closed before the next sync keeps it.
- **Other machines send each session's tab with its row** in `rows`, and the sync stores it beside the row.
- **What a match shows:**
  - Session matches (the prompt's sessions list and a `?` search) are grouped under their tab's row.
  - Groups are ordered by their best match, and sessions within a group by their own score.
  - The tab's row says its name, its machine, and open, closed or done.
  - A match with no tab is a row alone, as today.
- **Opening a match opens the tab,** from the tab's row or any of its sessions:
  - **open here:** shown, with the pane on that conversation focused if there is one;
  - **closed here:** reopened;
  - **another machine's:** opened as that machine's tab, or reopened there with a `resume` per session;
  - **in Completed:** reopened, and its mark taken off, as ↩ on its card does.
- **A match with no tab** is resumed in a new one-pane tab, as today, and the conversation joins that tab's history.
- **Every row added to the session list, the prompt's list and the results** goes into the panel's height in each branch, with the selection's order and the row ids that follow the highlight.

**The session list**
- **A tab's row under Tabs:**
  - its name or focused pane, as today;
  - its Claude sessions and how many wait on the user or work ("3 sessions · 1 waiting");
  - its other panes as "N panes", as today.
- **Under each paired machine's name, one row per tab,** grouped by the tab id the host lists (option 01). ↩ opens the tab (option 01: its sessions on their cards, in one tab here).
- **Recent's rows are closed tabs.** Each gives its name or focused session's title, its sessions, its folder, when it closed and its machine.

**The Phone page**
- **Home lists the host's sessions under their tabs,** and Recent lists closed tabs.
- **Reopening a closed tab** asks `resume` for each of its sessions, together, on a Mac host and on the headless host alike, with the same checks as a resume: the host's own Recent offers it, and a refused one returns the open tab to take over.
- **The page still opens one session at a time.** A tab's panes, one at a time, come with option 03.

**The protocol** goes to 23, with the Phone page's constant:
- `recent` lists closed tabs, each with its id, name, when it closed, its Claude sessions (conversation, title, folder, agent) and its mark (option 01);
- `rows` gives each row its tab's id and name;
- there is no `reopen`: `resume` names the tab.

## Testing Decisions

- **No test target yet.** The pure parts are where tests would go once there is one:
  - which tab a conversation belongs to after moves, reopens and resumes;
  - the grouping and order of search matches;
  - the migration of Recent;
  - what a host's `recent` answer does to the merged Recent.
- **Builds:** `make build`, the package's build on Linux, and `bun test` in the Phone page.
- **By hand,** after the user restarts Varnick on each Mac and upgrades the headless host:
  - **The tab row.** A tab with three Claude panes, one waiting on a question: its row says "3 sessions · 1 waiting".
  - **A `/clear`.** `/clear` in one pane: the left conversation isn't in Recent. A search for it shows it under that tab, and ↩ shows the tab.
  - **Reopen from Recent.** Close the tab with ×: it is first in Recent, and ↩ brings back the layout.
  - **A grouped search.** Search for a word in two of its sessions: one group, two matches under it.
  - **Another Mac's closed tab.** On Mac B, Mac A's closed tab is in Recent, marked Mac A. ↩ reopens it on Mac A and opens it on Mac B.
  - **The Ryzen.** A Ryzen session ended is in Recent as a one-pane tab, and ↩ resumes it there.
  - **A session from before.** One that belonged to no tab opens in a new tab, and a second search shows it under that tab.
  - **The phone.** The page's home lists sessions by tab, and its Recent reopens a Mac's closed tab.

## Out of Scope

- Another machine's tab opened whole, with its layout, terminals and the rest (option 03).
- Resuming one exact old conversation from search into a pane of its tab.
- **Folding the session names into the new table:** a refactor worth raising, not asked for. Each tab's name would then be kept once, and the board and search would read it from one place.

## Further Notes

- **No ADR of its own.** It follows from decision 3 and option 01's tab ids. The CONTEXT.md entries for **Recent** and **Session** change ("what Recent lists" becomes the tab's history).
- **where-it-breaks to update:**
  - Panel size: the new rows;
  - Sessions and tabs: a tab's history and a conversation's one tab;
  - Search store: the new table, with "made if it isn't there" and its readers on an older database;
  - Peers: `recent` as tabs, `rows` with tabs, a tab's `resume`s.
- **Verified in the code at 0d1d161:**
  - Recent lists sessions, including those a `/clear` or `/resume` left behind;
  - opening a search match activates the pane on that conversation, or resumes it in a new tab;
  - the session names table is written from the saved tabs at each sync and at once on naming;
  - a Mac host gives a session started for the phone or a peer its own one-pane tab;
  - the Phone page lists `sessions` and `recent`.
- **Inferred:**
  - Claude Code's own `/resume` picker lists the folder's conversations, so an old conversation of an open tab is one `/resume` away inside it.
- **Picked:**
  - a history cap of 50;
  - closed tabs in Recent whether or not they were Done, as today's Done sessions are;
  - a conversation belonging to the latest tab that held it.
- **Decided by the user (2026-10-12),** when accepting this option, each the recommendation:
  1. **A conversation a `/clear` or `/resume` left behind** stays in its tab's history.
  2. **↩ on a search match** opens the tab only; the conversation is reached with `/resume` inside it, with no second key for now.
