# 05 — Run a Turn against the Agent SDK

**What to build:** A developer types a message, watches the answer stream in, sees the agent's tool calls as they happen, and can interrupt a wrong direction after seconds rather than minutes. Today the reply is an echo after 600ms. After this, the chat is a working Claude Code session.

**Blocked by:** 03 (needs a running agent).

**Status:** ready-for-agent

**Realizes:** `turn.sending`, `turn.streaming`, `turn.interrupting`, `turn.failed`, `turn.idle`

The actor contract is unchanged and comes from the prototype: input `{ sessionId, prompt, model, effort }`, output `{ text, tokensUsed }`, a thrown `Error` whose message lands in `turn.failed`.

- [ ] Response text arrives incrementally, so working is distinguishable from hung
- [ ] Tool calls appear in the transcript as they happen — this is the audit trail that makes unattended work reviewable rather than opaque
- [ ] Token usage is real, so the context meter measures something
- [ ] Interrupting keeps the partial: an interrupted Turn still said something, and discarding it loses work the user watched arrive
- [ ] The composer stays live while a Turn runs, so the next instruction can be queued
- [ ] A model or effort change mid-turn applies to the next Turn and does not disturb the one in flight
- [ ] `#/states → sending`, `→ streaming`, `→ interrupting` and `→ turn-failed` render unchanged against the real actor
- [ ] Swapping the actor changes no state, guard or transition. If it does, the model was wrong and the change belongs back in the machine stage

Covers stories 27, 28, 29, 30.
