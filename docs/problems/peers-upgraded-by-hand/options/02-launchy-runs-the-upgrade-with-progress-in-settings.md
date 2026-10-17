---
problem: peers-upgraded-by-hand
title: The same builds and target, with Varnick running the upgrade and showing its progress in Settings
summary: Builds, the target, the probe, the refusals and the three upgrade scripts are option 01's. The difference is where the scripts run. Upgrade starts them in a zmx session of their own, as Launchy runs the Phone page server, rather than in a terminal tab. The row in Settings › Peers shows the step and the time it has taken. A failure shows the log's last lines with Retry, and Cancel works until the restart begins. The log stays in a file to open in a pane.
status: rejected
reason: Not built (ADR 0013). Option 03 was built instead, since a Launchy started from an SSH login lacks the GUI session's Keychain, and launchctl there starts a second Launchy beside one make run started.
---

## Solution

Everything option 01 says about detection is the same here: the build stamp, the probe, the target, where each build stands, and what blocks an upgrade. So are the three upgrade scripts and their steps. This option changes only how an upgrade runs and where it shows.

- **Where it runs.** Upgrade starts the machine's script in a zmx session named after the machine, made the way the Phone page server's is. It writes to a log in Application Support. It is not a pane, so the launch sweep leaves it alone, and it outlives the restart of this Mac it may end with. It runs in its own process, never Launchy's and never a Claude process.
- **What the row shows.** While it runs, the machine's row in Settings › Peers says the step: Checking, Sending, Building with the time so far, Restarting, or Verifying. The scripts print the steps as markers, and Settings reads them from the log.
- **When it ends.**
  - A success shows the new build after a fresh probe.
  - A failure shows the log's last 20 lines in the row, with Retry and Show log. Show log opens the file in a file pane.
- **Cancel** ends the session, until the restart step begins. After that the row says "Restarting…" and Cancel is gone.
- **This Mac.** Its confirmation is option 01's. After Launchy restarts, the row reads the log the session left and shows how it ended.

## Trade-offs

- **Better:**
  - No tab to open or close.
  - Progress and failures sit on the machine's own row, where the user is already looking.
  - Several machines can be upgraded side by side and followed in one place.
- **Worse than a tab:**
  - A build's failure is read in a 20-line box or a log file, without the terminal's colours or SwiftPM's progress line.
  - ^C becomes a Cancel button that can't stop a restart already under way.
  - Nothing can be typed into the script, for example to answer a prompt from git.
- **More code in the app.** A session runner for the scripts (the Phone page runner's shape), reading the log and its step markers, Cancel, Retry, and state that survives this Mac's restart. Option 01 needs a button that opens a tab.
- **A second kind of zmx session that isn't a pane.** Like the Phone page server's, it needs its own fixed names, which the sweep and the relay's session list must never read as a pane's.
- Everything else is option 01's: no protocol change, the LaunchAgent needed on a Mac peer, and the commits sent from this Mac.

## User Stories

Option 01's stories 1 to 7 and 9 to 14 hold, with story 8 replaced:

8. As a Launchy user, I want each machine's row to show which step its upgrade is on and how long it has taken, and on a failure the build's last lines with Retry, so that I don't leave Settings to follow it.
15. As a Launchy user, I want to cancel an upgrade before it restarts anything.
16. As a Launchy user, I want to open an upgrade's full log after it ended, also after this Mac restarted.

## Implementation Decisions

- **Option 01 applies** for the build stamp, the probe, the target, where each build stands, what blocks an upgrade, the three scripts and their steps, the installer's commit argument, and Settings' rows and lines, except where this section says otherwise.
- **The session.**
  - Each upgrade runs in a zmx session named "launchy-upgrade-" followed by the machine's handle. That is never a pane's name: the sweep and the relay read a pane's id from a name. It is made through Launchy's own pty, waited for, and detached, as the Phone page server is, never with `zmx run`.
  - Its environment is the short list the Phone page server gets, plus the user's SSH agent.
  - Its log is a file in Application Support's upgrades folder, one per machine, emptied when an upgrade starts.
- **Steps.** The scripts print a step marker as each step begins: check, send, merge, build, restart, verify, done or failed. Settings reads the log every second while Peers shows, off the main actor, and only its tail.
- **Cancel** kills the session, then removes the lock if the script's process is gone. From the restart marker on, Cancel is hidden, because the stop and the launchd start must run together.
- **Retry** starts the same upgrade again after a fresh probe.
- **One upgrade per machine.** A session that is still running shows its progress when Settings opens, and its Upgrade button is hidden.
- **This Mac.** Its session survives the restart. The new Launchy finds the session or its log at launch and shows how it ended. A finished session's log stays until the next upgrade of that machine.
- **Docs, once accepted:** option 01's ADR and notes, plus where-it-breaks' rule for the upgrade sessions' names beside the Phone page server's.

## Testing Decisions

- Option 01's spike and checks.
- Also:
  - Cancel during the build: the session is gone, the lock is freed, and Launchy there still runs.
  - Cancel isn't offered once the restart marker is in the log.
  - This Mac's upgrade: the row after the restart shows the result read from the log.
  - The sweep at launch leaves an upgrade session alone.

## Out of Scope

Option 01's list, and a live view of the build's terminal output in Settings beyond the log's tail.

## Further Notes

- **Sibling to copy:** the Phone page server, for running a session that outlives Launchy with a log and a "Start again" with the last lines.
- **Not recommended over option 01.** It spends more code on progress the terminal tab already shows. Choose it if Upgrade should stay inside Settings, for instance to upgrade several machines while working in a tab.
