# 03 — Spawn the agent process under `srt`

**What to build:** The real Claude Agent SDK process starts with the established sandbox wrapping its whole process tree, and the surface reflects what the process actually does. Killing it externally shows the agent stopped and why; restarting brings it back with the conversation intact.

**Blocked by:** 01 (sandbox), 02 (credential) — the start gate reads both — and 15 (the renderer cannot reach the host without it).

**Status:** ready-for-agent

**Realizes:** `agent.starting`, `agent.running`, `agent.crashed`

The start gate already exists and is not re-implemented here: `canStartAgent()` reads the credential and sandbox facts, and `START` falls through to a refusal that explains itself. This ticket supplies the facts, not the decision.

- [ ] Process exit is wired back into the machine as `AGENT_EXIT` carrying a real reason
- [ ] Killing the process externally lands on `agent.crashed` with that reason shown
- [ ] Restart returns to `agent.running`
- [ ] The Session spawned at the first `agent.running` is the same actor after a restart — the transcript survives, which is the property that makes durability structural rather than a save loop
- [ ] `#/states → starting-agent` and `→ agent-crashed` render unchanged against the real actor
- [ ] No fallback path starts the agent when the sandbox is not established, under any flag

Covers stories 1, 10, 24.
