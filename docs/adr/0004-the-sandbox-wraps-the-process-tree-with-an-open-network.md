# The Sandbox wraps the whole process tree, permissions bypassed inside, network open

`@anthropic-ai/sandbox-runtime` wraps the terminal's command, so every process the agent spawns is under the same kernel policy, and Claude Code runs with its own permission prompts as a second layer that is not the boundary. It ran unchanged under Deno 2.9.6 in a probe on 2026-09-17, including the `$HOME` denial holding for a wrapped command.

The network is open. An egress allowlist was the previous version's first source of friction and its second source of ADRs, and with the Credential outside the Sandbox (ADR-0005) an open network gives the agent nothing to send. Narrowing is a later decision, and it would land like any other change.

`$HOME` is denied, so git gets its identity from `GIT_AUTHOR_NAME` and friends with `GIT_CONFIG_GLOBAL=/dev/null`, and Claude Code gets its home from `CLAUDE_CONFIG_DIR` pointing into the clone (ADR-0009). Nothing is generated or projected.
