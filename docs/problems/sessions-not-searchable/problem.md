---
title: Claude sessions aren't searchable
description: The panel reaches a past Claude session only through Recent, which keeps the last 20 sessions that ended in a Launchy pane, shows 5 of them, and only while the search field is empty. Typing searches History and bookmarks alone. Older sessions, and every session started in a plain terminal, can't be found from the panel, though their transcripts stay on disk.
impact: To get back to a session the user has to remember which folder it ran in and resume it from there by hand, or start over and re-explain what the old session already knew. On this Mac that is 423 sessions the user typed into, against the 5 Recent shows.
severity: mid
evidence: Measured 2026-10-03 on the user's Mac. `~/.claude/projects` has 153 folders, 3,018 session transcripts and 842 subagent transcripts (1.7 GB; the session transcripts alone 1.2 GB), dated 2026-08-05 to today. Only 423 transcripts hold a prompt the user typed. Of the 2,595 that hold none, 2,575 come from tools that run Claude Code headless (claude-mem observers, the Hudson knowledge-base review, hooks). The 423 span 105 folders and hold 5,830 prompts (2.5 million characters); 343 have a title from Claude. `SessionStore.recentLimit` is 20 and `LauncherModel.recentShown` is 5.
status: open
---

When the search field is empty the panel lists open **Tabs**, then **Recent**. Recent holds sessions that ended in a Launchy pane, or that a pane left with `/clear` or `/resume`: at most 20 are kept and 5 shown. A session that falls off Recent is gone from Launchy. So is every session started in a terminal, which Launchy never sees.

As soon as anything is typed, the list gives way to search results, and search covers **History** and **Bookmarks** only. Not even an open tab or a Recent session can be found by typing its name.

Claude Code keeps each session's transcript as a JSON-lines file, in one folder per working directory under `~/.claude/projects`, and Launchy already reads them in two places: a session a pane leaves with `/clear` or `/resume` takes its Recent title from its transcript, and the prompt sorts projects by their newest transcript. The folder names can't be decoded back into paths, because every non-alphanumeric character of the path becomes `-`.

The search store isn't tied to Chrome. Each row has a source, keyword search covers its title, description and tags, each row has an embedding, and the History sync refreshes the store every minute.
