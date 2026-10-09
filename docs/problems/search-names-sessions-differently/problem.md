---
title: Search calls a Claude session by another name than the board does
description: The session board names a Claude session as its pane does, by the name given with /rename, else the title Launchy generated from the first prompt. Session search names it from the transcript, by Claude Code's latest title, else the first prompt's first line. The same session goes by two unrelated names, and the user, who knows it by its card, can't recognise it in search.
impact: Looking for an earlier session by the name the user remembers either misses it or turns up a row under an unfamiliar name. A /rename name or a generated title is matched only where its words happen to be in a prompt. The user falls back to searching for what they typed, scanning by folder and date, or starting over. Every session with a generated or /rename name has the mismatch.
severity: mid
evidence: Seen on 2026-10-09 in one pane, whose card showed its generated title while search showed Claude's title for the same conversation, two names with no word in common (the names stay out of this file). Reported by the user and relayed by the coordinator, who also relayed the choice between the options. Code read at 716ee79.
status: closed
---

## Today

Verified in the code at 716ee79, except under Unverified.

### The board's name

- A pane keeps one title record, for the conversation it is on (`TitleRecord`, SessionTitles.swift:6-16): the /rename name, the generated title or a failed mark. What it shows is the name, else the title while Session titles is on (`shown`, :15).
- The title is generated once per conversation, from its first typed prompt (`ClaudeSession.checkTitle`, ClaudeSession.swift:1072-1117). A /rename found in the transcript's tail outranks it (`checkRename`, :1121-1130).
- A running card shows the pane's label (SessionBoard.swift:315): that name when there is one, else Claude's terminal title (ClaudeSession.swift:1212-1231). A single-pane tab named with ⌘⇧R shows the tab's name instead. Ended and completed cards show the record's `title` (SessionBoard.swift:344, SessionStore.swift:75), which is the label as it was when the pane left the conversation.
- The record, title record included, is saved to `sessions.json` on every label change (LauncherModel.swift:1593, 1692-1704).

### Which conversation a record names

- A record names its current conversation only (`currentTitleRecord`, SessionStore.swift:69).
- When /clear, /resume or a clear-context continuation moves a pane, the conversation left behind becomes a Recent record of its own, with its title record and the name it showed, and the pane's record starts with none (`checkConversation`, ClaudeSession.swift:1030-1053; LauncherModel.swift:1751-1755).
- Recent keeps 20 entries and Completed 20; the ended list has no cap (SessionStore.swift:160-161). A conversation left behind goes to Recent only, so its name leaves `sessions.json` once 20 newer entries arrive (LauncherModel.swift:1759-1770).
- A pane here for a session on a paired Mac generates no title (`isOnPeer` in `checkTitle`); the host's pane for it does.

### Search's name

- The sync stores Claude's last `ai-title` as each transcript's title (HistorySync.swift:485-490; TranscriptReader.swift:99-101). The reader also finds the last /rename (`customTitle`, TranscriptReader.swift:102-104), but the sync doesn't store it. Nothing in the sync reads `sessions.json`.
- A session row's title is that title, else the first prompt's first line, cut at 80 characters (`sessionEntry`, HistorySync.swift:768-777, :25).
- `sessionEntries` (HistorySync.swift:740-766) is the one source of session rows. It feeds the digest that decides whether search rows are rebuilt (:846-851), the exchanges embedded for meaning, each of which starts with the title (SessionExchanges.swift:43-63), the search rows (HistorySync.swift:915-921), and the `rows` reply to paired Macs (:945-961).
- Keyword search weighs the title column 10, the prompts 1 and the tags 4 (KnowledgeBase.swift:84-85). The panel shows a row's stored title as it is (LauncherView.swift:505, 622, 1037), and a pane resumed from search takes that title (LauncherModel.swift:1427).

### Paired Macs

- A paired Mac's sessions arrive as `PeerSessionRow`s, whose `title` is the host's row title (PeerProtocol.swift:410-424), stored here as sent (HistorySync.swift:1187-1195). The protocol is 17 (PeerProtocol.swift:9).
- The relay answers `rows` from the search database, opened read-only (MacPeerHost.swift:108-129).
- The asking Mac reads each Mac in full once per launch, then only the rows whose transcript changed since its stamp (HistorySync.swift:1099, 956).

## Unverified

- That the host's pane for a session a paired Mac started always gets a title record: `checkTitle` needs the pane started, and a pane starts when it is first shown.
- How many conversations in `sessions.json` have a title record today. Not counted.
