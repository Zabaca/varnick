---
problem: search-names-sessions-differently
title: The board follows Claude's latest title, as it follows a /rename
summary: A pane takes Claude Code's latest `ai-title` as its name the way it takes a /rename name, so the card and search both show Claude's title. Search is unchanged.
status: rejected
reason: cards would rename themselves while the user works, and the board's name is the one the user knows
---

## Solution

A pane reads Claude's latest title from the transcript as it reads a /rename, and that title outranks the generated one. Card, tab and search then all show Claude's title, and search needs no change.

## Trade-offs

- Claude Code writes a new title as a conversation moves on, so a card's name would change under the user while they work.
- The generated title, which is the name the user learns from the board, would stop being shown wherever Claude has a title.

## User Stories

1. As a user, I want the board and search to use one name for a session.

## Implementation Decisions

- None. The option was rejected before it was planned.

## Testing Decisions

- None.

## Out of Scope

- Everything option 01 covers.

## Further Notes

- Rejected by the user on 2026-10-09, as relayed by the coordinator.
