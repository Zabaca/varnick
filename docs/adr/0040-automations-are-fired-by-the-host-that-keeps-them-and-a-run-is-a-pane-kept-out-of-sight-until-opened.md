# Automations are fired by the host that keeps them, and a run is a pane kept out of sight until opened

Builds on [ADR 0004](0004-pane-processes-live-in-zmx.md) (a pane's process lives in zmx), [ADR 0010](0010-a-panes-turn-comes-from-hooks-that-write-to-the-pane-folder.md) (the turn and the notices come from hooks that write to the pane folder) and [ADR 0030](0030-the-outline-is-one-json-file-varnick-owns-of-bullets-and-placements-never-written-over-when-unreadable.md) (a file that can't be read is never written over). The problem and the option are in `docs/problems/prompts-cant-run-on-a-schedule/`, option 01, accepted 2026-10-15 with the user's decisions of that day. The mechanics and what breaks them are in `docs/agents/where-it-breaks.md`, Automations.

An **Automation** (`CONTEXT.md`) is a saved prompt with a folder, an optional agent and a cadence. The host that keeps it fires it: nothing else decides when, and no other machine is needed awake. A **Run** is one slot's session: a Claude pane started exactly as a typed prompt is, in zmx, in a tab that nobody sees until the user opens it. This ADR covers slice 1, this Mac alone; the headless host's half (a systemd user timer that runs the relay once a minute, protocol 29) is slice 2 and amends [ADR 0009](0009-a-headless-host-runs-varnicks-relay-alone.md) then.

- **Fired by the running Varnick.** Once a minute, at launch and a few seconds after a wake. Nothing resident is added: no launchd job, no daemon, so a run needs nothing the app's own launch doesn't give it (ADR 0013 records why launchd stays out of sessions). A Mac that sleeps or a Varnick that is quit fires nothing, and catches up once.
- **Anything the user does starts the clock from now.** A new automation, a changed cadence or zone, an automation switched on and Automations switched on all set the last slot to the time of the change, so a slot before it is never caught up. Only a sleep or a quit between two checks catches a slot up (once), and a Run now touches nothing.
- **One pure function says what is due,** in the shared package (`AutomationSlot.check`), so the relay calls it unchanged in slice 2. The newest slot since the last fired is due if it is under 12 hours old, every other slot since is recorded missed and never run. The cadence is a preset kept as data (every 15 or 30 minutes, every 1, 2, 3, 4, 6 or 12 hours, daily, weekdays, weekly at a time), in the zone of the Mac that saved it.
- **A run is a typed prompt.** It has the same command line, hooks, transcript, search, notices, resume and pane. Its record is marked as a run of the automation, and unopened. Its MCP config lists `notify` alone, so it never gets Screen access's or Panel access's tools. Its permissions are Varnick's Skip permissions at its start, unless the automation overrides them (Ask, Allowed tools only as `--permission-mode dontAsk`, Skip), and are stored on the record like any pane's.
- **Kept out of sight by a rule on lists, not by a place.** The tab stays in the model's list of tabs, which saving, the launch sweep, the notifier and the host's listing read, so a restart restores it and its notice still comes. `shownTabs` leaves it out of every list for the eye until it is opened. Turning Automations off opens every run at once.
- **The list is a file of its own** (`automations.json`), never `sessions.json`, written only by the running Varnick and never over a file it can't read or that a newer build wrote. Each automation keeps its last 20 runs.
- **A run ends its process, not its conversation.** A turn past the working limit, 24 hours of waiting on the user, or 10 minutes of Done with nobody opening it ends the run's zmx session, and its tab closes into the run list and never Recent. Opening an ended run resumes the conversation in a new tab.

## Considered Options

- **Print mode (option 02):** not chosen. A dialog becomes a refusal and the run is not a pane, so it has no live view, no Needs you and no resume as a session.
- **launchd or a detached daemon on a Mac:** not chosen. The user's rules keep both out of sessions (XProtect once killed a Claude process that ran `launchctl`), and a run inside the running Varnick needs neither.
- **Run tabs in a list of their own (not in `tabs`):** not chosen. Every place that looks a pane up, saves, sweeps or notifies would have to read two lists, and one that missed would lose a notice or kill a session silently. A list that forgets to leave a run tab out is seen at once.
- **Skip permissions never inherited:** the user chose the opposite. A run follows the setting a typed prompt follows, and each automation can override it.

## Consequences

- **An unattended run on a Mac can reach the screen** through the macOS grants every pane inherits (`panes-share-launchys-permissions`), with a shell and no tool for it. With Skip permissions on, which is every install that predates the setting, a run runs any command without asking. The editor says so; only closing that problem would change it.
- **Each run draws on the user's Claude subscription,** unattended. The 15-minute floor and the one-run-at-a-time rule bound it; nothing caps it.
- **Until the headless host has runs,** a run tab is listed to paired Macs and the phone as an ordinary tab, which is what lets the host's page server push its notices.
- **A run ended at its limit tells no one.** The pane is gone, so neither the Mac's notifier nor the page server has a turn to read; it is marked in the run list only.
- **Nothing lets a session make an automation.** That is deferred beyond this build.
