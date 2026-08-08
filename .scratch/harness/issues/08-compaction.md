# Compact the conversation for real

**Status:** ready-for-agent

**Blocked by:** 05

**Realizes:** `turn.compacting`

`compactSession` returns a one-line fake summary and resets the token count to 300. This slice makes `/compact` summarise the conversation through the model and return the real post-compaction token count.

Contract, unchanged: input `{ sessionId, messages, model }`, output `{ messages, tokensUsed }`, a thrown `Error` that lands in `compactError` while the Turn returns to `idle`.

The failure path is the interesting half and it is already modelled: a failed compaction returns to `idle` and states that the conversation is unchanged. Keep that literally true — the messages array must not be partially rewritten before the failure.

**Done when** the context meter drops by an amount that reflects the actual summary, `#/states → compacting` and `→ compact-failed` render against the real actor, and `/clear` still resets the transcript and the count together so the meter cannot disagree with the screen.

Covers stories 66, 67, 68, 69.
