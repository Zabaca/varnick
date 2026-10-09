---
title: Claude sessions in Launchy's panes can't see the screen, act on apps or point at things
description: The user wants a Claude session running in a Launchy pane to do three things. It should look at the screen (a window's controls, or a picture of it), act on apps (click, type), and mark things for the user with Launchy's Arrow. Launchy itself can now read windows, capture them and draw the Arrow (ADR 0019, 0021), and a session in a pane can do none of it unless Launchy holds those grants. When Launchy does, every pane's session gets them directly, measured by macOS's own attribution, with nothing in between.
impact: A session can't check what it built in a native app, follow a setup in System Settings, or show the user which button to press. It asks the user to look and describe, or to click for it. The other side of it: whenever the user grants Launchy Accessibility and Screen Recording for Point at the screen, every pane session can view and control the screen unsupervised, Skip-permissions ones included (below).
severity: mid
evidence: The user's request of 2026-10-09, relayed by the coordinator. Code read on 2026-10-09 at ca01eb4. Measured that day from a session in a Launchy pane, also relayed: the process chain, the trust checks with zmx granted, and macOS's privacy service's own attribution of a pane's process (its log). What each showed is under Today.
status: open
---

## What the user asked (2026-10-09)

Claude sessions in Launchy's panes should be able to:
1. view the screen;
2. control apps: click, type;
3. mark things with the Arrow.

The coordinator relayed a proposed direction, not a decision: Launchy brokers it. It already holds the grants and has the reading, capture and Arrow code. It would expose a local command channel with verbs such as look, point, click and type.

## The interim state, and its risk

**Granting zmx did nothing** (measured 2026-10-09). The user granted zmx Accessibility and Screen Recording. Then, from a session in a pane:
- a freshly compiled binary got `false` from both `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`;
- `screencapture` failed.

**A helper binary's own grant does nothing either.** The user tried a small executable of their own, outside the repository, ad-hoc signed with the identifier `com.zabaca.screenhand`. Its subcommands are `displays`, `shot`, `tree`, `activate`, `click`, `type`, `key`, `press` and `point`. Run from the same pane, macOS's privacy service asked about Launchy, not about the helper (Today). So the helper's grant is never consulted.

**What the interim really is: Launchy's grants.** Whenever Launchy holds Accessibility and Screen Recording, as Point at the screen asks it to, every process in every pane gets them. That covers:
- each session, those started with Skip permissions included (one is running now);
- anything those sessions start: the helper, `osascript`, `screencapture`, scripts.

Nothing asks, Launchy shows nothing and records nothing, and any of them can click Allow in a prompt of Launchy's. The pane's denial on 2026-10-09 came only because the Launchy on disk had been rebuilt after the user granted the running build, so the grant no longer matched.

Removing it is by hand, in System Settings › Privacy & Security › Accessibility and Screen & System Audio Recording, and it takes Point at the screen with it.

## Today

Read in the code at ca01eb4 unless marked.

**Where a session runs, and whose grants it has**
- **With Keep sessions running on,** a Claude pane runs under zmx. The process chain is the shell, then claude, then zmx, whose parent is launchd (pid 1). Seen in a pane on 2026-10-09.
- **macOS attributes a pane's processes to Launchy,** even under zmx. Measured on 2026-10-09 from the privacy service's own log (`log show` on the `com.apple.TCC` subsystem):
  - The helper was run from a zmx-hosted pane, and the log's attribution named Launchy (`com.zabaca.launchy`, at its build path) as responsible, with the helper as the binary.
  - Accessibility and Screen Recording were denied, since the build on disk no longer matched the grant.
  - So a grant to zmx or to any executable run in a pane is never consulted, and **a grant to Launchy reaches every pane session**. The attribution is measured; the effect is to be confirmed once Launchy holds a matching grant.
- **Readings this replaces:**
  - "zmx is responsible" came from `spoken-requests-cant-see-the-screen`'s eval.
  - "Each process is its own" came from macOS's private responsibility lookup (`responsibility_get_pid_responsible_for_pid`), which reported each process in the chain as its own. That lookup misled, and the privacy service's log is what decides.
  - Why the eval saw `AXIsProcessTrusted()` turn true after only zmx was granted is still unexplained.
- **Why Launchy, inferred:** nothing in Launchy, SwiftTerm or zmx disclaims responsibility. So it passes from Launchy to the first zmx it starts, and on to every process zmx starts. Neither Launchy's nor SwiftTerm's sources disclaim it, and zmx imports only `fork`, `forkpty` and `setsid`.
- **With Keep sessions running off (the default), or zmx missing,** a pane is Launchy's own child, so it is attributed to Launchy too. That is inferred; the zmx case is the measured one.
- **The fix belongs to `panes-share-launchys-permissions`:** start panes so that macOS doesn't hold Launchy responsible for them.

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
- **No computer-use flag** is listed. Whether Claude Code offers one by other means is unverified; if it does, it would run as its own executable in the pane and need its own grant.

**What a session's context reaches**
- Whatever a session is shown goes to Anthropic with its context, and stays in its transcript on this Mac.
- Launchy's session search reads typed prompts and Claude's replies, not tool results (ADR 0018), so a picture or element list in a transcript isn't searched or sent to a paired Mac. Inferred from that ADR.

## Left to decide

- **Broker or grant.** Launchy acting for a session, with its own checks, or an executable the session runs holding the grant and acting directly.
- **Which verbs.** Look and point only, or click and type too.
- **Which panes.** Every session, a session the user turns on, or one started for it.
- **Approval for control.** Each action approved, a time-boxed grant for one session, or none.
- **What a session may be shown.** One window or the whole display, element lists or pictures, and windows never shown (a password manager).
- **How the user knows.** An indicator while a session looks or acts, and a record of what it did.
- **The interim.** Launchy's grants reach every pane today. Is that acceptable until a broker ships, or do the grants come off and Point at the screen with them?
- **A broker needs the inheritance cut.** While pane processes get Launchy's grants, a session can act around any broker. Options 01, 02 and 04 depend on `panes-share-launchys-permissions`.
