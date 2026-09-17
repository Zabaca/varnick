# v1: a window around an agent

Status: ready-for-agent

## Problem Statement

I want to hand a coding agent real autonomy on my own machine and still be able to say in one sentence where its work goes. Running `claude` in a terminal puts its work wherever it happens to be and hands it my credentials. The previous varnick confined it with a kernel sandbox, but did so by letting the agent edit the tree the app ran from and then building fence after fence to stop that edit from becoming running code. Every fence was a decision, and the decisions became the work.

I also want the agent to be able to run varnick with me, or without me: open a session, land a branch, preview a change, restart. Today only a click can do those things.

## Solution

A window, built with Deno Desktop, that shows a list of Sessions and a terminal. Each Session is a git Worktree, a zmx session and a terminal running `claude` in that Worktree, with a placeholder credential the Host's Proxy swaps for the real one. There is no kernel sandbox in v1 (ADR-0004). The Live tree is only ever written by Landing, a fast-forward the Host performs on request. Restart promotes what landed. A Preview runs a Worktree's copy of varnick as a separate process.

Everything the window can do is an Event on a Machine whose actor lives in the Host, sent through one loopback API, the Door. The buttons, the agent and the tests all use it.

## User Stories

1. As a developer, I want to launch varnick from the Live tree with one command, so that promotion is a Restart and nothing is built.
2. As a developer, I want the window to list every Session, so that I can see what the agent is working on across branches.
3. As a developer, I want to open a new Session by naming a branch, so that a Worktree, a zmx session and a terminal running `claude` appear together.
4. As a developer, I want the terminal for the selected Session shown in the window, so that I talk to the agent where it lives.
5. As a developer, I want a Session to survive closing and reopening the window, so that an agent mid-task is not interrupted by my day.
6. As a developer, I want a Session to survive a Restart of the Host, so that promoting a change does not kill the work in flight.
7. As a developer, I want scrollback replayed when I reattach, so that I can read what happened while I was away.
8. As a developer, I want the agent started in its Worktree and told that is where its work goes, so that the Live tree is written only by Landing.
9. As a developer, I want the agent to have an open network, so that npm, GitHub and documentation work on day one without an allowlist to maintain.
10. As a developer, I want the agent to never hold my credential, so that an `env` dump or a logged configuration yields nothing usable.
11. As a developer, I want the credential kept in a sops-encrypted file committed to the repo, so that every clone carries it and only my age key opens it.
12. As a developer, I want the agent to use a Claude Code home inside the clone, so that its skills and settings are shared across Sessions and my own `~/.claude` is never touched.
13. As a developer, I want git in a Session to commit under my name and email, so that history is attributable.
14. As a developer, I want a Land button on a Session, so that the Live tree fast-forwards to its branch with one click.
15. As a developer, I want Landing refused when the Live tree is dirty, so that my own uncommitted work is never merged over.
16. As a developer, I want Landing refused when the branch is not a fast-forward, with the reason shown, so that I know to ask the agent to rebase.
17. As a developer, I want a Restart button, so that the Live Host relaunches onto whatever has landed.
18. As a developer, I want a Preview button on a Session, so that its Worktree's copy of varnick opens as a separate window before I land it.
19. As a developer, I want to reap a Session, so that its Worktree, zmx session and terminal go away together.
20. As a developer, I want reaping refused when the Worktree has uncommitted or unpushed work, so that finished work is not destroyed from outside.
21. As a developer, I want the window to rebuild its picture from git and zmx at launch, so that a Restart never shows me a stale list.
22. As a developer, I want a Session's state shown when it is in flight or has failed, so that a Landing that is checking or a Session that is being created reads as what it is.
23. As an agent in a Session, I want a command on my PATH that opens a new Session, so that I can hand work to another agent on another branch.
24. As an agent in a Session, I want to request Landing of my own branch, so that finished work reaches the Live tree without waiting for a click.
25. As an agent in a Session, I want to request a Preview of my own Worktree, so that I can try a change to varnick itself.
26. As an agent in a Session, I want to read the Snapshot of any Machine, so that I can see what the developer sees.
27. As an agent in a Session, I want the Door's URL in my environment, so that a Session opened by a Preview drives that Preview and not Live.
28. As a test, I want to drive a real Host through the Door against a temp git repo with no window, so that behaviour is proved without a human.
29. As a test, I want to substitute the `claude` executable with a stub, so that a Session can be exercised without a model.
30. As a developer reading the code, I want one Machine per thing that can be in flight or fail, and none for a plain list, so that the machines carry meaning.
31. As a developer, I want a state named in its Machine and nowhere else, so that the page and the docs cannot disagree with the code.
32. As a developer, I want a broken Landing undone with `git revert` from any terminal, so that recovery needs nothing varnick built.

## Implementation Decisions

**Runtime and layout.** One Deno 2.9 project. The Host is the `deno desktop` entry; the page is a Vite React app the Host serves as a static build in Live and under HMR in dev. Modules: host entry, door, machines, wrap, proxy, secrets, sessions (git plus zmx plus ttyd), page. Nothing runs in the webview except rendering.

**The Door.** A loopback HTTP API on a port chosen at launch. Actors are addressed by name. Read a Snapshot: `GET /actors/{name}`. Send an Event: `POST /actors/{name}/events` with the Event as JSON, responding with the Snapshot after the Event is processed. Subscribe: `GET /stream`, Server-Sent Events carrying every Snapshot change of every actor, each event tagged with the actor name. Deno Desktop bindings and `executeJs` are not used (ADR-0006).

**Machines.** XState 5, latest. Three actors at launch:

- `sessions`: holds the list and spawns one child actor per Session. A Session child has states for creating, running, reaping, and failed variants of each. Creating means: worktree added, zmx session started with the wrapped command, ttyd started attached to it. Its context carries branch, worktree path, ttyd URL and the last error.
- `landing`: idle, checking, refused with a reason (dirty, notFastForward, unknownBranch), landing, landed. Takes a `LAND` Event carrying a branch name and nothing else; the Host decides everything from that name.
- `host`: running, restarting, previewing. Takes `RESTART` and `PREVIEW` with a branch name.

A list is not a Machine. A state is named in its Machine and nowhere else (ADR-0010).

**Rebuild at launch.** `sessions` initial context comes from `git worktree list --porcelain` joined with `zmx ls`. A Worktree with no zmx session is shown as detached and can be reaped or reattached. Nothing is persisted (ADR-0007).

**Sessions.** The Worktree is `.claude/worktrees/{branch}` in the Live tree. The zmx session is named by the branch. The command zmx runs is Wrap applied to `claude`, with cwd the Worktree. One ttyd per Session, on its own loopback port, running `zmx attach {branch}`; the page shows it in an iframe. Reap is refused for a dirty or unpushed Worktree unless the Event says `force`.

**Wrap.** One function from the agent's command to the command a Session runs; in v1 the identity. It is the seam a kernel sandbox would occupy (ADR-0004). Environment for the agent: `ANTHROPIC_BASE_URL` at the Proxy, `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` set to a placeholder matching the Credential's kind, `CLAUDE_CONFIG_DIR` at `.varnick/claude` in the Live tree, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` from the developer's gitconfig read by the Host, `VARNICK_DOOR` set to the Door's URL. The `claude` executable is whatever `which claude` finds on the Host's PATH; a launch option overrides it for tests.

**Proxy.** A `Deno.serve` on loopback that forwards to `api.anthropic.com`, replacing the `authorization` or `x-api-key` header carrying the placeholder with the Credential. Any request without the placeholder is refused. No TLS termination, no allowlist.

**Secrets.** `secrets.yaml` at the repo root, sops-encrypted with age. The Host runs `sops -d` at launch and holds the Credential in memory. The kind is decided from the key's shape: an `sk-ant-` API key or an OAuth token from `claude setup-token`.

**Landing.** The Host runs, in the Live tree: refuse if `git status --porcelain` is non-empty; refuse if the branch is not an ancestor-forward of `HEAD`; else `git merge --ff-only {branch}`. The refusal reason is in the Snapshot.

**Restart.** The Host spawns a fresh copy of its own launch command from the Live tree, detached, then exits. Sessions are untouched because zmx and ttyd are not children of the Host; ttyd processes are adopted at the next launch by port recorded in a per-clone file under `.varnick/`, or restarted if gone.

**Preview.** The Host spawns the same launch command with cwd the Worktree, detached, with a different Door port. Its host code is the agent's (ADR-0008). Its Sessions are the same zmx sessions; each Session's `VARNICK_DOOR` names the Host that created it.

**Agent command.** A small script the Host puts on the agent's PATH, `varnick`, that turns `varnick land`, `varnick preview`, `varnick session new {branch}`, `varnick snapshot {actor}` into Door calls using `VARNICK_DOOR`.

**Page.** Vite plus React. Subscribes to `/stream`, keeps the latest Snapshot per actor, renders the Session list with state badges, the selected Session's ttyd iframe, and Land, Preview, Reap, New Session and Restart controls that send Events. No `@xstate/react`.

## Testing Decisions

A good test starts a real Host with no window against a temp git repo with one commit, points `claude` at a stub script, and drives it entirely through the Door: send an Event, read the Snapshot or the stream, assert on the state value, the context and the world (a worktree exists, `HEAD` moved, a zmx session is listed). It never imports a Machine to poke it and never asserts on internals.

Tested through the Door: creating a Session, reaping and refused reaping, Landing and each refusal, rebuild at launch from a pre-made worktree and zmx session, the agent command against a running Host, the Proxy swapping the placeholder (against a local stub upstream), Secrets decoding with a test age key.

Tests run under `deno test` and require `git`, `zmx`, `ttyd` and `sops` installed; they skip with a clear message otherwise.

No prior art in this repo; this is the first code on the branch.

## Out of Scope

A kernel sandbox, an egress allowlist, or the MITM proxy. A signed or distributable app. A structured transcript view. Secrets other than the Credential. An MCP wrapper for the agent command. Multiple machines. Linux or Windows. A states page. Hot reload of the Live window on Landing.

## Further Notes

Facts from the 2026-09-17 probes: sandbox-runtime 0.0.67 (not used in v1, ADR-0004) and the Agent SDK run under Deno 2.9.6; node-pty does not, which is moot. Deno Desktop opens a window and `Deno.serve` binds to the address the webview navigates to.

ttyd 1.7.7 and zmx 0.8.1 are installed (`brew install ttyd zmx`). The Seatbelt question ADR-0004 left open is answered: it works. `spikes/seatbelt-terminal/probe.ts` puts a Seatbelt-wrapped `bash` in a zmx session with a ttyd attached on a loopback port, and all five of its checks pass on macOS 26.5.1 — ttyd binds, its websocket opens under the `tty` subprotocol and carries the sandboxed shell's PTY output, the session outlives the websocket, a write inside the allowed directory succeeds, and a write outside it fails with `Operation not permitted`. Wrapping only the Session's command is what makes this work: ttyd and the zmx server stay unconfined on the Host, so nothing sandboxed has to bind or accept a socket. A sandbox that instead confined ttyd itself is untested and is not the shape `Wrap` implies. This changes nothing in v1; it is the fact a returning sandbox would need.

Vocabulary is defined in `CONTEXT.md`. ADR-0003 is the rule most of this spec follows from.
