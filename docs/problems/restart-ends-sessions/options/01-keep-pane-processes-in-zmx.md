---
problem: restart-ends-sessions
title: Keep pane processes in zmx
summary: Each Claude and terminal pane runs its process inside its own zmx session, so restarting, quitting or crashing Launchy only detaches it and the pane reconnects, screen restored, when Launchy is back. Closing a pane ends the session. Behind a setting, off by default, with a pinned zmx binary fetched by `make build`.
status: shipped
---

## Solution

zmx keeps a terminal process in a background daemon of its own, one per session, and lets clients attach and detach. On attach it restores the screen from a terminal state it keeps with libghostty-vt.

Each Claude and terminal pane gets a zmx session named after the pane (`launchy-` plus the pane's record id) and labelled `launchy=1`. Instead of starting the pane's command directly, the pane's terminal runs zmx attach with that name and the same command it runs today. zmx runs the command if no such session exists, and otherwise reconnects to the running one. When Launchy stops for any reason, the pane's client goes away and the process keeps running. When Launchy is back, the pane reconnects the first time it is shown. Closing a pane ends its zmx session. After a reboot or logout the sessions are gone, so the attach creates a fresh one with today's command: `claude --resume` for a Claude pane, a new shell in the last folder for a terminal.

It is behind a setting, off by default, until SwiftTerm's rendering of a reattached Claude Code screen has been checked on one pane. Launchy uses its own copy of zmx, pinned to one release and fetched with a checksum by `make build`, the way `mlx.metallib` is (ADR 0003). The decision and its alternatives are recorded in ADR 0004.

## Trade-offs

- **In-flight work survives** restarts, quits and crashes: tool calls, background subagents, background commands, and a terminal's dev server or build.
- **Quit no longer stops sessions.** A Claude session in the middle of a task keeps working, and spending tokens, while Launchy is closed. Closing the pane is the only way to stop it.
- **A new runtime dependency.** zmx is a prebuilt binary, not a Swift package. A zmx release that changes its IPC protocol can't talk to daemons started by the previous one, so bumping the pin ends running sessions once (they fall back to `--resume`).
- **A layer between SwiftTerm and the program.** Each pane adds a daemon process, and a reattached screen is zmx's snapshot redrawn by SwiftTerm. That rendering is unverified for Claude Code.
- **No exit codes.** zmx attach exits 0 however the session ended, so Launchy can no longer tell a failed start from a normal exit by its code.
- **Terminals come back live.** A restored terminal is the same shell, with its history and running command, not a fresh shell in its last folder. Fresh is now only the fallback.
- **Reboot and logout still end sessions.**
- **Shared with the user's own zmx.** The sessions sit in the socket directory the user's interactive zmx already uses, so `zmx ls` there lists them and their own zmx can attach to or kill them.

## User Stories

1. As a Launchy user with a long Claude session running subagents, I want `make run` to leave it running, so that its in-flight work isn't redone.
2. As a Launchy user, I want a Launchy crash to leave my sessions running, so that a bug in Launchy doesn't cost me work.
3. As a Launchy user with the LaunchAgent installed, I want `make install` and `launchctl kickstart -k` to leave my sessions running too, so that every way of restarting behaves the same.
4. As a Launchy user, I want to quit Launchy and find my sessions still there when I open it again, so that quitting isn't destructive.
5. As a Launchy user, I want a reconnected pane to show the screen as it was, so that I can carry on where I left off.
6. As a Launchy user, I want closing a pane (⌘W, or closing its tab) to end its process for good, as it does today, so that nothing I closed keeps running.
7. As a Launchy user, I want a terminal running a dev server to keep it running across a restart, so that I don't restart it by hand.
8. As a Launchy user, I want a scratch page to keep serving across a restart, so that the browser pane beside the session doesn't drop out.
9. As a Launchy user, I want my panes to resume as they do today after a reboot, so that I am no worse off when the sessions are gone.
10. As a Launchy user, I want this off until I turn it on, and back to today's behaviour at the next launch when I turn it off, so that I can try it safely.
11. As a Launchy user whose build has no zmx, I want the setting to say how to get it, and my panes to run as today, so that a missing binary never breaks a pane.
12. As an agent running in a Launchy pane, I want to restart Launchy to try a change without ending my own session, so that I can check my work.

## Implementation Decisions

**Which panes**
- Claude and terminal panes run inside zmx. The live transcript pane stays a direct child: nothing in it is in flight, and a restart should pick up the new day's file. Web and file panes have no process.

**Naming**
- The session name is `launchy-` plus the pane's record id in lowercase, 44 characters. The record id stays with the pane across `/clear` and `/resume`, as the scratch area does, so the zmx session follows the pane, not the conversation.
- The `launchy=1` label is applied by the attach that creates the session, in one step, so a crash between creating and labelling can't leave an unlabelled session.

**Socket directory and environment**
- Every zmx command Launchy runs sets `ZMX_DIR` to `/tmp/zmx-<uid>`. Without it, zmx under launchd uses `$TMPDIR` while interactive shells use `/tmp`, so the `make run` instance, the LaunchAgent instance and the user's terminal wouldn't see each other's sessions. A short directory also keeps socket paths under macOS's 104-byte limit (spike).
- `/tmp/zmx-<uid>` is also where the user's interactive zmx keeps its sessions. Sharing it means the user's zmx inside a Launchy terminal sees the same sessions as Launchy, and they can attach to a pane from a terminal.
- `ZMX_NO_DETACH_KEY=1` disables ctrl+\, which would otherwise detach the client. A detach looks like the session ending, since Launchy watches the client process, and it would close the pane.
- The pane's client gets today's minimal pane environment plus those two variables. zmx starts the pane's command with the environment of the client that created the session, plus `ZMX_SESSION`. `LAUNCHY_SESSION_FILE` names a file in the pane's scratch folder, so the SessionStart hook still reports conversation changes to the same pane across reattaches.
- Launchy's other zmx commands (kill, list, get labels) run with an environment Launchy builds, not the one it inherited. A Launchy restarted from inside a pane inherits `ZMX_SESSION`, and possibly `ZMX_SESSION_PREFIX` from the user's shell config, and both change which session a zmx command acts on.

**Starting a pane**
- The command after the session name is exactly today's: a new Claude pane with `--session-id` and its prompt, a restored one with `--resume`, a terminal with a login shell in its folder. zmx uses it only when it creates the session, so a pane whose session is gone resumes or starts fresh as it does today, and a pane whose session is running ignores it.
- Restored panes stay dormant and attach when first shown, as today. Their processes run either way. Attaching on show means that after a reboot, when every session is gone, Launchy doesn't start every `claude --resume` at once. While a pane is dormant, its tab shows the saved title, and Launchy catches up on title and conversation when it attaches.

**Ending a pane**
- Whenever a pane ends while Launchy keeps running (⌘W, closing its tab, or its process exiting), Launchy kills its zmx session. Quitting Launchy, or Launchy being stopped by a signal, kills nothing. Ending only the pane's terminal process would detach the client and leave the session running.
- Each pane remembers, in memory, whether it was started inside zmx. Only those get their session killed, so changing the setting while panes are open doesn't affect how they close.

**Noticing the end**
- The pane's process is now the zmx client, which exits when its session ends or is killed, so the existing poll of the pane's process still closes the pane.
- The client exits 0 however the session ended, so a zmx pane reports its exit code as unknown. A Claude pane that ends within seconds of starting then still shows the failed-start error, with the code unknown, as it does today for a nonzero code.

**Sweep at launch**
- After tabs are restored and before the panel first shows, off the main thread, Launchy lists the zmx sessions named `launchy-<uuid>` that carry the label and kills those no restored pane points to. With the setting off it kills all of them, which returns to today's behaviour at the next launch.
- If the saved state existed but failed to decode, the sweep is skipped for that launch. A decode failure already drops every open tab. Without this guard it would also kill every running session.
- The sweep reads the short listing, which prints names only. The long listing prints each session's command, and a Claude pane's command carries a system prompt that spans lines, so its lines can't be parsed reliably (inferred).

**Scratch servers**
- With the setting on, a Vite server whose scratch folder belongs to a restored Claude pane is adopted at launch instead of killed. Launchy treats it as that pane's running server, so it doesn't start a second server on the same port. It stops the server when the pane ends and notices if the server exits on its own. Servers that belong to no restored pane are killed as today.
- With the setting on, Quit leaves Claude panes' servers running, since their sessions keep running too.
- The orphan pass runs after tabs are restored, because it needs the restored panes. Restored panes start only when shown, which is after this pass.

**Setting**
- "Keep sessions running" goes in Settings › Claude, after Skip permissions, off by default, as a UserDefaults boolean. The detail line says panes keep running when Launchy restarts, quits or crashes, and that closing a pane ends it.
- It applies to panes started after it changes. Turning it off ends Launchy's zmx sessions at the next launch, through the sweep.
- When Launchy's zmx binary is missing, the toggle is disabled with an orange note ("Needs zmx: build with make"), like semantic search's note for a missing `mlx.metallib`. Panes then run as today, even if the saved value is on. The sweep is skipped, since it needs the binary.

**Pinned binary**
- `make build` fetches the macOS arm64 tarball of a pinned zmx release from its GitHub releases, checks its SHA-256 against the value in the Makefile, and puts `zmx` next to Launchy's binary, where Launchy looks for it as it does for `mlx.metallib`. A stamp named after the checksum makes a new pin fetch again.
- The new binary goes in place by rename, so daemons still running the old one keep their file.
- Launchy never uses a zmx from `PATH`. Homebrew's copy upgrades on its own schedule, and a protocol change would end every running session.
- Pin 0.8.1, the version the spike used. Bump the pin deliberately: the first restart after a protocol-changing bump ends running sessions, and they fall back to `--resume`.

**Restart commands**
- `make stop`, which `make install` runs, matches Launchy's binary anchored to its path, as the restart script already does. Its unanchored pattern also matches any process whose arguments mention the build path, such as a Claude pane started with a prompt that names the binary. Today that goes unnoticed because everything stops anyway; with zmx it would kill a session that should survive (inferred).

**Docs**
- ADR 0004 records the decision. The dependency list in the coding standards adds zmx and points to it.

## Testing Decisions

- There is no test target. Two pure steps are the seams for first tests once one exists: building a pane's attach command line from its record and the setting, and choosing which sessions the sweep kills from the listing and the restored pane ids.
- By hand, with the setting on, after `make build`, starting with one pane, and listing Launchy's sessions with `ZMX_DIR=/tmp/zmx-$(id -u) zmx ls`:
  - Give a Claude pane a long task with a background subagent, then `make run`. After the restart the pane shows the session still working (the same claude pid), and the screen is intact.
  - In that reattached pane, check keys and rendering: typing, arrows, shift+enter, ⌘V of text and of an image, scrolling back, resizing the panel. zmx re-enables the Kitty keyboard protocol on reattach. SwiftTerm supports the protocol, but whether Claude Code behaves afterwards is the open risk.
  - Repeat with the LaunchAgent: `launchctl kickstart -k`, then `make install`. Repeat after `kill -9` of Launchy. Quit from the menu bar and reopen.
  - ⌘W on a pane, closing a tab of several panes, and `/exit` in Claude: each pane's session leaves the listing, and the Claude session goes to Recent as today.
  - A terminal running a long command keeps running across a restart.
  - A session with the label and a name no pane has is killed at the next launch. With a `sessions.json` that fails to decode, nothing is killed.
  - Turn the setting off and restart: every Launchy session is gone, and panes resume as today.
  - Move the binary aside: the setting shows the note, and new panes run directly.
  - A pane with a live scratch page keeps serving across a restart, with no "Waiting for…" page and no second server. Closing the pane stops the server.
  - With `claude` temporarily off `PATH`, a new Claude pane still shows the failed-start error.

## Out of Scope

- Surviving a reboot or logout.
- Turning the setting on by default, which waits on the hand check above.
- Relaxing the CLAUDE.md line that leaves restarts to the user. That waits until the setting is on by default.
- Keeping the live transcript pane in zmx.
- Attaching to Launchy panes through the user's ttyd and zmx-picker setup. Its attach script accepts names of up to 32 characters, and `launchy-<uuid>` is 44.
- A list of orphaned sessions, or a way to adopt one into a pane.
- Intel Macs. Only the arm64 binary is fetched, and MLX already needs Apple Silicon.

## Further Notes

- **Spike, 2026-10-03.** A throwaway LaunchAgent with the same `ProcessType Interactive` as Launchy's ran `script -q /dev/null zmx attach --labels launchy=1 launchy-spike-launchd <heartbeat loop>`.
  - `launchctl kickstart -k` on the job: the inner process survived (the heartbeat continued, same pid), and the restarted job's client reattached (clients=1).
  - SIGKILL of the parent holding the terminal, as in a crash or `pkill`: the inner process survived.
  - Under launchd, zmx put its sockets in `$TMPDIR/zmx-501` while interactive shells use `/tmp/zmx-501`, so instances started different ways wouldn't see each other's sessions. Hence the explicit `ZMX_DIR`.
  - The macOS Unix socket path limit is 104 bytes, and the `$TMPDIR` path with `launchy-<uuid>` is 101.
  - Not verified: SwiftTerm rendering a reattached Claude Code screen; `launchctl bootout` (part of `make install` and `make uninstall`), which the spike didn't try.
- **Read in zmx 0.8.1's source.** The daemon double-forks and calls `setsid`, which is why it outlives its parent. The session's command runs with the creating client's environment plus `ZMX_SESSION`. attach returns no code, so the client exits 0 whether it detached or the session ended. attach switches the calling terminal to the named session when `ZMX_SESSION` is already set. A socket path over the limit is refused with an error.
- **Read in SwiftTerm 1.20.** It implements the Kitty keyboard protocol, so zmx's re-enable on reattach reaches a terminal that understands it. A reattached pane starts at whatever size the view has when it first shows, and Claude redraws on the resize that follows; whether that leaves a clean screen is part of the rendering check.
- zmx shipped four releases between 2026-07-23 and 2026-09-05 (0.7.0 to 0.8.1). That pace is the reason for pinning, and the README lists protocol changes ending sessions as a known issue.
- The release publishes a `.sha256` beside each tarball. The Makefile pins its own copy of the checksum, as it does for the MLX wheel.
