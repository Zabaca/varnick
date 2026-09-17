# Live runs in dev mode permanently; a Preview is a separate process

Live is `deno desktop --hmr -A` run from the Live tree, and promotion is a Restart of it. There is no compiled binary in the loop and no build artifact store: a bad Landing breaks the window and is undone with `git revert` from any terminal. A Preview is the same command run from a Worktree as a separate process with its own window and port, launched by the Host on request because a confined process cannot open a window on macOS. Its host code is the agent's and runs unconfined, which is accepted: you chose to preview it, and its agent is confined to that Worktree by ADR-0003 like any other.

Distribution, meaning a signed `.app` anyone can install, is deferred and not designed for.
