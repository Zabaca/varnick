---
title: Launchy's sessions can't be reached from the phone
description: The user's Claude sessions run on their Macs, and soon on a Linux box, and can only be seen, typed into or started from a Mac running Launchy. Away from the desk, from their Android phone (a Pixel 8a on the tailnet), they can't see which sessions run on a host, can't answer or take over one, and can't start a new one in a project with an agent.
impact: A session waiting on a question or a permission sits idle until the user is back at a Mac. Work can't be started from the phone, so ideas wait as well. The ways the user tried, Termux or an SSH app and Claude Code's Remote Control, are ruled out (below), so today there is no way at all.
severity: mid
evidence: The user's request of 2026-10-05. Code read at fd3d8be. Read-only checks on 2026-10-05, on the MacBook Air (`tailscale serve status`, `tailscale funnel status`, `tailscale status`, `tailscale whois` of the phone, the Tailscale variant, and the Bun, ttyd and zmx versions), and over SSH on the Mac Studio and on the Ryzen (the same serve and funnel checks, tools, services, and which user runs tailscaled). Prior art read in the source of the user's existing browser terminal (its decision record, installers and glossary). Nothing was installed, served or started.
status: open
---

## What the user wants

From the phone's browser, the way the user's existing browser terminal (a Picker and ttyd) already works for plain shells:

1. **See the sessions on a host:** which run, and which Mac (or the phone) is in control of each.
2. **Pick one up:** resume an ended one, or take over one that runs.
3. **Start a new one:** pick a project and an agent, type a prompt, and land in its terminal.

## Decided by the user

**In this request:**
- **A web page in the phone's browser,** like the existing browser terminal's Picker plus ttyd.
- **Not Termux or an SSH app:** "too many steps and awkward".
- **Not Claude Code's Remote Control.** The user likes it, but it doesn't work with the sign-in they use, `claude setup-token` (`CLAUDE_CODE_OAUTH_TOKEN`).
- **Linux hosts too.** The page must work on a headless Linux host, the Ryzen, which a plan being written now makes a host (`docs/problems/sessions-hosted-only-on-macs/`).

**Carried over from earlier problems:**
- **Control is a handoff.** One controller at a time, never shared typing (`sessions-tied-to-one-mac`).
- **Closing ends only what was started for the closer.** Closing in control ends a session the host started for the Mac closing it, and otherwise releases it to the host, which keeps running it. The host decides, by the session's origin (that problem's decision 6).
- **A session ended on purpose is never resumed automatically.**
- **The live view** (`frozen-screen-not-live`, option 04 accepted, not built) scales the controller's grid to fit and updates only while the window is visible.

## Today

Verified in the code unless marked otherwise.

- **Nothing in Launchy listens on a port.** Other Macs come in over SSH, through the relay (ADR 0007), and the relay talks to the running Launchy over an owner-only Unix socket.
- **The relay already has every operation the phone needs:**
  - for lists, `sessions`, `recent`, `status` and `screen`;
  - for control, `attach` (with take) and `end`;
  - for starting, `start`, `resume`, `projects` and `agents`.
  - `start`, `resume`, `end`, `projects` and `agents` need the running Launchy. The others need only zmx and the saved tabs.
- **Who may ask.** The relay answers everything but hello only when the request's `by` names a Mac in the saved peer list. `attach` also needs `by` to be a UUID, since it becomes a zmx label. The running Launchy checks the list again for `start`, `resume` and `end`.
- **A third controller is already handled as "someone else".**
  - On the host, a pane treats any `launchy-control` label but its own id as another controller and shows the card.
  - On a peer Mac, a pane takes control only when the label names that Mac.
  - So a label naming a phone would keep every Mac's pane on its card. The card would read "Controlled on another Mac", since an id not in the peer list has no name.
- **The origin rule works for any id.** The host's `start` and `resume` write the asker's id as the session's `launchy-origin`. Its `end` ends the session if the origin names the asker, and otherwise releases it.
- **The launch sweep spares only sessions labelled for a listed peer.** A session labelled for any other id, with no pane on the host, would be killed at the next launch. The host keeps a pane for every session it runs, so this happens only if that pane was closed.
- **Launchy already runs Bun servers,** in zmx and not as LaunchAgents: custom app servers (ADR 0005).

## Facts the options rely on

### Hosts and tools

Checked read-only on 2026-10-05.

**The MacBook Air**
- Tailscale 1.102.3, the standalone app. Its daemon runs as a system extension, as root.
- `tailscale serve` publishes `https://mac-mini.example.ts.net:8443` (tailnet only): `/` goes to 127.0.0.1:7682 and `/t` to 127.0.0.1:7681. That is the existing browser terminal. Funnel status lists only it, as tailnet only.
- Bun 1.3.14, ttyd 1.7.7 and zmx 0.8.1 (Homebrew) are installed.
- The only LaunchAgents of the user's own are the existing browser terminal's two. Launchy isn't one here.

**The Mac Studio**
- Homebrew's tailscale 1.92.2, whose daemon runs as root under launchd.
- The same existing browser terminal mounts on 8443, tailnet only.
- ttyd 1.7.7, and zmx 0.8.1 both from Homebrew and next to Launchy.
- Bun 1.3.14 and claude are on the interactive login shell's path.
- Launchy runs as a LaunchAgent, and the relay's link is in place.

**The Ryzen**
- Ubuntu 24.04.4, x86-64, tailscale 1.98.8 (daemon as root).
- `tailscale serve` publishes the existing browser terminal on 443 (`https://linux-box.example.ts.net`), tailnet only. It runs as systemd user units, the ttyd one with `KillMode=process`. Linger is on.
- zmx 0.8.1, claude, ttyd 1.7.7 and Bun 1.3.14 are installed. There is no Swift toolchain.

**On every host**
- Nothing is served on 8444.
- Bun 1.3.14 has `Bun.Terminal`, a pseudo-terminal with write, resize, raw mode and close. Checked with `typeof` on the Air and the Ryzen, never used.

### The tailnet

- **The phone** is a Pixel 8a (`phone-1` here), at 100.64.0.4, Android. It was last seen 21 hours before the check.
- **Every device has the same user.** `tailscale whois` of the phone's address gives its node name and the user's login (an email address), and every Mac in `tailscale status` belongs to the same user. So a header naming the user can't tell the phone from a Mac.
- **Two devices are tagged:** a VM and a VPS.

### What `tailscale serve` passes to the server behind it

Inferred from Tailscale's source and documentation. None of this was observed, since nothing was served (spike, step 1).

- **Who the user is.** For a device that isn't tagged, serve adds `Tailscale-User-Login`, `Tailscale-User-Name` and `Tailscale-User-Profile-Pic`. It first deletes any copies the browser sent. No header names the device.
- **Where the request came from.**
  - `X-Forwarded-For` carries the caller's tailnet address, and serve replaces any value the browser sent.
  - Serve also sets `X-Forwarded-Host` and `X-Forwarded-Proto`, and keeps the browser's `Host`.
  - The local `tailscale whois` turns that address into a device.
- **App capabilities.** With `--accept-app-caps`, serve also forwards `Tailscale-App-Capabilities`, which the tailnet policy's grants set per device or user.
- **A Unix socket can be the target.** `tailscale serve --help` on the Air lists `unix:<path>` for macOS and Linux (verified). Whether the Air's system extension may open a socket in the user's Library folder isn't known.
- **When to trust the headers.**
  - On a loopback TCP port, any local process can connect and send any header. That terminal's decision record says so, and drops its header check for that reason.
  - On a Unix socket that only the user can open, only the user's own processes and root can connect (file permissions, inferred). Those can already run zmx directly.

### Prior art: the user's existing browser terminal

Its decision record and setup scripts, read-only.

**What it is.** Each machine runs a Picker (Python, listing `zmx ls`) and ttyd, both on loopback, behind `tailscale serve`: the Picker at `/`, and ttyd at `/t` with `-b /t`, `-O` (check the websocket's origin), `-a` (arguments from the URL) and `-m 8`. ttyd runs a wrapper that:
- checks the name against `^[A-Za-z0-9_-]{1,32}$`;
- pins the locale;
- unsets `ZMX_SESSION`;
- runs `zmx attach`.

**The gotchas it records:**
- Funnel must be off. The installer checks that no line for its port lacks "(tailnet only)".
- ttyd's `-b` must equal serve's `--set-path`, or every asset 404s.
- `Tailscale-User-Login` isn't checked, because a loopback port lets any local process forge it. "If a machine is ever shared, the fix is a unix socket, not the header."
- systemd needs `KillMode=process`, or a restart kills every session under ttyd.
- An existing serve mount is never rewritten, only a missing one added. A port someone else holds is refused.
- The URL is derived on the machine from `tailscale status --json`, and verified from another machine, since a Linux host can't reach its own serve URL.
- ttyd's default exit signal detaches the client without ending the session.

**Why it can't simply be pointed at Launchy's sessions.**
- Its sessions live in launchd's temporary folder, apart from Launchy's `/tmp/zmx-<uid>`.
- Its name check refuses Launchy's 44-character names.
- It attaches without labels, so the phone would become a second keyboard.

### Phone browsers

Inferred from how Android Chrome behaves, not tested here (spike, step 3).

- **Backgrounded tabs.** Chrome on Android freezes background tabs and drops their websockets after a while. The page learns it is visible again through `visibilitychange`.
- **The server can't tell closing from backgrounding.** Either way, the websocket just closes.
- **The soft keyboard.**
  - Gboard has no Esc, Tab or Ctrl keys.
  - Its autocorrect and composition events are known to trouble xterm.js.
  - Claude Code needs Enter, Esc, Shift+Tab, the arrows and Ctrl+C.

## Not part of this problem

- Reaching a host from off the tailnet. Funnel stays off.
- A native app, and notifications when a session wants an answer.
- Pasting images from the phone.
- Terminal, web, file and app panes. Only Claude sessions.
- How a Linux host runs the relay and answers `start`. That belongs to `sessions-hosted-only-on-macs`. The page only needs that host to answer the relay's requests.
