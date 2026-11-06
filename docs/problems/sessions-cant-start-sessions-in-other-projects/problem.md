---
title: A Claude session can't start a session in another project, or reach one it started
description: A Claude session in a Varnick pane can open a Claude session only beside itself, in its own tab and its own project (`pane_open`). A session in Home, or in one repo, that wants work done in another of the user's projects has no way to start a session there that the user can see. When it does open a helper, the reply names the pane (`s1`), not the session as Claude Code's `SendMessage` knows it, so the opener can't send it work or wait for it without guessing which session is which.
impact: Work across projects falls to the user, who types a `#project` prompt in the panel and pastes in what the lead session wrote, or it runs as a subagent or a background `claude` the user can't watch, answer or mark Done, and which dies with the lead (`orchestration-lives-in-one-session` has the costs). A helper opened beside the lead would be in the wrong tab anyway: its tab's project is the lead's, and Done on the lead's tab ends it too. Even within a project, a lead that opened a helper matches it to a `SendMessage` name by its start time in `ListAgents`, which picks the wrong session when two start together.
severity: mid
evidence: The user's request and decisions of 2026-11-06, relayed by the coordinator (below). Tests run the same day in Claude sessions on the user's Mac, relayed by the coordinator. Code read at main 29551eb. Claude Code 2.1.319's own session files and the texts of its `SendMessage` tool, read on the user's Mac on 2026-11-06 (figures kept to counts; no paths or names). Related: `panes-open-only-by-hand-at-a-mac` (closed; its option 01 left "opening a new tab" out of scope), `orchestration-lives-in-one-session` option 04, and ADR 0031 with its amendments.
status: closed
---

## What the user asked (2026-11-06)

A tool that lets a Claude session open a new tab holding a Claude session in another project. Today a session in Home can't start one in a repo under the project folders.

## Decided with the user (2026-11-06)

Every option follows these (relayed by the coordinator):

1. **A new tool, `tab_open`, not an extension of `pane_open`.** A tab's project is its first Claude pane's, and Done is a tab's, so a session for another project belongs in a tab of its own. `pane_open` stays as it is.
2. **The folder must be a Project under Varnick's project folders setting** (Settings › Claude, default `~/Projects`): the same rule the panel's `#project` new session follows.

Left open, for the options: what the tool takes and what it answers (an address the caller can `SendMessage`, not only a pane id); whether the tab comes forward or opens behind; how `pane_open`'s rule for skipping permission checks carries over; and whether the new session is told who opened it.

## Today

Verified in the code at 29551eb unless marked.

**How a Claude session starts in a project**
- A typed **Prompt** with `#name` starts a new tab in that **Project**, brought up. A Project is a git repository found under the project folders, a worktree (whose `.git` is a file) and hidden folders left out; `#name` is its folder's name, or `group/name` when two projects share a name, and an ambiguous bare name matches nothing. `@name` must be an agent found in that folder. The list is scanned at launch, when the folders change, and when the panel's field turns into a prompt.
- `pane_open` with `kind: claude` takes a folder that must be the caller's project or inside it (a worktree under it included) and puts the pane beside the caller, in the caller's tab. Its reply gives the pane's `s` id, its kind, and that it is not focused. A prompt is at most 20,000 bytes.
- `find_open` resumes an existing conversation in a new tab, in the conversation's own folder, as Return does on a search row. It is the only tool that makes a tab with a Claude session in another folder, and only for a conversation that already exists; it is refused while the panel is hidden.
- A paired Mac's `start` with no tab named makes a new tab on this Mac at the end of the strip, starts the session at once and does not bring the tab up, then waits for the session to run before it answers.
- A Task's Claude step can start in another folder, but as a **Run**, out of sight, with `notify` alone, and only while Tasks is on.
- The pane tools (`pane_open`, `pane_close`) are listed to every Claude session in a Varnick pane but the voice session, a run, a Task step and a headless host's session (ADR 0031's amendment of 2026-10-17). They have no switch.
- A new Claude pane a session opens skips permission checks only while Skip permissions is on and the calling session was itself started skipping them; it is saved so that a later change of the setting never makes it skip. where-it-breaks › Panel access says every new tool that starts a Claude session must apply the same rule.

**What Varnick knows of a session's name**
- Varnick starts every new Claude pane with a session id of its choosing, the pane's own id. It never reads the name Claude Code gives the session.
- Claude Code (2.1.319, read on the user's Mac) keeps a small file for each running interactive session in its own folder: the session id, the folder, a name and a messaging socket. In the 11 sessions running then, the name was set when the file was written, made of the folder's name and two hexadecimal characters (such as `home-4e`, made up). By the files' creation times against the processes' start times, to the second, the file appeared within 2 s of claude's start in 9 of the 11, and at 4 s and 10 s in the other two.
- `SendMessage`'s own description (read from Claude Code 2.1.319, not tried) says its recipient is "a peer session name from ListAgents, or an explicit `uds:<socket>` / `bridge:<session id>` address".
- Claude Code's own refusals (read, not tried) say `notify_when_idle` is only for Claude sessions on this machine, and only from a session's main conversation, not from a subagent or a teammate.

**Found in tests on 2026-11-06** (relayed by the coordinator, as found)
- A session can `SendMessage` another local session, and the receiver replies to the message's `from` without being told the sender's name.
- `SendMessage` with `notify_when_idle` gives one notice when the receiver has no turn and no background work left. It waited through a background subagent of 2 minutes.
- `pane_open` returned a pane id (`s1`), but `SendMessage` needed the session's name; the two were matched only by guessing from `ListAgents`' "started 2s ago".

## Where it fails

- **No visible session in another project.** A session in Home asks the user to type the prompt, or runs the work as a subagent or a background `claude`, which the user can't watch, type into, answer or mark Done. `pane_open` refuses a folder outside the caller's project.
- **The wrong tab even where it would work.** A helper beside the lead takes the lead's tab: the strip files it under the lead's project, its sessions join the lead's Tab history, and Done on the lead's tab closes it.
- **What was opened can't be reached.** The opener holds a pane id, while `SendMessage` and `notify_when_idle` need the session's name. Matching by start time is a guess.
