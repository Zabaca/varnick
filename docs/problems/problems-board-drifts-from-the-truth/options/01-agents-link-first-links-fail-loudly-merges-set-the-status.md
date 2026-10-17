---
problem: problems-board-drifts-from-the-truth
title: Agents link first, a link nothing recorded fails, a subagent keeps its link between rounds, and every merge sets its option's status
summary: Accepted by the user on 2026-10-17, relayed by the coordinator. The builder, planner and orchestrator definitions say when to run `/work`, pointing to `issue-tracker.md`. `/work` no longer says "Linked" before a hook has recorded anything. It asks for a second command that confirms the record, and that command exits non-zero, naming the cause, when the hook never took the marker. SubagentStop keeps a subagent's record aside instead of deleting it, and a new SubagentStart hook gives it back when the same subagent runs again, so a builder resumed with SendMessage is linked again. A nested helper with no record takes its parent subagent's, found through the metadata file Claude Code writes beside the helper's transcript, if a first check shows that file is there in time. Every merge that builds an option sets it shipped or in-progress, never leaves it accepted, and closes the problem when nothing is left. In-progress already puts a problem in Building, so partly built work stops showing as Decided with no change to the board's code. Ties and links to shipped or rejected options, deleted branches and dead panes are already ignored, and stay so.
status: shipped
---

## Solution

### The agent definitions say when to link

- **The builder** links before any other work: `/work option <slug>/<NN>` for the option its brief names, confirmed as the skill says. The definition points to `issue-tracker.md` › "Branch tie" for the rule and the git fallback rather than restating them.
- **The planner,** when the problem already exists, runs `/work problem <slug>` before it writes, so its edits through Bash are linked as well as its Write and Edit calls. A new problem needs nothing: writing its `problem.md` links the planner and marks the problem's origin. It points to `issue-tracker.md` › "Work links".
- **The orchestrator** names the option, as `<slug>/<NN>`, or the problem in every builder and planner brief, so the subagent's `/work` has its argument. Its merge step carries the status rule below, by pointer.

### `/work` says when nothing was recorded

The hook after Bash writes the record after the command has ended, so the script can't see its own result. `/work` therefore takes two commands:

1. **The first** checks its arguments, ties the branch, prints the marker, and says the link is being recorded. Its last line is the second command to run, naming its marker.
2. **The second** confirms. The hook deletes the marker's file when it takes the marker. If the file has gone and a record names the link, the command prints "Linked to …" and exits 0. If the file is still there, no hook took the marker. The command removes the file, so a later replay can't link, and exits non-zero. It says the session's claude was started without the work hooks: before they existed, with the Problems board switch off, or by a build whose marker differs. It says a restart of the session fixes it, and whether the branch was tied anyway.

Outside a Varnick pane the first command already knows that no record will be written. It says so, says whether the branch was tied, and exits non-zero.

The skill tells the agent to run both commands and report the second's output. A failed link doesn't stop the work: the branch tie still keeps the option Building.

### A subagent keeps its link between rounds

- **SubagentStop holds the record** instead of deleting it. The record moves to a name the reader skips, so it stops counting as live, and the log gets its `end` line as today.
- **A new SubagentStart hook gives it back.** When a subagent with a held record starts again under the same agent id, which is what a SendMessage resume is, the record returns and the log gets the link again. The card then shows the builder linked through every review round.
- **Held records go when the pane next starts claude,** with the subagents' live records, as today.

### A helper takes its parent's link, if a check shows it can

No hook input names a parent agent. Claude Code does write a metadata file beside each subagent's transcript, and for a nested subagent that file names the parent's agent id.

At SubagentStart, a subagent with no record of its own reads that file. If the file names a parent whose record names a problem or an option, the helper gets a copy of that record with its own agent type. A builder's Explore helper, or a fork of the builder, then shows under the builder's link. If the file is missing or names no parent, nothing changes: a subagent of the lead already works under the session's record.

This part is built only if the first check (Testing Decisions) shows that the file is there and holds the parent when SubagentStart fires. Otherwise helpers stay as they are, and `where-it-breaks.md` says so.

### Stale state

Most of this already holds, and stays as it is:

- **Deleting a branch drops its tie** (git removes the branch's config section).
- **The board ignores a tie** whose branch git can't count, or whose option is shipped, rejected or abandoned.
- **The board ignores a session record** whose pane isn't live, or whose option isn't open. So a dead pane's leftover record makes nothing Building.

What changes is the step that leaves state behind:

- **An option the user decides against,** built or not, is set rejected or abandoned with the user's reason, and its branch is deleted. That drops its tie. A branch that shows Building with no one working on it means its option's status is wrong, and the fix is the status, not the board.

### The merge sets the status

`issue-tracker.md` › "Who sets an option's status" changes from "a merge that leaves the option unfinished sets nothing" to:

- **Every merge of a branch that builds an option sets the option's status** in the merge commit:
  - `shipped` when nothing of the option is left;
  - else `in-progress`, with what is left named in the merge message.

  It never leaves an option it built `accepted`.
- **`in-progress` gains a second source:** a merge that leaves part of the option unbuilt, beside work started that no branch shows yet.
- **The same merge closes the problem** when it leaves no option accepted or in-progress and the shipped options solve the problem as its statement reads. The lead names the closing when it asks the user for the go-ahead, so the user's go covers it. A problem that still holds real work is restated instead, its title and description cut to what is left.
- **Closing leaves proposed options as they are.** The problem's status is what says nothing more is wanted, and the options stay on record if it is ever opened again.

The orchestrator's merge step says, in one clause with the pointer: the merge sets every option it built shipped or in-progress, and closes the problem when nothing is left.

### The board's columns

No code change. `in-progress` already puts a problem in Building, and its evidence line names the option. With merges setting `in-progress`, partly built work with no live branch is Building, not Decided.

## Trade-offs

- **Two commands for `/work`, against one.** One command can't check its own record, because the hook runs after it ends. Alternatives:
  - The script reads its claude's command line for the marker the hooks accept. That is fragile across ps, shells and the headless Linux host.
  - The hook prints a confirmation to Claude. That breaks the hooks' rule of printing nothing, and an agent misses a line that never comes.
- **Holding a record, against a reminder.** A SubagentStart hook could instead add a line telling a builder to run `/work` again. It would reach every subagent, Explore and reviewers included, and still depend on the agent doing it. Holding the record needs nothing from the agent.
- **The parent from an undocumented file.** The metadata file is Claude Code's own and may change. If it does, a helper falls back to today's behaviour, unlinked, and gets no wrong link. Pairing a helper with its parent by order instead, as the parent's Agent call followed by the helper's start, can pair the wrong two when two parents spawn at once.
- **Status from the merge, against status from git.** The board could look for merges naming an option. That means parsing commit messages, and it still couldn't tell a finished option from a partly built one. The merge already holds the knowledge, and the lead already edits the option there.
- **Closing in the merge** makes the lead judge "nothing left". The user's go-ahead covers the judgement, and a wrong close is a one-line revert. A problem left open under a false title costs more, because it misleads everyone who reads the board.

## User Stories

1. As the user, I want every builder linked to its option without the lead remembering to say so, so the board shows who builds what.
2. As the user, I want an agent told plainly when its link wasn't recorded, so a session with old hooks is restarted, not trusted.
3. As the user, I want a builder working on review fixes still shown on its option, so Building and the chips are true between rounds.
4. As the user, I want a builder's helpers shown under the builder's option, so the card names everyone who worked on it.
5. As the user, I want a merge that finishes an option to mark it shipped, and one that finishes part to mark it in progress, so the board never shows built work as Decided.
6. As the user, I want a problem closed by the merge that solves it, so solved problems leave the board's open columns without a catch-up.
7. As the user, I want an option I drop to stop showing Building, so an abandoned branch doesn't look like live work.
8. As the lead, I want the merge rule in my merge step, so I don't have to remember it from a doc read days ago.

## Implementation Decisions

- **The skill and its script.** The first command's output and the second command's checks are as above. The marker's form, its nonce file and the hook that takes it don't change. The second command finds the nonce in its arguments.
- **The hooks.**
  - SubagentStop renames the record instead of removing it. The held name doesn't start with the record prefix, so `PaneFolder.work` skips it.
  - SubagentStart is new in `ClaudeCommand.hookSettings`, with the Problems board switch, after any other entry of its event. It is the one hook that reads the input's `transcript_path`, so that key joins the hooks' one grep and its `case`, as `where-it-breaks.md` asks of a new key.
  - Both follow the work hooks' rules: POSIX sh, print nothing, exit 0, write by rename, and log every change so the app reads the records again.
- **Clearing.** `PaneFolder.clearSubagentWork` also removes held records, in the app and in the relay's launch, logging `end` as today when it removed any.
- **Hosts.** The hooks change on every host's claude command line, so a session started earlier keeps the old hooks until it restarts, as ADR 0020 records. The protocol doesn't change: records and logs keep their form, and a held record is never sent.
- **Docs, one meaning each:**
  - `issue-tracker.md`: the merge rule, `in-progress`'s second source, closing and its leftover options, the dropped option's branch, and `/work`'s confirmation.
  - The three agent definitions: one step or clause each, pointing to `issue-tracker.md`.
  - `where-it-breaks.md`: held records, SubagentStart and its key, the metadata file as an undocumented input, and the confirmation.
  - ADR 0020: an amendment for SubagentStop keeping the record, SubagentStart, and the parent's link.

## Testing Decisions

- **The first check, before the hooks change:** a throwaway `claude -p` run in a scratch folder, with hooks that append their input to a file there, run at the user's word since it uses their plan. Its prompt spawns a subagent, sends it a second message with SendMessage, and has it spawn a helper. It answers:
  - whether SubagentStart fires on the resume, with the same agent id;
  - whether the helper's metadata file exists and names its parent when the helper's SubagentStart fires;
  - which transcript `transcript_path` names in a subagent's hook.

  If SubagentStart doesn't fire on a resume, the held record isn't built. The orchestrator's definition instead says to start each SendMessage round to a builder with `/work option <slug>/<NN>`. If the metadata file isn't there in time, the parent's link isn't built.
- **A `make check-work`**, built like `check-slots`, with no Varnick, no claude and no network. It runs the work hooks' scripts under sh, and under bash, zsh and dash where present, on scratch pane folders with JSON inputs:
  - SubagentStop holds a record and SubagentStart gives it back;
  - a helper takes its parent's record from a metadata file, and with none takes nothing;
  - clearing removes held records;
  - `/work`'s second command succeeds once the marker's file is gone and a record names the link, and fails non-zero when the file is still there.

  TDD fits this: it is logic over files, checkable without the UI.
- **`make build`.**
- **By hand, after a restart (the user's call):**
  - a builder subagent linked, then resumed with SendMessage, keeps its chip and its option Building;
  - `/work` in a pane started with the Problems board switch off fails with the restart message.

## Out of Scope

- **Clearing a dead pane's session record.** The board already ignores it. A reopened tab bringing one back is unverified (problem.md).
- **Showing a tied branch's age** in the Building evidence, so a stalled branch is visible. Worth raising if a status still drifts after this.
- **Links from writes outside Write and Edit,** such as MCP writes or evals in agent-lab. The planner's `/work problem` covers its own Bash edits.
- **A reviewer or prototyper linking.** Their definitions stay as they are.
- **Why a lead's restart once removed a running builder's record.** Unverified (problem.md). The held record doesn't change it.
- **Home's problems.** Home has the skill but no problems, so its sessions, the voice session among them, have nothing to link to.

## Further Notes

- **Accepted 2026-10-17.** The user approved the audits' fixes and this problem with "ok lets do all", relayed by the coordinator. The catch-up of statuses and closings it calls for is already done, in 373f3bf.
- **First check, run 2026-10-17 on Claude Code 2.1.302.** SubagentStart fires on a `SendMessage` resume under the same agent id, so held records are built. `transcript_path` in a subagent's hooks names the session's transcript. The metadata file is not there when SubagentStart fires, for a top-level subagent or a nested helper, so ticket 4 (a helper taking its parent's link) was not built and helpers stay unlinked, as before. Reading the file at the helper's first tool call would work but costs a hook on every call.
- **Verified against inferred.** The board's rules, the hooks and the script were read at bda4a64, and git's dropping of a deleted branch's tie was checked. Claude Code's hook inputs, its SubagentStart event and its resume path come from reading the 2.1.302 binary, not from a run: the first check settles them.
- **Suggested tickets,** for `/to-tickets`:
  1. the first check;
  2. `/work`'s confirmation, with `make check-work`;
  3. held records and SubagentStart, after 1;
  4. the parent's link, after 1 and 3, only if 1 allows it;
  5. the docs and the three agent definitions, after 2 and 3.
