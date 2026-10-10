# Follow a pane's session with a SessionStart hook

Varnick starts each Claude pane on a session it names itself (`claude --session-id`), but `/clear` and `/resume` move the pane to a session Varnick never named, so after a restart it resumed the wrong one. Every Claude pane is now started with a SessionStart hook, passed with `--settings`, that writes the current session's id to a file in the pane's own folder under Varnick's support folder (it was the scratch area until ADR 0005); Varnick reads it, keeps it with the pane, and resumes that session. The session the pane left goes to Recent.

## Considered Options

- **Newest transcript in `~/.claude/projects/<folder>`**: rejected; several panes share a folder, so the newest transcript can belong to another pane.

## Consequences

Hooks passed with `--settings` are added to the user's own, not in place of them, so their SessionStart hooks still run.
