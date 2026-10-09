---
problem: session-search-sees-only-the-start
title: Embed a summary with the opening prompts, one vector per session
summary: The text generator Launchy ships writes a paragraph summing up each session, and the session's one vector becomes its title, folder, summary, then the prompts cut at 1,000 characters as today. No exchanges.
status: proposed
---

## Solution

As in option 02, the text generator summarises each session on the Mac that holds its transcript, and the summary travels to the paired Macs with the session's row. Instead of adding a vector, the session's one embedding text becomes the title, the folder's name, the summary, then the prompts cut at 1,000 characters. Ranking is unchanged.

## Trade-offs

- **Better than today.** Fused mean reciprocal rank goes from 0.468 to 0.621 for descriptive searches and from 0.560 to 0.640 for short ones. The right session is among the 3 shown for 72% and 67% of searches, against 53% and 58% today.
- **Worse than option 01 on short searches** (option 01 is +0.086 [+0.049, +0.122] ahead), and level on descriptive ones (+0.042 [−0.005, +0.085]).
- **The least bias toward long sessions.** A long session outscores the target in 21% of descriptive searches, against 32% with option 01. A target with 1 or 2 exchanges' worth of text scores 0.63 and 0.65 ranked by meaning alone.
- **Option 02's language-model costs, and its accuracy and privacy questions,** without option 01's growth in vectors.
- **The summary is written again as a session grows**, so a long-running session's vector changes now and then; option 01's exchanges never change once done.

## User Stories

1. As a Launchy user, I want to find a session by what it was about as a whole, so that its later work counts as much as its first prompts.

## Implementation Decisions

- The summary as option 02 has it: the same recipe, schedule, columns and protocol field.
- The session's embedding text is the title, the folder's name, the summary, then the prompts, cut at 1,000 characters after the summary. The summary itself is uncut: at most about 1,600 characters in the eval, so the text stays far inside the embedder's context.
- `sessionSimilarityFloor` is checked again, since the longer text moves similarities.

## Testing Decisions

As option 02.

## Out of Scope

Exchanges, and the summary in keyword search.

## Further Notes

- The summary alone, without the prompts, lost to today on short searches about a session's start (−0.062 [−0.108, −0.013]), so the prompts stay. Today's text with the summary appended was level with this one.
