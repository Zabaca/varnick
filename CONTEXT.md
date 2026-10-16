# Varnick

A macOS launcher: a floating panel that searches browser history, and runs Claude Code sessions side by side with terminals, web pages and files.

Called Launchy until 2026-10. Older records keep that name; [ADR 0024](docs/adr/0024-launchy-is-renamed-varnick.md) maps old names to new.

## Language

### Search

**History**:
Pages visited in Chrome, kept in a local archive after Chrome drops them, and searched from the panel.
A **Peer**'s History is searched with this Mac's, marked with its Mac when only that Mac visited the page.
_Avoid_: Favorite, browsing data, history of a tab (that is its **Tab history**)

**Bookmark**:
A page saved in Chrome's bookmarks, searched alongside **History** whether or not it was visited. Varnick follows Chrome, so a bookmark deleted there leaves search.
_Avoid_: Favorite, saved page

**Search term**:
What was typed into a search engine before clicking through to a page of **History**; kept with the page and searched alongside its title.
_Avoid_: Keyword, query (the query is what's typed into Varnick)

**Relevance filter**:
Search's last pass: a model judges which of the top 20 pages match what the search is after and moves them to the top, leaving the rest below in their order. Runs on TypeSafe or on this Mac, for a **Spoken request** as for a typed search; for a typed search a Claude session is never judged, and for a **Spoken request** it also scores up to 3 sessions.
_Avoid_: Reranker (in the UI), Jev

**Page description**:
A page's own summary from its `<head>`, fetched once without cookies, so pages behind a login have none.

### Workspace

**Session**:
One Claude Code conversation: what `/clear` starts fresh and what `/resume` brings back. A pane can move from one session to another without closing, and the **Tab** keeps the ones it has held as its **Tab history**. Search finds sessions, since that is where the text is, and shows each under the tab that holds it. The process zmx keeps for a pane is a "zmx session", never just a session.
_Avoid_: Conversation, chat

**Exchange**:
One prompt typed in a **Session** and the last text Claude wrote before the next prompt. Session search embeds each one.
_Avoid_: Turn (what Claude is doing now), chunk (the sync embeds in chunks)

**Turn**:
What Claude is doing in a **Session** right now: working, waiting for the user's next prompt, waiting in the middle of a turn on a permission dialog, a question, a plan to approve or an MCP server's request, background (the turn ended with background agents, busy teammates, workflows or shells still running, which start Claude's next turn when they end), or failed (the turn stopped on an API error, such as a rate limit; derived from the transcript like background, never written to the turn file).
_Avoid_: Status, state, running (a session "runs" while its zmx session is alive)

**Notice**:
A session's call for a look, raised by the Mac in control of it when its **Turn** changes: done (working or background to waiting, but not after the user's own Esc), needs you (a permission dialog, a question, a plan or an MCP request), stopped on an error or, raised by the session itself, a **Message**. It marks the menu bar icon with a dot, plays a sound and heads the menu bar menu, where choosing it opens the pane. A pane has at most one, cleared when its turn moves on, when the pane comes on screen or closes, or when its category is switched off in Settings › Claude; none is raised for the pane the user is looking at, for background work still running, or for a pane showing a **Card**. It is not a macOS notification. The same table is pushed to the phone by a host's **Phone page** server, routed by who controls the pane and whether they are there (**Presence**); a host's Esc mark and error kind travel to the Macs that follow its panes, so a peer's Esc raises no Done and its error names its kind.

A **Message** is the one notice the session raises itself: a call of the `notify` tool of Varnick's MCP server (a title and an optional body; listed in every Claude pane, a headless host's too) or of Claude Code's own PushNotification, recorded by one PostToolUse hook in the pane's folder. It replaces what stands and gets the louder sound and the orange dot, and the menu line shows its title. A Done that follows a standing message is folded into it, with no time limit, and Needs you and an error replace it. It clears at the user's next prompt, a `/clear` or a start of claude in the pane. A pane alerts for a message at most once a minute. Its words travel only over the user's own links, never in a push.
_Avoid_: Alert, notification (macOS's banners, which options 02 and 03 of `sessions-finish-unnoticed` add on top)

**Panel**:
Varnick's one floating window, shown and hidden with its show/hide shortcut and pinnable, that shows one view at a time: the search, a **Tab** of **Pane**s, the **Session board**, the **Outline** or **Resources**, with Settings over it.
_Avoid_: Window (another app's, which **Screen access** reaches), popup

**Session board**:
The panel's view of the **Tab**s with a Claude pane on this Mac and the tabs open on paired Macs, each as one **board card**, listing the tab's sessions, in one of three columns by the **Turn** of its most urgent session (waiting on the user mid-turn, then working, then background, then waiting for the next prompt): Running (working or background), Stopped (everything else, marked when Claude waits on the user mid-turn, or "API error" when the turn failed, and below the live cards the **ended cards** of tabs that closed without Done, or that a paired Mac's Recent says closed there after this Mac listed them open, kept until the user marks them done or opens them) and Completed (reached only by Done, which is a tab's and closes all its panes, and shared between the paired Macs through each tab's host: [ADR 0032](docs/adr/0032-a-tabs-done-mark-belongs-to-its-host-and-completed-lists-tabs.md)). ↩ on a Completed or ended card reopens the tab whole. It replaces the panel's content as Settings does. Beside Sessions it has a Runs tab, while Settings › Experimental › Automations is on, listing every **Run** of every **Automation** newest first. And it has a Problems tab, while Settings › Experimental › Problems board is on: a card per problem of the projects that keep `docs/problems`, in Backlog, Decided, Building, Shipped or Closed by what the problem and option files say, the branches tied to options and the **Work links** of live sessions, not by **Turn**, with a chip for each session that worked on it.
_Avoid_: Kanban (the command's name), dashboard; "card" alone, which is a pane's **Card**

**Resources**:
The panel's view of what Varnick's memory is made of, opened by ⌘⇧M or `!resources` (also `!memory`): the total and its process count, the same processes grouped by kind, the app's own memory split into on-device models and the rest, then the **Tab**s that run on this Mac biggest first, each opening into its **Pane**s and their processes and each with a Close that does what the tab's × does, and below them what Varnick runs that belongs to no tab, the tabs of other machines open here (where they run, with no figures from the host) and, greyed, Claude Code outside Varnick. Every figure is a footprint, the figure Activity Monitor's Memory column shows, and every process is counted once, by ancestry from the pane's zmx session, never by name. Settings › Resources shows the same table. It reads the processes only while it shows.
_Avoid_: Memory view, task manager, process list, Activity Monitor

**Pane**:
One box inside a tab, showing a session, a terminal, a web page, a **Custom app**, a file or the live **Transcript**.
_Avoid_: Window, view, leaf

**Task**:
A saved piece of work Varnick carries out, with an input, steps and a result: "find the delivery price of this product on this site". Each **Step** uses one **Capability**. Two Tasks ship with Varnick. **Claude prompt** is one Claude step whose input is a prompt, a folder and an agent; it is what an **Automation** runs. **On this site** is one Website step whose input is a site and a goal; it is what `!task` starts by hand: the harness owns the loop (it reads the page, peeks at every link, keeps a value bank for forms, checks in code and gets itself out of loops), Jev chooses each step (Claude, in its place, when the relevance filter isn't on TypeSafe with a key, or after Jev fails), and the user's own Claude Code writes the values and steers when Jev is unsure. The user types passwords, one-time codes and card numbers in the page, ticks the terms and allows every form submit but a search. One Website pane works at a time; it ends with its pane, with Stop, or when Varnick restarts. Behind a switch, off by default (Settings › Experimental); see [ADR 0041](docs/adr/0041-a-task-is-a-checked-state-graph-run-by-varnick-and-an-automation-is-its-trigger.md) and [ADR 0039](docs/adr/0039-varnick-carries-out-a-task-in-a-browser-of-its-own-with-jev-choosing-each-step-and-claude-steering.md).
_Avoid_: Workflow (Claude Code's Workflow tool), job, pipeline, flow, routine, recipe, Agent (a Claude Code definition), computer use (avoided for **Screen access**), automation (that is the **Automation**, a trigger that starts a Task on a cadence)

**Step**:
One part of a **Task**: it uses one **Capability**, takes its values from the Task's input and from earlier steps, and names the next step for each of its outcomes. A **Run** records each one.
_Avoid_: Stage, action

**Capability**:
What a **Step** does: Claude, Website (the **Website pane**'s loop), Judge, Notify or another Task.
_Avoid_: Tool (an MCP tool), skill

**Automation**:
A trigger: a cadence, a **Task** and the values it takes, which Varnick starts as a **Run** on the cadence. Today its Task is always the Claude prompt, so it is a saved prompt that Varnick starts as a Claude **Session**, in a folder (a **Project**, or **Home**) with an optional **Agent**: "every weekday at 9:00, summarise what changed in this repo". It is made and edited in Settings › Automations, or by a Claude **Session** on this Mac through Varnick's MCP server, kept in a file on the **Host** that runs it (this Mac's `automations.json`, at version 2, with the Task's name and its input; a headless host's, saved there from any listed Mac in Settings › Automations, which then labels its runs) and fired by that host alone: once a minute while its Varnick runs, at launch and after a wake, or on a headless host by a systemd timer that runs its relay once a minute, with every Mac asleep. The prompt goes to Claude as written. Its cadence is a preset (every 15 or 30 minutes, every 1, 2, 3, 4, 6 or 12 hours, daily, weekdays or weekly at a time, in the zone of the Mac that saved it), its permissions follow Settings › Claude's Skip permissions unless it says Ask, Allowed tools only or Skip, and its working limit ends a run that goes on too long. At most one **Run** of it goes at a time. A slot that passed while the Mac slept or Varnick was quit runs once, at the next wake or launch, if it is under 12 hours old; the older ones are marked missed. Behind a switch, off by default (Settings › Experimental). What a session may do to one, and what shows when it has, is in [ADR 0040](docs/adr/0040-automations-are-fired-by-the-host-that-keeps-them-and-a-run-is-a-pane-kept-out-of-sight-until-opened.md); the Task and the Run are in [ADR 0041](docs/adr/0041-a-task-is-a-checked-state-graph-run-by-varnick-and-an-automation-is-its-trigger.md).
_Avoid_: Schedule, cron job, routine, scheduled task (Claude Code's and Claude Desktop's own)

**Run**:
Any **Task**'s execution and what became of it; in this build always an **Automation**'s slot, kept in the runs file (`runs.json`, a file of its own beside `automations.json`). It holds the Task's name, a copy of the input it started with, what started it (the automation, the slot, whether it was late or Run now), its state, its steps and when it started and ended. For the Claude prompt Task it is a Claude pane started as a typed **Prompt** is, in zmx, in a tab of its own named after the automation, kept out of the tab strip, the session list, the **Session board**'s Sessions tab, Recent and search's tab rows until the user opens it, from the board's Runs tab or a **Notice** in the menu; its pane is found through its step, and its id is the pane's. A run on a headless host is labelled for the Mac that last saved its automation, which holds it as an unseen view; the host marks its tab in its listing, so other Macs keep it out of their lists while their Automations switch is on and the phone lists it under Runs, until it is opened. Its MCP server lists `notify` alone, never **Screen access**'s or **Panel access**'s tools or the automation tools. It raises the notices any pane does (Done, Needs you, an error, a **Message**). Opened while it works or waits, it shows live and is an ordinary tab from then on; ended, its conversation is resumed in a new tab. A run ends its process, never its conversation, when its turn works past the automation's limit, after 24 hours of waiting on the user, or 10 minutes after Done if nobody opened it. A slot that did not run is a run too, marked skipped (the last was still going), missed or couldn't start, and the board's Runs tab lists them all, newest first.
_Avoid_: Job, execution, session (a run is a session, but a session is not a run)

**Website pane**:
A **Pane** that is a browser of Varnick's own, picked with `!task` or the split picker's Website tile: an address bar, a line for what to do, the page, and a column of steps (its trail), each marked with who acted (Jev, Claude, the harness, the user). Its website data is its own, not kept, and gone when it closes. It reads and acts inside the page only, never on the screen, so it needs no permission. It is never saved, so a restart ends it, and it is not listed to paired Macs or the phone. It was called the Task pane until 2026-10, and the code still says Task (`TaskPane`, `TaskController`, `Settings.tasksOn` and its key, `ShortcutAction.stopTask`, the `!task` word), because a changed key or id would lose a setting or a rebinding. The new record types start with Task too (`TaskRun`), since the bare name is Swift's own.
_Avoid_: Task pane, Agent pane, automation pane

**Restart**:
Ending the Claude process in a pane that runs on this Mac and starting it again in the same pane, resuming the same **Session**, so it picks up the current hooks. The tab, splits, title and folder stay. It asks first when the **Turn** is working or background. A pane showing a **Card**, or a session on a **Peer**, can't restart. Not Restart Varnick (the app quitting and starting again, which ends every pane) and not the peer `restart` request (a **Peer**'s Varnick restarting).
_Avoid_: Reload, relaunch

**Custom app**:
A small web app that Varnick runs and shows in a pane picked from the split picker, kept in a project's or the user's custom-apps folder. The user builds it, or turns it on from the **Catalog**; it appears only where it's installed.
_Avoid_: Plugin, extension, add-on

**Catalog**:
The custom apps that ship with Varnick, reviewed in its repository, which the user turns on one by one in Settings › Apps. A catalog app, once on, is one of the user's **Custom apps**.
_Avoid_: Marketplace, store, built-in app

**Tab**:
A group of panes, split side by side or stacked, shown together in the panel. It keeps an id across launches, which is how the **Session board**, Completed and other machines name it, and belongs to one machine, its **Host**, which keeps its layout, panes and mark. A tab here that shows another machine's is a view of it, under its id, in the host's layout with every pane of it ([ADR 0034](docs/adr/0034-a-tab-lives-on-one-host-which-keeps-its-layout-panes-and-mark-and-other-devices-view-or-take-over-the-tab-whole.md)): only the machine **in control** of it changes it, and a split starts the new pane on the host. The user's unit of work: Done is a tab's, and it closes every pane in it. It keeps a **Tab history**.
_Avoid_: Workspace, window

**Tab history**:
The **Session**s a **Tab** has held, newest first (the newest 50), saved with it: the ones `/clear` and `/resume` left behind and those of panes closed while it stayed open included. A session is in the Tab history of the latest tab that held it, and search shows it under that tab.
_Avoid_: History (the Chrome archive, see **History**), Recent

**Home**:
Varnick's own folder for sessions that belong to no project: `Home` in its support folder. A new session with no project starts there, and so does an automation with no project. It is not the user's home folder, and it is not a setting. Varnick marks it trusted in Claude Code. A headless **Host** has one too, in its relay's state folder, where an **Automation** with no project runs; Claude Code never saves trust for an account's own home folder, so nothing runs there.
_Avoid_: Default folder, Working folder, Claude folder, home folder

**Recent**:
The tabs that closed, Done or not, newest first (the newest 20); ↩ on one reopens it whole. A **Peer**'s closed tabs are listed with this Mac's, marked with their Mac, and reopened on that Mac. A **Session** `/clear` or `/resume` left behind is in its **Tab history**, not in Recent.
_Avoid_: History (the Chrome archive, see **History**), closed sessions

**Scratch area**:
A folder in the project, belonging to one Claude pane, where Claude builds a page that Scratch, a **Custom app** split from that pane, shows live. It stays with the pane when the pane moves to another session.
_Avoid_: Sandbox, playground

**Peer**:
Another machine that this Mac is paired with over SSH: a Mac running Varnick, or a **Headless host**. Pairing is mutual between Macs, and removal is not.
_Avoid_: Remote, node

**Build**:
The commit a machine's Varnick or relay was built from, and its protocol. A Mac can have a newer build waiting for Restart Varnick: built, not yet running. Upgrade makes a build and never runs it.
_Avoid_: Version

**Published build**:
A **Build** that is signed, notarized and attached to a release, which a person downloads and installs as Varnick.app. A Mac on one is updated by downloading the next.
_Avoid_: Release (it already means giving up control of a pane), version

**Device**:
Another device of the user's on the tailnet, such as the phone, listed on a **Host** by its tailnet node so it may use that host's **Phone page**. It can be **in control** of a session, and is never contacted.
_Avoid_: Client, browser, peer (a peer is paired over SSH)

**Phone page**:
The web page a **Host** serves on port 8444 of its tailnet name, for a **Device**: its open tabs, each shown one pane at a time, **Recent**, a new session and a terminal (typed into with the phone's own keyboard, plus one row of keys it lacks: Esc, Tab, Shift+Tab, the arrows and a sticky Ctrl), all through the host's own relay, and links to the other hosts' pages. It installs as an app on the phone, one per host (each host's page is its own origin), named for its host and opening full screen. It can send the phone a push notification when a session of the host needs the user, with one switch each for needs me, done, errors and messages: the **Notice** table, sent when the user is away from the Mac that controls the session (see **Presence**), or when the phone controls it. The same server runs the host's **Port proxy**.
_Avoid_: Web UI, dashboard, remote

**Presence**:
Whether the user is at a Mac, as raw facts: the seconds since its last keyboard, mouse or trackpad input, an away flag for a locked screen, a display asleep or a login session switched away, and which Claude panes the Mac holds a **Notice** for and shows on screen. Each Mac reads its own (no permission) and tells every host it has a pane on, on the `status` request it sends every 5 s; the host's page server alone turns the facts into **present** (screen unlocked, display awake, login session active and under 2 minutes since the last input) or **away**. A report older than 20 s, or none, means the Mac can't be told, which counts as away. It decides only where a **Notice** goes: a Mac whose user is present notifies there, and the phone is pushed when it isn't, unless the Mac has shown the user the notice by then.
_Avoid_: Idle, online, active (a session is active)

**Port proxy**:
The reverse proxy in a **Host**'s **Phone page** server that lets another Mac or a **Device** load the host's web and app panes, which run at the host's localhost. It listens on the host's tailnet addresses, one TLS listener for each port an open tab's web or app pane uses, only while that pane's server answers, and only for the user's listed devices and paired Macs. The host's `tabs` listing gives each such pane its proxied address, or says why it has none.
_Avoid_: Tunnel, forward (a forward is one request through it)

**Host**:
The machine where a session's Claude process runs, kept alive by its zmx: a Mac, or a **Headless host**. A session's host never changes, and a **Tab**'s is the machine its panes run on. The host keeps the tab's layout, its panes and its done mark, and lists its open tabs whole to the other machines and devices.
_Avoid_: Server, remote

**Headless host**:
A host with no Varnick app, such as an always-on Linux machine: Varnick's relay alone answers for it, and nothing runs between requests. It keeps tabs of several panes, Claude sessions and terminals. A Mac or a **Device** is always the one **in control** of a tab on it.
_Avoid_: Server, Linux host

**In control**:
The one Mac or **Device** whose keyboard reaches a **Tab**'s Claude and terminal panes, the same for each; other Macs show their live screens. Only it changes the tab's layout. On a **Headless host** it is always a Mac or a Device.
_Avoid_: Owner, leader (zmx's word)

**Card**:
(Not a board card on the **Session board**.) What a Claude or terminal pane shows in place of its terminal while another Mac or a **Device** is in control of its tab, or its host can't be reached. It holds no process, and closing it on a peer ends nothing (except a Resuming card, which closes the request to start the session again); on the host it asks first, since the card is the only pane that session has there. While another Mac or a Device is in control ("Controlled on Phone") it draws the pane's **live screen** under a bar with Take over; when the host can't be reached, or has lost the session, or lists the pane as not running, it is a message with Reconnect, Retry or Start. A pane of another machine's tab that stays on it (the Transcript, an app, a page at a local address) is a plainer card that says where it runs.

**Live screen**:
The session's screen as its host's zmx has it, sent to the card of the Mac that isn't in control while the card is shown, and to the session view of a **Device**'s **Phone page** that isn't in control while the page is visible, as it changes. It is drawn at the grid of the Mac or Device in control, scaled to fit the pane (on the phone, the width, with pinch to zoom), and is read-only: it takes no input.
_Avoid_: Mirror (an Outline term, see **Mirror**), stream, live view

**Frozen screen**:
The last **live screen** kept in the card while it isn't updating: the pane was hidden, or the link is down or reconnecting. Marked "Last screen at HH:MM".
_Avoid_: Mirror (an Outline term, see **Mirror**)

**Take over**:
Moving control of a **Tab** to the Mac or **Device** that asks: relabel every Claude and terminal pane of it, detach their clients, attach each pane. Offered on a card, and it takes all the tab's panes. Opening a paired Mac's open tab, from the session list or from ↩ on a Recent or search row, shows the cards first, so control moves only when the user presses Take over; reopening a closed tab there is the one case that starts it labelled for the asker.
_Avoid_: Steal, attach

**Release**:
What closing a pane, or a whole tab, that is in control does unless it came from the Mac closing it: the pane closes, control goes back to the host, and the session keeps running there. Closing ends a session only when the host started it for the Mac closing it, as closing a pane always has; a tab ends when every running pane of it was. Any other Mac or **Device** in control only releases it: the host started it itself (at its own prompt), or for a different Mac or Device. The host decides, since only it knows where it came from. A headless host has no keyboard to hand control to, so there the label stays: the session shows as last controlled on the Mac or Device that released it ("Last controlled on Phone").
_Avoid_: Detach, hand back

### Starting a session

**Prompt**:
What is typed into the panel, unless it starts with `?` (a search) or `!` (a **Command**): it starts a new session. It is an optional peer (`^name`, a **Peer**), project (`#name`) and agent (`@name`), in any order, then the message: the rest, which is what Claude receives. Matching sessions list under it, each group under a row for the **Tab** that holds them.
_Avoid_: Ask, command

**Project**:
A git repo under the project folders that a session can start in instead of **Home**. A **Tab**'s project is its first Claude pane's (else its first pane's).
_Avoid_: Repo, workspace

**Agent**:
A Claude Code agent definition (its instructions, tools and model) that a session runs as from its start.
_Avoid_: Profile, persona

### Commands

**Command**:
A word typed after `!` that runs a Varnick action instead of searching, such as `!listen` or `!transcript`.
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

### Outline

**Outline**:
The panel's view of one tree of **Bullet**s the user writes, kept in a file on this Mac and nowhere else (a **Session** that **Panel access** lets read it sends what it reads to Anthropic, and can edit it without asking). It replaces the panel's content as Settings and the **Session board** do. It is behind a switch, off by default (Settings › Experimental); the switch never touches the file.
_Avoid_: WorkFlowy (the app it copies), notes, outliner, document

**Bullet**:
One line of the **Outline**: its text, an optional note under it, whether it is completed, and the bullets nested under it. A completed bullet is struck through, and hidden unless Show completed is on. (Not the board's Completed column, which holds sessions marked Done.)
_Avoid_: Item, node, row, entry, task, card

**Zoom**:
Showing one **Bullet** as the top of the **Outline**: its text as the title, the bullets nested under it below, and breadcrumbs back up the way the user came in.
_Avoid_: Focus (a pane's), open, drill down

**Filter**:
Words typed at the top of the **Outline** that hide every **Bullet** that doesn't match, while keeping each match's ancestors. It looks only inside the bullet zoomed into. Not the **Relevance filter**, which is search's last pass.
_Avoid_: Search (a `?` query searches **History**), find

**Tag**:
A `#word` or `@word` in a **Bullet**'s text or note. Clicking it filters the **Outline** to it, and clicking it again takes it out of the filter. Not a **Project** or an **Agent**, which `#name` and `@name` name in a **Prompt**.
_Avoid_: Label, hashtag, mention

**Placement**:
One spot where a **Bullet** shows: an entry in its parent's list. A bullet's text, note and completion are kept once, however many placements it has.
_Avoid_: Instance, occurrence, link

**Mirror**:
A **Bullet** with more than one **Placement**, so an edit in one spot shows in all. Collapse is each placement's own. None is the original: deleting a placement removes only that spot, and the bullet is gone with its last. Not the **Live screen**, which avoids the word.
_Avoid_: Copy, clone, link, reference, original

**Selection**:
**Bullet**s chosen whole in the **Outline**: siblings next to each other, each with everything nested under it, so that one key acts on all of them. Not text selected inside one bullet, which never runs into the next.
_Avoid_: Highlight (the **Filter**'s mark on matching words), block, multi-select

**Varnick's own copy**:
What ⌘C or ⌘X on a **Selection** puts on the clipboard beside the indented text: **Bullet**s with their notes, completion and collapse, nested, and no ids, in a pasteboard type of Varnick's with a version. A paste prefers it to the text, and makes new bullets from it. Not the **Mirror** copy, which ⌥⌘C keeps in the app and never puts on the clipboard.
_Avoid_: Clipboard format, native paste

### Listening

**Listening**:
Varnick transcribing the microphone and the Mac's own audio on this Mac, until it's turned off. Off at each launch.
_Avoid_: Recording, dictation

**Transcript**:
What Varnick heard while listening: one file per day, a line per finished phrase with its time and source (`mic` or `system`), and a line for each answer Varnick spoke (`varnick`). What the mic hears while Varnick speaks isn't in it. Not a Claude Code conversation's transcript, and not **Saved audio**.
_Avoid_: Log, recording

**Saved audio**:
The sound itself, kept only with Settings › Listening › Save audio on: m4a files of the mic and of the Mac's audio, made while **Listening** runs. It holds everything heard, including the mic while Varnick speaks, which the **Transcript** leaves out. Local only; Varnick never deletes it. Kept to test speaker separation and voice recognition on real calls.
_Avoid_: Recording, call recording

**Wake phrase**:
"Hey Varnick" at the start of something said into the microphone while **Listening** is on. It turns what follows into a **Spoken request**.
_Avoid_: Hotword, trigger

**Fallback voice**:
The voice installed on this Mac that speaks a line when an ElevenLabs voice is chosen and ElevenLabs fails or is slow. It is the same setting that holds the installed voice otherwise, kept when an ElevenLabs voice is picked.
_Avoid_: Backup voice

**Text helper**:
The signed copy of Bun inside Varnick.app and the `agent.js` it runs, which write a text through the user's own `claude` when Text generation is set to Claude Code. It keeps no transcript and shows on no board, so a call is not a **Session**.
_Avoid_: Agent (an **Agent** is a Claude Code definition), Claude session

**Spoken request**:
What the user says after the **Wake phrase**. **History**, **Bookmark**s and **Session**s are all searched for it, sessions also by a project's folder name and by when they were used, and it is answered aloud from the rows the **Relevance filter** keeps or, with **Answer from the web** on, from the web when they can't answer it. A question about the time or the date is answered from this Mac's clock. When it asks about something in the window in front of the user, it is answered aloud and with an **Arrow** at that thing. Nothing is ever opened, clicked or focused.
_Avoid_: Ask (except `--ask`, the command-line flag that runs one), prompt (a **Prompt** starts a session), command, query

**Route**:
The one call that decides what a **Spoken request** means, Jev's or, when Jev isn't used or fails, the Text generation model's: how likely each source is, whether it asks the time or asks for something Varnick can't do, whether it is about the screen, which **Project** and which time it names, whether only the user's own things can answer it, one result or several, and which of its words to search for. It orders the rows and shapes the session search; it never shuts a source out, and no phrase list decides anything.
_Avoid_: Router, decide step, classifier

**Project index**:
What the **Route** reads to tell a **Project** from a word: for each of up to 40 projects, its name, other names (its git remote's repo name, the title of its `CLAUDE.md` or README), a one-line description and its last three **Session** titles. Built on this Mac after each project scan and session sync, and kept in memory.
_Avoid_: Project list (that is `#name`'s)

**Judge**:
The Jev call that scores the first 20 pages and up to 3 sessions of a **Spoken request** for whether each helps answer it. Rows at 0.5 or more are kept, as are the sessions a named **Project** or a window with `own` selected. For a typed search the **Relevance filter** is a call of its own.
_Avoid_: Filter (for the spoken call), reranker

**Writer**:
Text generation as it writes the answer to a **Spoken request** from the rows the **Judge** kept. With **Answer from the web** on, and no session among the rows, it may reply that they don't hold the answer, and the request goes to the web.
_Avoid_: Answerer, model

**Acknowledgement**:
The general line a **Spoken request** gets when the hold ends and its answer isn't ready ("Let me check."), and "Looking that up." when the web is asked. Said before the answer, which is queued behind it, and not written to the transcript. A request whose one line is ready (the clock, something Varnick can't do, nothing found) gets none.
_Avoid_: Cue, earcon (the wake sound is a sound, not a line)

**Answer from the web**:
The setting (Settings › Listening, off by default) that answers a **Spoken request** from the web, through the user's own Claude Code and its search tool, when the rows can't. A request that names a session folder, or is only a time, is never asked of the web.
_Avoid_: Web search (the tool is Claude Code's, not Varnick's)

**Arrow**:
What Varnick draws over the screen to point at the thing a **Spoken request** asked about, or that a **Session** points at with its screen tools: a big arrow with a sign holding the note Varnick says aloud, or the session's name and note. It lets clicks through, never takes focus and goes by itself.
_Avoid_: Highlight, cursor, annotation, overlay

**Screen access**:
The setting (Settings › Claude, off by default) that gives the Claude **Session**s in Varnick's panes, started or restarted while it is on, six tools: `look` at a window's controls (and which one has focus, and with `picture` an image of it, password fields painted black, or with `screen` or `display` an image of every display or one, nothing blacked out), `point` at one with the **Arrow**, `click`, `type`, `drag` and `window` (move or resize). The running Varnick does the work under its own permissions, with the code a **Spoken request** uses, and an action happens without asking, the **Arrow** showing on its target for a second first and the app brought to the front (not for `window`). What a session is shown, a picture included (which shows everything on the window or the displays, typed text too), goes to Anthropic with it.
_Avoid_: Computer use, remote control

**Panel access**:
The setting (Settings › Claude, under **Screen access**, off by default) that gives the Claude **Session**s in Varnick's panes, started or restarted while it is on, tools to read what the panel shows, the **Session board**'s cards, the panes' terminal screens and the **Outline**'s bullets, to change what the panel shows, to edit the Outline without asking (each edit one undo step; an edit to the bullet being typed in goes into it as a key does, around the user's caret), and to press keys in the panel through its own key handling while it is up and the user is not typing in it, through Varnick's own model, with no permission. What a session reads goes to Anthropic with it; see [ADR 0031](docs/adr/0031-sessions-read-and-act-on-varnick-through-its-own-model-on-the-varnick-server-with-no-grant.md).
_Avoid_: Screen access (any app's window, through Accessibility), API, automation (that is the **Automation**)
