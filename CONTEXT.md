# varnick — domain model

varnick is a desktop window around a coding agent. It gives the agent a worktree, a terminal and no Credential of yours, and gives you a button that lands the work.

## Language

### Instances

**Host**:
The one Deno process behind a window. It holds the actors, serves the page, owns the Door, runs the Proxy if there is a Secrets file, and spawns everything else.
_Avoid_: backend, server, harness, core

**Live**:
The Host that runs the live tree. There is one, and it is what you promote onto by restarting it.
_Avoid_: main, production, the app

**Preview**:
A Host launched from a Worktree as a separate process, so a change to varnick itself can be tried before it lands. Its own window, its own Door, its own port; it sees the same Sessions as Live. The Preview writes down where its Door came up, as every Host does in its own tree, and the Host that launched it says so in its own Snapshot.
_Avoid_: dev instance, second instance, varnick-in-varnick

**Restart**:
A Host replacing itself with a fresh launch of the same tree. On Live this is promotion: whatever has landed is now what runs.
_Avoid_: promote, deploy, reload

### Where work happens

**Live tree**:
The checkout the Live Host runs from. The agent never writes it; work reaches it only by Landing.
_Avoid_: main checkout, repo root, the clone

**Worktree**:
A git worktree under `.claude/worktrees/`, one per Session, named by its branch. The only place the agent may write.
_Avoid_: branch (a Worktree has one), checkout

**Session**:
One zmx session holding one terminal running the agent in one Worktree. Outlives the window and the Host; reaped with its Worktree.
_Avoid_: chat, conversation, tab, terminal (the terminal is what a Session shows)

**Landing**:
Fast-forwarding the Live tree to a Worktree's branch. The Host performs it on request and refuses a dirty Live tree or a branch that is not a fast-forward; rebasing is the agent's job.
_Avoid_: merge (it is one, but a fast-forward only), collect, sync, promote

### Confinement

**Wrap**:
The one function that turns the agent's command into the command a Session runs. In v1 it returns the command unchanged; it is the only place a kernel sandbox would go if one returns (ADR-0004).
_Avoid_: sandbox (there is none), confinement, seatbelt

**Credential**:
What authenticates the agent to Anthropic. When there is a Secrets file it is held by the Host and never by the agent, which carries a placeholder; with no Secrets file the Host holds none and the Session inherits whatever the launching shell had (ADR-0005, amended).
_Avoid_: token, API key (either may be the Credential's kind), secret

**Proxy**:
The loopback reverse proxy the Host runs when there is a Secrets file, selected in the agent's environment by `ANTHROPIC_BASE_URL`. It replaces the placeholder with the Credential on the way out. Without a Secrets file it does not run, and the Session takes the credential variables of the shell that launched varnick — or, where that shell had none, the agent logs itself in (ADR-0005, amended).
_Avoid_: MITM (a stronger form, not built), gateway

**Secrets file**:
`secrets.yaml`, sops-encrypted to your age key and committed if you make one. Holds the Credential. Optional: its presence is what turns the Proxy on, and one that is there and will not decrypt stops the launch (ADR-0005, amended). Readable in every Worktree; decrypting it needs your age key, which the agent is trusted not to use rather than prevented from using (ADR-0004).
_Avoid_: vault, keychain, env file

**Agent home**:
The Claude Code configuration directory the agent runs with, inside the clone under `.varnick/`, shared by every Session and separate from your own `~/.claude`.
_Avoid_: config dir, profile

### Driving it

**Machine**:
An XState machine for one thing whose state can be in flight or fail. Its actor runs in the Host, once, and is the only truth for that thing.
_Avoid_: store, reducer, state (a Machine has states)

**Snapshot**:
What a Machine's actor looks like right now: state value, context and tags, JSON. The only thing the page ever renders. Tags are how something waiting on a Machine knows it has come to rest without repeating a state name outside it.
_Avoid_: state, model, view model

**Door**:
The Host's one loopback HTTP API: send an Event, read a Snapshot, subscribe to Snapshots. The page, the agent and a test all enter by it and there is no other way in.
_Avoid_: bridge, bindings, IPC, RPC, control channel

**Event**:
One thing sent through the Door to a Machine, the same whether a button, an agent or a test sent it.
_Avoid_: command, action, message, request

**The varnick command**:
`varnick`, the command the Host installs on the agent's PATH inside a Session (`.varnick/bin/`). `varnick land`, `varnick preview`, `varnick session new <branch>` and `varnick snapshot <actor>` are Door calls over `VARNICK_DOOR`, defaulting to the Session's own branch — `VARNICK_BRANCH` — where one is implied. It prints the resulting Snapshot as JSON and exits non-zero when varnick refused. It is not a second way in: every one of them is an Event or a Snapshot the page could send or read.
_Avoid_: CLI tool, MCP tool, agent API, SDK
