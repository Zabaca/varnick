---
problem: panes-share-launchys-permissions
title: Start pane processes with responsibility disclaimed, so macOS checks them as themselves and not as Launchy
summary: The planned way to make Launchy the only path to the screen, later. Measured from a pane on 2026-10-09, a process started with `posix_spawn` and the private `responsibility_spawnattrs_setdisclaim(&attrs, 1)` is no longer attributed to Launchy. Its Accessibility and Screen Recording checks read false, and so do a shell started that way and its children. `osascript` to System Events and `screencapture` were refused, and macOS's prompt named zsh, not Launchy. This option starts every pane's process that way. Sessions would stop getting Launchy's grants, and Launchy's tools (`sessions-cant-see-or-act-on-the-screen` option 01) would become their only way to the screen, so that option's deferred permissioning could gate something. It is untested whether it holds through zmx's client and daemon, and whether SwiftTerm's view can drive a terminal Launchy started itself, since SwiftTerm starts its child with `forkpty` today. Panes lose Launchy's microphone too.
status: proposed
---

## Solution

Launchy starts each pane's process itself with `posix_spawn` and the disclaim attribute, instead of SwiftTerm starting it with `forkpty`. That process is the pane's command, or the zmx client that wraps it when Keep sessions running is on. macOS then holds the process responsible for itself, and its children follow it. A pane's session, shell and tools are checked under their own names, and none of Launchy's grants reach them: Accessibility, Screen Recording, the microphone and system audio. A prompt names them, not Launchy.

**Measured on 2026-10-09, from a session in a pane,** while Launchy held both grants and they read true from that pane:
- a process started with `posix_spawn` and `responsibility_spawnattrs_setdisclaim(&attrs, 1)` got `false` from `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`;
- a shell started that way got `false` too, and so did its children;
- `osascript` to System Events was refused, and so was `screencapture`;
- macOS prompted naming "zsh", the disclaimed shell, rather than Launchy.

**Untested:** the same through zmx, for both its client and the daemon the client starts.

## Trade-offs

- **The screen becomes Launchy's to give.**
  - Pane processes stop getting its grants, so a session reaches the screen only through Launchy's tools.
  - Those tools' permissioning (a per-pane switch, approval, a record) then gates something. Today any pane process can act around it.
- **A private call.**
  - `responsibility_spawnattrs_setdisclaim` is undocumented, declared by hand and looked up at run time.
  - A macOS update could change it with no error, and panes would quietly share Launchy's grants again. The first hand check (Testing Decisions) is repeated after each macOS update.
- **zmx, untested.**
  - With Keep sessions running on, the pane's process is a zmx client, which starts the session's daemon when the session is new.
  - If the daemon follows the disclaimed client, the session is checked as zmx. "zmx is never granted" then becomes the rule that holds the line. Inferred.
  - A daemon started before this change keeps Launchy's attribution for its life. A pane already running keeps the grants until its zmx session is started again.
- **SwiftTerm's spawn.**
  - SwiftTerm starts a pane's child with `forkpty`, which takes no spawn attributes. Its `posix_spawn` path is compiled out.
  - So Launchy opens the pseudo-terminal and starts the child itself, as the headless host's `PtyClient` already does with `posix_spawn` and a new session, and gives SwiftTerm's view the terminal.
  - Whether the view drives a terminal it didn't start is unverified: resizes, the exit notification, and the poll that catches a missed exit.
- **The microphone goes too.** A tool in a pane that uses the microphone or system audio asks under its own name, or fails. Launchy's own Listening is unaffected.
- **Launchy's own binary is still Launchy.**
  - A process that runs Launchy's binary carries Launchy's signature, so even when disclaimed it is very likely checked as Launchy. Inferred.
  - The hardened runtime keeps other code out of that binary (ADR 0022), so only Launchy's own modes matter.
  - `--mcp` only relays. `--ask --app` and its `--draw` read and draw in their own process, so they must stop doing so for a caller in a pane (Further Notes).
- **Other processes Launchy starts,** inferred and listed when building:
  - custom app servers, which are panes and so are covered;
  - the upgrade build's zmx session, which runs `make`, compilers and scripts;
  - the Phone page's server;
  - short runs of git, zmx and ssh.

  The ones that run code other than Apple's tools get the disclaim too.
- **A deliberate grant stays possible.** A user who wants a tool in a pane to have Accessibility can grant it to that tool, and macOS asks under the tool's name.

## User Stories

1. As a Launchy user, I want granting Launchy Accessibility for Point at the screen to grant it to Launchy alone, not to every session in its panes.
2. As a Launchy user, I want a session's screen access to go only through Launchy's tools, so that what I set there holds.
3. As a Launchy user, I want a tool in a pane that needs a permission to ask for it under its own name.

## Implementation Decisions

- **One spawn.** A single function starts a process on a new pseudo-terminal with `posix_spawn`, a new session (as `PtyClient` does) and the disclaim. If the call is missing, it starts the process as today and logs that it couldn't disclaim.
- **Panes.** Claude, terminal and custom-app panes all start through it, direct or through zmx. SwiftTerm's view gets the terminal instead of starting the child.
- **Beyond panes.** The upgrade build's zmx session and the Phone page's server start through it too. Short runs of Apple's tools are left as they are.
- **The docs follow:**
  - SECURITY.md, Point at the screen's detail in Settings and `docs/agents/where-it-breaks.md` stop saying that every pane gets Launchy's grants, and say from which build panes don't;
  - ADR 0019 and 0021 get a dated correction.

## Testing Decisions

- **A spike first,** by hand in a pane, with Launchy granted:
  1. Through zmx. A zmx client started disclaimed, the daemon it starts and the command the daemon runs should all read `false` from both trust checks. `screencapture` should be refused, and the privacy service's log (`log show` on `com.apple.TCC`) should name the process or zmx, not Launchy.
  2. SwiftTerm. A view driving a terminal Launchy started should handle typing, resizing, exit and the alternate screen.

  If either fails, the option goes back to the user before building.
- **After building,** once the user restarts Launchy:
  - New Claude and terminal panes, with Keep sessions running on and off, should give a fresh binary `false` from both trust checks. `screencapture` and `osascript` to System Events should be refused, and the log shouldn't name Launchy.
  - Hey Launchy should still point, and Listening should still hear. Those are Launchy's own grants.
  - A Screen access session's `look`, `point` and `click` should still work, through Launchy.
  - A pane started before the change should keep the grants until its session is started again.
- **After each macOS update:** the first of these checks again.

## Out of Scope

- Permissioning for Launchy's tools. That is `sessions-cant-see-or-act-on-the-screen` option 01's follow-up, which this option enables.
- A per-pane exception that keeps Launchy's grants.

## Further Notes

- **Recorded on 2026-10-09** from the user's measurement, relayed by the coordinator, as the planned follow-up to `sessions-cant-see-or-act-on-the-screen` option 01.
- **Left to decide on acceptance:**
  - whether `--ask --app` refuses for good or asks the running Launchy over the socket like a session;
  - whether any short run needs the disclaim.
- **ADR, on acceptance:** pane processes are started responsible for themselves. It closes ADR 0019's correction ("every pane process is attributed to Launchy") for panes started since.
- **Verified in the code at 9f24a4e:**
  - SwiftTerm's `startProcess` takes its `forkpty` path, with the `posix_spawn` path compiled out;
  - `PtyClient` in LaunchyPeer starts its child with `openpty`, `posix_spawn` and `POSIX_SPAWN_SETSID`;
  - nothing in `Sources/` or `Packages/` disclaims today.
- **Inferred:**
  - that a disclaimed process running Launchy's binary is still Launchy to macOS;
  - which other processes run code worth disclaiming.
- **Unverified:**
  - everything through zmx;
  - SwiftTerm with a terminal it didn't start;
  - the call's presence on every macOS Launchy runs on, which is checked at run time.
