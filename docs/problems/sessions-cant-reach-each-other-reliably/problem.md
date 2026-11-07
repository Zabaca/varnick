---
title: A session can reach another only by a name that changes, and never on another Mac
description: A Claude session in a Varnick pane that wants to send work or a result to another session uses Claude Code's `SendMessage`, which takes the receiver's session name. That name is derived by Claude Code and changes whenever the session restarts, so a session opened with `tab_open` is told its opener's session id and a recipe to look the current name up with `claude agents --json`, and a lead that holds a helper's pane id (`s7`) has no way to send to it without a name. `SendMessage` reaches only sessions on the same Mac, so a session can't send anything to a session in a tab hosted on a paired Mac, although `board_read` lists those sessions with ids.
impact: Every send between sessions rests on a name that a Restart of either pane, a Varnick restart or a `/rename` makes stale, and the fix is a recipe the receiving session must follow from its system prompt, reading a list of every session on the Mac. A send to a stale name fails and suggests other names that only look alike. Work spread across Macs (a build on the Mac with the bigger disk, a lead on the laptop) can't be coordinated by the sessions at all: the user carries every result across by hand.
severity: mid
evidence: The user's request and chosen design of 2026-11-07, relayed by the coordinator (below), with a drawing of it kept outside the repository. Tests of Claude Code's channels on the user's Mac on 2026-11-07 (Claude Code 2.1.319), relayed by the coordinator, and four more by the planner the same day (Found in tests, below); the throwaway servers and logs are kept outside the repository. Claude Code 2.1.319's own code for channels, read the same day. Code read at main 2f6ddf2. Related: `sessions-cant-start-sessions-in-other-projects` (closed; its options 01, 04 and 06 shipped), whose return path this changes, and ADR 0031 with its amendments.
status: open
---

## What the user asked (2026-11-07)

Varnick becomes a Claude Code **channel**: a session sends a message to another Varnick pane, and it is pushed into that session unprompted, on this Mac and later across Macs.

## Decided with the user (2026-11-07)

Every option but 05 follows these (relayed by the coordinator):

1. **One MCP server per session, one router per Mac.** Every Claude pane already runs its own Varnick MCP server, which talks to the running Varnick; the server also delivers messages, and Varnick routes them by pane, whose id is stable across restarts, unlike Claude Code's names.
2. **A send tool, to a pane id, with text.** The receiver is told which pane sent it and answers with the same tool.
3. **Varnick's channel ships as a Claude Code plugin,** so the machine's policy can approve it and no pane starts with the development flag or its dialog. Varnick's entry joins the machine's policy (one admin password).
4. **`tab_open`'s return path moves to pane ids,** away from the opener's session id and the name lookup.
5. **Across Macs, through the link Varnick already has between Macs.** A later phase is fine.
6. **Set up with a switch, not a command** (later on 2026-11-07): one switch in Settings › Claude whose checklist fixes each missing piece with a button (the administrator password through macOS's own dialog) and ends with a live test, and a second switch for the user's other Macs. Options 01 and 02 say how.

Rejected by the user: pressing Enter through the development flag's dialog for each pane (kept only as a fallback). Not possible: putting the approval in Varnick's or the user's own settings, since Claude Code reads it only from machine policy (below).

## Today

Verified in the code at 2f6ddf2 unless marked.

**How sessions reach each other**
- A session reaches another on the same Mac with Claude Code's `SendMessage`, by the name Claude Code gives it. The receiver answers the message's `from` without being told the sender's name (tested 2026-11-06). Claude Code's own description of `SendMessage` (read, not tried) says a receiver running in a different permission mode holds a message for its user's approval and may let it expire, and that a session can refuse them.
- Names change: a restart kept a session's id and changed its name three times in a row (tested 2026-11-06). A send to an old name fails and lists names that merely look alike.
- `tab_open` gives the new session's name in its reply, read from Claude Code's undocumented per-session file by the session id Varnick gave it, waiting up to 12 s. It appends a paragraph to the new session's system prompt with the opener's session id and name at the open, and tells it to look the id up with `claude agents --json` when a send fails (option 04 of `sessions-cant-start-sessions-in-other-projects`). The paragraph and its fields are saved with the new pane and dropped when the pane moves to another conversation.
- The pane that opened a tab is also saved as an opened-by mark, which `tab_done` reads, and which is cleared once the user clicks, types or moves focus into the tab.

**What Varnick gives a session**
- Every Claude pane starts one MCP server, `varnick`, which is Varnick's own binary in relay mode with the pane's id as an argument. It answers each tool call by sending one request line to the running Varnick over a socket only the user can open, and printing the reply: one request, one reply, then the connection closes. It never pushes anything unasked, and it can't today: it reads its input one line at a time and answers.
- The server declares only tools. It answers the MCP protocol revisions up to 2025-06-18 and gives the newest it knows to a client asking for a later one.
- Which tools a pane lists is decided at each start. The pane tools (`pane_open`, `pane_close`, `tab_open`, `tab_done`) go to every Claude pane but the voice session, a run, a Task step and a headless host's session, with no switch.
- Ids are `s1`, `s2`… per calling pane, held in the running Varnick's memory: the same pane gets the same id at every read for that caller, a Restart of a pane keeps the table, and a Varnick restart resets every table. `board_read` lists every tab with a Claude pane, a paired Mac's included ("on" that Mac), each session with its id.
- Every pane's environment carries its pane id (`VARNICK_PANE_ID`).
- A tool call from a pane another Mac or the phone controls is refused, except for a fixed list (the pane tools and the reads that only describe).

**The link between Macs**
- A paired Mac sends a request as one SSH command that runs Varnick's relay with the request as an argument; the relay answers alone or passes it to the running app over the same socket. The SSH connection is kept open for 10 minutes and reused. Every request but a hello is answered only for a Mac or device the host lists. A request travels base64-encoded as one argument of that command (the phone page's relay caps its own at 120,000 bytes).
- Both Macs must speak the same protocol (34 now): a new request is a protocol change, and two Macs on different builds refuse each other's requests until both are upgraded.
- A tab lives on one host, which runs its sessions; another Mac shows it as a view and may control it (ADR 0034).

**Claude Code's channels (2.1.319)**
- A channel is an MCP server that declares `claude/channel` among its experimental capabilities and sends a `notifications/claude/channel` notification with the text and optional attributes. The session sees `<channel source="<server>" key="value"…>` around the text and acts on it, unprompted; it answers through any tool. Attribute names must be letters, digits and underscores.
- Claude Code registers the channel only when, in order: the server declares the capability; the connection runs on a protocol revision older than 2026-07-28 (a newer one "has no unsolicited notification path"); the login is Anthropic's own, not a third-party provider's; Anthropic's server-side switch for channels is on (it doesn't arrive while `DO_NOT_TRACK` is truthy; the user set it to "0" on 2026-11-07); machine policy has `channelsEnabled: true` (needed for Team and Enterprise plans, and for Console logins once any managed-settings file exists); the session was started with the server in its `--channels` list; and, for a plugin, the plugin's marketplace matches and it is on the allowlist, which is Anthropic's own list unless machine policy sets `allowedChannelPlugins`, which then replaces it.
- Machine policy is read only from root-owned places (`/Library/Application Support/ClaudeCode/managed-settings.json`, its `managed-settings.d/` folder, `/Library/Managed Preferences/`); user, project and `--settings` levels are ignored for these keys. The policy file is readable by the user. On 2026-11-07 the user wrote it with a test entry.
- A plugin loaded with `--plugin-dir` (no install) is named `<plugin>@inline` (read in Claude Code's code).
- A channel that is not registered drops its messages with no error to the server.

## Found in tests on 2026-11-07

By the coordinator (relayed): a throwaway stdio server, packaged as a plugin in a local directory marketplace and installed for one folder, with the session started with `--channels plugin:<plugin>@<marketplace>`: no dialog, no refusal, and a pushed line got an answer through the server's tool in about 7 s. Without the policy entry it was refused ("not on the approved channels allowlist"). An installed plugin's server runs from Claude Code's cache copy, so it can't find files beside it.

By the planner, in throwaway sessions driven in a terminal:
1. **A `--plugin-dir` plugin's server gets the pane id.** `${VARNICK_PANE_ID}` in the plugin's server arguments and environment expanded to the session's value, the server also inherited the variable itself, and the server ran from the plugin folder itself, not a cache copy.
2. **A `--plugin-dir` plugin passes the marketplace check.** Started with `--channels plugin:<plugin>@inline`, it was refused only at the allowlist step ("not on your org's approved channels list"), the step a policy entry clears. With an entry for it, registration is inferred from the code, not seen.
3. **A message that arrives mid-turn waits for the running tool, then joins the same turn.** Pushed 6 s into a 30 s shell command, it was read in the one model request after the command ended, in the same turn; nothing was interrupted. One that arrives while the session waits starts a turn at once (answers came 5 to 8 s after the push).
4. **How the message is framed decides whether it is acted on.** With a server that said only how to answer, one session acted on a first message and then declined a second ("messages from that channel aren't from you"), saying it shouldn't have acted on the first. With the server's instructions saying the messages come from the user's other sessions in Varnick and are never the user's approval, a session acted on a request (counted the files in its folder) and answered through the send tool, 8 s after the push. One run each.
5. **Varnick's hooks see it.** A message fires `UserPromptSubmit`, with the framed text as the prompt, and `Stop` at the end of the turn. The transcript keeps it as a user entry marked meta, with a channel origin.
6. **Claude Code first probes a new server with `server/discover`;** a server that answers "method not found" stays on the older protocol revision, where channels work.

## Where it fails

- **Names go stale.** Every restart of either session renames it; the opened session is taught a lookup to survive that, and the opener has no address for a session it opened beyond what the reply gave once.
- **The opener can't send to a pane.** It holds `s7` from `tab_open`, `pane_open` or `board_read`, and `SendMessage` takes none of them.
- **Nothing crosses Macs.** A session can see a paired Mac's sessions on the board and can't send them a word.
