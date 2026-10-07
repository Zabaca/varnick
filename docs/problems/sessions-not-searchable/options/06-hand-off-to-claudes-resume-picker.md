---
problem: sessions-not-searchable
title: Hand off to Claude Code's resume picker
summary: Open a pane running `claude --resume` with the query as its search term, and let Claude Code's own picker find and resume the session.
status: rejected
reason: The search happens in a terminal picker, not in the panel's search, and it has no matching by meaning. The picker starts in one folder, and whether it can search every folder's sessions is unverified, so it may not reach sessions from other folders at all.
---

## Solution

A command (or a row under the search results) opens a new tab whose Claude pane runs `claude --resume` with what was typed as the picker's search term. Picking a session in it resumes that session in the pane.

## Trade-offs

- **Almost nothing to build,** and it follows whatever Claude Code's picker does.
- **Two searches.** The user types in the panel, then searches again in a terminal UI.
- **Folder-bound.** The pane starts in one folder; reaching another folder's sessions depends on the picker (unverified).
- **No meaning, no section.** Sessions never appear beside page results.

## User Stories

1. As a Launchy user, I want to jump into Claude Code's session picker from the panel, so that I can resume a session without opening a terminal.

## Implementation Decisions

None worked out.

## Testing Decisions

None.

## Out of Scope

Searching sessions in the panel.
