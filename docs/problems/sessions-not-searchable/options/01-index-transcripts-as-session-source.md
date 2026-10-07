---
problem: sessions-not-searchable
title: Index every Claude transcript as a session source
summary: Each sync reads the Claude Code transcripts that changed and keeps one search row per session the user typed into, with source `session`, built from Claude's title, the user's prompts, its folder and when it was last used. Searching shows the top few session matches in a Sessions section above the page results, never sent to the reranker; picking one switches to its tab or resumes it in its own folder.
status: shipped
---

## Solution

Every minute the History sync also lists the transcripts in Claude Code's projects folder and rereads only those that changed since the last sync. From each it keeps what a search row needs: Claude's title for the session, the prompts the user typed (not Claude's replies), the folder the session runs in, the agent it was started as, and when the last prompt was typed. Each session becomes a row in the search store with its own source, `session`, embedded like a page, so keyword and semantic search reach it through the existing pipeline. Sessions started in a terminal are included, since they are on disk like any other. Subagent transcripts and sessions run by tools (no typed prompt) are left out.

Typing searches sessions and pages separately. Up to 3 sessions show in a Sessions section at the top of the results list, above the page results, so sessions are never ranked against pages, and they never go to the TypeSafe reranker. Picking a session switches to the tab that has it open, or else resumes it in a new tab in its own folder, as Recent does.

## Trade-offs

- **Every session the user typed into is reachable**, wherever it was started: 423 on this Mac against the 20 Recent keeps.
- **It depends on Claude Code's transcript format,** which is undocumented: the `origin`, `ai-title`, `agent-setting` and `cwd` fields. Launchy already reads `ai-title`. A Claude Code release that changes them would empty the Sessions section, not break page search.
- **The first sync after this ships reads every transcript once,** about 1.2 GB here. A prototype scan with the same line filter took 3 seconds with the files cached (Python, not Swift). After that, a sync rereads only transcripts that changed: here 12 changed in the last hour, 22 MB in all.
- **A matching session takes Return from the top page.** The selection starts on the first row, so when a session matches, Return resumes it instead of opening the top page. The similarity floor (below) keeps this to real matches.
- **Sessions are ordered by keyword and meaning only.** The reranker never sees them, so a session matched on a stray word can sit above a better one.
- **A session still running in a terminal outside Launchy can be resumed a second time in Launchy.** Launchy can't tell, and what Claude Code does with two processes on one session is unverified.
- **The search store now holds the user's prompts.** About 2.5 million characters here, in the same local database as History. Embeddings are computed on this Mac and the reranker never sees sessions, so prompts don't leave it.

## User Stories

1. As a Launchy user, I want to type a few words I remember asking Claude and see the session, so that I can get back to it however long ago it was.
2. As a Launchy user, I want sessions I started in a plain terminal to come up too, so that where I started a session doesn't decide whether I can find it.
3. As a Launchy user with the embedding model downloaded, I want sessions matched by meaning as well as by keyword, so that I find one without its exact words.
4. As a Launchy user, I want picking a session that's open in a tab to take me to that tab, so that I don't start a second copy.
5. As a Launchy user, I want picking a session that isn't open to resume it in its own folder, so that Claude carries on with the same files.
6. As a Launchy user, I want a session started as an agent to resume as that agent, so that it behaves as it did.
7. As a Launchy user, I want session matches shown apart from page results, so that I can tell a conversation from a web page and pages aren't pushed out.
8. As a Launchy user, I want each session row to show its title, its folder, when I last used it and the prompt that matched, so that I can tell similar sessions apart.
9. As a Launchy user, I want no session rows when no session really matches, so that the top row is still the page I'm after.
10. As a Launchy user, I want my sessions' titles and prompts never sent to TypeSafe, so that what I discuss with Claude stays on this Mac.
11. As a Launchy user, I want a session whose transcript is deleted to leave search within a minute, so that search follows what's on disk.
12. As a Launchy user, I want sessions run by tools (headless Claude Code, subagents) left out, so that the section holds only conversations I had.

## Implementation Decisions

**Finding transcripts**
- Each sync lists the files directly inside each folder of `~/.claude/projects`. Subagent transcripts sit one level deeper, in a `subagents` folder under their session's folder, so listing only the top level leaves them out.
- A transcript is reread only when its modification date or size differs from what the archive recorded. Every transcript read is recorded, including those that turn out not to be sessions, so that the ~2,600 tool transcripts here aren't read again until they change.
- A transcript is read line by line. A line is parsed as JSON only if it contains a marker for one of the lines below; every other line is skipped unparsed.

**What is read from a transcript**
- **Prompts**: lines of type `user` whose `origin.kind` is `human` and that aren't `isSidechain`. That leaves out tool results, task notifications, interruptions, skill bodies, compaction summaries, and prompts from hooks and the SDK. The text is the string content, or the text blocks of list content, without images. A slash command line (wrapped in command-name and command-args tags) becomes `/name args`. Prompts Launchy passes on the command line are marked `human` too (checked on 5 Recent sessions).
- **Title**: the last `ai-title` line's `aiTitle`, as Launchy already reads it for a session a pane leaves.
- **Agent**: the last `agent-setting` line's `agentSetting`, the `--agent` the session was started with (12 sessions here).
- **Folder**: the first `cwd` whose encoding (every non-alphanumeric becomes `-`, as Launchy already encodes folders) equals the transcript's folder name. A session can change directory, for instance by entering a worktree, and 145 transcripts here have several `cwd` values. Launchy finds a session's transcript, and so decides whether it can be resumed, from that encoding, so the session is resumed in that folder. Every session here has such a `cwd`.
- **Times**: the `timestamp` of the first and last prompt. The last one is the session's "last used". A file's modification date changes on every reply, but last used only changes when the user types.

**What gets no search row**
- A transcript with no prompt as defined above (2,595 here). It is still recorded in the archive, as not a session.
- A transcript with no `cwd` that encodes to its folder name (none here).
- A session whose folder no longer exists, because resuming it would fail (8 here, mostly deleted worktrees). The folder is checked at every sync, not only when the transcript is read, so a session drops out when its folder goes and comes back with it.
- One row per session id. A session that moved into a worktree can leave a copy of its transcript in each folder (9 ids here are in two folders); the most recently modified copy wins.

**Archive**
- A new archive table, `sessions`, has one row per transcript file: its path under the projects folder, modification date, size, session id, folder (empty when it isn't a session), title, agent, prompts, and first and last prompt time. It is created with the other archive tables, so existing databases gain it at the next launch.
- It mirrors the disk. A transcript no longer there loses its row at the next sync, and with it its search row and embedding. Claude Code deletes old transcripts on its own schedule, and those sessions leave search with them.

**Session rows**
- One search row per session, keyed `session:` plus the session id. That key can't collide with page keys, and it keeps the row's id across syncs, since rows are updated in place by key.
- Source `session`, with the badge name "Claude session" and Claude's symbol and colour, as Recent rows use.
- The title is Claude's title, else the first line of the first prompt cut to 80 characters, as a pane's label falls back to its prompt (80 of the 423 sessions here have no title).
- The description is the prompts, oldest first, separated by blank lines, each cut at 2,000 characters (89 of 5,830 prompts here are longer, mostly pasted logs and plans). It is what keyword search covers, what the row's snippet comes from and what the preview shows. No reply text.
- Tags hold the folder's name and the agent's name, with spaces turned into underscores as profile names are. In keyword ranking, tags weigh 4 against 10 for the title and 1 for the description.
- The URL field holds the session's folder path; the date shown is last used.
- The embedding text is the title, the folder's name, then the prompts oldest first, cut at 1,000 characters in all. The opening prompts say what a session is about. Once a session's first 1,000 characters are written its text stops changing, so an active session isn't re-embedded on every prompt, only when its title changes. Session embeddings are stored under the row key beside page entries and embedded in the same chunks. The cleanup that drops embeddings of entries that are gone has to count session keys as current; otherwise it deletes every session embedding on every sync.
- One refresh writes page and session rows in the same transaction and removes stale rows of both kinds. The refresh deletes every row it didn't write, so writing sessions anywhere else would have them deleted each time.

**Sync**
- Transcripts are read in the sync's first background step, beside the Chrome read, every minute.
- The archive signature also covers sessions, as a digest of the row fields (title, prompts, folder, agent, last used) of each session whose folder exists. A reply from Claude changes the transcript but not the row, so it costs a reread but no rebuild of the search rows; a folder going or coming back does rebuild them.

**Searching**
- Keyword and semantic search each run separately for pages (History and bookmarks) and for sessions, so neither takes the other's places among the 60 candidates. Sessions are fused the same way as pages (reciprocal rank fusion) and the top 3 shown.
- A session matched only by meaning shows only when its similarity reaches a floor, a named constant tuned by hand. Nearest neighbours always exist, so without a floor 3 unrelated sessions would top every search. Keyword matches always qualify.
- Sessions never go to the TypeSafe reranker: its candidates are page results only. The relevance divider and the "relevant" count apply to pages only.
- The `--search` command-line flag prints session matches above page results, with their similarity, to tune the floor.

**Panel**
- Session matches show at the top of the results list under a "Sessions" section label, the label the Tabs and Recent sections use, followed by the page results under "Pages". With no session match the list is as today.
- They go inside the results list rather than in a full-width band above it. That way the panel keeps its height, the preview stays beside the selected row, and the list already draws a section label ("Less relevant").
- Panel height: the results layout shows when pages or sessions match, in `panelHeight` and in the view alike, with no new height. A query that matches only sessions shows the results layout, not "No results".
- A session row shows the Claude tile and the title. Its second line is the matching prompt fragment, highlighted, for a keyword match, and otherwise the folder's name and when it was last used. It is marked when the session is open in a tab, and is as tall as a page row.
- The preview of a session shows its title, "Claude session", its folder path where pages show the host, when it was last used, its folder and agent as chips, and its prompts.
- The selection runs over sessions, then pages, starting at the first row. Refinement passes keep the user's pick by row id, as they do today.
- The footer puts the session count before the page count. The search field placeholder names sessions; check that it still fits beside the `>` and `!` hints.

**Picking a session**
- Return or a double-click on a session row: if a pane in any tab is on that session (its current conversation is the session id), switch to that tab and focus the pane, as `!transcript` does with its pane.
- Otherwise resume it in a new tab, the way Recent does. If Recent holds the session, that record is used, and the session leaves Recent. Otherwise a new record is made with the session's title, folder and agent, on that conversation, built the way a pane builds a record for the session it left after `/clear`.
- ⌘↩ on a session row does nothing; there is no link to copy.

## Testing Decisions

- There is no test target. Reading a transcript is a pure step: the file's lines and its folder name go in, and either a session (title, prompts, folder, agent, times) or "not a session" comes out. That step is the seam for a first test once a test target exists.
- By hand, after the user restarts Launchy and a sync has run:
  - Search a phrase from a prompt in an old session started in a terminal. It shows under Sessions, and Return resumes it in its own folder (the row's folder, and the pane's).
  - Search a session that's open in a tab: Return switches to the tab and focuses its pane.
  - Search a session that's in Recent: after picking it, it has left Recent.
  - Resume a session started as an agent: it runs as that agent.
  - Search something no session is about, such as a news site: no Sessions section. Tune the floor with `--search` until unrelated queries show none.
  - A query that matches only a session shows the results layout with no clipped rows or gap.
  - Delete a test transcript: within a minute it is gone from search.
  - Run a second sync and check that session embeddings were not dropped: `--search` shows sessions matched by meaning.
  - Check that the reranker's candidates hold no session: `--search` prints sources with relevance.
  - A sync with nothing changed still takes about a second.

## Out of Scope

- Claude's replies (option 03).
- Sessions run by tools, subagent transcripts, and sessions whose folder is gone.
- Showing a transcript in the panel without resuming it.
- Telling whether a session is running in a terminal outside Launchy.
- A command to copy a resume command, filtering by folder, a setting to leave sessions out of search, deleting sessions from Launchy.
- Changing what Recent keeps or shows, or listing more sessions when the query is empty.
- Renaming the `favorites` table and its store to match the glossary.

## Further Notes

- **No ADR.** As with bookmarks, this adds a source to the existing search pipeline and reads from disk what Claude Code already keeps, as ADR 0002 does for agents and projects. The rule most likely to be broken by a later change is that sessions never reach the reranker. Add it to where-it-breaks, under the search store, when this is built.
- **Glossary.** **Session** already means any Claude Code conversation, so sessions started outside Launchy need no new term.
- **Verified** on this Mac's transcripts (2026-08-05 to 2026-10-03) and in the code: the counts above; `origin.kind` `human` marking typed prompts, including Launchy's command-line prompts; a matching `cwd` in every session; the `agent-setting` and `ai-title` lines; ids in two folders; the refresh deleting rows it didn't write and the embedding cleanup deleting keys it doesn't know.
- **Assumed**: transcripts are compact JSON, one object per line, so the line markers match without spaces; reading in Swift is about as fast as the Python prototype; the similarity floor's value, which has to be found by hand.
- A `custom-title` line, set by renaming a session in Claude Code, appears in 1 transcript here. Letting it win over Claude's title would be a small follow-up.
