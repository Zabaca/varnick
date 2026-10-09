---
title: Claude sessions in Launchy's panes can't see the screen, act on apps or point at things
description: The user wants a Claude session running in a Launchy pane to do three things. It should look at the screen (a window's controls, or a picture of it), act on apps (click, type), and mark things for the user with Launchy's Arrow. Launchy itself can now read windows, capture them and draw the Arrow (ADR 0019, 0021), but a session can do none of it. macOS checks each executable in a pane as itself, and none of a session's own executables holds a grant.
impact: A session can't check what it built in a native app, follow a setup in System Settings, or show the user which button to press. It asks the user to look and describe, or to click for it. The stopgap the user chose on 2026-10-09 is a helper binary granted Accessibility and Screen Recording, which any process of the user can run, unsupervised (below). Granting zmx, tried first, did nothing.
severity: mid
evidence: The user's request of 2026-10-09, relayed by the coordinator. Code read on 2026-10-09 at ca01eb4. Measured that day from a session in a Launchy pane, also relayed: the process chain, each process's responsible process, and the trust checks with zmx granted. The commands run, and what they showed, are noted under Today.
status: open
---

## What the user asked (2026-10-09)

Claude sessions in Launchy's panes should be able to:
1. view the screen;
2. control apps: click, type;
3. mark things with the Arrow.

The coordinator relayed a proposed direction, not a decision: Launchy brokers it. It already holds the grants and has the reading, capture and Arrow code. It would expose a local command channel with verbs such as look, point, click and type.

## The interim state, and its risk

**Granting zmx did nothing** (measured 2026-10-09). The user granted zmx Accessibility and Screen Recording, and then from a session in a pane:
- a freshly compiled binary got `false` from both `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`;
- `screencapture` failed.

The reason is under Today: each executable is checked as itself. The user is removing zmx's grants.

**The interim is a helper binary.** It is a small executable of the user's, outside the repository, ad-hoc signed with the identifier `com.zabaca.screenhand`. Its subcommands are `displays`, `shot`, `tree`, `activate`, `click`, `type`, `key`, `press` and `point`. The user is granting that one binary Accessibility and Screen Recording. While it holds them:
- **Any process of the user can run it and get those powers.** That covers every pane's session, those started with Skip permissions included (one is running now), anything they start, and any script. There is no approval, no Launchy indicator and no record, beyond what the helper itself does.
- **It could click Allow in a prompt of Launchy's,** such as option 01's approval prompt. Option 01's gate holds only while no executable a pane can run holds Accessibility, and this helper is one.
- **Its grant probably lapses when it is rebuilt.** Its ad-hoc signature names its code hash, as Launchy's does. Inferred.
- **It isn't in this repository,** so nothing here reviews what it does.
- **Removing it is by hand,** in System Settings › Privacy & Security › Accessibility, and in Screen & System Audio Recording.

## Today

Read in the code at ca01eb4 unless marked.

**Where a session runs, and whose grants it has**
- **With Keep sessions running on,** a Claude pane runs under zmx. The process chain is the shell, then claude, then zmx, whose parent is launchd (pid 1); Launchy isn't an ancestor. Seen in a pane on 2026-10-09.
- **Every process in that chain is its own responsible process** (measured 2026-10-09). macOS's private lookup, `responsibility_get_pid_responsible_for_pid` (reached with `dlsym`), was run on each one: zsh, the claude binary, zmx, and each command the shell ran (`sleep`, a test binary). Each reported itself. A zsh under another terminal app (cmux) reports that app, so the lookup works.
- **So macOS checks each executable in a pane as itself.**
  - A grant to zmx reaches no session's commands (the measurement above).
  - A grant to one executable reaches whatever process runs that executable, which is why the helper works.
  - This replaces the "zmx is responsible" reading in `spoken-requests-cant-see-the-screen`.
- **Why the panes are self-responsible is unexplained.**
  - Nothing disclaims responsibility: no such call is in Launchy's or SwiftTerm's sources, and zmx's binary imports `fork`, `forkpty` and `setsid` but no spawn attributes or responsibility calls.
  - One hypothesis, unverified: Launchy is a bare executable, not an app that LaunchServices started, and passes no responsibility to its children.
  - Why `spoken-requests-cant-see-the-screen`'s eval recheck turned true, with only zmx granted, is unexplained too.
- **With Keep sessions running off (the default), or zmx missing,** a pane is Launchy's own child, through SwiftTerm. Whether its processes share Launchy's grants is now doubtful, and unmeasured: the same lookup in such a pane settles it (`panes-share-launchys-permissions`).

**What a grant to an executable lends** (inferred from the above)
- **Launchy's own binary is the executable its grants name.** Run from a pane, it is probably trusted too. Its command-line modes would then act with Launchy's grants: `Launchy --ask <file> --app <name>` would read another app's window from any shell.
- **Launchy is signed ad hoc without the hardened runtime.** `codesign` shows `flags=0x2(adhoc)`. So a process can probably load its own code into Launchy's binary (`DYLD_INSERT_LIBRARIES`) and use every grant Launchy holds, the microphone included. The same holds for any ad-hoc helper.
- **To measure:**
  - from a pane, `Launchy --ask` with `--app` naming another app;
  - a test binary's trust check when run through `DYLD_INSERT_LIBRARIES` into Launchy's binary, with the result kept local.
- **The fix for the injection risk** is the hardened runtime, `runs-only-from-a-checkout` option 01.

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
- **The interim helper.** When its grants are removed, and what replaces it.
- **What Launchy's own grants lend,** while its binary runs from any shell without the hardened runtime.
