# 06 — Mirror the Session host-side

**What to build:** The transcript is written to a host-side store the developer can read and back up, alongside the Agent SDK's own persistence. Two stores deliberately: the SDK's is for resumption, the mirror is what survives a build the agent just broke and what gives the UI something queryable. A save that fails is visibly a different problem from a Turn that fails, and neither cancels the other.

**Blocked by:** None — can start immediately. `persistSession` takes `{ sessionId, messages }` and does not care where the messages came from, so this is demoable against the seeded Turn: send a message, quit, read it off disk. An edge to 05 was considered and dropped — it bought a nicer demo and serialised two independent slices.

**Status:** ready-for-agent

**Realizes:** `persistence.saving`, `persistence.saved`, `persistence.saveFailed`

**The storage mechanism is the open decision in this ticket**, carried unresolved from `PRODUCT.md` and the spec. Whatever is chosen must be inspectable by hand — "durable" that cannot be read is a claim taken on faith.

- [ ] The transcript is written at every Turn boundary
- [ ] The store is readable and backupable without varnick running
- [ ] A save failure surfaces as its own problem, distinct from a Turn failure — `#/states → save-failed` beside `→ turn-failed` is the check
- [ ] Retrying the save recovers without touching the conversation
- [ ] A save can fail while a Turn streams, and a running Turn never blocks a save
- [ ] No secret value reaches the mirror — durability of the Session must not become durability of the developer's keys

Covers stories 21, 22, 26.
