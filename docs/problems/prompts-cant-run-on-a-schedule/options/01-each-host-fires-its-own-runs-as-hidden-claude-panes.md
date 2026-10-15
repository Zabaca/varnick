---
problem: prompts-cant-run-on-a-schedule
title: Each host fires its own automations, and a run is a Claude pane in zmx that stays out of sight until opened
summary: Behind an Automations switch in Settings › Experimental. Automations are made and edited in Settings › Automations on any Mac. Each one has a name, a prompt, a folder, an optional agent, a host, a cadence chosen from presets, and a permission choice. It is kept on the host that runs it, and that host fires it. On a Mac, the running Varnick checks once a minute, at launch and on wake. On the headless host, a systemd user timer runs the relay once a minute, so nothing stays running. A due run starts a Claude pane exactly as a typed prompt would, in zmx, in a run tab of its own. The tab is kept out of the strip, the session list, the board and Recent until the user opens it from the board's Runs tab or from a notice. The notices need nothing new: Done is finished, Needs you is stuck, and errors and Messages work as in any pane. A run missed while the Mac slept or Varnick was quit runs once when it wakes or launches. A run never overlaps itself, stops at a time limit, and ends its process a few minutes after it finishes, so its conversation is resumed when opened. A run never gets Screen access or Panel access, and never inherits Skip permissions. Recommended. Built this Mac first, then the headless host, which needs protocol 29.
status: proposed
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
  - a permission choice and a list of allowed tools;
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

  Nothing stays running, so ADR 0009's rule holds for every process except the timer.
- **launchd is not used.** Every Mac run happens inside the running Varnick, so a run needs nothing that Varnick's own launch doesn't already give it.

### Due, missed and caught up

- **The last slot.** Each automation remembers the last slot it fired for. A slot is the cadence's time, such as 9:00 on a Wednesday.
- **What a check runs.** At a check, the newest slot that has passed since then is due. Every older one that also passed is recorded as missed and never run.
- **Catching up.** A due slot is run if it is under 12 hours old. Otherwise it too is recorded as missed.
- **What that means for a sleeping Mac or a quit Varnick.** At the next wake or launch, a run due in the meantime runs once, and the history says it ran late. This is Claude Desktop's catch-up once, bounded so a Mac shut for a weekend doesn't start Friday's runs on Monday.
- **A headless host's runs don't depend on any Mac being awake.** The host fires them itself, and a reboot is caught up by the same rule at the timer's next run.

### The cadence

- **Presets, kept as data, not as a cron string:**
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
  - Recent and Completed;
  - search's tab rows.
- **The board gets a Runs tab** beside Sessions and Problems, behind the same switch. It lists every run of every automation on every host, newest first, each with:
  - the automation's name;
  - when it ran and where;
  - its state: running, waiting on you, done, or a message's title;
  - or why it didn't run: stopped at its limit, skipped, missed, couldn't start.
- **Opening a run** from that list, from a notice or from the phone:
  - **Still running or waiting on the user:** its run tab moves into the strip and shows, live, so the user can watch, answer the dialog or type.
  - **Ended:** its conversation is resumed in a new tab, as ↩ on Recent does.

  From then on it is an ordinary tab: Done closes it, and it goes to Recent when closed.
- **On the headless host,** a run is that host's tab, labelled with the Mac that saved the automation as its origin and its controller, as if that Mac had typed `^host` and the prompt.
  - **While that Mac's Varnick runs,** it holds the run tab as an unseen view of the host's tab, attached as it attaches to any session it controls there. So it follows the turn and raises its own notices, and the host's page server routes by that Mac's presence.
  - **While that Mac is asleep or quit,** the session has no client. The page server's rule for a Mac with no client then pushes to the phone after the settle.
  - **Finding new runs.** The Mac learns of runs it didn't start by asking each host it has automations on for their runs, at its once-a-minute check.
- **The phone** sees a host's run tabs in its `tabs`, marked as runs, and lists them under Runs on that host's Home. A push for a run lands on its pane, as for any pane.

### Notices: nothing new

A run is a Claude pane, so the table applies as it stands:

| A run… | notice |
|---|---|
| finishes its turn | **Done** |
| stops on a permission dialog, a question, a plan or an MCP request | **Needs you** |
| ends on an API error | **Stopped on an error** |
| calls `notify` | **Message**, with the Done that follows folded into it |

They are routed by **Presence** as for any pane: on the Mac in control when the user is there, pushed to the phone when they aren't.

### Overlap and limits

- **One run of an automation at a time.** A slot that falls due while the last run still works or waits on the user is recorded "skipped: the last run was still going". Run now is refused for the same reason.
- **A working limit,** one hour by default and set per automation. A run whose turn has worked or run background work past it is ended. Its zmx session is killed, and the conversation is kept so it can be resumed. It raises an error notice whose kind reads "ran past its limit".
- **A run waiting on the user** is kept while it waits, since that is the stuck the user asked to hear about, and it blocks the automation's next slots. After 24 hours of waiting it is ended the same way, and the history says why.
- **A finished run ends its process.** Once its turn has been waiting for 10 minutes, with no client of the user's attached and nobody having opened it, its zmx session is killed. The run tab closes into the automation's history, so finished runs don't pile up as processes. Each holds a claude and an MCP server, the latter about 19 MB by the snapshot of 2026-10-13. Opening it later resumes the conversation.

### Permissions

Each automation picks one. The default is Ask:

- **Ask.** Claude's normal mode. The automation's allowed tools run without a dialog, and anything else shows its dialog. The run waits, and Needs you is raised.
- **Allowed tools only.** Anything not allowed is refused with no dialog. Claude goes on or ends, and a run never waits on the user for a permission. This is Claude Code's `dontAsk` mode, whose interactive behaviour is checked before this choice is offered (Testing Decisions).
- **Skip permission checks.** Offered only on the automation itself, with a warning in the editor. A run never takes it from the global Skip permissions setting.

Whatever the choice:

- **No screen tools.** A run's MCP config lists `notify` alone, so it never gets Screen access's or Panel access's tools, whatever those switches say. The user's rule that agents don't drive the screen unasked holds there.
- **A warning about the macOS grants.** On a Mac, the editor says that a shell command a run is allowed can still reach the screen through the grants every pane inherits (`panes-share-launchys-permissions`). It suggests the headless host, which has no screen, for an automation that allows broad shell use.
- **The allowed tools** are written in Claude Code's own rule syntax (such as `Bash(git *)`, `Edit` or `WebSearch`). They go in the run's settings beside `notify`'s allowance, and add to the user's own.

## Trade-offs

- **A run is exactly a typed prompt.** It has the same command line, hooks, transcript, search, notices, resume and pane. That is the user's first decision kept literally, and nearly everything a run needs already exists.
- **Stuck means Needs you.** The user's third decision names it, and a pane delivers it with no new notice kind. The cost is that a run in Ask mode waits for the user. The overlap rule and the 24-hour end keep the wait from piling up, but the work waits too.
- **The always-on host is used as always-on.** Its runs fire with every Mac asleep, and only their notices need a Mac or the phone.
- **The headless host is no longer request-only.** A timer now starts sessions there with no request. The relay's rule "nothing starts one unasked" becomes "nothing but an automation the user saved".
- **It has the most moving parts of the options.** It needs:
  - two firing paths;
  - a file per host;
  - protocol 29 for the requests and the run flag in `tabs`;
  - hiding run tabs everywhere tabs are listed;
  - a Mac holding remote runs it didn't start.

  The Mac half alone is a first slice, and needs no protocol bump.
- **Hiding a tab is a new rule across many lists.** The strip, the session list, the board, Recent, search's tab rows, the phone's Home and the remembered tabs each need to leave run tabs out until opened. A list that misses one floods with runs.
- **Ending a finished run's process** keeps memory bounded. The cost is that opening a finished run is a resume, not a live pane: its screen is redrawn from the conversation, not kept.
- **Varnick must be running on a Mac.** A Mac's runs fire only while it runs, and catch up once at its launch. Open at login covers most of that for the installed app.
- **On a Mac, the macOS grants leak into anything a run's shell runs.** Ask mode stops each shell call at a dialog, but an automation that allows `Bash` broadly runs unattended with Accessibility and Screen Recording. Only `panes-share-launchys-permissions` fixes that.
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
9. As the user, I want a run never to use the screen tools or my global Skip permissions, so that nothing unattended drives my screen or runs unchecked without my choosing it for that automation.
10. As the user, I want "daily at 9:00" on the headless host to mean my 9:00.
11. As the user, I want Run now, to try an automation before I leave it to the clock.
12. As the user, I want to see each automation's runs, with what happened and why a slot didn't run.

## Implementation Decisions

### Shape and state

- **The automation record** is a small codable value with an id. Its cadence is a tagged value per preset, with the zone's identifier. It keeps the last fired slot, its runs (newest first, capped at 20 per automation) and each run's outcome.
- **The run record:**
  - the slot;
  - when it started;
  - the pane's id and conversation;
  - its outcome, as one of: running, waiting, done, a message's title, stopped at its limit, skipped, missed, couldn't start (with the reason).

  It names no folder content or words beyond the message's title, which the pane folder already holds.
- **When a slot is due** is one pure function: the cadence, the zone, the last fired slot and the time now give the due slot, if any, and the missed ones. Both hosts call it. It lives in the shared package, like the notice rule.
- **On a Mac,** the run tab is a saved tab with an optional field naming the automation, set while it is unopened and cleared when opened. So the launch sweep keeps its zmx session as it keeps any saved tab's. An older build reads the field as absent and shows the tab as an ordinary one, which is harmless.
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
- **The permission choice:**
  - Ask is no flag;
  - Allowed tools only is `--permission-mode dontAsk`;
  - Skip is the existing skip flag.

  It is stored on the record like `skipPermissions`, so a resume or a restart keeps it.
- **The allowed tools** join `notify` in the run's `--settings` allowance. The hooks' settings stay the same as every pane's, so the turn and message readers work unchanged.

### Limits and ending

- **The limits are checked** on the Mac by the minute check, and on the headless host by the timer's run. Both read the turn and its age from the pane folder, as the notices do.
- **Ending a run** is `zmx kill` of its session, confirmed gone from a listing, as a restart does. The record becomes ended, and the conversation stays resumable.
- **The error kind** for a run ended at its working limit is a new failure word in the turn's error kind. It is carried in `status` and `tabs` like the others. A kind that a Mac or the page server doesn't know reads "API error", as now, so it fails safe.

### Documents

- **ADR,** once accepted: automations are fired by the host that keeps them, and a headless host's timer is the one thing there that starts a session unasked.
- **ADR 0009,** amended: its "nothing resident" now excepts the timer.
- **`CONTEXT.md`:**
  - new entries: **Automation**, **Run**, the board's Runs tab;
  - **Task** and **Panel access** keep "automation" under Avoid, now pointing to the new term.
- **where-it-breaks:**
  - the hidden-tab rule and every list it applies to;
  - the slot function and time zones;
  - the run's MCP config and permission rules;
  - the timer, and its installer flag;
  - protocol 29.

## Testing Decisions

- **Before anything relies on it, a throwaway check** of `--permission-mode dontAsk` in an interactive session started with a prompt, in a scratch folder. Does a tool allowed nowhere get refused with no dialog, and does Claude carry on? If not, Allowed tools only isn't offered, and Ask and Skip remain.
- **A check of the slot function, run by a make target over a table of cases,** as `make check-mcp` checks the MCP server. Neither Varnick nor the shared package has a test target. The cases are:
  - every preset;
  - a zone different from the host's;
  - a daylight-saving change;
  - the 12-hour catch-up bound;
  - many missed slots giving one due slot;
  - a slot exactly at the check's minute.
- **`make build`**, and the protocol versions match.
- **By hand, after the user restarts Varnick and reinstalls the headless host with the timer:**
  - **This Mac:** an automation every 15 minutes with "say hello and notify me". The run opens nothing, the Mac's Message notice comes, and the run is on the board's Runs tab. Opening it shows the pane live.
  - **Missed:** with the Mac asleep through a slot, one run comes at wake, marked late, and the older slots are marked missed.
  - **Quit:** with Varnick quit through a slot, one run comes at launch.
  - **Overlap:** a prompt that asks a question stays waiting (Needs you), and the next slot is skipped.
  - **Limit:** a working limit of 2 minutes on a long prompt ends the run with the error notice, and opening it resumes the conversation.
  - **Ending:** a finished run's zmx session is gone 10 minutes after Done, and opening it resumes.
  - **Headless, Mac awake:** a run there gives the Mac's notice and no push while the user is at the Mac.
  - **Headless, Mac asleep:** with the Mac asleep, the phone gets the push, and the tap lands on the run's pane.
  - **Permissions:** an Ask run that needs Bash shows Needs you. A run never lists Screen access tools with that switch on (`/mcp` in the opened run).
  - **The switch off:** nothing fires on this Mac.
  - **An older build** restoring the saved tabs shows a run tab as an ordinary tab and drops nothing.

## Out of Scope

- **Scheduling a Task** (the website loop), terminal commands, or anything but a Claude prompt.
- **Cron expressions** (open question 3).
- **A session making an automation.** This is option 04, or a later step here: a `propose` tool on Varnick's MCP server, recorded by a hook as `notify` is, which the user saves from a prefilled editor.
- **Keeping a closed Mac awake** for its runs (`closed-lid-pauses-sessions`).
- **A cap on usage** beyond the floor and the overlap rule.
- **Runs started by the phone,** or automations edited there.
- **Waking a sleeping Mac** to run (`pmset` schedules).

## Further Notes

### Build order

1. **This Mac:** the switch, the list and editor, the minute check with wake and launch, run tabs kept out of sight, the board's Runs tab, the limits, overlap and missed slots. No protocol bump.
2. **The headless host:** its file, protocol 29, the timer and the relay's firing step, the label for the saving Mac, the Mac holding remote runs, and the phone's Runs.
3. **Later:** a session proposes an automation (Out of Scope).

### Verified and inferred

- **Verified at d70f766:**
  - `hostStart`'s background tab;
  - the shared command line and its MCP config;
  - Skip permissions per record;
  - the notifier reading unopened panes;
  - the page server's routing by controller, and its push to a Mac with no client;
  - the headless control label;
  - the launch sweep;
  - the installer's user unit and its linger warning;
  - `SavedTab` and `PeerTab` having no hiding field;
  - Claude Code 2.1.301's permission modes by name.
- **Inferred, unverified:**
  - what `dontAsk` does interactively;
  - that a hidden pane on a Mac starts and attaches as a background tab does;
  - that session search indexes runs' conversations like any other;
  - that a systemd timer with linger fires with no login;
  - the memory a finished run holds.

### Open questions, recommendation first

1. **Does a stuck run wait for you, or get refused and end?** Recommendation: wait (this option), with Allowed tools only as a choice per automation for those that must never wait. Option 02 is the other answer.
2. **Catch up once within 12 hours, or never catch up?** Recommendation: once within 12 hours. With no catch-up, a Mac that sleeps through 9:00 every day never runs its morning automation.
3. **Presets only, or cron too?** Recommendation: presets only in the first build, kept as data so cron can be added as another case later. The shortest is 15 minutes.
4. **Where is the run list:** the board's Runs tab, or Settings › Automations? Recommendation: the board, which already lists sessions by turn and opens them, with Settings showing each automation's last outcome.
5. **End a finished run's process after 10 minutes, or keep it until opened?** Recommendation: end it. A resume shows the whole conversation, and an hourly automation would otherwise hold 24 claudes a day.
6. **On the headless host, does the saving Mac attach to the run** (this option), **or only follow it, with the page server routing a run by that Mac's presence even with no client?** Recommendation: attach. It is how every Mac-controlled session there already works, and it needs no change to the routing.
7. **The default permission choice:** Ask, or Allowed tools only? Recommendation: Ask, since Needs you is the stuck the user asked to hear about.
