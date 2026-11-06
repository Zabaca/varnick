---
title: Automation runs crowd the menu with Done notices
description: Every run of an automation raises a Done notice when its turn ends, like a typed session. A run's tab stays out of sight until the user opens it, so its notice is never cleared by the pane coming on screen, and an hourly automation leaves a new Done line in the menu bar menu every hour (a daily one each day besides). The notices the user does want from a run, a message it sends with `notify`, a dialog waiting on them, an error, are buried among them.
impact: The menu fills with notices that say nothing the user needs, the dot is always lit, and the phone is pushed a Done for every run. The only control, Settings › Notifications › "is done", is global and would also silence the user's interactive sessions. The more automations the user keeps, the less the notices are worth.
severity: mid
evidence: The user's report of 2026-11-06, relayed by the coordinator: the hourly X drafter and the daily research run each leave a Done notice per run that accumulates in the menu bar menu. Code and docs read at 29551eb (main).
status: open
---

## Today

- **A run is a typed prompt, notices included** (ADR 0040): its pane raises Done, Needs you, an error and a message by the same rule as any Claude pane (`NoticeRule`), on the Mac and, through the host's page server, on the phone.
- **A notice is cleared when its pane comes on screen,** closes, or its turn moves on. A run's tab is hidden until the user opens it from the board's Runs tab or the notice, so an unopened run's Done stands; after its process is ended (10 minutes of Done with nobody opening it) the notice still stands, and choosing it resumes the conversation.
- **The switches are global.** Settings › Notifications has one per kind (needs me, is done, stops on an error, sends me a message), and each phone subscription has the same four. Nothing is per session or per automation.
- **A run can already tell the user what matters** with the `notify` tool (a title and a body), which raises a Message notice of its own; the hourly X drafter does ("X draft waiting").
