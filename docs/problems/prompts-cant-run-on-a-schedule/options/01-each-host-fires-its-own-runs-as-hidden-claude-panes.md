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
  - a folder (a **Project**, or the **Default folder**);
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

### Slice 2: the headless host

Its file and the protocol 29 requests, the systemd timer and the relay's firing step, the label for the saving Mac, the Mac holding remote runs, the run flag in `tabs`, and the phone's Runs. ADR 0009 is amended then.

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
| folder | an existing folder on this Mac. Absent is the calling session's own folder: "this repo every morning" means the session's folder, and the Default folder is a Settings choice the session can't see. The editor already shows a folder that isn't a project |
| agent | an agent of that folder; another is refused, and the reply lists them |
| permissions | absent follows Varnick's setting; else Ask or Allowed tools only. Skip is refused, and so is any edit of an automation set to Skip |
| allowed tools | a list of Claude Code rules, one line each |
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

1. **On the headless host, does the saving Mac attach to the run** (this option), **or only follow it, with the page server routing a run by that Mac's presence even with no client?** For slice 2. Recommendation: attach. It is how every Mac-controlled session there already works, and it needs no change to the routing.
2. **Should a run ended at its working limit raise a notice?** The pane is gone, so it needs one of two things: a notice the notifier keeps for a run rather than a pane, or a way to end the turn and leave the pane. Recommendation: decide after slice 1's hand test shows how often limits are hit. Until then it is marked in the run list only.
