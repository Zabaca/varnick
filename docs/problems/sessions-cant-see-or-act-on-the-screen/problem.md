---
title: Claude sessions in Launchy's panes can't see the screen, act on apps or point at things
description: The user wants a Claude session running in a Launchy pane to do three things. It should look at the screen (a window's controls, or a picture of it), act on apps (click, type), and mark things for the user with Launchy's Arrow. Launchy itself can now read windows, capture them and draw the Arrow (ADR 0019, 0021), but a session can do none of it. Its processes run under zmx, and macOS holds zmx, which has no grants, responsible for them. The rule written into ADR 0019 and 0021 is that zmx is never granted.
impact: A session can't check what it built in a native app, follow a setup in System Settings, or show the user which button to press. It asks the user to look and describe, or to click for it. The stopgap the user chose on 2026-10-09 is granting zmx Accessibility and Screen Recording, which gives that power to every session zmx hosts, unsupervised (below).
severity: mid
evidence: The user's request of 2026-10-09, relayed by the coordinator. Code read on 2026-10-09 at ca01eb4. The process chain was seen that day in a session in a Launchy pane. The commands run, and what they showed, are noted under Today.
status: open
---

## What the user asked (2026-10-09)

Claude sessions in Launchy's panes should be able to:
1. view the screen;
2. control apps: click, type;
3. mark things with the Arrow.

The coordinator relayed a proposed direction, not a decision: Launchy brokers it. It already holds the grants and has the reading, capture and Arrow code. It would expose a local command channel with verbs such as look, point, click and type.

## The interim state, and its risk

As a stopgap, the user is granting zmx Accessibility and Screen Recording temporarily, so that one session can view, control and mark. While those grants stand, the following holds. All of it is inferred from how macOS attributes grants, and from the eval's recheck in `spoken-requests-cant-see-the-screen`.
- **Every session zmx hosts gets the grants.** That is every Claude pane while Keep sessions running is on, including any started with Skip permissions (one is running now). Each can read any window, capture the screen, and send clicks and keystrokes to any app without asking: with `screencapture`, `osascript` through System Events, bigarrow, or a script of its own.
- **Everything those sessions start gets them too:** shells, tools, MCP servers, subagents.
- **Nothing shows it is happening.** Launchy draws nothing and logs nothing, since the session acts directly. Screen captures may show macOS's own recording indicator.
- **The grant doesn't lapse by itself.**
  - zmx is a pinned release binary with an ad-hoc signature that names its own code hash (`codesign -d -r-` on the copy beside Launchy's binary).
  - `make build` doesn't rebuild it, so the grant should hold until the zmx pin changes.
  - Removing it is by hand, in System Settings › Privacy & Security › Accessibility, and in Screen & System Audio Recording.
- **This reverses ADR 0019 and ADR 0021's rule for as long as it stands.** Their temporary exception was the eval's.

## Today

Read in the code at ca01eb4 unless marked.

**Where a session runs**
- **With Keep sessions running on,** a Claude pane runs under zmx. The process chain is the shell, then claude, then zmx, whose parent is launchd (pid 1); Launchy isn't an ancestor. This was seen in a pane on 2026-10-09.
- **The grants follow the process macOS holds responsible.** For a zmx pane that is very likely zmx: in `spoken-requests-cant-see-the-screen`'s eval, a pane turned trusted once zmx alone was granted.
- **With Keep sessions running off (the default), or zmx missing,** a pane is Launchy's own child. It probably shares Launchy's grants (`panes-share-launchys-permissions`), so there a session may already see and act on the screen once Launchy is granted. That is unmeasured.

**What Launchy can already do, in its own process**
- **`ScreenReader`** reads the focused window's Accessibility tree, or another app's by name for `--ask --app`. It lists elements with their labels, kinds, frames and the text beside them, and never reads what a field holds.
- **`ScreenText`** captures one window into memory with ScreenCaptureKit and reads its short lines with Vision on this Mac.
- **`ArrowOverlay`** draws the Arrow and a sign at a frame. It never takes focus or the mouse.
- **Nothing in Launchy clicks or types into another app.**

**How a process reaches the running Launchy**
- **The peer socket** is a Unix socket in Launchy's Application Support folder, mode 0600, and accepts only the same user (`getpeereid`). The relay mode (ADR 0007) sends it one line and prints the reply. It is the only local channel into the running app.
- **Any process of the user can open it,** including every pane's.

**Who a caller is**
- **The pane id.** A pane's processes carry `LAUNCHY_PANE_ID`, set when the pane starts. Every pane's folder in Application Support is named by it.
- **The environment can be read by the same user.** `ps -wwE` on another of the user's processes shows its environment, `LAUNCHY_PANE_ID` included. Checked on 2026-10-09 against the user's running claude processes.
- **So the pane id, or any secret passed the same way, is readable by any process of the user,** and a process of the user can also attach to another pane's zmx session and type into it. Within one account, no channel can prove which pane is calling. It can only make pretending deliberate.

**What Claude Code offers** (version 2.1.296, from its `--help`)
- **`--mcp-config`** loads MCP servers for a session. Launchy already starts every pane's claude with `--settings`, for its hooks.
- **`--chrome`** enables Claude's Chrome integration, which acts inside Chrome only.
- **No computer-use flag** is listed. Whether Claude Code offers one by other means is unverified; if it does, it would run in the pane under zmx and need zmx granted.

**What a session's context reaches**
- Whatever a session is shown goes to Anthropic with its context, and stays in its transcript on this Mac.
- Launchy's session search reads typed prompts and Claude's replies, not tool results (ADR 0018), so a picture or element list in a transcript isn't searched or sent to a paired Mac. Inferred from that ADR.

## Left to decide

- **Broker or grant.** Launchy acting for a session, with its own checks, or zmx or a pane holding the grant and acting directly.
- **Which verbs.** Look and point only, or click and type too.
- **Which panes.** Every session, a session the user turns on, or one started for it.
- **Approval for control.** Each action approved, a time-boxed grant for one session, or none.
- **What a session may be shown.** One window or the whole display, element lists or pictures, and windows never shown (a password manager).
- **How the user knows.** An indicator while a session looks or acts, and a record of what it did.
- **The interim zmx grant.** When it is removed, and what replaces it.
