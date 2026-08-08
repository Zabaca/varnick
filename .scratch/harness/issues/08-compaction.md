# 08 — Compact the conversation for real

**What to build:** `/compact` summarises the conversation through the model and frees real context, so a long session can continue instead of hitting the window. When it fails, the conversation is explicitly unchanged rather than silently half-rewritten.

**Blocked by:** 05 (needs a real model call and real token accounting).

**Status:** done

**Realizes:** `turn.compacting`

Contract, unchanged: input `{ sessionId, messages, model }`, output `{ messages, tokensUsed }`, a thrown `Error` that records the reason while the Turn returns to idle.

- [ ] The context meter drops by an amount that reflects the actual summary
- [ ] A failed compaction leaves the messages literally untouched — not partially rewritten before the failure — and says so
- [ ] `#/states → compacting` and `→ compact-failed` render unchanged against the real actor
- [ ] `/clear` still resets the transcript and the count together, so the meter cannot disagree with the screen

Covers stories 66, 67, 68, 69.
