---
problem: sessions-not-searchable
title: Search Claude's replies too
summary: Index the text of Claude's replies alongside the user's prompts, so a session can be found by something Claude said in it.
status: rejected
reason: "Deferred: prompts hold what the user asked, which is what they remember a session by. Replies are 4.3 times the text of prompts here (10.8 million characters against 2.5 million, before tool output), so they would bury the prompts in keyword ranking and multiply what is stored and embedded. Revisit if searching prompts proves not enough."
---

## Solution

As option 01, but each session row's searched text also holds the text blocks of Claude's replies (not tool calls, tool results or thinking).

## Trade-offs

- **Finds a session by its answer,** such as a command or a file name Claude suggested.
- **Much more text.** Replies add 10.8 million characters to the 2.5 million of prompts here. Keyword ranking normalises by length, so long sessions sink, and a word Claude used in passing matches as strongly as one the user asked about.
- **Embedding gains little.** The embedded text is capped either way, and the opening prompts say what a session is about.
- **More to reread.** An active session's row changes with every reply, not only every prompt, so search rows are rebuilt more often.

## User Stories

1. As a Launchy user, I want to find a session by something Claude told me in it, so that I can get back to the answer.

## Implementation Decisions

As option 01, plus the reply text in the row's description after the prompts, with a cap per session.

## Testing Decisions

As option 01.

## Out of Scope

Tool output and thinking.

## Further Notes

- Measured 2026-10-03 over the 423 sessions with a typed prompt, counting only reply text blocks.
