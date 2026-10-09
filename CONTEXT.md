# Launchy

A macOS launcher: a floating panel that searches browser history, and runs Claude Code sessions side by side with terminals, web pages and files.

## Language

### Search

**History**:
Pages visited in Chrome, kept in a local archive after Chrome drops them, and searched from the panel.
A **Peer**'s History is searched with this Mac's, marked with its Mac when only that Mac visited the page.
_Avoid_: Favorite, browsing data

**Bookmark**:
A page saved in Chrome's bookmarks, searched alongside **History** whether or not it was visited. Launchy follows Chrome, so a bookmark deleted there leaves search.
_Avoid_: Favorite, saved page

**Search term**:
What was typed into a search engine before clicking through to a page of **History**; kept with the page and searched alongside its title.
_Avoid_: Keyword, query (the query is what's typed into Launchy)

**Relevance filter**:
Search's last pass: a model judges which of the top 20 pages match what the search is after and moves them to the top, leaving the rest below in their order. Runs on TypeSafe or on this Mac, for a **Spoken request** as for a typed search; a Claude session is never judged.
_Avoid_: Reranker (in the UI), Jev

**Page description**:
A page's own summary from its `<head>`, fetched once without cookies, so pages behind a login have none.

### Workspace

**Session**:
One Claude Code conversation: what `/clear` starts fresh, what `/resume` brings back, and what Recent lists. A pane can move from one session to another without closing. The process zmx keeps for a pane is a "zmx session", never just a session.
_Avoid_: Conversation, chat

**Exchange**:
One prompt typed in a **Session** and the last text Claude wrote before the next prompt. Session search embeds each one.
_Avoid_: Turn (what Claude is doing now), chunk (the sync embeds in chunks)

**Turn**:
What Claude is doing in a **Session** right now: working, waiting for the user's next prompt, waiting in the middle of a turn on a permission dialog, a question, a plan to approve or an MCP server's request, or background (the turn ended with background agents, busy teammates, workflows or shells still running, which start Claude's next turn when they end).
_Avoid_: Status, state, running (a session "runs" while its zmx session is alive)

**Session board**:
The panel's view of the Claude panes on this Mac and the sessions open on paired Macs, each as a **board card** in one of three columns by **Turn**: Running (working or background), Stopped (everything else, marked when Claude waits on the user mid-turn, and below the live cards the **ended cards** of sessions whose pane closed without Done, or that a paired Mac's Recent says closed there after this Mac listed them open, kept until the user marks them done or opens them) and Completed (reached only by Done: on a live card it closes the pane, on a paired Mac's session it only marks it and nothing ends there, and on an ended card it just moves it). It replaces the panel's content as Settings does. Beside Sessions it has a Problems tab: a card per problem of the projects that keep `docs/problems`, in Backlog, Decided, Building, Shipped or Closed by what the problem and option files say, the branches tied to options and the **Work links** of live sessions, not by **Turn**, with a chip for each session that worked on it.
_Avoid_: Kanban (the command's name), dashboard; "card" alone, which is a pane's **Card**

**Pane**:
One box inside a tab, showing a session, a terminal, a web page, a **Custom app**, a file or the live **Transcript**.
_Avoid_: Window, view, leaf

**Restart**:
Ending the Claude process in a pane that runs on this Mac and starting it again in the same pane, resuming the same **Session**, so it picks up the current hooks. The tab, splits, title and folder stay. It asks first when the **Turn** is working or background. A pane showing a **Card**, or a session on a **Peer**, can't restart. Not Restart Launchy (the app quitting and starting again, which ends every pane) and not the peer `restart` request (a **Peer**'s Launchy restarting).
_Avoid_: Reload, relaunch

**Custom app**:
A small web app the user builds, kept in a project's or the user's custom-apps folder, that Launchy runs and shows in a pane picked from the split picker. It is not part of Launchy, and only appears where it's installed.
_Avoid_: Plugin, extension, add-on

**Tab**:
A group of panes, split side by side or stacked, shown together in the panel.
_Avoid_: Workspace, window

**Default folder**:
The folder a new session starts in when no project is picked.
_Avoid_: Working folder, Claude folder, home folder

**Recent**:
Sessions no longer open in any pane (ended, or left by `/clear` or `/resume`), newest first; any of them can be resumed. A **Peer**'s ended sessions are listed with this Mac's, marked with their Mac, and resumed on that Mac.
_Avoid_: History, closed sessions

**Scratch area**:
A folder in the project, belonging to one Claude pane, where Claude builds a page that Scratch, a **Custom app** split from that pane, shows live. It stays with the pane when the pane moves to another session.
_Avoid_: Sandbox, playground

**Peer**:
Another machine that this Mac is paired with over SSH: a Mac running Launchy, or a **Headless host**. Pairing is mutual between Macs, and removal is not.
_Avoid_: Remote, node

**Build**:
The commit a machine's Launchy or relay was built from, and its protocol. A Mac can have a newer build waiting for Restart Launchy: built, not yet running. Upgrade makes a build and never runs it.
_Avoid_: Version

**Device**:
Another device of the user's on the tailnet, such as the phone, listed on a **Host** by its tailnet node so it may use that host's **Phone page**. It can be **in control** of a session, and is never contacted.
_Avoid_: Client, browser, peer (a peer is paired over SSH)

**Phone page**:
The web page a **Host** serves on port 8444 of its tailnet name, for a **Device**: its sessions, **Recent**, a new session and a terminal, all through the host's own relay, and links to the other hosts' pages.
_Avoid_: Web UI, dashboard, remote

**Host**:
The machine where a session's Claude process runs, kept alive by its zmx: a Mac, or a **Headless host**. A session's host never changes.
_Avoid_: Server, remote

**Headless host**:
A host with no Launchy app, such as an always-on Linux machine: Launchy's relay alone answers for it, and nothing runs between requests. A Mac or a **Device** is always the one **in control** of a session on it.
_Avoid_: Server, Linux host

**In control**:
The one Mac or **Device** whose keyboard reaches a session; other Macs show its live screen. On a **Headless host** it is always a Mac or a Device.
_Avoid_: Owner, leader (zmx's word)

**Card**:
(Not a board card on the **Session board**.) What a pane shows in place of its terminal while another Mac or a **Device** is in control of its session, or its host can't be reached. It holds no process, and closing it on a peer ends nothing (except a Resuming card, which closes the request to start the session again); on the host it asks first, since the card is the only pane that session has there. While another Mac or a Device is in control ("Controlled on Phone") it draws the session's **live screen** under a bar with Take over; when the host can't be reached, or has lost the session, it is a message with Reconnect or Retry.

**Live screen**:
The session's screen as its host's zmx has it, sent to the card of the Mac that isn't in control while the card is shown, and to the session view of a **Device**'s **Phone page** that isn't in control while the page is visible, as it changes. It is drawn at the grid of the Mac or Device in control, scaled to fit the pane (on the phone, the width, with pinch to zoom), and is read-only: it takes no input.
_Avoid_: Mirror, stream, live view

**Frozen screen**:
The last **live screen** kept in the card while it isn't updating: the pane was hidden, or the link is down or reconnecting. Marked "Last screen at HH:MM".
_Avoid_: Mirror

**Take over**:
Moving control of a session to the Mac or **Device** that asks: relabel it, detach every client, attach. Offered on the card. Opening a paired Mac's open session, from the session list or from ↩ on a Recent or search row, shows the card first, so control moves only when the user presses Take over.
_Avoid_: Steal, attach

**Release**:
What closing a pane that is in control does unless the session came from the Mac closing it: the pane closes, control goes back to the host, and the session keeps running there. Closing ends a session only when the host started it for the Mac closing it, as closing a pane always has. Any other Mac or **Device** in control only releases it: the host started it itself (at its own prompt), or for a different Mac or Device. The host decides, since only it knows where the session came from. A headless host has no keyboard to hand control to, so there the label stays: the session shows as last controlled on the Mac or Device that released it ("Last controlled on Phone").
_Avoid_: Detach, hand back

### Starting a session

**Prompt**:
What is typed into the panel, unless it starts with `?` (a search) or `!` (a **Command**): it starts a new session. It is an optional peer (`^name`, a **Peer**), project (`#name`) and agent (`@name`), in any order, then the message: the rest, which is what Claude receives. Matching sessions list under it.
_Avoid_: Ask, command

**Project**:
A git repo under the project folders that a session can start in instead of the default folder.
_Avoid_: Repo, workspace

**Agent**:
A Claude Code agent definition (its instructions, tools and model) that a session runs as from its start.
_Avoid_: Profile, persona

### Commands

**Command**:
A word typed after `!` that runs a Launchy action instead of searching, such as `!listen` or `!transcript`.
_Avoid_: Prompt, action, shortcut

### Planning

**Problem**:
Something wrong or missing for the user, written down before any solution: what it is, what it costs, how bad. Lives in `docs/problems/<slug>/problem.md`; open until closed by hand.
_Avoid_: Bug, feature request, ticket

**Option**:
One way of solving a **Problem**, with its trade-offs. A problem can have several live at once; each carries its own status, and a rejected one keeps its reason.
_Avoid_: Proposal, solution, spec (an accepted option serves as the spec)

**Work link**:
The problem, or the option of a problem, that a **Session** or one of its subagents works on, kept as files in the pane's folder: none (the default, and a state of its own), a problem or an option. Made by writing a problem's files, by `/work`, and by the skills that create work; never read from a transcript. A session whose link names an open option makes the problem Building; a link to a shipped option is not live. A session that ends keeps its links in its saved record and in the search database. A paired Mac's sessions send theirs.
_Avoid_: Tag, assignment

### Listening

**Listening**:
Launchy transcribing the microphone and the Mac's own audio on this Mac, until it's turned off. Off at each launch.
_Avoid_: Recording, dictation

**Transcript**:
What Launchy heard while listening: one file per day, a line per finished phrase with its time and source (`mic` or `system`), and a line for each answer Launchy spoke (`launchy`). What the mic hears while Launchy speaks isn't in it. Not a Claude Code conversation's transcript.
_Avoid_: Log, recording

**Wake phrase**:
"Hey Launchy" at the start of something said into the microphone while **Listening** is on. It turns what follows into a **Spoken request**.
_Avoid_: Hotword, trigger

**Spoken request**:
What the user says after the **Wake phrase**. It is answered aloud from **History**, **Bookmark**s and **Session**s. When it asks about something in the window in front of the user, it is answered aloud and with an **Arrow** at that thing. Nothing is ever opened, clicked or focused.
_Avoid_: Ask (except `--ask`, the command-line flag that runs one), prompt (a **Prompt** starts a session), command, query

**Arrow**:
What Launchy draws over the screen to point at the thing a **Spoken request** asked about: a big arrow with a sign holding the note Launchy says aloud. It lets clicks through, never takes focus and goes by itself.
_Avoid_: Highlight, cursor, annotation, overlay
