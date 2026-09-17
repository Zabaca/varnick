# varnick — domain model

varnick is a desktop window around a coding agent. It gives the agent a worktree, a terminal and no credential, and gives you a button that lands the work.

## Language

### Instances

**Host**:
The one Deno process behind a window. It holds the actors, serves the page, owns the Door, runs the Proxy, and spawns everything else.
_Avoid_: backend, server, harness, core

**Live**:
The Host that runs the live tree. There is one, and it is what you promote onto by restarting it.
_Avoid_: main, production, the app

**Preview**:
A Host launched from a Worktree as a separate process, so a change to varnick itself can be tried before it lands. Its own window, its own Door, its own port; it sees the same Sessions as Live. The Host that launches it chooses that port and hands it over in `VARNICK_PORT`, then says in its own Snapshot where the Preview answers.
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
What authenticates the agent to Anthropic. Held by the Host, never by the agent; the agent carries a placeholder.
_Avoid_: token, API key (either may be the Credential's kind), secret

**Proxy**:
The loopback reverse proxy the Host runs, selected in the agent's environment by `ANTHROPIC_BASE_URL`. It replaces the placeholder with the Credential on the way out.
_Avoid_: MITM (a stronger form, not built), gateway

**Secrets file**:
`secrets.yaml`, sops-encrypted to your age key, committed. Holds the Credential. Readable in every Worktree; decrypting it needs your age key, which the agent is trusted not to use rather than prevented from using (ADR-0004).
_Avoid_: vault, keychain, env file

**Agent home**:
The Claude Code configuration directory the agent runs with, inside the clone under `.varnick/`, shared by every Session and separate from your own `~/.claude`.
_Avoid_: config dir, profile

### Driving it

**Machine**:
An XState machine for one thing whose state can be in flight or fail. Its actor runs in the Host, once, and is the only truth for that thing.
_Avoid_: store, reducer, state (a Machine has states)

**Snapshot**:
What a Machine's actor looks like right now: state value and context, JSON. The only thing the page ever renders.
_Avoid_: state, model, view model

**Door**:
The Host's one loopback HTTP API: send an Event, read a Snapshot, subscribe to Snapshots. The page, the agent and a test all enter by it and there is no other way in.
_Avoid_: bridge, bindings, IPC, RPC, control channel

**Event**:
One thing sent through the Door to a Machine, the same whether a button, an agent or a test sent it.
_Avoid_: command, action, message, request
