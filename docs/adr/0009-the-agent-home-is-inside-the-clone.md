# The agent's Claude Code home is inside the clone

`CLAUDE_CONFIG_DIR` points at `.varnick/claude/` in the Live tree, one directory shared by every Session, gitignored. Skills, settings, and the transcripts Claude Code writes live there and survive a reaped Worktree. Your own `~/.claude` is neither read nor written by the agent, so nothing you run outside varnick is affected by anything it does.

Considered: one home per Worktree, which scatters skills and loses transcripts on reap; letting the Sandbox reach your real `~/.claude`, which makes the agent's mistakes yours.
