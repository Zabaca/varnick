# Run a Turn against the Agent SDK

**Status:** ready-for-agent

**Blocked by:** 04

**Realizes:** `turn.sending`, `turn.streaming`, `turn.interrupting`, `turn.failed`, `turn.idle`

`runTurn` echoes the prompt back after 600ms. This slice sends the prompt to the running agent, streams the response into the machine as `STREAM_DELTA`, and reports real token usage so the context meter measures something.

Contract, unchanged: input `{ sessionId, prompt, model, effort }`, output `{ text, tokensUsed }`, a thrown `Error` whose message lands in `turn.failed`. `model` and `effort` come from the Session and are settable mid-turn — they apply to the next Turn and must not disturb the one in flight.

Two behaviours the machine already guarantees and the implementation must honour rather than reinvent:

- `INTERRUPT` keeps the partial. An interrupted Turn still said something, and discarding it loses work the user watched arrive.
- The composer stays live while a Turn runs. `EDIT_DRAFT` is handled at the machine root for exactly this reason.

Tool calls stream into the transcript here too — story 29 is the audit trail, and it is the difference between unattended work being auditable and being a black box.

**Done when** `#/states → streaming`, `→ interrupting` and `→ turn-failed` render against the real actor with no change to the component, and swapping the actor changes no state, guard, or transition. If it does, the model was wrong and the change belongs in stage 3.

Covers stories 27, 28, 29, 30.
