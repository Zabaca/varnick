---
problem: sessions-cant-start-sessions-in-other-projects
title: "`tab_open` on another machine: a session finds a machine's projects with `project_search` and opens a tab hosted on a paired Mac or the headless host, controlled from its own Mac, with `opener` and `tab_done` as on one Mac"
summary: Built on options 01, 04 and 06, and on options 02 and 07 of `sessions-cant-reach-each-other-reliably`. A new tool, `project_search`, lists the Projects of this Mac, a paired Mac or the headless host, with an optional search word, each with the word `tab_open` takes, its group, its path there, when Claude last used it and whether that machine's Claude Code trusts it, read through the `projects` request machines already answer. `tab_open` gains an optional `machine`, named as `board_read` names it. That machine hosts the new tab and runs the session; the caller's Mac controls it, as when the user types `^machine #project` in the panel, so the tab joins the end of the caller's own strip, not brought up. The project must be one of that machine's Projects that its Claude Code trusts; that machine checks, and an unknown name is refused with close matches. The new session is told who opened it and on which machine, and reaches it with `send` to `opener`, across restarts of either side and of Varnick; on the host, the opener is put in the session's table of senders at the open, so the host's answer-only rule allows it. `tab_done` marks such a tab Done through its host while the user hasn't used it. Opening on another machine needs messages in both directions, so a session without `send`, or a machine not ready for messages, is refused with what to turn on. Permissions follow the caller's Mac. No protocol bump: one new request and some optional fields, so only the machines involved take the build.
status: shipped
---

## Solution

Everything in options 01, 04 and 06 holds for a tab on this Mac. A session can now also find the projects on any of the user's machines, and open a tab on another one.

**A new tool, `project_search`: what projects a machine has.** In the pane tools' set, beside `tab_open`, so the same sessions get it.

| Argument | Needed | What it is |
|---|---|---|
| `machine` | no | This Mac when left out; otherwise a paired Mac or the headless host, named as `tab_open`'s `machine` is. |
| `search` | no | A word matched, ignoring case, against each project's folder name and its group. Left out, every project. |

It answers one line per Project of that machine (a repository under its Settings › Claude › Project folders, or the headless host's project folders), those Claude used most recently first, at most 50, with how many more there are. For example, with made-up values:

> Projects on the desktop matching "kest" (2 of 41, most recently used by Claude first):
> kestrel · group zabaca · /home/someone/Projects/zabaca/kestrel · used by Claude 2 h ago · trusted
> tools/kestrel-cli · group tools · /home/someone/Projects/tools/kestrel-cli · never used by Claude · not trusted: open a session there once before tab_open

- **The word first** is the one `tab_open`'s `project` takes there: the folder's name, or `group/name` when two projects there share a name.
- **The path is that machine's own.** Its files are there, not on the caller's machine.
- **Trust** is "trusted", "not trusted" (with what to do), or "not known" when that machine runs a Varnick from before this build.
- **Read fresh** each time: this Mac scans its folders again (as `tab_open` does for a name it doesn't know), and another machine answers its `projects` request, which scans fresh there.
- **Refused** for an unknown or ambiguous machine (with the machines that answer), and for a machine that doesn't answer or whose Varnick app isn't running, each in words.

**One more argument to `tab_open`.**

| Argument | Needed | What it is |
|---|---|---|
| `machine` | no | A paired Mac or the headless host, by the name `board_read` shows after "on", or by the word the panel's `^` takes (its name, or one word of it). Left out, or naming this Mac, the tab opens here as today. |

`project`, `agent` and `prompt` are as in option 01, read on that machine: `project` is one of **that machine's** Projects, named as `project_search` gives it or by its absolute path there; `agent` is one found in that project there. An unknown name is refused with the names there that contain it, as today, and the refusal points to `project_search`.

**Where it runs and who controls it** (the user's decision). The named machine hosts the tab and runs the session, as for any tab hosted there (ADR 0034). The caller's Mac controls it, exactly as when the user types `^machine #project` in the panel: the tab is in the caller's Mac's strip as a view of that machine's tab, and that Mac has control of it. So the user meets the helper where its lead is, and a headless host, which has no screen, never holds a tab nobody's strip shows.

**What the user sees.**
- **On the caller's Mac:** a new tab at the end of the strip, marked with the machine it runs on, as a `^machine #project` tab is. It is not brought up: the panel, the tab on screen and the keyboard stay as they were. The session board shows its card "on" that machine; its Done and Needs you notices come as for any tab on that machine. Its view attaches the first time the user shows it, as a remote tab restored after a restart does, so a lead that opens several helpers holds no connection for each until the user looks.
- **On a paired Mac that hosts it:** the tab joins the end of that Mac's strip, showing "Controlled on" the caller's Mac, as for a tab the user started from there. Its Done, its notices and its Take over work there as for any such tab.
- **On the phone:** in the host's open tabs, like any tab.

**What the new session is told.** Option 04's paragraph in its `send` form, naming the machine the opener runs on, and saying that files there are not its own. For example, with made-up values:

> This session was opened by another Claude session in home (its tab: Plan the release) on the laptop, with Varnick's `tab_open`. You run on another machine, so its files are not yours. You can reach it with Varnick's `send`, with `to` set to `opener`; that works whatever restarts either of you. Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. If `send` says it can't be reached (that machine asleep, or that session closed), say so here in your own reply, and never send to another pane in its place. The user can see this tab and type into it.

The prompt goes to Claude as written. The note is saved on the host's record of the pane and passed at every start of it, until the pane moves to another conversation, as on a Mac.

**`opener` across machines.**
- **From a paired Mac:** `send` to `opener` goes to the opener's pane on the opener's Mac over option 02's request. That Mac applies option 01's checks, and the two `opener` refusals: the pane has closed (`openerGone`), or it now holds another conversation than the one that opened the tab (`openerMoved`).
- **From the headless host:** at the open, the host puts the opener in the new session's table of senders under the word `opener`, and the opener's Mac marks the opener's pane as having messaged that host. So option 07's rule (a host session answers only a `from` it received, and a Mac takes a host's message only for a pane that messaged that host) allows it, and the Mac starts collecting from that host. The host session's `send` to `opener` then goes through option 07's outbox, and the Mac applies the same two `opener` refusals.
- **Restarts.** A Restart of either pane, a restart of Varnick on either Mac and a reboot of the host keep it: the note and the host's table are saved with the pane, the opener's mark of the host with the opener's pane, and the opener's pane keeps its id. A `/clear` or `/resume` in the new session drops the note there, and `opener` is then refused, as on a Mac.
- **The opener's Mac asleep or off.** The new session's `send` to `opener` is refused at once with option 02's or option 07's words; nothing is held. The session says so in its own pane, where the user sees it, and can send again once that Mac is back.

**`tab_done` on such a tab.** Option 06's rule, applied on the caller's Mac, where the marks are:
- the mark is on the caller's Mac's view of the new pane, and the user's click, key or focus there clears it, as on a tab of this Mac;
- a Take over on the hosting Mac or the phone clears it, as for a tab of this Mac;
- just before Done, the caller's Mac asks the host for the tab's turns and who controls it, and refuses as option 06 does (mid-turn, waiting on the user, controlled elsewhere);
- Done is the model's Done on another machine's tab (ADR 0045): the host closes the tab and marks it, and the view here closes as a Done. The host checks again, right before it closes, that the caller's Mac still controls every running pane and that none is mid-turn, since a turn could start in the second the request travels.

**Permissions follow the caller's Mac** (the user's decision). `pane_open`'s rule decides there, as today: the new session skips permission checks only when Skip permissions is on on the caller's Mac and the caller was itself started skipping them, and otherwise always asks, whatever the other machine's own setting says. As for a remote tab the user starts, the choice is sent with the request and kept by the other machine for that session's restarts.

**Refused unless messages go both ways** (the user's decision), and each refusal says what would change it. In addition to option 01's refusals:
- the caller has no `send` (Messages between sessions off or not ready on its Mac, or the session started before), or its Mac's Also between my Macs and hosts is off;
- an unknown or ambiguous machine, with the machines that answer;
- that machine doesn't answer (asleep, off the network) or runs an older Varnick (Update it from its row in Settings › Peers);
- that machine isn't ready for messages (its row under Also between my Macs and hosts says why);
- a paired Mac with Keep sessions running off, or whose Varnick isn't running;
- an unknown project there (with names that contain the word, and a pointer to `project_search`), an ambiguous one, a folder that isn't one of its Projects, an agent not found there, or a folder its Claude Code hasn't trusted, each naming the machine.

**What it answers.** For example, with made-up values: "Opened a new tab in kestrel on the desktop, not brought up: s7, a Claude session as @builder. It runs on the desktop, in this Mac's strip and controlled from here, so its files are the desktop's. Send it work with `send` to s7. It was told it can reach this session with `send` to `opener`, and its result comes back as a message from it." When the other machine has not answered by the end of the call's time, the reply says it may still open, that the tab will be in the strip and on `board_read` if it does, and not to call again for the same work.

## Trade-offs

- **The lead pattern spans machines.** A lead on the laptop finds the right project on the desktop or the headless host, starts a build there, hears back, and tidies it up, with no one at either machine.
- **Sessions stop guessing where work belongs.** Without a way to see a machine's projects, a session would start its helper in Home or ask the user; `project_search` shows each project's word, where it lives there and whether it is ready to open.
- **One more tool in every pane's list.** `project_search` is listed wherever `tab_open` is, which costs each of those sessions a little context whether or not it opens tabs.
- **Project paths of every machine go to Anthropic** with the session that asks, as file paths on this Mac already do.
- **Built from what exists.** The panel's `^machine #project` start for the asking side and the hosts' own starts, the `projects` request the panel and the phone already use, option 04's note, options 02 and 07's messages, ADR 0045's Done. One new request, no new message route.
- **Messages both ways are required.** A session with no `send` can open tabs on this Mac only, and every machine involved needs option 02's or 07's setup. A session that just wants a tab started elsewhere asks the user to type `^machine`. Without the return path the tab would be out of the lead's reach entirely, since Claude Code's own messages don't cross machines.
- **Permissions, in outcome terms:** a helper on another machine never skips permission checks unless its lead does and Skip permissions is on on the lead's Mac. It does not matter what the other machine's own setting says, as for a remote tab the user starts from the panel. So with the setting on on the laptop and off on the desktop, a lead on the laptop that skips starts a helper on the desktop that also skips; with it off on the laptop, the helper always asks, even if the desktop has it on. Requiring both machines to allow it was not chosen, because a helper that asks could then not send its result to a lead that skips (messages may not go from a session that asks to one that skips). The helper keeps the choice made at the open for its restarts, so turning the setting off on the laptop later doesn't stop that helper skipping.
- **The tab is in the caller's Mac's strip, not the host's own.** On a paired Mac the user can still take it over there, which makes it theirs.
- **A slower call.** One SSH request plus the host's start (up to about 8 s while it waits for the session to run) inside the relay's 15 s; a cold connection or a slow scan can run past it, and then the caller learns of the tab from the board instead of the reply.
- **One held SSH channel per host while the opener lives**, for option 07's collecting, from the open on. sshd limits the channels on the shared connection, and cards' live screens use some.
- **No new power.** A session that could already `send` to a machine's sessions can now also start one there, in a Project that machine's Claude Code trusts, never skipping more than it does.
- **What reaches Anthropic** grows by the opener's machine name, sent with the new session's system prompt.
- **A paired Mac's user sees a tab appear** in their strip, controlled from another Mac, as when the user starts one there from the laptop.

## User Stories

1. As the user, I want a session on my laptop to start a session in a project on my desktop, so that a long job runs on the bigger machine while the lead stays with me.
2. As the user, I want a session to start a session on the headless host, so that work runs on the always-on box without my typing `^host` and pasting the task.
3. As a session, I want to list the projects on this Mac, a paired Mac or the headless host, so that I can open work in the right repository instead of in Home.
4. As a session, I want to narrow that list with a word, so that I find the one repository among dozens.
5. As a session, I want each project's line to give the word `tab_open` takes, so that I pass it as it is, even when two projects share a name.
6. As a session, I want each project's path as that machine knows it, so that I don't mistake it for a folder on mine.
7. As a session, I want to see when Claude last used each project, so that I can tell an active repository from an old one.
8. As a session, I want to see whether that machine's Claude Code trusts each project, so that I ask the user to open it once instead of calling `tab_open` and being refused.
9. As the user, I want the new tab in my current Mac's strip, behind my work, so that I can look in on it where I already am.
10. As the user, I want the tab to run on the machine it was opened on, so that it uses that machine's files, tools and disk.
11. As the user, I want it opened only in one of that machine's Projects that its Claude Code trusts, so that a session can't start Claude in any folder there or stall on a trust question nobody sees.
12. As a session, I want to name the machine as `board_read` names it, so that I don't need a second vocabulary.
13. As a session, I want a refusal for an unknown project to list close names and point to `project_search`, so that I can call again correctly.
14. As a session, I want the reply to give the new pane's id, so that I can `send` it work, read its turn on the board and end it later.
15. As a session opened on another machine, I want to be told that my opener runs elsewhere and how to reach it, so that I send my result back and don't assume its files are mine.
16. As a session on the headless host, I want `send` to `opener` to work without my opener messaging me first, so that I can report a job given in my prompt.
17. As a session on a paired Mac, I want `send` to `opener` to reach the lead on the other Mac, so that the result gets back without the user.
18. As either session, I want `opener` to keep working after a Restart of either pane, a Varnick restart or a host reboot, so that a restart doesn't cut the lead off from its helper.
19. As a session, I want a clear refusal when my opener's machine is asleep or its session closed, so that I say so in my pane instead of waiting.
20. As the user, I want a session I `/clear`ed and reused to stop reporting to its old opener, so that new work doesn't go to a session that never asked for it.
21. As a lead session, I want to mark Done a helper tab I opened on another machine once I have its result, so that finished helpers don't pile up in my strip or on the host.
22. As the user, I want a helper tab I clicked in, typed into or took over on the desktop or the phone to stay mine, so that a session never ends work I joined, on any machine.
23. As the user, I want a helper that is working or waiting on me never to be ended by its lead, even if a turn starts while the request travels, so that no work is cut off.
24. As the user, I want a helper on another machine never to skip permission checks its lead doesn't skip, so that opening a tab elsewhere gives no more power than the lead has.
25. As a session, I want a refusal when messages can't go both ways, with what to turn on, so that I don't start a helper I can't hear from.
26. As a session, I want a refusal that names the machine when it is asleep, on an older Varnick or not ready, so that I can tell the user what to fix.
27. As the user, I want only the machines involved to need the new build, so that my other Mac keeps working while I try this.
28. As the user, I want the phone kept out of starting tabs this way, so that a listed device can't start sessions through it.
29. As a session, I want a slow machine's open to tell me not to call again, so that I don't start the same helper twice.

## Implementation Decisions

**The siblings.** The asking side copies the panel's `^machine #project` start (`startOnPeer`): a request to the peer, then a view tab here under the host's tab id, in control, with the host recorded on the pane. The making copies each host's own `start` answer (`hostStart` on a Mac, the relay's `start` on the headless host): a record labelled for the asker, started at once, answered once it runs. The checks copy option 01's (`TabOpen.choose`, `Agent.available`, `ClaudeTrust`), all in the shared package, so the host runs them too. `project_search`'s remote read is the panel's own ask of a peer's projects (`askProjects`).

**`project_search`.**
- **Where:** in the pane tools' set (the `--panes` set), beside `tab_open` and `tab_done`, so it is listed to every Claude session in a Varnick pane but the voice session, a run, a Task step and a headless host's session, with no switch. It goes through `PanelAccess.panes` and is in `answersControlled`, since it only reads.
- **This Mac:** `freshProjects()` (which also refreshes the panel's list), and the trust of each, from Claude Code's config read once per answer (`ClaudeTrust.isTrusted(_:in:)`).
- **Another machine:** the `projects` request, which both hosts answer with a fresh scan of their own folders. `PeerProject` gains one optional field, whether that machine's Claude Code trusts the folder, which a Mac's `hostProjects` and the relay's `projects` fill the same way. An older build leaves it out, which reads as "not known". It is an optional field, so it is no protocol change (ADR 0007's amendment of 2026-11-07), and the phone, which also asks `projects`, ignores it.
- **The pure part,** in the package beside `TabOpen`: from the projects, the word and the cap, the lines in order, each with `TabOpen.token`'s word, the group, the path, the age of last use and the trust word. `tab_open`'s refusal for an unknown name keeps `TabOpen.choose`'s close matches and adds the pointer to `project_search`.
- **Its log** holds the tool, whether it asked another machine and the count of lines: never a machine's name, a search word, a project or a path.

**The open request.** One new request for a listed Mac only (added to `PeerProtocol.isMacsOnly`, so the relay refuses a device): open a tab as `tab_open` would. It carries the project word, the agent, the prompt, the skip value, the new session's id (chosen by the asker, as `PeerStart.id` is) and the opener (its pane id and conversation, its project, its tab's name, its Mac's id and name). The reply carries the tab id, the folder, the project's name, whether the new session starts with the channel, or the refusal's words. An older build answers "Unknown request", which the asker turns into "Update it from its row in Settings › Peers".

**On the machine that hosts it,** in this order:
1. (A Mac) Keep sessions running on and the app running, with `hostStart`'s words.
2. Ready for messages from other machines: on a Mac both switches on and its checklist passing; on the host `startsWithChannel`. Read at the request, so the decision is fresh.
3. The project: `TabOpen.choose` against a fresh scan of its own project folders, as `projects` scans them now.
4. The agent, then the trust (`ClaudeTrust`).
5. The record: the opener note, the skip value, labelled for the asker as its control and origin, as for `start`. Then the start, and the reply once the session runs, within the existing wait.

The decision of steps 2 to 4 is one pure function in the package, given the scan, the agents, the trust and the ready state, returning the project or the refusal's kind; each host turns the kind into words naming itself.

**`OpenerNote` gains the opener's machine** (its peer id and name), optional so older files load. `paragraph(messages:)` gains the machine form above when the machine is set; the other forms are unchanged.

**On a paired Mac:** the record's `opener` holds the note as today. `send` to `opener` resolves a note with a machine to that machine's pane, as option 02's remote destination, instead of looking for the pane here. The message gains an optional field for the conversation the opener held at the open. The opener's Mac refuses `openerMoved` when its pane now holds another, and the sender reads a `gone` answer to `opener` as `openerGone`. Both cases exist already, so no reply gains an enum case.

**On the headless host:**
- the session record gains an optional opener note;
- `launch` passes its paragraph with `--append-system-prompt`, as a Mac's start does, while the record's conversation is still the one the note was given for;
- the open writes the `opener` entry into the pane's table of senders (`SenderTable`, which already reads an entry by its word);
- the send server refuses `opener` once the session has moved to another conversation, with option 01's `noOpener` words;
- a message to `opener` carries the opener's conversation as an optional field of `PeerHostMessage`, which the Mac checks as above.

**On the caller's Mac** (`tab_open`'s half):
1. The machine word, matched as the panel's `^` word is (the peer's handles), against the peers that answered their last hello. `project_search` uses the same match.
2. Its own preconditions: the caller receives messages, and Also between my Macs and hosts is on.
3. For the host, the opener's mark of that host (`SentHosts`) is written before the request goes, so an answer is taken even if this Mac restarts while it waits.
4. The request, with a deadline counted from the call's arrival, a second inside the relay's 15 s, as option 01's should-fix asks.
5. On success: a view tab at the end of the strip, not shown and not started, under the host's tab id, in control, its pane's record naming the host, the skip value and the caller as `openedBy`. Then collecting is refreshed.
6. Past the deadline, the call answers as above; the ask goes on for up to the 40 s the panel's start allows, and an answer that comes adds the view tab the same way.

**`tab_done` on a tab whose host is another machine,** in place of today's refusal:
- the marks of the view's panes, as option 06 reads them;
- the host's `status` for the tab's panes (the request the Mac already sends every 5 s), giving each turn and who controls it, read off the main actor; then the decision again, with `TabDone.decide` unchanged;
- `done` to the host with a new optional field asking it to refuse unless every running pane of the tab names the asker and no Claude session in it is mid-turn (both hosts read this as they read control for `arrange`, and turns from their own records). An older host ignores the field, but it never sees this request, since it couldn't have opened the tab;
- the view closes as a Done when the host answers, as the model's Done on another machine's tab does. The reply waits for the host's answer.

**Clearing the mark of a view** (option 06's new clearings, extended):
- the user's click, key or focus on the view, through `userTook`, as for any pane here;
- the view turning into a card because another machine or the phone took the tab (today `onControlled` fires only for this Mac's own panes);
- a reopen of the closed tab.

**Protocol: no bump**, by ADR 0007's amendment of 2026-11-07. One new request and optional fields (on `PeerProject`, the request, the reply, `done`, `PeerSessionMessage` and `PeerHostMessage`). The new request is an operation, which travels only in requests; no enum that travels in a reply gains a case.

**The log** of `tab_open` and `tab_done` holds the tool, the outcome's kind and whether the tab is on another machine and answered late: never a machine's name, a project, an agent, a prompt or an id.

**Descriptions.** `project_search`'s says what it lists, what `machine` and `search` take, what each line holds, and that its first word is `tab_open`'s `project`. `tab_open`'s says `machine` and what it takes, points to `project_search`, says that the tab runs there and is controlled from this Mac, and gives the messages precondition; it drops "This Mac's projects only". `send`'s says `opener` reaches across machines. `tab_done`'s says it ends a tab opened on another machine too.

**Docs:**
- where-it-breaks: Panel access (`project_search`, `tab_open` and `tab_done` on another machine, the deadline, the view not attached until shown), Messages between sessions (`opener` across machines, the host's seeded entry and the early `SentHosts` mark; it now says `opener` stays on one Mac), Peers (the request, `PeerProject`'s field, the `done` field) and the hand check;
- an amendment of ADR 0031: a session can list any of the user's machines' projects and start a session on another machine;
- an amendment of ADR 0045: a `done` may ask its host to refuse unless the asker controls the tab and nothing in it is mid-turn;
- CONTEXT.md's Panel access and Session message entries;
- the privacy doc: a session can read the names and paths of every machine's projects, which go to Anthropic with it; it can start one on another machine; the opener's machine name goes with the new session's system prompt;
- the guide's paragraph on `tab_open`.

## Testing Decisions

- **A good test** drives what a session or the user sees: the lines and refusals' words, the paragraph, which machine a word means, the reply, the rows of a decision. It never drives how a file is named.
- **`make check-open`** (where `tab_open`'s and `tab_done`'s pure rules are pinned) gains:
  - `project_search`'s lines: the order, the cap with its count, a search word in the name and in the group, two projects sharing a name (the `group/name` word), last use never and long ago, and each trust word, "not known" included;
  - the host-side decision: not ready, an unknown project with close names and the pointer, ambiguous, not a Project, an unknown agent, untrusted, found;
  - the paragraph's machine form, and that the earlier forms are unchanged;
  - `TabDone.decide` with control read from a host's status;
  - the host's `done` check: control here, another machine, mixed, and each turn.
- **`make check-messages`** gains `opener` across machines: a note with a machine resolves to that machine's pane; `gone` read as `openerGone`; `openerMoved` from the carried conversation; the host's table entry `opener` found by the send server, and refused after the conversation moved; a Mac taking a host's message for a pane marked before the open.
- **`make check-mcp`**: `project_search` listed only in the pane tools' set, with no clash, and `tab_open`'s schema listing `machine`.
- **On the host:** the package builds on Linux (the installer builds it; nothing else checks a Linux build).
- **By hand, after the paired Mac and the host run the build and Varnick restarts on both Macs,** in sessions restarted after it:
  - `project_search` with no machine, on the paired Mac and on the host, with and without a word: the words, the paths there, the last use and the trust match what the panel's `#` and a trusted session show; a machine on an older build says "not known" for trust;
  - from a session in Home, `tab_open` a project on the host with a task: a tab joins the end of the strip, not brought up, marked for the host, and nothing else on screen changes; its notices arrive; the helper's `send` to `opener` starts a turn in Home;
  - the same on the paired Mac, where its strip shows the tab controlled from here;
  - Restart either pane, restart Varnick on the opener's Mac, and `opener` still works both ways; `/clear` in the helper and `opener` is refused there;
  - put the opener's Mac to sleep: the helper's `send` to `opener` is refused at once, and works after it wakes;
  - `tab_done` ends it on each machine; a click in it, a Take over on the paired Mac and a Take over on the phone each make it refuse; a working helper is refused;
  - each refusal: no `send`, the Also switch off, an unknown machine, an older build, the host not ready, an unknown project (with names and the pointer), an untrusted folder there;
  - a skipping lead with Skip permissions on opens a skipping helper; a lead that doesn't skip opens one that asks;
  - a cold connection (after 10 idle minutes): how long the open takes, and the late answer's words if it passes the call's time;
  - the logs on all three machines hold no name, project, path, search word, prompt or id.

## Out of Scope

- A session on the headless host listing projects or opening tabs: host sessions get no pane tools.
- A session without `send` opening a tab on another machine (the user's decision: refused).
- `pane_open` on another machine, or a tab of any kind but a Claude session.
- The other machine's own tab, controlled there (considered, below).
- Making a project trusted from a session: `project_search` only says so.
- The phone opening tabs this way.
- Holding a request for a machine that is asleep.
- A machine's own Skip permissions setting limiting a helper started from another Mac (Trade-offs).

## Further Notes

- **The user's request (2026-11-08),** relayed by the coordinator: a session can open a tab with a Claude session on another machine (a paired Mac or the headless host), not only on this Mac, with the same return path and closing as locally. Option 01 left "a paired Mac's or a headless host's projects" out of scope, and `sessions-cant-reach-each-other-reliably` options 02 and 07 left `tab_open` and `opener` on another machine out of theirs.
- **Decided by the user (2026-11-08),** relayed by the coordinator; this option is accepted, and the problem reopened:
  1. A project search tool, against the planner's first recommendation of none: without one, a session can't discover a machine's projects and would open everything in Home. It takes an optional machine (this Mac by default) and an optional search word, answers each project's name, group, path there, last use by Claude and trust, through the existing `projects` request, for this Mac, paired Macs and the host. `tab_open`'s close matches stay.
  2. The caller's Mac controls the tab.
  3. Opening on another machine is refused unless messages go both ways, with what to turn on.
  4. Permissions follow the caller's Mac, not the other machine's setting.
  5. `tab_done` on another machine's tab may ship as a second slice (the recommendation is below).
- **Found live on 2026-11-08** (relayed by the coordinator): a Mac session's `board_read` found a session on the headless host and `send` got its answer back with `from_mac`. The host's two project folders hold a few dozen projects (read over SSH; figures kept locally).
- **Verified in the code at main b2c4541:**
  - `tab_open`'s description ends "This Mac's projects only"; it resolves the project in this Mac's list and checks trust here, then makes the tab with `addTab(show: false)` and `start()`;
  - no session tool lists projects; a peer's `projects` answer holds each project's path and last use and nothing else, from a fresh scan on a Mac (`hostProjects`) and on the host (its configured folders, `~/Projects` by default); the panel asks it for `^machine #project`;
  - `ClaudeTrust` can answer for many folders from one read of Claude Code's config;
  - `send` resolves `opener` only to a pane of this Mac, else `openerGone`, and where-it-breaks says `opener` stays on one Mac;
  - the panel's `^machine #project` sends `start` with a path from that machine's `projects` answer and the asker's Skip permissions setting, then makes the view tab here under the host's tab id, in control;
  - a Mac host's `start` checks only that the folder exists (no Project or trust check), refuses with Keep sessions running off, labels the session for the asker and adds the tab to its own strip without showing it; the headless host's checks trust only for the messages test;
  - the project choice, the trust check and the agents are in the shared package the host builds;
  - the host's records have no opener field and its `launch` passes no appended system prompt;
  - a host session's `send` reads the table of senders in its pane folder, kept across restarts, by the word given;
  - the Mac's `SentHosts` mark decides both collecting and the answer-only check;
  - `tab_done` refuses any tab whose host is another machine; the model's Done on such a tab sends `done`, which both hosts carry out without asking, whatever the turns;
  - a remote pane's turn on a Mac comes from the host's `status`, asked every 5 s for every Claude pane on that host in the Mac's tabs, started or not;
  - `onControlled` fires only for this Mac's own panes;
  - `board_read` names a card's machine "on" its name; the `^` word matches a peer's handles; `send` and the pane tools answer from a pane another machine controls;
  - the relay waits 15 s for a tool call, the panel's remote start up to 40 s, and a host's start up to about 8 s for the session to run;
  - protocol 35; an unknown request is answered "Unknown request" on a Mac and by the relay; peer JSON ignores unknown fields; the operation travels only in requests.
- **Assumptions, each open to overturning:**
  - `project_search` is the name, with `machine` and `search` as its arguments, at most 50 lines;
  - it sits in the pane tools' set, since it serves `tab_open`, and not in Panel access's own set, which the voice session also gets;
  - the view attaches only when the user first shows it;
  - the deadline is the call's arrival plus 14 s;
  - the opener's mark of the host is written before the request, and stays if the open fails (it only lets that host's sessions answer a pane that asked them for nothing).
- **Considered: the other machine's own tab, controlled there.** No connection held, and the tab sits where it runs. But a headless host has no strip, so nobody would see the tab but on the board and the phone; on a paired Mac the user at the laptop finds it only on the board; and `tab_done` would need the marks and the user's use kept on that machine, with a new request to read them. Not chosen.
- **Slices.** Recommended: build both in one branch, as two tickets, the second being `tab_done` on another machine's tab, and merge once. Each merge of this work means upgrading the host (a Swift build there) and the paired Mac, restarting Varnick on both Macs and a cross-machine hand test, about an hour of the user's time, which a second merge would repeat to save about 1.5 hours of agent time. Without the second ticket, `tab_done` refuses such tabs as today and finished helpers stay in the strip until the user marks them Done. If the review holds the second ticket, the first can merge alone.
- **Unverified:**
  - that a view added behind and never shown raises its notices and is followed (inferred from the status poll, which covers every pane on that host);
  - that a reopen of another machine's tab drops the marks as a reopen here does;
  - the time a remote open takes on a cold connection;
  - that a paired Mac's start for a peer lets go of its own client when the asker doesn't attach at once (the panel's start does the same when the prompt moves on).
- **Before building:**
  1. Time the panel's `^host #project` and `^mac #project` starts with a short prompt, warm and after 10 idle minutes, against the 15 s call limit. It opens real sessions on the host and the paired Mac, so the coordinator asks the user before running it.
  2. Upgrade the paired Mac and the host to main. Both must already be on option 07's build for messages, as the live test of 2026-11-08 suggests.
- **What a worktree can check:** `make build`, `make check-open`, `make check-messages` and `make check-mcp` with the cases above (the relay is a package executable that builds on macOS).
- **What only the host can check:** the Linux build, the trust field in its `projects` answer, the seeded table, the paragraph passed at `launch`, and the `done` check there.
- **What only the main checkouts can check, after restarts:** the hand test above, across the Mac, the paired Mac and the host.
- **Size, in agent time:** about 8.5 to 9.5 hours of building, and 2 hours of review and a fix round.
  - `project_search` (the tool, this Mac's answer, the trust field on both hosts, the lines and their check): about 1 hour.
  - The open request and both hosts' handlers with the shared decision: about 2 hours.
  - The asking side (the argument, the preconditions, the deadline and late answer, the view tab, the reply and the descriptions): about 1.5 hours.
  - `opener` across machines (the paired Mac's route, the host's note, paragraph and table, the conversation check): about 1.5 hours.
  - `tab_done` on another machine's tab (the status read, the `done` field on both hosts, the clearing on Take over): about 1.5 hours, the second ticket.
  - Docs and checks: about 1 to 1.5 hours.
  - On top: the host's install (a Swift build there, unmeasured), and the user's steps, about an hour: the timing check first, then upgrade the paired Mac and the host, restart Varnick on both Macs, restart the sessions that should use it, and a hand test of about 45 minutes.
  - Wall clock: about one working day, a little more with the host's build.
- **Depends on** options 01, 04 and 06 here and options 01, 02 and 07 of `sessions-cant-reach-each-other-reliably`, all shipped. It closes the "`opener` stays on one Mac" line of their docs.
- **Combines with** option 03 (bringing the tab up, which would apply to the view here) and option 05 (always asking, which would apply on the other machine too).
- **Review follow-ups (merged 2026-11-08; reviewer verdict merge; one fix round, raised by the coordinator, made the host's `send` description name `opener` so a helper on the host isn't told it can't send first, and corrected where-it-breaks):**
  - should-fix: the `machine` word is matched against every listed peer, not only those that answered their last hello, so a silent peer sharing a word with a live one gives "more than one machine" and a silent one gets a transport error instead of the list of machines that answer.
  - nit, unverified: if the connection fails after the host already started the session, the tab runs on the host with no view and no mark on the caller's Mac; it shows on board_read but tab_done can't end it.
  - nits: four doc comments over two lines; CONTEXT.md's text on project_search and tab_open's machine sits in the Session message entry; a third private `nilIfEmpty`, a repeated PeerProject-to-Item map, and `HostSend.Refusal.noOpener` sharing a name with two other refusals; the reply doesn't carry whether the new session starts with the channel (implied, since the host refuses unless ready); the project_search log has no line count; the headless done re-check is skipped when the controls can't be read, and the Mac host's uses the pane's cached turn.
- **Hand check owed** after the Air and the host take this build and both Macs restart: project_search on each machine; tab_open on the host and on the Air (tab at the end of the strip, not brought up; the helper's send to `opener` starts a turn here); restarts and `/clear`; an asleep Air; tab_done on each, refused after a click, a Take over on the Air or the phone, and while working; each refusal; the skip rule; cold timing; logs holding no names, projects, paths, words, prompts or ids.
