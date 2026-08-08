# 05 — Run a Turn against the Agent SDK

**What to build:** A developer types a message, watches the answer stream in, sees the agent's tool calls as they happen, and can interrupt a wrong direction after seconds rather than minutes. Today the reply is an echo after 600ms. After this, the chat is a working Claude Code session.

**Blocked by:** 03 (needs a running agent).

**Status:** done

**Realizes:** `turn.sending`, `turn.streaming`, `turn.interrupting`, `turn.failed`, `turn.idle`

The actor contract is unchanged and comes from the prototype: input `{ sessionId, prompt, model, effort }`, output `{ text, tokensUsed }`, a thrown `Error` whose message lands in `turn.failed`.

- [x] Response text arrives incrementally, so working is distinguishable from hung
- [x] Tool calls appear in the transcript as they happen — this is the audit trail that makes unattended work reviewable rather than opaque
- [x] Token usage is real, so the context meter measures something
- [x] Interrupting keeps the partial: an interrupted Turn still said something, and discarding it loses work the user watched arrive
- [x] The composer stays live while a Turn runs, so the next instruction can be queued
- [x] A model or effort change mid-turn applies to the next Turn and does not disturb the one in flight
- [x] `#/states → sending`, `→ streaming`, `→ interrupting` and `→ turn-failed` render unchanged against the real actor
- [x] Swapping the actor changes no state, guard or transition. If it does, the model was wrong and the change belongs back in the machine stage

Covers stories 27, 28, 29, 30.

## How it was built

**The agent process gained a control channel, and that is the whole design.**
It was spawned with `stdin` closed and `stdout` inherited, so there was no way
to ask the confined session anything — which is why ticket 09 was tempted into
opening a second one. Both pipes are now piped: control requests in as
newline-delimited JSON, Turn events out, framed exactly like the runtime channel
beside it. `run-turn`, `next-turn-event` and `interrupt-turn` are answered by the
Rust host, because that is the process that spawned the agent.

**`credential.rejected` is routed, and no machine changed.** A Turn that fails
on authentication reports the tag `authentication`; the live actor sends
`CREDENTIAL_REJECTED` to the Harness from `hooks.ts`, which is where `AGENT_EXIT`
already comes from and for the same reason — it is something the world did, and
the layer that owns the machines is the one that can address two of them. The
Session still never sends to its parent.

**Carried out of ticket 02:** `credentialRejection()` has a caller —
`failureOfThrown` in `agent.ts` — and now recognises the Agent SDK's own
`authentication_failed`, which is how the SDK reports a refused credential.

Left open, deliberately: nothing asks the confined session for plan usage yet.
The channel a `get_usage` control request needs now exists; adding the kind is
ticket 09's work.
