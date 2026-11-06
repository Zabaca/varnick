---
problem: sessions-cant-start-sessions-in-other-projects
title: "`tab_open` starts a Claude session in a Project, in a new tab behind the user's work, and answers with the name `SendMessage` takes"
summary: One more tool in the pane tools' set, so every Claude session in a Varnick pane gets it and the voice session, runs and headless hosts don't. It takes a project (as `#` names it, or its folder), an optional agent from that project and an optional first message, and opens a new tab at the end of the strip with one Claude pane there, started at once. The tab is not brought up: the panel, the tab on screen and the keyboard stay as they were. Permission checks follow `pane_open`'s rule unchanged. The reply gives the new pane's `s` id and the session's name as `ListAgents` and `SendMessage` know it, which Varnick reads from Claude Code's own file for the session id Varnick gave it, waiting up to 12 s. The new session is not told who opened it.
status: shipped
---

## Solution

**One tool, in the pane tools' set.** `tab_open` joins `pane_open` and `pane_close` on the `varnick` server, so the sessions that get those get it too: every Claude session in a Varnick pane, but not the voice session, a run, a Task step or a headless host's session (ADR 0031's amendment of 2026-10-17). No switch, as the pane tools have none. A session gains it at its next start or restart.

**What it takes:**

| Argument | Needed | What it is |
|---|---|---|
| `project` | yes | A **Project** as the panel's `#` word names it, without the `#`: its folder's name, or `group/name` when two projects share a name. Or the Project's folder as an absolute path. |
| `agent` | no | An agent found in that project's folder, as `@name` would find it there. |
| `prompt` | no | The new session's first message, at most 20,000 bytes as for `pane_open`. Left out, the session waits for one. |

- **Only a Project** (the user's decision): a git repository under Settings › Claude › Project folders, found as `#project` finds it. A worktree, a folder inside a project, Home and any other folder are refused. A name missing from the last scan gets one fresh scan before it is refused, so a repository cloned a minute ago is found. An ambiguous bare name is refused with the `group/name` forms that would work, and an unknown one with the projects whose names contain the word.
- **A folder Claude Code hasn't trusted is refused**, with the line a Task step gives: open a session there once and accept. Behind the user's work nobody would see Claude Code's question, and the session would wait on it with no notice.

**What opens.** A new tab on this Mac, at the end of the strip (under that project's row in the projects column), holding one Claude pane in the project's folder, as the agent named, with the prompt as its first message. It starts at once, as a paired Mac's start of a new tab does.

- **Not brought up.** The panel's view, the tab on screen, the keyboard and whether the panel shows are as they were. No tab is swapped in or out, so a hidden panel is fine. The user meets the tab in the strip, on the session board, in its notices (Done when it finishes, Needs you when it asks) and in the Phone page's open tabs.
- **An ordinary tab.** Saved and restored, its own Tab history, its own Done, which closes it alone. The caller's tab does not change.
- **Permissions: `pane_open`'s rule, unchanged.** The new session skips permission checks only while Skip permissions is on and the calling session was itself started skipping them, and is saved so that a later change of the setting never makes it skip. Otherwise it asks before its tools in its own tab. A caller that doesn't skip is asked by Claude Code before the call itself, since the tool is not on its allow list.
- **Not told who opened it.** The prompt goes to Claude as written. The opener puts what the session needs in the prompt, or sends the work with `SendMessage` after the open, and the new session's replies go to that message's `from`.
- **From a tab another Mac or the phone controls,** it is answered too: the new tab is this Mac's own, not labelled for that machine, and the reply says the user there finds it in this Mac's open tabs.

**What it answers.** For example: "Opened a new tab in kestrel, not brought up: s7, a Claude session as @builder. Its name for SendMessage is kestrel-4e." (made-up values), followed by one line on use: send it work with `SendMessage` to that name; with `notify_when_idle` the caller gets one notice when it has nothing left to do.

- **The `s` id** is the one `pane_read`, `board_read` and `show` take, and the one `board_read` lists for that session from then on. `pane_close` refuses it: it is in another tab.
- **The name** is Claude Code's own name for the session, read from the file Claude Code keeps for each running session on this Mac, matched by the session id Varnick gave the pane when it started claude, never by time or folder. Varnick waits for it up to 12 s, inside the 15 s the relay waits for any call. If it hasn't come by then, the call still succeeds (the tab is open) and the reply says the session is still starting and its name isn't known yet.
- **A refusal says what to change:** the project, the agent (with the ones found there), the prompt's length, or the trust.

## Trade-offs

- **The visible half of a cross-project helper, built from what exists.** A paired Mac's start of a new tab, the panel's `#project @agent` checks, and `pane_open`'s route, prompt limit and permission rule. No new request type, no protocol change, no new saved field.
- **It reads a file Claude Code doesn't document.** A renamed field, a moved folder or a Claude Code that stops writing the file leaves the reply with no name and no error beyond "not known yet". The pane, the tab and everything else work as before. This is the same kind of reliance as the transcript and hook fields Varnick already reads.
- **A name can change.** A `/rename` by the user, or Claude Code's own renaming, makes the opener's next `SendMessage` miss. A reply from the session carries its current address in `from`. Unverified: whether the derived name survives a Restart of the pane.
- **Behind, not in front.** The user learns of the tab from the strip, the board and its notices, and from what the calling session says. A caller that wants it up calls `show` with the reply's id, under `show`'s refusals (the panel hidden, Settings or the split picker showing, a key in the panel within 2 s). Bringing it up by default is option 03.
- **No cap**, as `pane_open` has none: each call is a tab and a Claude session on the user's subscription and memory, and a lead that opens five raises five Done notices. The tool's description says to open only what the user asked for or the work plainly needs.
- **Untrusted projects need the user once.** The first session in a newly cloned repository is the user's to start.
- **Only Projects.** A worktree is not a Project, so a lead can't open a tab in a builder's worktree (the builder makes its own), and Home is not one either.
- **A subagent can open a tab but not wait on it.** Claude Code allows `notify_when_idle` only from a session's main conversation, and a subagent's `SendMessage` replies go to that main conversation (Claude Code's own texts, not tried).
- **This Mac only.** A paired Mac's projects (`^mac #project`) are not reached.
- **No new power.** A caller that skips checks could already start a skipping `claude` in any folder from its Bash; this makes the session visible. A caller that doesn't skip is asked before the call and gets a session that asks too.

## User Stories

1. As the user, I want a session in Home to start a session in one of my projects in a tab of its own, so that I can watch it, type into it and mark it Done apart from the session that started it.
2. As the user, I want the new tab to leave my panel, the tab I'm looking at and my keyboard as they were, so that I keep working where I was.
3. As the user, I want it to start only in one of my projects, found as `#project` finds it, so that a session can't start Claude in any folder it likes.
4. As the user, I want the new session to run as the agent the caller named, from that project's agents, so that it follows that project's instructions.
5. As the user, I want the new session never to skip permission checks that the session that started it doesn't skip, so that opening a tab gives no more power than the caller has.
6. As the user, I want the new tab to come back after a restart and to show on the board and the phone like any tab, so that nothing about it is special.
7. As a session, I want the reply to give the new session's name as `SendMessage` takes it, so that I can send it work and wait for it to finish without guessing which session is which.
8. As a session, I want the reply to give the new pane's id, so that I can read its screen with `pane_read` and follow its turn with `board_read`.
9. As a session, I want a refusal to say what to change (an unknown or ambiguous project, an unknown agent, an untrusted folder, a long prompt), so that I can call again correctly or tell the user why not.

## Implementation Decisions

- **The sibling** is a paired Mac's start of a new tab on this Mac: a session record in the folder with the agent and the prompt, a tab made and appended to the strip without being shown, the session started at once, then a wait before the reply. The checks of the folder and the agent are the panel's `#project @agent` prompt's; the prompt's limit and the permission rule are `pane_open`'s.
- **The request** is Panel access's request with the new tool name, answered by the pane tools' router after its own checks (the version, Varnick starting, the calling pane, the hidden tab), so where-it-breaks › Panel access's rule that a new tool in the set goes through that router holds. The caller's tab's layout lock is not applied: `tab_open` changes no layout of that tab. The tool joins the list of tools answered in a tab another machine controls. The request's version stays, since only a tool name is new (inferred, as for `pane_open`).
- **The project** is resolved against the panel's project list as `#` resolves it; when nothing matches, one scan off the main actor, then the calling pane is checked again before anything is made, as the pane tools check again after a wait. A path is accepted only when it is a listed Project's folder.
- **The name** is read off the main actor from Claude Code's per-session files in its own folder (under `CLAUDE_CONFIG_DIR` when set, as the trust check finds Claude Code's config), taking only the name of the entry whose session id is the pane's, polled about every 100 ms. The file's other contents are never read into Varnick.
- **Permissions** are saved as `pane_open` saves them: off when the rule says no, following the setting when it says yes, never on.
- **The log** holds the tool, the outcome's kind, whether a name was found and the time: never a project, a prompt, an agent or a name.
- **The description** says what opens, that it is not brought up, that the session draws on the user's subscription, to open only what the user asked for or the work plainly needs, and how to message the session and wait for it.
- **Docs:** an amendment to ADR 0031 (a session now adds a tab, and Varnick reads a session's name from Claude Code's file), where-it-breaks › Panel access (the name read and what breaks it), the guide's paragraph on opening panes, `CONTEXT.md`'s Panel access entry, and the privacy doc's line on what sessions may do (a session can now start a session in any of the user's projects).

## Testing Decisions

- **No test target yet.** Where tests would go: resolving `project` (a bare name, `group/name`, a path, an ambiguous name, a worktree, Home, a folder outside the project folders), and picking the name out of sample session files by session id (a missing file, another session's file, an unreadable one). `make check-mcp` gains `tab_open`, listed only in the pane tools' set, with no clash.
- **Build:** `make build`.
- **By hand, after the user restarts Varnick,** in a session restarted after the build:
  - from a session in Home, `tab_open` on a project with a prompt opens a tab at the end of the strip and starts it; the panel, the tab on screen and the keyboard are unchanged, also with the panel hidden, and no other terminal changes size (`VARNICK_LOG_RESIZE=1`);
  - the reply's name is the one `ListAgents` lists for that session; `SendMessage` to it reaches it and its reply comes back; with `notify_when_idle` one notice comes when it is done;
  - with Skip permissions off, or from a caller that doesn't skip, the new session asks before its tools;
  - an agent from that project runs; an unknown project, an ambiguous bare name, a worktree, Home and an untrusted folder are refused, each with what to change;
  - Done on the new tab leaves the caller's tab open; after a restart of Varnick the new tab comes back;
  - from a tab the phone controls, the tab opens on this Mac and the phone lists it;
  - the voice session's `/mcp` doesn't list the tool, and a run's lists `notify` alone.

## Out of Scope

- `pane_open`'s reply, which stays as it is (the user's decision). A name for every session in `board_read` would close the same gap for `pane_open` without changing it, and is worth raising on its own.
- Closing a tab a session opened, or marking it Done.
- A paired Mac's or a headless host's projects.
- A worktree, a subfolder or Home as the folder.
- A terminal, a page, an app or a file in a new tab.
- Learning when the session is waiting or done beyond `SendMessage`'s `notify_when_idle` and the board's turns (`orchestration-lives-in-one-session` option 04's result files).
- The voice session, whose tools are `panes-open-only-by-hand-at-a-mac` option 01's open question.

## Further Notes

- **Verified in the code at 29551eb:** a paired Mac's start of a new tab appends the tab without showing it and starts the session at once; `#name` matches a bare folder name only when no other project shares it, else `group/name`; the project scan keeps git repositories with a `.git` folder and leaves worktrees out; a new Claude pane is started with the pane's id as its session id; the pane tools' set is given to every pane but the voice session's, runs' and Task steps'; `pane_open`'s permission rule and its saved form; nothing in Varnick reads Claude Code's session files today.
- **Read on the user's Mac, 2026-11-06 (Claude Code 2.1.319), not built on yet:** the per-session file and its name, the time it takes to appear (`problem.md`, Today), and `SendMessage`'s description of its recipient.
- **Unverified:** that the derived name stays the same across a Restart of the pane or a `/clear`; how long the file takes on a cold start of a large project (the 12 s wait assumes the measured spread).
- **The user's decisions of 2026-11-06** (relayed by the coordinator): a new tool, `tab_open`, not an extension of `pane_open`; the folder must be a Project under the project folders, as for `#project`.
- **Combines with** option 02 (Varnick names the session, in place of reading the name), option 03 (bringing the tab up), option 04 (telling the session who opened it) and option 05 (always asking). With `notify_when_idle` it covers most of `orchestration-lives-in-one-session` option 04's need: a lead opens its builders as panes the user can watch, and learns when each is done.
- **Open questions:**
  1. May a caller that skips ask for a session that doesn't (a `permissions: ask` argument, which can only ever lower)? Recommended: not now; option 05 is the stricter policy if the user wants it.
  2. Should the reply also give the `uds:` socket address, which `SendMessage` accepts and which a rename should not change? Recommended: no. The socket is named for the claude process (inferred from its form), so a Restart of the pane would change it, and the name is what `ListAgents` shows.

Follow-ups from the review (2026-11-06, verdict merge), for this option and option 04, built together:

- **should-fix:** the 12 s wait for the name is counted from inside the call, not from when the request arrived, so the controller lookup before it is not counted. If that takes over a second and the name never shows, the reply lands after the relay's 15 s timeout: the caller sees a timeout although the tab opened, and may call again and open a second tab. Count from the request's arrival.
- **should-fix:** in Wrap mode, a new tab that starts a new row in the strip grows its header and resizes every pane, the one on screen included, as a paired Mac's new tab already does. Run the hand check in Wrap mode too, then accept and document it or stop the strip resizing panes for a tab added behind.
- **should-fix:** the hand check after a restart (the full list in where-it-breaks, "By hand after a restart (tab_open)") is still owed.
- **nits:** the comment on the pane tool set still names only `pane_open` and `pane_close`; where-it-breaks' "What the tools do not promise" doesn't yet cover `tab_open`, whose open question (a project's own settings making a helper skip permissions) now reaches every project; the privacy doc leaves out the opener's tab title, which the fallback paragraph sends; the session-file read takes the first match by session id without checking that its process is alive (the paragraph's lookup rule recovers).
