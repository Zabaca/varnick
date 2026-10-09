---
title: A Claude session can only run on a Mac that runs Launchy
description: The user has a Linux box, a 24-core Ryzen, that runs no GUI and can't run Launchy's app. Option 01's first three tickets are built, so from either Mac the user starts Claude sessions that run on it in zmx, attaches to them and takes them over, ends or releases them, and finds its ended ones in Recent. What remains is search. The Ryzen's relay answers `rows` with nothing, so none of its conversations can be found from either Mac's search (option 01's ticket 4).
impact: A conversation held on the Ryzen can be found only by scrolling Recent, never by what was asked or said in it, while each Mac's own conversations, and a paired Mac's, come up in search.
severity: mid
evidence: The user's request of 2026-10-05. Read-only checks on the Ryzen over `ssh -o BatchMode=yes alex@linux-box` on 2026-10-05 (below). Code read at fd3d8be. The source of the user's existing fleet tooling (a separate repo) read for prior art: its decision records, shared scripts and terminal installer. The accepted live view, frozen-screen-not-live option 04. Nothing was installed or started on the Ryzen, and no zmx session or claude was run there.
status: open
---

## What the user wants

From either Mac:

1. Start a session that runs on the Ryzen.
2. Attach to it and take it over.
3. End it or release it.
4. Later: find its conversations in Recent and search.

The Ryzen runs no GUI and no Launchy app. On top of that:

- **A Mac is always in control.** The Ryzen has no keyboard of its own, so it shows no cards and keeps no tabs.
- **Its sessions show in each Mac's session list.** `^linux` in the prompt starts one there.
- **Peers still pair.** Hello, the protocol version check and the rule that only a paired Mac is answered all hold without an app on the Ryzen.
- **Nothing sweeps sessions there.**
- **Projects and agents** come from the Ryzen's own `~/.claude/projects` and filesystem.
- **It fits the accepted live view** (frozen-screen-not-live, option 04), whose fifth wish was to leave a Linux host possible.

## Today

Verified in the code at fd3d8be unless marked otherwise.

### What hosting needs now

- **The relay** is Launchy's macOS binary run as `Launchy --peer <base64 JSON>`, through a link at a fixed path the Mac's SSH command names: `$HOME/Library/Application Support/Launchy/launchy-peer`.
- **Protocol 7.** The relay answers some requests alone, from zmx and saved files: hello (offered to the app first), attach, status, screen, sessions, recent and rows. It hands `start`, `resume`, `end`, `projects` and `agents` to the running app over a Unix socket, and they fail without it ("Launchy isn't running on <Mac>").
- **The app starts each session** from its GUI login and keeps a pane for it in a background tab. That pane's own zmx client creates the session, and the asking Mac then attaches with take. The relay doesn't start sessions because claude's sign-in on a Mac needs the GUI session's Keychain (ADR 0007).
- **What the relay reads:** the identity and peer list from UserDefaults, open and ended sessions from `sessions.json`, session rows from the search database (SQLite), and the conversation from the host pane's hook file. It writes none of them, because the app owns them.
- **zmx** is the copy next to Launchy's binary, never one from PATH, with `ZMX_DIR=/tmp/zmx-<uid>`.

### What a Mac assumes about a host

- **No control label means the host is in control.** The card and the session list then name the host as the Mac in control.
- **Release** happens when the Mac in control closes a session that didn't come from it. It clears the label and detaches every client, and the host's card goes live. A session with no pane on the host is ended instead, since nothing would own it once released.
- **Following /clear and /resume:** `status` reads the conversation from the host pane's hook file, else the saved record. It sends a title only while the host is in control.
- **A session gone on its host** (after a reboot) is started again only into a pane the host restored and hasn't started.
- **Find Macs** probes only tailnet nodes whose OS is macOS. Adding by address works for any machine.
- **`^name` matches exactly** a peer's whole name run together, or one of its whitespace-separated words. A peer named `linux-box` answers to `^linuxbox` but not to `^linux`.
- **The hello** carries `keepSessions` and `running`, and a peer's row warns when Keep sessions running is off.

### Darwin-only in the relay's code

- **The app socket** uses `sun_len`, `SO_NOSIGPIPE`, `getpeereid` and Darwin's `write` and `accept`. A host with no app has no socket to talk to.
- **The SSH runner** imports CryptoKit. Only the calling Mac uses it.
- **App-only reads.** The identity reads a key from the Settings file (AppKit) and the computer name from `Host`. Zmx's "is it enabled" reads Settings. Saved records look up custom apps (AppKit).
- **The search database** and its transcript sync sit with SQLite and the MLX embedder.
- **Portable as written** (Foundation only): the protocol types, the zmx commands, the frozen screen's preparation, the transcript reader, project scanning, agent reading, and the attach's `execve`.

## The Ryzen, checked 2026-10-05

| | |
|---|---|
| Machine | Ubuntu 24.04.4 LTS, x86_64, 24 cores, 60 GB of RAM (27 GB available) |
| Tailnet | `linux-box.example.ts.net`. Tailscale 1.98.8 reports its OS as `linux`. Online beside it: the Air, the Studio and a VPS (also Linux). It serves the existing browser terminal on 443. |
| Login shell | `/usr/bin/zsh`, from the account record. A non-login SSH command runs in zsh with `~/.bun/bin` on PATH but not `~/.local/bin`. `.zshrc` adds `~/.local/bin`, so `zsh -l -i` finds claude. `.profile`, read by bash and not by zsh, is what sources the missing `~/.deno/env`. |
| zmx | 0.8.1, the same ghostty_vt build as the Macs, at `~/.local/bin/zmx`: a static ELF the existing browser terminal installed on 2026-09-14 |
| zmx folders | The existing browser terminal's sessions live in `/run/user/1000/zmx`. `/tmp/zmx-1000` exists, holding only an empty log made on 2026-10-05 at 02:49, and no sessions. |
| Claude Code | 2.1.285 at `~/.local/bin/claude`. It signs in from `~/.claude/.credentials.json` (mode 0600), and `settings.json` also sets an environment variable holding its token in its `env`. The user's own hooks are Notification, PreToolUse, Stop and UserPromptSubmit, with no SessionStart. |
| Transcripts | `~/.claude/projects` has 13 folders and 5246 top-level transcripts (880 MB). 5096 of them (818 MB) are the agentmemory service's headless runs, and 16 hold prompts the user typed. Reading all of them took 0.25 s with a warm cache. |
| Agents | 2 in `~/.claude/agents` |
| Projects | 48 git repos under `~/Projects`, at depth 5 or less |
| SSH | Tailscale SSH, which swallows exit codes. A command runs as a child of tailscaled, in a logind session scope (`session-c….scope`). |
| systemd | Linger is on. `KillUserProcesses` isn't set (Ubuntu's default is off, inferred). User units: a credential proxy, the browser terminal (ttyd and the Picker), and the claude-mem backups. |
| /tmp | `systemd-tmpfiles` removes entries older than 30 days (`D /tmp 1777 root root 30d`). |
| Tools | go 1.26.4, bun, node, python3, jq and git. No Swift and no sqlite3 command. |

**Not checked:**
- whether a zmx session created by an SSH command outlives the connection;
- what size a session created without a terminal starts at;
- Tailscale SSH's limit on channels per connection;
- whether tmpfiles leaves alone a socket in use that is older than 30 days (inferred that it does).

## The build Mac

On this MacBook Air:
- Swift 6.3.3 from the Command Line Tools, with no Xcode.
- No swift.org toolchain and no Swift SDK installed (`swift sdk list`).
- Bun 1.3.14, and no Go.

`make build` runs whichever `swift` is first on PATH. Swift's static Linux SDK works only with the swift.org toolchain of the same version, not with Apple's (inferred from swift.org's documentation, not tried).

## Prior art: the existing fleet tooling's Linux installs

The user's existing fleet tooling, a separate repo, already ships to the Ryzen:

- **A compiled binary.** Built on the operator's Mac for the host's OS and architecture, copied over SSH, and run as a systemd user unit with linger.
- **Installers in two halves.** A local script, and a far half piped into `bash -s` with a shared prelude. The far half reports results as `KEY=value` marker lines, because SSH and lima can swallow exit codes. Verify means reach it.
- **zmx 0.8.1** from the release tarball, checked against its published SHA-256, into `~/.local/bin`. Anything but x86_64 is refused.
- **Conventions:** an install root per capability; the login shell read from the account record; `XDG_RUNTIME_DIR` adopted from the user manager, because a non-login `bash -s` has none.
- **zmx without a terminal.** Its verify creates a throwaway session with `zmx attach` and no terminal. The client dies, and the daemon it started lives on.

## Not part of this problem

- Launchy's app, or any GUI, on Linux.
- Terminal, web, file and app panes on the Ryzen.
- The Ryzen calling a Mac.
- Chrome history on the Ryzen.
- Hosts other than the Ryzen, though nothing should limit the design to one.
