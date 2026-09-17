# No kernel sandbox in v1, and one place for it to return

The agent's process tree runs unconfined. What keeps it in its Worktree is the rule in ADR-0003 and Claude Code's own permission prompts; what keeps the Credential from it is the Proxy (ADR-0005). Both are advisory against a determined prompt injection, and that is accepted: an agent that wants your age key can read it.

`@anthropic-ai/sandbox-runtime` was probed and works under Deno 2.9.6, so this is a choice rather than a limitation. It was made because a kernel sandbox was the previous version's largest source of decisions and failures, because it is macOS-only and every Fredrin Worker on Linux would test something else, and because the one unverified assumption in v1, whether ttyd's websocket survives Seatbelt, would have gated every Session ticket on a spike.

The seam is kept. The command a Session runs comes out of one function, Wrap, which in v1 returns its input. A sandbox returns as a change to that function and a flag, with its own ADR, and nothing else in the Host has to know.

The network is open. `$HOME` is readable, so git and Claude Code find their own config; git identity and `CLAUDE_CONFIG_DIR` are still set explicitly (ADR-0009) so the agent's home is separate by default rather than by force.
