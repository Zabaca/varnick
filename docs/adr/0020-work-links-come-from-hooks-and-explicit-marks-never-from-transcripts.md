# Work links come from hooks and explicit marks, never from transcripts

Which problem or option a Claude session, or one of its subagents, works on is recorded on purpose, as files in the pane's folder beside ADR 0010's turn file, and the Problems tab on the session board reads them. A **work link** is `none` (the default, and a state of its own), a problem, or an option of a problem, with the repository's main checkout so a builder in a worktree links to the same problem as a planner in the checkout. Problem and options: `docs/problems/problems-not-on-the-board/`; this records option 01. It is built in three branches: the tab from the files and branch ties, then this (the hooks, records, chips and saved links), then the peers' replies and the search database's history.

## Decision

- **Files.** `work` holds the session's record, `work.<agent id>` a subagent's own, and `work-log` is appended to by every hook that changes a record: when, who (agent id and type, or `-`), the link, and `origin` when the write created the problem. The record is what is live; the log is the history and the signal (the app stats the log once a second per pane and reads the records only when its date changes). A subagent with no record of its own works under its session's; when it ends its record is removed.
- **Links are made four ways and no other.** A `PreToolUse` hook on Write, Edit, MultiEdit and NotebookEdit links the writer to the problem whose folder (`docs/problems/<slug>/`, or `.scratch/<slug>/` of an existing problem) the file is in. It never replaces an option record. A `/work` skill (`.claude/skills/work`) checks its argument against the files and prints one marker line with a one-shot nonce, and a `PostToolUse(Bash)` hook writes the record from it, because only the hook input carries `agent_id`; `/work option` also ties the branch (`git config branch.<name>.launchy-option`, `issue-tracker.md`). `SubagentStop` removes the subagent's record. `SessionStart` adds one line for Claude about `/work` and the open problems, only in a repository that has both `docs/problems` and the skill.
- **Building** includes an option, not shipped, rejected or abandoned, that an open pane's record here names (the session's, or a subagent's of that session). A link to a shipped option is not live.
- **Chips.** A problem's card lists the Sessions cards whose links, live, logged or kept, name it. The cards are read once a second on both tabs, so the chips' dots stay current; only Sessions asks the paired Macs.
- **History.** When a pane closes, its log's links (and any live record the log lacks) go into an optional `SessionRecord.workLinks`, so ended and Completed cards keep their chips.
- **No transcript reading.** The prototype's links, weighted from reads, writes and prompts, needed thresholds and still couldn't tell reading from working.

## Considered Options

- **One link per session (option 02)**: not chosen; a subagent's link would be its session's, so an orchestrator would stay on the option its builder works on and the chips couldn't say who did what.
- **A hook on every Bash call that parses `/work` from the command**: rejected; the command carries no more than the arguments, and the validation lives in the script.
- **The script writes the record itself** (option 02): rejected; no agent id reaches a Bash command's environment (unverified, 2.1.295), so a script can't tell a subagent's `/work` from its session's, and only the hook input carries the id.

## Consequences

- The claude command line changes on every host (`ClaudeCommand.hookSettings`): `PreToolUse`, a `PostToolUse` entry for Bash, `SubagentStop`, and a SessionStart entry. Both Macs need a rebuild and the headless host a reinstall (ADR 0009); a session started earlier makes no links until restarted. The protocol stays at 16.
- Every host's Claude Code must ignore hook events it doesn't know, as ADR 0010 says; these four are events Claude Code 2.1.295 documents.
- Unverified in 2.1.295, and handled defensively: a teammate's tool calls may carry no `agent_id`, so its writes link the session; `SubagentStop` may not fire for a teammate, so its record, if it had one, stays until the pane starts claude again (`PaneFolder.clearSubagentWork`) or the session ends; `file_path` may be relative, and the hook resolves it against the input's `cwd`, ignoring the call when there is none.
- The links miss work that writes nothing: a session that only reads, or writes through Bash or an MCP tool, links only through `/work`. A write the user denies still links, since the hook runs before the tool.
- Each file write and each Bash call runs one more short shell, measured on this Mac with the hook's input on stdin: a typical Write costs 6 to 9 ms, 3 to 5 ms of it the shell's start-up; a 240 KB write that links costs 13 to 23 ms under sh and zsh, and dash about half. A reviewer measured up to about 60 ms for that last case. The hook runs before the tool and one grep reads all the keys it needs.
- A subagent killed without ending keeps its record until its session ends, or until the pane starts claude again, which removes it and logs an `end` line so the app reads the records again.
- A marker printed again, in a transcript read back or a log, links nothing: the hook accepts a marker once, by deleting its nonce's file. A subagent inherits its session's option record only for the problem that option belongs to; for another problem it gets its own record.
- A link's subagent types are kept (`WorkLink.agents`), so the opened card names them after the subagent has ended.
- The rules every hook follows, and the marker's form, are in `docs/agents/where-it-breaks.md`.
