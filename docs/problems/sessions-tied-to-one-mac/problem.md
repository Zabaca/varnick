---
title: A Claude session can only be used from the Mac whose Varnick started it
description: The user runs Launchy on two Macs. A Claude session runs in the zmx of the Mac that started it, and only that Mac's Launchy can show it, type into it, resume it or find it. From the other Mac the user can't start a session that runs on the first, can't pick up a session already running there, and doesn't see its conversations in Recent or search.
impact: Moving between the two Macs means leaving work behind. A session started on one Mac can't be continued from the other without going back to it, and a finished conversation can't be found or resumed from the other Mac. Long sessions, whose subagents and background work zmx now keeps alive, stay stuck on the Mac they started on.
severity: mid
evidence: The user's request of 2026-10-04 and the decisions recorded below. Code read at 1503840. zmx 0.8.1 read in its tagged source (the README, the client, daemon and IPC code, and the changelog). This Mac's tailnet read with `tailscale status --json` on 2026-10-04. Prior art read in the source of the user's existing browser terminal (its decision record, installer and shared scripts, and glossary). Nothing was run on the other Mac, which isn't reachable from here.
status: closed
---

## What the user wants

In this order:

1. Start a new Claude session from Mac A that runs on Mac B.
2. From A, pick up a session that is already running on B.
3. List and resume B's sessions from A, in Recent and in search.

## Decided by the user

- **Transport:** SSH over Tailscale, with keys.
- **Peers:** each Launchy knows about the other Launchy instances. They are peers, not a list of SSH hosts.
- **Control is a handoff, not shared typing.** Each session has one host, the Mac it runs on. Either Mac can take control of it, but only one Mac controls it at a time. The Mac not in control shows a snapshot of the session (a frozen screen, or "Controlled on <Mac>") with a Take over action. The user never types into one session from both Macs at once.

## Today

Verified in the code unless marked otherwise.

- **No remote code.** Nothing in Launchy runs `ssh`, listens on a socket or port, or talks to another Mac. zmx is the only persistence backend (ADR 0004; tmux was rejected there).
- **How a pane runs.** A Claude pane runs one local child process on a pseudo-terminal through SwiftTerm. With Keep sessions running on, that process is Launchy's bundled zmx attaching to `launchy-<pane id>`, labelled `launchy=1`, running `zsh -l -i -c 'exec claude "$@"'` with claude's arguments passed positionally. Its environment is deliberately minimal, plus `ZMX_DIR=/tmp/zmx-<uid>` and `ZMX_NO_DETACH_KEY=1`. claude gets `--settings` with the SessionStart hook, then `--session-id <pane id>` and the prompt for a new session or `--resume <id>`.
- **zmx is pinned** to 0.8.1 by the Makefile, and Launchy only uses the copy next to its own binary, which sits in the repo checkout's build folder. Where that is on the other Mac isn't known.
- Saved panes and Recent are in `sessions.json` in Launchy's Application Support folder.

### What is local only

1. **The launch sweep** kills every zmx session labelled `launchy=1` that no pane on this Mac owns. Run on B, it would kill every session A started on B. With a handoff, the panes on the host are no longer the whole set of owners.
2. **A client that exits is a pane that ended.** When a zmx pane's client process exits, the pane finishes: it closes, goes to Recent, and its zmx session is killed. A takeover detaches the other Mac's client, so as things stand the Mac losing control would kill the session it just handed over.
3. **Restore and Recent check for a transcript on this Mac.** A Claude pane is restored, and a record kept in Recent, only if its transcript is in this Mac's `~/.claude/projects`.
4. **Search reads this Mac's transcripts,** and also leaves out any session whose folder doesn't exist on this Mac.
5. **Following /clear and /resume.** The SessionStart hook writes the new session's id to `$LAUNCHY_SESSION_FILE` in the pane's folder, and Launchy polls that file on this Mac every half second. A session running on B writes it on B.
6. **Agents, projects and checks look at this Mac.** A resumed session's agent is dropped if its file isn't in the folder on this Mac. `#project` and `@agent` in the prompt come from this Mac's disk (ADR 0002). The zmx checks (is the session running, kill it) run this Mac's zmx.
7. **A pane's environment has no SSH agent.** Panes get a minimal environment, so an `ssh` started in one wouldn't find the user's agent socket unless it is passed in.
8. **Session prompts must stay on this Mac.** `docs/agents/where-it-breaks.md` says a session's search row holds the user's prompts, which must stay on this Mac and never reach a reranker. Wish 3 moves B's prompts to A.

## Facts the options rely on

### zmx 0.8.1, read in its source

- **Several clients can attach to one session.** One of them is the leader: the last client to send typed input (not terminal replies). Only the leader's size applies; the others' input is dropped until they type, which makes them the leader. A client that attaches when there is no leader becomes the leader and gets the screen restored at its size. That is shared typing with an implicit takeover, which the user doesn't want.
- **`zmx detach` detaches every client of one session.** It takes the session's name from `ZMX_SESSION` in its environment. There is no way to detach one particular client from outside. The session keeps running.
- **A detached client looks like an ended one.** attach returns no code either way, so the client exits 0. On the way out it writes a terminal reset (RIS plus colour resets), and on the way in attach clears the screen. A pane whose client is detached has its screen wiped.
- **`zmx history <name> --vt`** prints the session's screen and scrollback, with escape sequences, from the state zmx keeps, without attaching.
- **Labels** are key-value pairs kept in memory with a running session, set with `zmx set`, read with `zmx get`, or given at creation with `attach --labels`. They end with the session.
- **`zmx list`** reports how many clients each session has.
- **The README** says to use `ssh -t` (without a terminal the display breaks), and lists nested zmx across SSH (a zmx client on A wrapping an SSH to B's zmx) as unsupported, with corrupted cursor positions.
- **attach with `ZMX_SESSION` set switches the calling terminal** to the named session instead of attaching. Anything that attaches on its own behalf has to unset it, as Launchy already does for its own commands.
- **Each Mac's zmx only talks to that Mac's daemons.** Over SSH, B's zmx client talks to B's daemon and SSH carries the terminal bytes, so the two Macs' zmx versions don't have to match (inferred from the design). What both Macs must agree on is whatever Launchy-to-Launchy requests an option adds.

### SSH

- ssh joins its command arguments into one string that the remote user's shell runs. It doesn't pass the environment, apart from `TERM` in the terminal request and what `SetEnv` and the server's `AcceptEnv` allow. User text such as a prompt or the hook's JSON can't safely go through that string unquoted.
- `-t` gives the remote command a terminal. With one, `~.` typed at the start of a line closes the connection unless the escape character is turned off (`-e none`).
- `BatchMode=yes` makes ssh fail rather than prompt. The first connection to a host needs its key accepted.
- This Mac's ssh config has no entries for the other Macs, and sets `TERM` for every host (checked). Whether Remote Login is on on the other Mac isn't known.
- A Mac's files under Desktop, Documents and Downloads are closed to processes started over SSH unless Remote Login allows full disk access (inferred from macOS behaviour, not checked here).
- Whether claude started from an SSH login finds its login in the macOS Keychain isn't known. Local panes are started from Launchy's GUI login and find it.

### Tailscale on this Mac

- This Mac is the MacBook Air. `tailscale status --json` lists three other macOS nodes: a MacBook Pro and a Mac Studio online, a third Mac offline. The user runs Launchy on this Mac and on the Mac Studio. Listing macOS nodes doesn't say which of them run Launchy.
- Each node has a MagicDNS name (`<name>.example.ts.net`), and the status lists the SSH host keys some peers advertise.
- Tailscale doesn't carry multicast, so Bonjour can't find peers across the tailnet (inferred from Tailscale's documentation, not checked here).

### Prior art: the user's existing browser terminal

The user's existing browser terminal, from a separate tooling repo, gives every machine a persistent terminal over zmx (its decision record: "a terminal is a capability and Tailscale is its only door"). It doesn't use SSH for the terminal. A browser opens `https://<magicdns-name>:8443/`, which `tailscale serve` maps to a small Python page listing `zmx ls` (the Picker, with an `/api/sessions` JSON route) and to ttyd under `/t`, both bound to loopback. ttyd runs a wrapper that checks the session name against `^[A-Za-z0-9_-]{1,32}$` and then runs `zmx attach <name>` with `ZMX_SESSION` unset. SSH (`ssh -o BatchMode=yes`) and scp are used only to install it. The installer pins ttyd 1.7.7 and zmx 0.8.1, installs zmx from Homebrew on macOS and from a checksummed release on Linux, and names the binaries by absolute path. The URL is derived on the machine from `tailscale status --json` and registered in the tooling's machine directory only after it has been reached from the operator's Mac ("verify means reach it"; the directory knows a terminal is registered, not that it is up). Recorded gotchas: a non-login `bash -s` over SSH lacks the runtime folder zmx uses on Linux; read the login shell from the account record, not `$SHELL`; refuse to install over another service's port; check that Funnel doesn't expose the port; don't trust the `Tailscale-User-Login` header from a loopback port.

It is installed on this Mac. Its launchd job sets no `ZMX_DIR`, so its sessions live under launchd's temporary folder, apart from Launchy's `/tmp/zmx-<uid>` (read from its plist). Its 32-character name limit rejects Launchy's 44-character session names, which is why ADR 0004's option already left it out.

What carries over to Launchy: Tailscale as the only way in and nothing bound to the tailnet; `BatchMode` for every call made without a person; a name check before a name becomes an argument; `ZMX_SESSION` unset before attaching; one pinned zmx named by absolute path; MagicDNS names from `tailscale status --json`; a peer counts only once it has been reached. Where Launchy differs: SSH carries the terminal (the user's decision) into SwiftTerm, not a browser; each Mac uses the zmx bundled with its own Launchy, not Homebrew's; and peers are Launchy instances talking to each other, not machines registered in a directory.

## Not part of this problem

- Terminal, web, file and app panes on another Mac. Only Claude sessions.
- Reaching a Mac from outside the tailnet.
- Keeping two Macs' settings, projects or agents in sync.
