---
title: Processes in panes started outside zmx probably share Launchy's macOS permissions
description: A pane that doesn't run in zmx (Keep sessions running off, which is the default, or zmx missing) is started as Launchy's own child process, and nothing tells macOS to hold it responsible for itself. So the Claude sessions, shells and tools in such a pane probably get whatever privacy permissions the user gave Launchy. Today that is the microphone and system audio. With Point at the screen, it will be Accessibility, which lets a process read and drive any app's UI.
impact: Granting Launchy Accessibility for Point at the screen would quietly grant it to every Claude session in those panes, including sessions started with Skip permissions, which act without asking. The user accepted this for now, with a plain line in Settings and in SECURITY.md, when they accepted spoken-requests-cant-see-the-screen option 01 on 2026-10-09.
severity: mid
evidence: Raised by spoken-requests-cant-see-the-screen, accepted with its option 01 on 2026-10-09. Code read on 2026-10-09 at 4090c28. An eval in agent-lab observed a zmx pane's processes on the same day. Whether panes outside zmx really get Launchy's grants is unmeasured; that option's hand check 2 measures it.
status: open
---

## Today

Read in the code at 4090c28 unless marked.

- **How a pane starts.**
  - `ClaudeSession.startInTerminal` runs a pane's command in zmx when Keep sessions running is on and zmx is there, and directly otherwise, as a child of Launchy, through SwiftTerm.
  - Keep sessions running is read with no default but `false` (`Settings.swift`), so on a new install every pane is Launchy's child.
  - A custom app's server always runs in zmx when zmx is there.
- **No disclaim.** Neither Launchy nor SwiftTerm marks a child as responsible for itself: no such call is in `Sources/`, `Packages/` or SwiftTerm's checkout. macOS gives a process the grants of its responsible app, so Launchy's children probably share Launchy's. This is inferred.
- **zmx panes are very likely not affected.** A zmx session's processes run under zmx, whose parent is launchd. In the eval, a check in such a pane turned trusted after the user granted zmx alone, with Launchy's switch off, so macOS very likely holds zmx responsible for them. Not confirmed.
- **What Launchy holds today:** the microphone and system audio, for Listening. Point at the screen adds Accessibility (ADR 0019).

## Left to decide

- **Measure first.** Option 01's hand check 2 in `spoken-requests-cant-see-the-screen` tells whether a pane outside zmx is trusted once Launchy is.
- **If it is, how to cut the link.** Possible directions, none of them checked:
  - start panes with responsibility disclaimed, through an undocumented macOS call that SwiftTerm's spawn doesn't offer;
  - always run panes in zmx, whatever Keep sessions running says;
  - start panes through launchd.

  Each changes the microphone too. A tool in a pane that uses the mic would then ask under its own name, or fail.
- **Whether zmx itself needs a rule.** It must never be granted anything, since its grants would reach every session it hosts (ADR 0019).
