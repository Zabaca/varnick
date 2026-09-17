# varnick

A desktop window around a coding agent. Developed on macOS; Linux untested.

The agent gets a git worktree, a terminal and no credential. You get a list of sessions, a button that fast-forwards the live tree to a session's branch, and a button that restarts the app onto it. An agent can press the same buttons through a loopback API.

Read [CONTEXT.md](CONTEXT.md) for the words and [docs/adr/](docs/adr/) for why. The previous version, a Tauri app, is on `main` and nothing here inherits from it (ADR-0001).

## The Credential

varnick will not launch without one. It lives in `secrets.yaml` at the repo
root, sops-encrypted to your age key and committed; the Host decrypts it at
launch, holds it in memory, and runs the Proxy that swaps the agent's
placeholder for it on the way to `api.anthropic.com` (ADR-0005). The agent never
sees it.

Set it up once:

```sh
brew install sops age                             # or your package manager
age-keygen -o ~/.config/sops/age/keys.txt         # prints your public key
```

Put that public key in `.sops.yaml` under the `secrets.yaml` creation rule
(the rule is there, commented, waiting for it), then write the file:

```sh
sops secrets.yaml
```

It holds one field, `credential`, whose value is either an `sk-ant-` API key or
an OAuth token from `claude setup-token`. The Host decides the kind from the
value's shape and the Snapshot of `host` reports that kind and never the value.

```yaml
credential: sk-ant-...
```

If `sops -d` fails, the launch stops and says so. `src/host/testdata/` holds a
fixture encrypted to a throwaway key so `deno task test` needs none of this.

## Sessions

A Session is opened by an Event, not a click: `POST /actors/sessions/events`
with `{"type":"NEW_SESSION","branch":"some-branch"}`. The Host adds the Worktree
at `.claude/worktrees/{branch}`, starts a zmx session of that name running the
agent with the Worktree as its cwd, and puts a ttyd on its own loopback port
attached to it. The Session's Snapshot carries the branch, the Worktree path and
the terminal's URL, and the page shows that terminal in an iframe.

The command the Session runs comes out of `Wrap` (`src/host/wrap.ts`), which in
v1 returns it unchanged — the one place a kernel sandbox would go (ADR-0004).
The agent's environment carries the Proxy in `ANTHROPIC_BASE_URL`, a placeholder
credential, `CLAUDE_CONFIG_DIR` at `.varnick/claude`, your git identity and the
Door's URL in `VARNICK_DOOR`; the Credential itself is not in it (ADR-0005).

A Session outlives the Host by design, so it is not stopped when varnick exits.
`deno task test` needs `git`, `zmx`, `ttyd` and `sops`; without any of them the
Session tests skip and say which is missing.

## Stack

- Deno 2.9 with `deno desktop`, system webview
- Vite + React for the page, XState 5 for the machines, in the host
- ttyd + zmx for the terminal, `claude` from your PATH
- sops + age for the credential
