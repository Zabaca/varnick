# Mirror the Session host-side

**Status:** ready-for-agent

**Realizes:** `persistence.saving`, `persistence.saved`, `persistence.saveFailed`

`persistSession` resolves after 120ms and writes nothing. This slice writes the transcript to a host-side store on every Turn boundary, alongside the Agent SDK's own persistence. Two stores, deliberately: the SDK's is for resumption, the mirror is what survives a build the agent just broke and what gives the UI something queryable.

**The storage mechanism is the open decision in this ticket** — it is carried unresolved from `PRODUCT.md` and the spec. Whatever is chosen must be readable and backupable by hand, because "durable" that cannot be inspected is a claim taken on faith.

The `persistence` region is parallel to `turn` and stays that way. A failed save must not cancel a Turn, and a running Turn must not block a save.

**Done when** a save failure is visibly a different problem from a Turn failure — `#/states → save-failed` next to `→ turn-failed` is the check — and `RETRY_SAVE` recovers without touching the conversation.

**Refuses:** no secret value reaches the mirror. Durability of the Session must not become durability of the user's keys.

Covers stories 21, 22, 26.
