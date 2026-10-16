---
problem: prompts-cant-run-on-a-schedule
title: Each host fires its own automations, and a run is a Claude pane in zmx that stays out of sight until opened
summary: Behind an Automations switch in Settings › Experimental. Automations are made and edited in Settings › Automations on any Mac. Each one has a name, a prompt, a folder, an optional agent, a host, a cadence chosen from presets, and permissions. It is kept on the host that runs it, and that host fires it. On a Mac, the running Varnick checks once a minute, at launch and on wake. On the headless host, a systemd user timer runs the relay once a minute, so nothing stays running. A due run starts a Claude pane exactly as a typed prompt would, in zmx, in a run tab of its own. The tab is kept out of the strip, the session list, the board and Recent until the user opens it from the board's Runs tab or from a notice. The notices need nothing new: Done is finished, Needs you is stuck, and errors and Messages work as in any pane. A run missed while the Mac slept or Varnick was quit runs once when it wakes or launches, if the slot is under 12 hours old. A run never overlaps itself, stops at a time limit, and ends its process 10 minutes after it finishes, so its conversation is resumed when opened. A run's permissions follow Settings › Claude's Skip permissions, as a typed prompt's do, unless the automation overrides them. A run never gets Screen access or Panel access tools. Accepted 2026-10-15. Slice 1 is this Mac only, with no protocol bump. Slice 2 is the headless host, with protocol 29.
status: accepted
---

## Solution

### An automation

- **What it holds:**
  - a name;
  - a prompt;
  - a folder (a **Project**, or **Home**; amended 2026-10-15, relayed by the coordinator: the Default folder setting is gone, and an automation with no folder runs in Home);
  - an optional **Agent**;
  - a host: this Mac, or a headless host from Settings › Peers;
  - a cadence;
  - permissions: Varnick's setting, or an override, with a list of allowed tools;
  - a working limit;
  - an on/off switch.
- **The prompt goes to Claude as written**, as the first message of a new session. Varnick adds nothing to it. A user who wants the result told writes that into the prompt ("…and notify me with the count"), and the run's `notify` call becomes a Message.

### Defined in Settings, kept by the host that runs it

- **Settings › Automations** shows only with the Automations switch on. It lists the automations by host. Each has:
  - its switch;
  - its next run;
  - its last outcome;
  - Run now;
  - an editor with the fields above.

  The project, agent and host are chosen from the same lists a **Prompt**'s `#`, `@` and `^` offer.
- **Each host keeps its own list** in a file of its own:
  - **On a Mac,** a file in Varnick's support folder, written only by the running Varnick. It is never `sessions.json`, whose decode failure would drop every tab.
  - **On a headless host,** a file in its state folder, written only by its relay under the state lock, as `devices.json` is.

  A file that can't be read fires nothing and is never written over (the rule ADR 0030 set for the Outline).
- **A Mac edits a headless host's list over the peer link.** New requests list, save, delete and run an automation now, and list its runs. They are protocol 29, answered only to a listed Mac, never to a device. A Mac shows the headless host's automations beside its own, read when Settings opens.

### Fired by the host itself

- **On a Mac:** the running Varnick checks the list once a minute, and at launch, and when the Mac wakes.
- **On the headless host:** a systemd user timer, installed by the installer like the Phone page's unit, runs the relay once a minute. The relay:
  1. reconciles its records with zmx, as every request does;
  2. starts what is due, through the same launch a `start` uses;
  3. exits.

  No process of Varnick's stays running. Only systemd's timer is resident, which ADR 0009 is amended to allow.
- **launchd is not used.** Every Mac run happens inside the running Varnick, so a run needs nothing that Varnick's own launch doesn't already give it.

### Due, missed and caught up

- **The last slot.** Each automation remembers the last slot it fired for. A slot is the cadence's time, such as 9:00 on a Wednesday.
- **What a check runs.** At a check, the newest slot that has passed since then is due. Every older one that also passed is recorded as missed and never run.
- **Catching up.** A due slot is run if it is under 12 hours old. Otherwise it too is recorded as missed.
- **What that means for a sleeping Mac or a quit Varnick.** At the next wake or launch, a run due in the meantime runs once, and the history says it ran late. This is Claude Desktop's catch-up once, bounded so a Mac shut for a weekend doesn't start Friday's runs on Monday.
- **A headless host's runs don't depend on any Mac being awake.** The host fires them itself, and a reboot is caught up by the same rule at the timer's next run.

### The cadence

- **Presets only, kept as data, not as a cron string:**
  - every 15 or 30 minutes;
  - every 1, 2, 3, 4, 6 or 12 hours;
  - daily at a time;
  - weekdays at a time;
  - weekly on a day at a time.

  Fifteen minutes is the shortest: each run is a whole Claude session.
- **The time zone is kept with the automation:** the zone of the Mac that saved it. A headless host in another zone runs "daily at 9:00" at the user's 9:00.

### A run

- **Started as a typed prompt is.** A due run starts a Claude pane exactly as a typed prompt would:
  - in zmx, with the hooks;
  - the prompt as its first message;
  - in the automation's folder, as its agent.

  Keep sessions running must be on, as for a peer's `start`. With it off, the run is recorded "couldn't start" with the reason.
- **Its own tab, the run tab.** It is named after the automation, so the notice's menu line and the phone's notification say "Morning summary". It is marked with the automation it came from. Until the user opens it, it is kept out of:
  - the strip, the session list and the board's Sessions tab;
  - the tab marks and the +N chip;
  - Recent, Completed and the ended cards;
  - search's tab rows.

  A restart restores it still hidden, and the launch sweep keeps its zmx session.
- **The board gets a Runs tab** beside Sessions and Problems, behind the same switch. It lists every run of every automation on every host, newest first, each with:
  - the automation's name;
  - when it ran and where;
  - its state: running, waiting on you, done, or a message's title;
  - or why it didn't run: stopped at its limit, ended after waiting, skipped, missed, couldn't start.
- **Opening a run** from that list, from a notice in the menu or from the phone:
  - **Still running or waiting on the user:** its run tab moves into the strip and shows, live, so the user can watch, answer the dialog or type.
  - **Ended:** its conversation is resumed in a new tab, as ↩ on Recent does.

  From then on it is an ordinary tab: Done closes it, and it goes to Recent when closed. A run that another Mac or the phone has taken over counts as opened.
- **Turning the switch off** stops firing. Every unopened run tab becomes an ordinary tab, so nothing runs out of sight while the switch is off.
- **On the headless host,** a run is that host's tab, labelled with the Mac that saved the automation as its origin and its controller, as if that Mac had typed `^host` and the prompt.
  - **While that Mac's Varnick runs,** it holds the run tab as an unseen view of the host's tab, attached as it attaches to any session it controls there. So it follows the turn and raises its own notices, and the host's page server routes by that Mac's presence.
  - **While that Mac is asleep or quit,** the session has no client. The page server's rule for a Mac with no client then pushes to the phone after the settle.
  - **Finding new runs.** The Mac learns of runs it didn't start by asking each host it has automations on for their runs, at its once-a-minute check.
- **The phone** sees a host's run tabs in its `tabs`, marked as runs from protocol 29, and lists them under Runs on that host's Home. A push for a run lands on its pane, as for any pane.

### Notices: nothing new

A run is a Claude pane, so the table applies as it stands:

| A run… | notice |
|---|---|
| finishes its turn | **Done** |
| stops on a permission dialog, a question, a plan or an MCP request | **Needs you** |
| ends on an API error | **Stopped on an error** |
| calls `notify` | **Message**, with the Done that follows folded into it |

They are routed by **Presence** as for any pane: on the Mac in control when the user is there, pushed to the phone when they aren't. Choosing a run's notice in the menu opens the run, as above.

### Overlap and limits

- **One run of an automation at a time.** A slot that falls due while the last run still works or waits on the user is recorded "skipped: the last run was still going". Run now is refused for the same reason.
- **A working limit,** one hour by default and set per automation. A run whose turn has worked or run background work past it is ended. Its zmx session is killed, the conversation is kept so it can be resumed, and the run list marks it "stopped at its limit".
  - It raises no notice. The pane is gone, so neither the Mac's notifier nor the page server has a turn to read.
  - A notice for it waits for the open question below.
- **A run waiting on the user** is kept while it waits, since that is the stuck the user asked to hear about, and it blocks the automation's next slots. After 24 hours of waiting it is ended the same way, marked "ended after waiting".
- **A finished run ends its process.** Once its turn has been waiting for 10 minutes and nobody has opened it, its zmx session is killed. Each run holds a claude and an MCP server, the latter about 19 MB by the snapshot of 2026-10-13. The run tab closes into the automation's history, not into Recent, and opening it later resumes the conversation.

### Permissions

- **By default, a run follows Varnick's own setting,** Settings › Claude's Skip permissions, read at the run's start and stored on its record, as a typed prompt's is. With Skip on, a run skips permission checks. With it off, it asks.
- **An automation can override it** with one of three choices:
  - **Ask.** Claude's normal mode. The automation's allowed tools run without a dialog, and anything else shows its dialog. The run waits, and Needs you is raised.
  - **Allowed tools only.** Anything not allowed is refused with no dialog. Claude goes on or ends, and a run never waits on the user for a permission. This is Claude Code's `dontAsk` mode. It is offered only if the throwaway check under Slice 1 finds it refuses that way in an interactive session.
  - **Skip permission checks,** whatever Varnick's setting says.
- **The editor warns about the macOS grants.** It shows the permissions the run will start with. On a Mac it says that a shell command a run may run can reach the screen through the grants every pane inherits (`panes-share-launchys-permissions`). That covers every command when permission checks are skipped. It suggests the headless host, which has no screen, for an automation that allows broad shell use.
- **No screen tools, whatever the choice.** A run's MCP config lists `notify` alone, so it never gets Screen access's or Panel access's tools, whatever those switches say.
- **The allowed tools** are written in Claude Code's own rule syntax (such as `Bash(git *)`, `Edit` or `WebSearch`). They go in the run's settings beside `notify`'s allowance, and add to the user's own.

## Trade-offs

- **A run is exactly a typed prompt.** It has the same command line, hooks, transcript, search, notices, resume and pane. That is the user's first decision kept literally, and nearly everything a run needs already exists.
- **Stuck means Needs you.** The user's third decision names it, and a pane delivers it with no new notice kind. The cost is that a run that asks waits for the user. The overlap rule and the 24-hour end keep the wait from piling up, but the work waits too.
- **Permissions follow the user's setting.** So a run behaves as their typed prompts do. On an install with Skip permissions on, which is every install that predates the setting, an unattended run on a Mac runs any command without asking, and with it the macOS grants every pane inherits (Accessibility and Screen Recording once Point at the screen is granted). The user chose this. The editor's warning and the per-automation override are what stand between a run and the screen, beside the missing screen tools. Only `panes-share-launchys-permissions` would close the gap.
- **The always-on host is used as always-on.** Its runs fire with every Mac asleep, and only their notices need a Mac or the phone.
- **The headless host is no longer request-only.** A timer now starts sessions there with no request. The relay's rule "nothing starts one unasked" becomes "nothing but an automation the user saved".
- **It has the most moving parts of the options.** It needs:
  - two firing paths;
  - a file per host;
  - protocol 29 for the requests and the run flag in `tabs`;
  - hiding run tabs everywhere tabs are listed;
  - a Mac holding remote runs it didn't start.

  Slice 1, this Mac alone, needs no protocol bump.
- **Hiding a tab is a new rule across many lists.** Every list that shows tabs must leave run tabs out until opened. A list that misses one floods with runs.
- **Ending a finished run's process** keeps memory bounded. The cost is that opening a finished run is a resume, not a live pane: its screen is redrawn from the conversation, not kept.
- **A run ended at its limit tells no one.** It is only marked in the run list, until the open question below is settled.
- **Varnick must be running on a Mac.** A Mac's runs fire only while it runs, and catch up once at its launch. Open at login covers most of that for the installed app.
- **Usage.** Each run draws on the user's subscription, unattended. The 15-minute floor and the overlap rule bound it, but nothing caps it.

## User Stories

1. As the user, I want to save a prompt, a folder and a cadence once, so that Claude runs it for me every morning without my typing it.
2. As the user, I want to choose per automation whether it runs on this Mac or on my always-on headless host, so that a nightly job runs with my laptop shut.
3. As the user, I want a run to open nothing, so that it doesn't take my screen or my tab strip.
4. As the user, I want to be told on my Mac, or on my phone when I'm away, when a run finishes, sends a message or gets stuck.
5. As the user, I want to open any run as a pane, live while it runs and resumed after it ends, so that I can see what it did and carry on from it.
6. As the user, I want a run missed while my Mac slept to run once when it wakes, not once for every missed slot.
7. As the user, I want a run never to start while the last one of the same automation is still going.
8. As the user, I want a run that works too long, or waits on me too long, to be ended, with its conversation kept.
9. As the user, I want a run's permissions to follow my Varnick setting, as my typed prompts do, and to override them for one automation. I also want a run never to get the screen tools.
10. As the user, I want "daily at 9:00" on the headless host to mean my 9:00.
11. As the user, I want Run now, to try an automation before I leave it to the clock.
12. As the user, I want to see each automation's runs, with what happened and why a slot didn't run.

## Implementation Decisions

### Shape and state

- **The automation record** is a small codable value with an id. It holds:
  - its cadence, as a tagged value per preset, with the zone's identifier;
  - its permissions: none (follow Varnick's setting), or an override;
  - the last fired slot;
  - its runs, newest first, capped at 20 per automation, each with its outcome.
- **The run record:**
  - the slot;
  - when it started;
  - the pane's id and conversation;
  - its outcome, as one of: running, waiting, done, a message's title, stopped at its limit, ended after waiting, skipped, missed, couldn't start (with the reason).

  It names no folder content or words beyond the message's title, which the pane folder already holds.
- **When a slot is due** is one pure function: the cadence, the zone, the last fired slot and the time now give the due slot, if any, and the missed ones. Both hosts call it. It lives in the shared package, like the notice rule.
- **On a Mac,** the run tab is a saved tab with an optional field naming the automation, set while it is unopened and cleared when opened. So it is restored and the launch sweep keeps its zmx session, as for any saved tab. An older build reads the field as absent and shows the tab as an ordinary one, which is harmless.
- **On the headless host,** a run is a record with an optional automation id. The host's tab listing carries an optional run flag in `tabs` (protocol 29), and the record keeps the origin and control naming the saving Mac.

### Firing

- **One firing step per host,** shaped alike: read the list, compute what is due, apply the overlap rule, start each due run, write the last slot and the run record. The list is written after the start answers, so a start that fails is recorded as such and not tried again for the same slot.
- **The Mac's check** runs from a minute timer on the main actor, from the wake notification, and once after the launch has restored the tabs. It is off while the switch is off.
- **The headless timer** is a user `.timer` with a matching `.service` that runs the relay with a new command. It is installed and removed by the installer with a flag of its own, as `--problems` is. With no timer, nothing fires there, and the Mac's Settings says so on that host's automations.
- **The start on each host reuses the existing path:**
  - **On a Mac,** the same steps a peer's `start` takes: a record with the prompt, folder and agent, a pane, a tab, a save and the start. The tab is marked as a run and not shown, and the pane is labelled for no one.
  - **On the headless host,** its `launch`, with control and origin set to the saving Mac's id.

### The run's command line

- **The MCP config** lists `notify` alone, on both hosts. On a Mac, the run's start passes the screen and panel sets as off whatever the switches say.
- **The permissions** are stored on the run's record, so a resume or a restart keeps them:
  - with no override, the record takes Varnick's Skip permissions setting at the start, as a typed prompt's does;
  - Ask is no flag;
  - Allowed tools only is `--permission-mode dontAsk`, a new flag in the shared command line, stored on the record;
  - Skip is the existing skip flag.
- **The allowed tools** join `notify` in the run's `--settings` allowance, also stored on the record. The hooks' settings are otherwise the same as every pane's, so the turn and message readers work unchanged.

### Limits and ending

- **The limits are checked** on the Mac by the minute check, and on the headless host by the timer's run. Both read the turn and its age from the pane folder, as the notices do.
- **Ending a run** is `zmx kill` of its session, confirmed gone from a listing, as a restart does. The run tab closes into the run's record, never into Recent, and the conversation stays resumable.
- **A run counts as opened** once it is shown in the strip, or once its control label names another machine (a take over). An opened run is never ended by the check.

### Documents

- **A new ADR:** automations are fired by the host that keeps them, a run is a pane kept out of sight until opened, and a headless host's timer is the one thing there that starts a session unasked.
- **ADR 0009,** amended in slice 2: its "nothing resident" now excepts the timer.
- **`CONTEXT.md`:**
  - new entries: **Automation**, **Run**, and the board's Runs tab;
  - **Task** and **Panel access** keep "automation" under Avoid, now pointing to the new term.
- **where-it-breaks:**
  - the hidden-tab rule and every list it applies to;
  - the slot function and time zones;
  - the run's MCP config and permission rules;
  - from slice 2: the timer, its installer flag and protocol 29.

## Testing Decisions

- **The throwaway check** under Slice 1 comes before Allowed tools only is offered.
- **A check of the slot function, run by a make target over a table of cases,** as `make check-mcp` checks the MCP server. Neither Varnick nor the shared package has a test target. The cases are:
  - every preset;
  - a zone different from the host's;
  - a daylight-saving change;
  - the 12-hour catch-up bound;
  - many missed slots giving one due slot;
  - a slot exactly at the check's minute.
- **`make build`**, and from slice 2 the protocol versions match.
- **By hand:** slice 1's list below, then slice 2's:
  - **Headless, Mac awake:** a run there gives the Mac's notice and no push while the user is at the Mac.
  - **Headless, Mac asleep:** the phone gets the push, and the tap lands on the run's pane.
  - **Headless, every Mac asleep:** a slot fires on time.

## Out of Scope

- **Scheduling a Task** (the website loop), terminal commands, or anything but a Claude prompt.
- **Cron expressions.** Presets only, by the user's decision.
- **A session deleting an automation or running one now.** Settings and the board keep those. A session makes, edits and switches automations from slice 3.
- **Keeping a closed Mac awake** for its runs (`closed-lid-pauses-sessions`).
- **A cap on usage** beyond the floor and the overlap rule.
- **Runs started by the phone,** or automations edited there.
- **Waking a sleeping Mac** to run (`pmset` schedules).

## Further Notes

### Accepted 2026-10-15

The user accepted this option, a run as a hidden Claude pane, over option 02's print mode. Their decisions, relayed by the coordinator:

1. **Permissions follow Varnick's setting.** A new automation takes the user's Varnick Claude permission setting, Skip included when that is what is set, and each automation can override it. This replaces the earlier rule that a run never inherits the global Skip. The editor keeps its warning that on a Mac a shell reaches the screen through Varnick's grants. The rule against Screen access and Panel access tools stays.
2. **Missed runs** are caught up once if the slot is under 12 hours old.
3. **Cadence:** presets only, shortest 15 minutes.
4. **The planner's recommendations, taken:**
   - the board's Runs tab;
   - ending a finished run's process after 10 minutes, with a resume on open;
   - the names **Automation** and **Run** in `CONTEXT.md`.
5. **Deferred:** a session making automations (the propose tool or option 04's files) is a later slice, not in this build.

"Takes the setting" is read as a pane already reads it: the automation stores no permission until it is overridden, and each run takes the setting at its start and keeps it on its record. A typed prompt's record works the same way.

### Slice 1: this Mac only, no protocol bump

Built and merged at af9ead1.

**In it:**
1. **The switch and the Settings section.** The Automations switch in Settings › Experimental, off by default, and Settings › Automations with it on. The host is this Mac alone, and the host picker comes in slice 2.
2. **This Mac's list.** Its file, the editor, Run now, and the switch per automation.
3. **The slot function** in the shared package, where slice 2's relay will call it unchanged, and its make check.
4. **Firing.** The minute check, plus launch and wake. Due, missed and the 12-hour catch-up, the overlap rule, and the 20-run history.
5. **Run tabs.** Each is started as a typed prompt is. It is kept out of every tab list named above, restored hidden after a restart, and kept by the launch sweep. It is opened from the board's Runs tab or a notice, and becomes an ordinary tab when the switch goes off.
6. **Permissions.** Varnick's setting by default. The overrides: Ask, Skip, and Allowed tools only if the check below passes. The allowed tools, the `notify`-only MCP config, and the editor's warning.
7. **Limits and ending.** The working limit, the 24-hour wait and ending a finished run after 10 minutes, each recorded in the run list.
8. **Documents.** The new ADR, the `CONTEXT.md` entries, and where-it-breaks.

**Not in it:**
- **The headless host:** its file, its timer and firing step, protocol 29, the Mac holding remote runs, and the phone's Runs.
- **Hiding runs from other screens.** With no run flag in `tabs` until slice 2, a Mac's run tabs are listed to the phone and to other Macs as ordinary tabs. That listing is what lets the host's page server see the run's turn and push its notices to the phone, and a finished run's tab closes after 10 minutes, so they don't pile up there.
- **Deferred beyond this build:** a session making automations, cron, and a cap on usage.

**Throwaway check first,** with the user's own `claude` in a scratch folder, in a zmx session of its own. Never the Varnick binary, and never the screen. Start an interactive session with `--permission-mode dontAsk`, a `--settings` that allows one Bash rule, and a hook that copies each event's input to a scratch file. Its prompt needs both the allowed command and one that is allowed nowhere. Read the transcript and the hook dumps:
- Is the command allowed nowhere refused with no dialog, and does Claude go on?
- Does the allowed one run?
- Does `PermissionRequest` fire? It shouldn't.
- What do the turn hooks write?

If the refusal brings up a dialog, Allowed tools only is left out and Ask and Skip remain. The dumps can hold paths, so they stay in this problem's scratch folder.

**By hand, after the user restarts Varnick with the Automations switch on:**
- **Quiet:** an automation every 15 minutes, "say hello, then notify me with the time", with Run now. Nothing opens, and the Mac's Message notice comes with the automation's name. The run is on the board's Runs tab, and opening it shows the pane live.
- **Away:** with the Mac locked and the phone subscribed, the phone gets the push, and the tap lands on the run's pane.
- **Missed:** with the Mac asleep through a slot, one run comes at wake, marked late, and the older slots are marked missed.
- **Quit:** with Varnick quit through a slot, one run comes at launch.
- **Overlap:** a prompt that asks a question waits with Needs you, and the next slot is skipped.
- **Working limit:** a limit of a few minutes on a long prompt ends the run, marked in the run list. Opening it resumes the conversation.
- **Ending:** a finished run's zmx session is gone 10 minutes after Done, and opening it resumes.
- **Permissions:**
  - with no override, a run follows Settings › Claude's Skip permissions, on and off;
  - an Ask override shows Needs you for a command it doesn't allow;
  - `/mcp` in an opened run lists `notify` alone, even with Screen access on.
- **Restart:** restart Varnick while a run works. The run tab comes back hidden, its session still running, and its notice still comes.
- **The switch off:** nothing fires, and an unopened run tab shows in the strip as an ordinary tab.
- **Keep sessions running off:** a due run is recorded "couldn't start", with the reason.

### Slice 2: the headless host, protocol 29

Defined 2026-10-15 against main at 9e66872, after slices 1 and 3 and slice 1 of `work-cant-be-saved-or-chained` option 01 (ADR 0041). The user decided that this slice is built on that shape: an automation is a trigger (a cadence, a Task and its input) in `automations.json` at version 2, and its Runs, with their steps, are in a runs file of their own. Protocol 29 carries Tasks and Runs as they are now. The user answered the slice's four questions as recommended later the same day (relayed by the coordinator): they are under Resolved for slice 2, below.

**Goal.** An automation can be kept on the headless host and fired there with every Mac asleep. Its run is a Claude pane in that host's zmx, labelled for the Mac that saved it. That Mac, while it runs, holds the run as an unseen tab and raises its notices; the phone gets the push when the user is away. Every Mac edits the host's list from Settings › Automations, the Runs tab lists the host's runs beside this Mac's, and a run nobody opened is hidden from every Mac's lists and listed under Runs on the phone.

**In it:**
1. **The host's two files** and the protocol 29 requests that read and change them.
2. **The firing step:** `varnick-peer tick`, run once a minute by a systemd user timer that the installer puts in with a flag of its own.
3. **The run on the host:** started as a `start` is, labelled for the Mac that saved the automation, with its permissions stored on the record.
4. **The run mark in `tabs`,** on both kinds of host, so a run nobody opened is hidden on other Macs and listed under Runs on the phone.
5. **The saving Mac's unseen view** of each run, adopted at its minute check.
6. **Settings › Automations** with a section per headless host, and the Runs tab with the hosts' runs.
7. **Documents:** ADR 0009 and ADR 0040 amended, `CONTEXT.md`, where-it-breaks, the guide and the privacy page.

**Not in it:**
- **The automation tools on the headless host** (resolved 2): they stay this Mac's.
- **Any Task but Claude prompt there** (below).
- **Search of a headless run's conversation:** no headless session is searched from a Mac (below).
- **A notice that outlives a headless run's view,** and a notice for a run ended at its limit: both wait for the Run's own notice, which the engine slice of `work-cant-be-saved-or-chained` builds.
- **The phone starting or editing automations,** and a Settings button that installs the timer.

#### Settled

**The host's files.**
- **`automations.json` and `runs.json` in the relay's state folder,** in the same formats as a Mac's (`AutomationFile` at version 2, `TaskRunFile` at version 1, from the shared package).
  - They are read under the shared state lock and written under the exclusive one, whole by rename, as `devices.json` is.
  - Only the relay writes them: its timer's run and the protocol 29 requests.
  - They follow the files' rules: unreadable or newer stops every check and every change there, is never written over, and Settings says so on that host's section.
- **A third file, `tick.json`,** holds when the timer last ran. Its two uses:
  - it gives a run's awake working time, as the Mac's minute check keeps it in memory (a gap over 150 s, a reboot or a stopped timer, adds nothing);
  - it tells Settings whether the timer fires.
- **Each automation there names the Mac that last saved it,** a new optional field, set by the host from the request's sender and never taken from the body. That Mac's id labels its runs, as the zone is the last saver's. Nil on a Mac.
- **A run's session record** gains four optional fields, as a Mac's `SessionRecord` has them:
  - the automation (for life);
  - unopened (until opened);
  - Allowed tools only;
  - the allowed tools.

  So a restart of the session passes them again. An older relay reads the record as an ordinary session.

**What fires them: the option's timer holds, with one change.**
- **A user `.timer`** (every minute, to the second, not persistent: the slot function catches up by itself) **starts a `oneshot` `.service`** that runs `varnick-peer tick`.
- **The change: the service has `KillMode=process`, as the Phone page's unit does.** A run's zmx daemon is created by the relay that the service runs, so it lives in the service's cgroup. Any other mode would end every run when the tick exits. The page's unit has the same line for the sessions its relay starts.
- **Every zmx command sets its socket folder itself,** so a tick's zmx and an ssh request's are the same zmx.
- **Unverified, and checked first** (Checks, below):
  - that the timer fires with linger on and nobody logged in;
  - that a session a tick started outlives the tick and the ticks after it;
  - what the journal says about the processes left behind at each start.

  If a session dies with its tick, each run's start goes into a transient scope of its own (`systemd-run --user --scope`) instead.
- **Installed by the installer with a flag of its own,** `--automations` and `--no-automations`, as `--problems` is.
  - The far half writes both units, enables the timer and reports it.
  - It warns when linger is off, as it does for the page.
  - An Upgrade keeps what is there, and `--uninstall` removes both units.
- **ADR 0009 is amended:** systemd's timer is resident beside the page's unit, and the relay starts sessions unasked, but only for an automation the user saved.

**The tick,** one pass:
1. Nothing saved: it exits at once.
2. It reconciles the records with zmx, as every request does.
3. Either file unreadable or newer: it logs one line and exits.
4. **A run session no Run names becomes ordinary** (its unopened mark goes), as `releaseUnnamedRuns` does at a Mac's launch.
5. **It tends each Run that is going**, with the Mac's rules:
   - its state, detail, conversation and working time come from zmx and the pane's turn file;
   - it counts as **opened** once its control label no longer names the Mac it was started for (a take over);
   - a session that is gone ends the Run, done or couldn't start;
   - an unopened one is **ended** past its working limit, after 24 hours of waiting, or 10 minutes after Done or a failed turn: its session is killed, its record marked ended and the Run dated.

   One decision function in the shared package says which, so `make check-slots` covers it.
6. **It judges the slots** with `AutomationSlot.check`, from the newer of the last slot and the newest Run's slot. It records missed slots, and a skipped one while a run is going.
7. **It starts what is due**, by the claim below.
8. **It writes the Runs, then the last slot, then `tick.json`.**

- **The lock** is taken for each read and each write, never across a launch or a zmx wait.
- **Two ticks never overlap:** systemd doesn't start a `oneshot` that is still running.
- **The log** names the step and the kind of outcome, never a name, a prompt, a folder or a title.

**Starting a run there, by the clock or by Run now.**
- **One claim under the exclusive lock** (as `claimResume` decides a resume):
  - if no Run of the automation is going, it records the Run as running, with its one Claude step;
  - in the same write it saves the session record as starting, marked with the automation and unopened, its origin the saving Mac, its tab named after the automation.

  So the timer and a Mac's Run now can't both start one, and a crash after the claim leaves a Run the anchor counts.
- **Then `launch`, outside the lock,** as `start` does. Its control and origin are the saving Mac, its MCP config lists `notify` alone, as every pane there does, and these come from the record:
  - Skip permissions;
  - `--permission-mode dontAsk`;
  - the allowed tools in `--settings`.
- **A start that fails** makes the Run "couldn't start" with the reply's reason, and the record is marked ended.
- **Refused before it starts, as on a Mac:**
  - a folder that isn't one there (none means the host's default folder);
  - an agent that folder doesn't have;
  - a folder Claude Code hasn't trusted;
  - an automation no Mac has saved.
- **The pane's title in `tabs` is the automation's name,** so the Mac's notice and the phone's notification say "Morning summary".
- **Kept out of the host's own lists until opened:**
  - a record that ended unopened never reaches the host's Recent, as a Mac's run never reaches Recent;
  - an unopened run's record is never started again by a Mac's restored pane (`start` with `resume`), so a run lost to a reboot stays ended.
- **A conversation that was a run's, resumed through `resume`,** takes the run step's permissions, as `applyRunFields` does on a Mac.

**Hiding a run tab from the phone and other Macs** (slice 1 left them showing):
- **The mark.** A host's `tabs` lists a tab whose pane is an unopened run with a mark, the automation's id (optional). A Mac's listing marks its own run tabs the same way, from the saved records.
- **The phone and the page server.** The page server still reads every tab, so it sees a run's turn and pushes its notices as now. Only the Home page splits them: marked tabs go under **Runs** on that host's Home, not under Tabs.
- **Other Macs** drop marked tabs from what their lists read (the session list, the board's cards, the remembered tabs and the marks) while their own Automations switch is on, and keep them in a list of their own for their views and for adopting. With the switch off they show them as ordinary tabs, so nothing runs out of sight.
- **The mark goes when the run is opened:** shown on the saving Mac (which tells the host), taken over anywhere, or released by Delete.

**The saving Mac's view** (resolved 1):
- **Adopted at the minute check.** Once a minute and after a wake, while Automations is on, each Mac asks each headless host on protocol 29 for its `tabs`. A marked tab whose control names this Mac, and that no tab here holds, opens here unseen:
  - as a tab of that host's, not shown (`openHostTab`, which opens a paired machine's tab without showing it);
  - its records marked with the automation and unopened, so the hidden-tab rule applies as it stands;
  - its panes started at once, so each attaches as any session this Mac controls there does.
- **From then on it is a Mac run tab,** and slice 1's rules hold:
  - the notifier reads its turn through the host's status;
  - the host's page server routes by this Mac's presence;
  - a restart restores it hidden;
  - its session ending on the host closes it without reaching Recent.
- **A tab the host no longer marks** (taken over elsewhere, or released) becomes ordinary here, as a run taken over on a Mac does.
- **Showing it, Automations going off, and Delete** all open it, and each sends the host `runOpened` for the tab.

**Settings and the Runs tab.**
- **A section per headless host,** below This Mac, read when Settings opens and after each change. Each row has:
  - its switch, next run, last outcome, Run now, Edit and Delete, as this Mac's rows have;
  - the host's file problem, or that its file is newer;
  - whether its timer has run in the last three minutes ("Nothing fires on it until its timer is installed": the installer with `--automations`).
- **The editor takes the host for a new automation:** This Mac, or a headless host on protocol 29. For a headless host:
  - the folders are its `projects` and the agents its `agents`;
  - "Varnick's setting" is that host's Skip permissions (resolved 3);
  - the warning drops the macOS grants, which the host doesn't have.

  An automation's host doesn't change once it is saved.
- **Any listed Mac may edit a headless automation;** the last to save it labels its later runs.
- **The Runs tab** lists the hosts' Runs beside this Mac's, newest first, "on <host>". Opening one:
  - **Going:** its unseen view shows, or, on another Mac, the host's tab opens on its card (Controlled on that Mac, Take over).
  - **Ended:** its conversation is resumed on the host (`resume`).

**The protocol 29 requests,** answered by a headless host to a listed Mac only, never to a device or the host's own page server. A Mac's relay hands them to its app, which says they aren't its to answer.

| Request | Carries | Answers |
|---|---|---|
| `automations` | nothing | the host's automations and Runs |
| `saveAutomation` | a whole automation (any Task and input) | the list after it, or every problem |
| `deleteAutomation` | the automation's id | the list after it |
| `runAutomation` (Run now) | the automation's id | the list after it, and the tab of the run |
| `runOpened` | a tab's id | nothing |

- **The `automations` reply** is one value. It holds:
  - the automations file's version and the runs file's;
  - the automations and their Runs, as the files hold them;
  - either file's problem;
  - how long ago the timer last ran;
  - the host's Skip permissions.

  Its reader applies the files' rule over the wire: a version newer than this build's is read as "newer" with no list, never as a reply that fails to decode. A Mac saves to a host only when the host's automations file is at this build's version.
- **A save is checked on the host,** which alone can see its folders and agents. Every problem is named, and nothing is saved.
  - **A new automation:** its slots start from now, and its sender is its saver.
  - **An edit:** the editor's fields go onto the host's copy, as the editor's Save does on a Mac. The last slot is kept unless the cadence or the zone changed or it was switched on, and the saver becomes the sender.
  - One function in the shared package does it, so `make check-slots` covers it.
- **The `tabs` change:** an optional run mark on a tab, read by the Macs and the phone (above).
- **Delete** turns its unopened run sessions into ordinary tabs and drops its Runs, in one write of both files.

**Room for the engine's Runs on protocol 29, without another bump:**
- **Runs travel whole:** the Run with its steps, input and typed result, as the runs file holds it, inside a value that carries the file's version.
  - The engine's additions that are optional fields, as every saved field must be, need nothing.
  - Any other change is a version of the runs file, which the other side reads as newer.
- **The mark is on the tab, not on a pane,** so a Run of several panes is one mark. Its automation is optional, so a Run started by hand or by a session is a mark with none.
- **`runOpened` names a tab, never a pane,** so it opens every pane of a Run at once.
- **A save carries any Task's name and input,** and the host checks the Task by name, so a new Task is a refusal or an acceptance there, not a new shape.

**"On this site" can't run on the headless host.** Its browser is the Website pane, which only a Mac's Varnick has.
- The host refuses a save naming any Task but Claude prompt: "On this site needs a Mac: its browser runs only in Varnick on a Mac", and for any other Task that this host runs Claude prompt only.
- The editor has no Task picker yet. The engine's own slice for the headless host keeps to Claude, Notify and Task steps there.

**What every Mac and the headless host must update together.**
- **Protocol 29 is one commit for all of them.** A 28 and a 29 build exchange only hello, Upgrade and Restart. So the steps are:
  - every Mac restarts on the build (Upgrade all);
  - the headless host is reinstalled from the same commit (its row's Upgrade);
  - each Phone page, whose server holds the protocol's number, comes with its host's install or launch snapshot.
- **Once, by hand:** the installer with `--automations` puts the timer on the host. Later Upgrades keep it.
- **No file version changes.** `automations.json` stays at 2, `runs.json` at 1, and `sessions.json` and the host's records only gain optional fields.

**Session search, and why it is untouched.**
- **A run on a Mac** is a transcript in this Mac's Claude Code projects, read like any other. While unopened, search lists its conversation with no tab, and ↩ resumes it with `notify` alone. Never checked, so it is in the hand test.
- **A headless run is not searched,** and neither is any headless session: a headless host answers `rows` with nothing. That stays so here.

#### Checks

**First, the throwaway check on the headless host,** run by the builder over ssh at the user's word (2026-10-15, relayed by the coordinator), and removed afterwards. It never touches the real install root or `/tmp/zmx-<uid>`:
1. Make a throwaway user timer and `oneshot` service with `KillMode=process`, every minute. Its script, in a throwaway folder:
   - appends the time and the account's login sessions to a file;
   - on its first run, makes a zmx session with the relay's own zmx, a short throwaway absolute `ZMX_DIR` and a pty, as Varnick does, running a long `sleep`, and detaches.
2. With linger on, end every login (or reboot), wait five minutes or more, then log in and read:
   - is there a line each minute with no login?
   - is the session still running after its tick and the next ones?
   - what does the service's journal say at each start?
3. While logged in there, run `make check-slots`' binary from the installed source once, so the zone and daylight-saving cases are known to hold in Linux's Foundation.
4. Remove the units, the session and the folder.

The answers go in where-it-breaks, Peers. Host names and figures stay in this problem's scratch folder.

**Then the build's own checks:**
- **`make check-slots`** gains cases for:
  - the `automations` value: same versions, and a newer automations or runs version read as newer with empty lists;
  - the save: a new automation, an edit keeping the last slot, a changed cadence, zone or switch resetting it, the saver;
  - the save's problems, other Tasks refused by name included;
  - the tend decision: the working limit across ticks and a gap, the 24 hours, the 10 minutes, opened by a take over, a session gone;
  - the run mark round trip.
- **The relay builds** for macOS from the package (inferred to build there). The host's Upgrade is its Linux build, judged by the installer's markers.
- **`bun test`** in the Phone page: the Runs split of Home, and the protocol number.
- **`make build`.**

**By hand,** after the user restarts every Mac on the build, upgrades the headless host and installs its timer, with Automations on:
1. **Settings:** the host's section shows, with its timer running.
2. **Headless, Mac awake:** an automation on the host ("say hello, then notify me with the time", every 15 minutes, in one of its projects), then Run now.
   - Nothing opens here.
   - The Message notice comes on this Mac named after the automation, and no push.
   - The Runs tab lists it on the host, and opening it shows it live.
3. **Headless, Mac asleep:** the next slot pushes to the phone, and the tap lands on the run's pane.
4. **Headless, every Mac asleep:** a slot fires on time (the Runs tab shows it on time once a Mac wakes).
5. **Hidden:** while it is unopened:
   - another Mac's session list and board don't show it;
   - the phone lists it under Runs, not Tabs;
   - another Mac with Automations off shows it as an ordinary tab.
6. **Ending:** 10 minutes after Done its session is gone on the host and this Mac's view with it, and opening it from the Runs tab resumes it on the host.
7. **Working limit:** a few minutes on a long prompt stops it, marked in the Runs tab.
8. **Overlap:** a prompt that asks a question waits with Needs you, and the next slot is skipped.
9. **Take over from the phone:** the run is an ordinary tab everywhere, and the tick never ends it.
10. **A second Mac edits it:** its next run is labelled for that Mac, which holds the view.
11. **Delete with a run going:** the run becomes an ordinary tab on the host.
12. **Reboot the host with a run going:**
    - the run reads ended, and nothing starts it again;
    - a slot that passed during the reboot runs once at the timer's next run, if under 12 hours old.
13. **Automations off on this Mac:** its views become ordinary tabs, and the host fires on (resolved 4).
14. **Three runs going at once:** each view attaches.
15. **Search,** on this Mac: a local run's prompt word finds its conversation, and ↩ resumes it with `/mcp` listing `notify` alone.

#### Where it touches, by symbol

- **The shared package:**
  - `PeerProtocol.version`, `PeerOp`, `PeerRequest` and `PeerReply`;
  - `PeerTab` (the mark);
  - `Automation` (the saver);
  - a new file for the `automations` value, the save, its problems and the tend decision;
  - the slot-check target.
- **The relay:**
  - a new file for the two files under the lock, the claim, the tick and the five answers (sibling: the devices file under the lock);
  - `HeadlessPeerHost.forward`, `tabs`, `pane`, `recent` and `resumeConversation`;
  - `HeadlessSession`;
  - `launch` (dontAsk and the allowed tools);
  - `HeadlessLifecycle.resumeDecision`;
  - the entry point's `tick`;
  - `PeerRelay.run`'s Macs-only list and its forwarded requests.
- **The app:**
  - `PeerManager` (the five requests) and `PeerManager.handle`;
  - a new file for the hosts' automations, the adoption and the remote half of opening;
  - one-line hooks in `AutomationRunner.start`, `runOpened`, `releaseHiddenRuns` and `openRun`;
  - `updatePeerTabs` (marked tabs out of `peerTabs`);
  - `PeerOpenTabs.list` (this Mac's mark);
  - `AutomationsSettingsView` and its editor;
  - `RunsBoard.refresh`;
  - the Automations switch's detail.
- **The Phone page:** its protocol number, `shapeHome`, the Home view and its tests.
- **The installer's two halves:** the flag, the units, the markers and the `supports:` word.

#### Resolved for slice 2

**Answered by the user, 2026-10-15** (relayed by the coordinator), all four as recommended:

1. **The saving Mac attaches to each headless run.** It holds the unseen view above, attached like any session it controls on the host, so the page server's routing and the notices don't change.
   - The cost, accepted with it: one ssh channel per unopened run going, on the connection the panes share. OpenSSH's default is ten sessions a connection; ADR 0008's spike ran 14 on Tailscale SSH. The hand test's three runs at once is its check.
   - Not chosen: following only, which needed a change to the push rule and a notice with no pane.
2. **Settings only in this slice.** The four automation tools stay this Mac's. A `host` argument comes in a later slice on these same requests, with no bump.
   - The reasons: the engine slice adds `task` and `input` to the same tools and files, a host's folders and agents can only be checked there, and the tools' answer would have to wait on ssh.
   - Not chosen: the tools taking a host now.
3. **"Varnick's setting" on the headless host is that host's own Skip permissions** (its config, off unless set), read at each run's start, stored on the run and shown in the editor. A session nobody asked for there follows that setting already.
   - Not chosen: the saving Mac's Skip permissions at its save, stored on the automation as if overridden.
4. **The Automations switch is each Mac's own.** A headless host fires its automations on its timer whatever any Mac's switch says; an automation's own switch, from any Mac, or removing the timer stops it. Turning a Mac's switch off opens that Mac's views of the host's runs, and the switch's detail says the host's automations go on.
   - Not chosen: turning the saving Mac's switch off also switching off the automations it saved on the host, which would lose their own on and off.

**The throwaway check** is the builder's, over ssh, at the user's word (Checks, above). It removes its units, its session and its folder when done.

#### Verified and inferred, for slice 2

- **Verified at 9e66872:**
  - the automation record as a trigger and the Run with its steps, in the shared package with their files' rules;
  - the Run's trigger naming an automation as a required field;
  - the relay's `launch` passing no Allowed tools only or allowed tools;
  - the Macs-only list of the relay;
  - a headless host's `rows` answering nothing;
  - every zmx command setting its socket folder;
  - the page's unit having `KillMode=process` for the sessions its relay starts, and the installer's linger marker;
  - opening a paired machine's tab without showing it;
  - a host pane on a card attaching when its label names this Mac, after waiting at most a second for its view;
  - the push for a Mac with no client;
  - the phone's notification titled by the pane;
  - the sessions-exited shortcut for any hidden run tab, a host's included, and `runClosed` passing over a Run it doesn't hold;
  - one place taking in a peer's `tabs` for the lists, the open sessions and the views;
  - the editor's Save merge being in the view;
  - the wire's dates written as Swift's default.
- **Inferred, unverified:**
  - the timer with linger and no login;
  - a `oneshot` with `KillMode=process` leaving its runs alone;
  - Linux's Foundation keeping zones and daylight saving as `make check-slots` does;
  - an unseen host pane started at once attaching at a default size;
  - the relay building on macOS;
  - a phone tap on a run's push finding a tab listed under Runs.

### Slice 3: sessions make, edit and switch automations (this Mac only)

**Decided by the user, later on 2026-10-15** (relayed by the coordinator): a Claude session can create an automation, edit one, and turn one on or off, through Varnick's MCP server, with no approval step. This replaces the `propose` tool and the deferral in item 5 above. The rest was fixed with it:
- a read-only list comes with them, since editing and switching need ids;
- a run's own session never gets them, and stays `notify`-only;
- this Mac only, like slice 1.

It is built next, before slice 2.

**Resolved by the user, 2026-10-15** (relayed by the coordinator), both as recommended:
- **No Skip from a session.** A session may only follow Varnick's setting, or choose Ask or Allowed tools only. It may switch an automation set to Skip on or off, but not edit it. A session then never gives an unattended run more than the user's own setting gives a typed prompt.
- **The mark alone.** The user is told of a session's create, edit or switch by the mark, with no notice.

**The tools,** a set of their own on Varnick's MCP server:
- **`automations_list`** gives every automation of this Mac with its id and every field create takes, plus:
  - its next run;
  - whether a run is going;
  - its last outcome;
  - its mark.

  It reads and changes nothing.
- **`automation_create`** makes one, and answers its id and when it first runs.
- **`automation_edit`** takes an id and any of create's fields, and changes only those given.
- **`automation_switch`** takes an id and on or off.

Deleting and Run now stay in Settings › Automations and on the board. A delete drops the run history and releases the automation's run tabs, and can't be undone. A session that wants an automation to stop can switch it off, so the user keeps the one act that loses anything.

**Which panes list them.** Every Claude pane on this Mac started or restarted while the Automations switch is on. Not a run's session, and not a run opened later, whose tool set stays `notify` alone. Not a headless host's pane either. The tools are not behind Panel access and have no switch of their own:
- Panel access grants reading every terminal's screen, the board and the Outline, and pressing keys in the panel. Tying automations to it would make the user grant all of that to get this.
- The Automations switch is already the user's opt-in to this feature. A third switch would gate the same decision the user has just made: that a session may turn an automation on itself.

The set is read at each start, as Screen and Panel access's are, so a pane gains or loses it at its next start or restart. The running Varnick refuses every call while Automations is off, as it refuses Panel access's calls while that switch is off, since the MCP server's process can't read a switch.

**They follow the pane's permissions.** Only `notify` is allowed in a session's settings; these four are not.
- A pane with Skip permissions on calls them with no dialog.
- A pane with it off shows Claude Code's dialog before each call, which raises Needs you like any dialog. That is Claude Code's own check, the same for every MCP tool, not a step of Varnick's.

**What create takes:**

| Field | |
|---|---|
| name | required, one line, cut to 80 characters |
| prompt | required, given to Claude as written |
| cadence | required: a kind (every N minutes, every N hours, daily, weekdays or weekly) with its numbers, as the presets have them. Anything else is refused, and the reply lists the presets |
| folder | an existing folder on this Mac. Absent is the calling session's own folder: "this repo every morning" means the session's folder, and an automation with no folder runs in Home (amended 2026-10-15, relayed by the coordinator: the Default folder setting is gone). The editor already shows a folder that isn't a project |
| agent | an agent of that folder; another is refused, and the reply lists them |
| permissions | absent follows Varnick's setting; else Ask or Allowed tools only. Skip is refused, and so is any edit of an automation set to Skip |
| allowed tools | a list of Claude Code rules, one line each. A session may set any rule, a broad one such as `Bash` included (the user's decision, 2026-10-15, relayed by the coordinator), so with Skip off a run can get more than a typed prompt gets; the mark names the rules |
| working limit | minutes, 5 to 1440, as the editor's; 60 when absent |
| enabled | on when absent, as the editor's Add |

- **Checks before writing.** Every field is checked before anything is written. A refusal names each wrong field and saves nothing.
- **The zone and the slots.** The zone is this Mac's, and the slots start from now, as the editor's Add does.

**Edit and switch.**
- **Only the fields given change.** They are applied onto the store's current copy, as the editor's Save does. The runs and the last slot stay.
- **Like the Save, an edit stamps this Mac's zone,** and a changed cadence or zone starts the slots from now.
- **Turning one on,** by edit or switch, starts its slots from now, as the row's switch does.
- **Turning one off** releases nothing: a run that is going goes on, as in slice 1.
- **An automation set to Skip** is refused for every edit by a session, and can still be switched on or off.
- **The editor and a session at once.** A session's edit made while the user has the editor open is overwritten by the user's Save, for the fields the editor holds. The user's own edit wins.

**The user sees it as a mark, not a notice.**
- **What the mark says.** Every create, edit and switch by a session leaves a mark on the automation: what was done, by which session (its title), and when.
- **Where it shows.** On the automation's row in Settings › Automations and beside its runs on the board's Runs tab, until the user opens its editor, switches it or presses Seen.
- **Why not a notice:**
  - the session the user just asked is usually the pane they are looking at, and no notice is raised for that pane;
  - a Message is written only by the hook, from Claude's own call;
  - a new notice kind would change the table in both languages.
- **The run tells them anyway.** A run raises its own notices, named after the automation. So an automation a session made or turned on while the user was away is seen at its first run at the latest.
- **The tool's reply asks Claude to tell the user what it did.**

**How a call reaches the store.** As Panel access's calls do:
- **The MCP server sends one line.** It turns each call into one request line on Varnick's socket, with a key and a version of its own, and prints the reply.
- **The running Varnick answers on the main actor,** checking in order:
  1. the switch;
  2. Varnick having started;
  3. the calling pane (a Claude pane on this Mac, and not a run's);
  4. the file being readable;
  5. then the tool.

  It writes only through the automation store, the one writer of the file. A pane another Mac or the phone controls may call: it runs here, so its automations are this Mac's.
- **With Varnick quit,** the reply is that it isn't running.
- **Not the `notify` path.** A hook records a call after it has been answered, so it can't hand back an id, a list or a refusal, and the app would have to watch a file in every pane's folder.
- **Any process on this Mac can open the socket and name a pane,** as for Panel access. It needs no grant, and where-it-breaks says so.
- **The log** says the tool and the kind of outcome only, never a name, a prompt or a title, as Panel access's log does.

**What `make check-mcp` covers:**
- the set listed alone and with the others;
- each tool's schema and description;
- create's required fields and the cadence's kinds;
- the permissions' values, with no Skip;
- a call to one of these tools on a server without the set, refused before anything is sent.

It never calls a tool the set lists. With Varnick running on the user's Mac, that call would reach it and make a real automation.

**Documents:**
- **ADR 0040, amended:** sessions make, edit and switch automations through the running Varnick, with no approval step, behind the Automations switch, never from a run. Deleting stays the user's.
- **`CONTEXT.md`,** the Automation entry.
- **The privacy page:** a session can set up unattended runs, and a session that lists the automations sends their prompts to Anthropic with it.
- **where-it-breaks,** Automations: the request and its checks, a run's exclusion, the permission rule, and check-mcp's rule.

**By hand, after the user restarts Varnick with Automations on, in a pane started since:**
- **The tools:** `/mcp` lists the four beside `notify`. An opened run lists `notify` alone.
- **Create:** "make an automation that says hello every 15 minutes in this folder". It is made and on, Settings shows the mark, and its first run comes at the next quarter hour with its notice.
- **Switch:**
  - "turn it off": no more runs, and a mark;
  - "turn it on": its slots start from now.
- **Edit:**
  - "change its prompt to …": only the prompt changes, and its runs and next run stay;
  - "make it daily at 9:00": the next run moves, and its slots start from now.
- **Refusals,** each with nothing saved: an agent the folder doesn't have, a folder that isn't there, every 5 minutes, Skip, and an edit of an automation set to Skip. Switching that automation off and on again works.
- **With Skip permissions off,** Claude Code asks before each call.
- **The switch:**
  - Automations off: every call is refused;
  - after a restart of the pane, the tools are gone.
- **Varnick quit:** the call says Varnick isn't running.

### Verified and inferred

- **Verified at d70f766:**
  - `hostStart`'s background tab;
  - a typed prompt's record taking Skip permissions at its start;
  - the shared command line, and a Mac pane's MCP config with both switches off listing `notify` alone;
  - the notifier reading unopened panes;
  - the page server's routing by controller, and its push to a Mac with no client;
  - the headless control label;
  - the launch sweep;
  - the installer's user unit and its linger warning;
  - `SavedTab` and `PeerTab` having no hiding field;
  - Claude Code 2.1.301's permission modes, by name only.
- **Checked by hand in slice 1 (2026-10-15):** `dontAsk` in an interactive session refuses a call no rule allows with no dialog and goes on (where-it-breaks, Automations).
- **Inferred, unverified:**
  - that a hidden pane on a Mac starts and attaches as a background tab does;
  - that session search indexes runs' conversations like any other;
  - that a systemd timer with linger fires with no login;
  - the memory a finished run holds.

### Open questions, recommendation first

1. **On the headless host, does the saving Mac attach to the run** (this option), **or only follow it, with the page server routing a run by that Mac's presence even with no client?** Resolved by the user, 2026-10-15 (relayed by the coordinator): attach, as recommended. It is how every Mac-controlled session there already works, and it needs no change to the routing. Slice 2's Resolved for slice 2 has the cost.
2. **Should a run ended at its working limit raise a notice?** The pane is gone, so it needs one of two things: a notice the notifier keeps for a run rather than a pane, or a way to end the turn and leave the pane. Recommendation: decide after slice 1's hand test shows how often limits are hit. Until then it is marked in the run list only.
