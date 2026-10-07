---
title: Starting a Claude session needs `>`, because typing searches
description: Whatever is typed into the panel searches History, bookmarks and sessions. A new Claude session needs `>` first, and the `#project`, `^host` and `@agent` words work only after it. The user wants typing to start a session, with search behind a prefix instead. As things stand, the common act is the one behind the prefix, and a prompt typed without `>` runs a search.
impact: Every new session costs an extra keystroke and a mode to remember. A prompt typed without `>` is treated as a search. ↩ opens whatever page or session tops the list, and after a pause the text goes to the relevance filter. On a Mac whose filter runs on TypeSafe, that sends the prompt to TypeSafe.
severity: low
evidence: The user's decisions of 2026-10-07, below. The launcher's code was read on 2026-10-07 at d5ee26e. This Mac's relevance filter is set to On this Mac (`defaults read`). A new install's filter is on and set to TypeSafe, and it runs whenever a key is set.
status: open
---

## Today

These were read in the code.

- **Typing searches.** Any query that doesn't start with `>` or `!` searches. At most 3 Claude sessions show under Sessions, this Mac's open ones first, and up to 40 pages show under Pages, with a preview pane and a footer. ↩ opens the top row. Once the typing pauses, a query of 3 characters or more goes to the relevance filter, on TypeSafe or on this Mac.
- **`>` asks Claude.** The text after `>` shows on the ask row. Its leading `^host`, `#project` and `@agent` words become badges, and suggestions show while such a word is being typed. ↩ starts the session, on this Mac or on the named one. No sessions or pages are listed in this mode.
- **`^host` counts only as the first word.** In `>#leeandco ^air fix the deploy`, `#leeandco` resolves among this Mac's projects and `^air` is sent as part of the message, so the session starts on this Mac.
- **`!` lists Launchy's commands.**
- **An empty field** lists the open tabs, the paired Macs' open sessions and 5 Recent sessions. ↩ opens the highlighted one. After ⌘N, the highlight is on the tab just left.

## What the user decided (2026-10-07)

1. **Claude is the default.** Typed text and ↩ start a new Claude session.
2. **`>` is removed entirely.** It isn't kept as a prefix that is accepted and ignored.
3. **`#`, `^` and `@` work directly, without `>`.** For example, `#leeandco ^air fix the deploy` and ↩ starts that session.
4. **`?` is the search prefix.** A leading `?` switches to today's search "across history pages and favorites" (the user's words), and ↩ opens the top result. Only a leading `?` counts: a question that ends in `?` is a prompt.
5. **Matching sessions still list as you type** in the default mode, below the prompt line. ↩ starts a new session, and ↓ then ↩ opens a listed one. The open sessions stay first.
6. **`!` commands are unchanged.**

## Left to decide

- What ↩ does when tokens are typed with no text after them, as in `#leeandco` alone, and whether tokens filter the session list.
- What the default mode lists: sessions only, or sessions and some pages, and how many of each.
- How the prompt line and the list look and move. The highlight starts on the prompt line, and ↓ moves into the list.
- What an empty field shows.
- Everything that reads the `>` mode today, and what each one becomes.
