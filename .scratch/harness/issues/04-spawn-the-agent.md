# Spawn the agent process under `srt`

**Status:** ready-for-agent

**Blocked by:** 01, 03

**Realizes:** `agent.starting`, `agent.running`, `agent.crashed`

`spawnAgent` returns a fake pid. This slice starts the real Claude Agent SDK process with the established sandbox wrapping its whole process tree, and wires process exit back into the machine as `AGENT_EXIT` carrying a reason.

The start gate already exists and must not be re-implemented: `canStartAgent()` reads `credentialState` and `sandboxState`, and `START` falls through to `startRefused` when it does not hold. This slice supplies the facts, not the decision.

**Done when** killing the process externally lands the surface in `agent.crashed` with the real reason, `RESTART` brings it back, and the Session spawned at first `agent.running` is the same actor afterwards — the transcript survives the restart, which is the property that makes durability structural rather than a save loop.

**Refuses:** no fallback path that starts the agent when the sandbox is not established, under any flag, including a debug one.

Covers stories 1, 10, 24.
