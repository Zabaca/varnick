---
title: Closing the lid puts every session to sleep
description: On a MacBook, closing the lid sleeps the Mac, and every process in Launchy's panes stops until it opens. The user wants closed-lid sessions to keep running while the Mac is on AC power, and the Mac to sleep on lid close as it does now when on battery.
impact: Long unattended work only runs with the lid open. The Air can't be shut on a desk while a session finishes, and a paired Mac loses the sessions it drives on the Air whenever its lid closes. The workaround is leaving the lid open, or running `caffeinate -s` by hand, which is untested for lid close and easy to forget.
severity: mid
evidence: Read-only checks on this Mac (Mac17,3, internal battery, macOS 26.6.2) on 2026-10-05. `ioreg -r -k AppleClamshellState -d 1` shows `AppleClamshellCausesSleep = Yes` and `SleepDisabled = No`. `pmset -g custom` shows system sleep 0 on AC and 1 on battery. `pmset -g assertions` shows each claude that Launchy started holding a `caffeinate -i -t 300` child (PreventUserIdleSystemSleep). The SDK's IOPMLib.h says of that assertion that "the system may still sleep for lid close", and marks PreventSystemSleep (what `caffeinate -s` takes) deprecated and "not supported", while caffeinate's man page says `-s` holds "only when system is running on AC power". Whether `caffeinate -s` keeps a closed Mac awake with no external display is unverified; the user is testing it.
status: open
---

When a MacBook's lid closes, macOS sleeps the Mac (clamshell sleep), and every pane's process stops until the lid opens. That includes Claude sessions in the middle of a task, their subagents, builds and dev servers in terminals, and the sessions a paired Mac drives here over SSH, whose link drops too. On wake they carry on. Nothing ends, but nothing runs while the lid is shut.

Idle sleep is already handled. Each claude process holds an idle-sleep assertion while it works, and this Mac's AC profile has system sleep off. Neither covers lid close.

The machine is a MacBook Air: Apple Silicon, fanless, used without an external display. macOS's own clamshell mode (AC power plus an external display) would keep it awake, but that isn't how it's used.

Two things make getting this wrong worse than leaving it alone:

- **Heat.** A fanless Air cools through its case, less well when closed, and in a bag on power it overheats. Whatever keeps it awake has to let it sleep when it runs hot.
- **A Mac left awake by mistake.** If Launchy quits or crashes, or the Mac is unplugged, a closed Mac should sleep as it does today. Otherwise a crash can leave it awake on battery in a bag.
