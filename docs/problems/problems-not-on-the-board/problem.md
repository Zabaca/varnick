---
title: Varnick can't show where each problem stands, or which sessions are working on it
description: A repo's problems and options say where each piece of work stands, and the Claude sessions in Launchy do that work, but nothing connects the two. The session board shows sessions by turn and nothing else. To see which problems are decided, being built or shipped, the user reads the files. Which session or subagent works on which problem is recorded nowhere; only the transcripts hint at it.
impact: With many sessions and subagents running at once, across Macs, the user loses track of what is being built and what waits on a decision. Statuses drift unnoticed (twelve options still said accepted after they were built). A link worked out from transcripts after the fact is a guess: the prototype needed weighted tiers and still couldn't tell a session that read a problem from one that worked on it.
severity: mid
evidence: The user's decisions of 2026-10-08, relayed by the coordinator. The prototype captured on the local branch `prototype/problems-kanban` at 74ff0cc (never pushed). Code read at c728ee4 (main) on 2026-10-08. Claude Code 2.1.295, installed here, read from the strings in its binary for its hook inputs and events; nothing was run. Option statuses checked against `git log --merges`, the root commit and the code; twelve were set to shipped in 58c1649.
status: closed
---

## What the user wants

A Problems view on the session board that says where every problem stands, and which sessions work on each, from records that are made on purpose rather than read back from transcripts. Decided on 2026-10-08, for every option below:

- **The view is the prototype's variant D.** A Problems tab beside Sessions on the board, holding a kanban with one card per problem in Backlog, Decided, Building, Shipped and Closed. A card shows the title only, session chips, and the severity on Backlog cards, which sort by severity. Opening a card shows the evidence for its column, and "Show evidence" opens it on every card. No slug, no option chips, no "last touched", no status toggle.
- **The files decide the columns.** Building is the only live state. Nothing is inferred from merges, tickets or transcripts.
- **No transcript reading for links.** A session is tied to a problem only by explicit actions and hooks: a work record per pane, kept as files in the pane folder beside the turn and stop files, set by a `/work` skill, by a hook on file writes under a problem's folders, and by the skills that create work. A subagent inherits its parent's record and can have its own. When a session ends, its links are copied into its saved record as history.
- **Building** is an option with a live session or subagent linked to it, or an unmerged builder branch tied to it.
- **Shipped is recorded,** by whoever merges, in the merge itself.

## Today

Verified in the code at c728ee4 unless marked.

### The board

- The session board (ADR 0010) is a view of the panel, like Settings: ⌘⇧B, `!kanban` or `!tabs` (LauncherModel.swift:106-107, 1956-1971, 2183-2224). It has a fixed height (LauncherModel.swift:288).
- It has one view: Running, Stopped and Completed, a card per Claude pane here, per session open on a paired Mac, per ended session and per session marked done (SessionBoard.swift:47-65, 222-248). Its header is the title and key hints (SessionBoard.swift:437-450).
- While it shows, it reads each pane's turn once a second on the main actor, by a stat of the turn file, and asks the paired Macs every 5 s (SessionBoard.swift:171-192).
- Nothing in Launchy reads `docs/problems/`.

### Problems, options and who sets a status

- The layout and statuses are in `docs/agents/issue-tracker.md`: an option is `proposed`, `accepted`, `in-progress`, `shipped`, `rejected` or `abandoned` (line 28); a problem `open` or `closed`, by hand.
- The orchestrator merges, with `git merge --no-ff`, then deletes the worktree and its branch (`.claude/agents/launchy-orchestrator.md:29`). Nothing in that step, or anywhere else, sets `shipped`. The builder reads the option and never edits it (`.claude/agents/launchy-builder.md:15`).
- Of thirteen options marked accepted on 2026-10-08, twelve were built: three merged that day (c869318, bf6fd5c, and 21be631 for an amendment), nine before the history was squashed into 253012d. The thirteenth, publishing the repository, waits on its last step, since origin is still private.
- Only this repository has a `docs/problems/` folder among the user's projects (checked on this Mac).

### What a pane's folder holds, and who writes it

- Each pane has a folder under Launchy's support folder. A Claude pane's holds the SessionStart hook's file (ADR 0001), the turn file and the `Stop` input (ADR 0010) (PaneFolder.swift:3-49).
- The hooks are one `--settings` value built in one place for every host (ClaudeCommand.swift:14-37), started by the app (ClaudeSession.swift:458-491) and by the headless relay (HeadlessLaunch.swift:40-42, 107). Each is a line of POSIX shell that writes by rename and exits 0; there is no jq in a hook's shell (ClaudeCommand.swift:64-92).
- claude gets `LAUNCHY_SESSION_FILE`, `LAUNCHY_PANE_ID` and `LAUNCHY_PROJECT` (ClaudeSession.swift:478-481). Every hook finds the pane folder from the first.
- Changing the hooks changes the claude command line. ADR 0010 states the cost: both Macs rebuilt, the headless relay reinstalled (ADR 0009), and sessions started earlier get the new hooks only once restarted.
- Launchy installs no skills. Scratch and Custom apps are skills in this repository (`.claude/skills/`).

### Peers

- A paired Mac's or the headless host's relay reads a pane's turn from its folder (`PeerTurn.read`, PeerProtocol.swift:20-28) and sends it in `status` and `sessions` (MacPeerHost.swift:165, 189; HeadlessHosting.swift:180, 201), as optional fields with explicit coding keys (PeerProtocol.swift:322-405). The protocol is 16 (PeerProtocol.swift:9).
- A project is a git repo under the project folders, worktrees left out, named `#name` or `#group/name` by its parent folder (Projects.swift:3-28; LauncherModel.swift:473-480). That is how a session's folder on another Mac is shown here too.

### Saved state and the search database

- A pane's record is a `SessionRecord` in `sessions.json`, where every field added since the first is optional so older files load (SessionStore.swift:7-126). When a Claude pane closes, its record goes to Recent and to Completed or an ended card (LauncherModel.swift:1700-1741, 1788-1801).
- Recent and Completed keep 20 each; ended cards have no cap (SessionStore.swift:141-161).
- The search database's tables are created if missing, and columns added if missing, at open (HistorySync.swift:37-154, 215-226). Its `sessions` table mirrors the transcripts and is rewritten from them (HistorySync.swift:73-86).

### Claude Code's hooks, for links

Read in 2.1.295's code. These are minified names, so this is a reading of the code, not a run.

- **Every hook's input** carries `session_id`, `transcript_path`, `cwd`, `permission_mode`, `agent_id` and `agent_type`. `agent_id` is "present only when the hook fires from within a subagent (e.g., a tool called by an AgentTool worker), absent for the main thread, even in --agent sessions". `agent_type` is there for a subagent, and on the main thread of a session started with `--agent`.
- **So PreToolUse and PostToolUse fire for a subagent's tool calls**, with its `agent_id`, and `session_id` is the session it runs in (inferred from the builder: it takes the session from the tool's context).
- **PreToolUse** adds `tool_name`, `tool_input` and `tool_use_id`. Exit 0 shows nothing and lets the tool run; exit 2 blocks it.
- **The file-writing tools** are Write, Edit, MultiEdit and NotebookEdit, Claude Code's own list of them. Write, Edit and MultiEdit name the file in `file_path`, NotebookEdit in `notebook_path`.
- **SessionStart**'s output (exit 0) goes to Claude. Its sources are startup, resume, clear, compact and fork.
- **SubagentStart** has `agent_id` and `agent_type`, and its output can add context for the subagent. **SubagentStop** has `agent_id`, `agent_type` and the subagent's transcript path.
- **No agent id reaches a Bash command's environment**: none is among the variables the binary names. Unverified, since nothing was run. So a script a subagent runs can't tell whose record to write; a hook can.

### What the prototype learnt

The prototype (`model.ts` on the capture branch) linked sessions to problems from the transcripts: reads, writes, searches and prompts that named a problem, weighted into "worked on", "involved" and "mentioned", with a cut for sessions that touched many problems. Building looked for a builder subagent active in the last ten minutes, or an unmerged branch it found the same way. It needed thresholds to be usable, and the user chose deterministic links instead.

## Unverified

- That `agent_id` reaches a teammate's tool calls the way it reaches a subagent's, and that SubagentStop fires when a teammate ends.
- That no environment variable gives a Bash command its agent's id.
- That Write, Edit and MultiEdit always pass an absolute `file_path`.
- How long the hooks this adds take on a busy Mac; they were never run.
