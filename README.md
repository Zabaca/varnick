# varnick

A desktop window around a coding agent. Developed on macOS; Linux untested.

The agent gets a git worktree, a terminal and no credential. You get a list of sessions, a button that fast-forwards the live tree to a session's branch, and a button that restarts the app onto it. An agent can press the same buttons through a loopback API.

Read [CONTEXT.md](CONTEXT.md) for the words and [docs/adr/](docs/adr/) for why. The previous version, a Tauri app, is on `main` and nothing here inherits from it (ADR-0001).

## Stack

- Deno 2.9 with `deno desktop`, system webview
- Vite + React for the page, XState 5 for the machines, in the host
- ttyd + zmx for the terminal, `claude` from your PATH
- sops + age for the credential
