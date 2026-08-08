# varnick — domain model

varnick is a desktop harness for a coding agent: a sandbox, credential injection, a secrets store, and a durable session, wrapped around a chat. You clone it and build your own workspace inside it.

## Language

### The two spaces

**Core**:
The harness and the chat — the code that confines the agent, injects its credentials, resolves its secrets, and holds the conversation. The agent cannot write to it; see [ADR-0002](./docs/adr/0002-core-userspace-boundary.md).
_Avoid_: framework, platform, engine, shell (the shell is a surface, not the harness)

**Userspace**:
Everything built inside a clone of varnick that is not Core. The agent writes here freely, and a failure here must never take Core down with it.
_Avoid_: plugins, extensions, user code (all imply an API contract varnick deliberately does not have)

**Surface**:
One built thing in Userspace with its own place in the window — a panel, a route, a view. Discovered from the filesystem rather than registered in Core, so adding one never requires a Core edit.
_Avoid_: page, screen, panel, widget, component (a Surface is composed of components; it is not one)

**Workspace**:
The environment a person builds around themselves inside their clone — the accumulated Surfaces, integrations, and data that make varnick theirs. What the product exists to let you grow.
_Avoid_: instance, install, project. **Note:** `zbc` uses this word for a disposable clone the agent is confined to — the opposite scope. In varnick, that is a **Clone**.

### Confinement

**Harness**:
Core's runtime half: the sandbox, credential injection, the Secrets Store, and session durability. Independently useful, kept as a package inside the clone rather than a published dependency so it stays editable.
_Avoid_: runtime, SDK, framework

**Sandbox**:
The kernel-level restrictions the agent's process tree runs under, applied with `@anthropic-ai/sandbox-runtime` around the whole tree rather than per command. See [ADR-0003](./docs/adr/0003-containment-wraps-the-process-tree.md).
_Avoid_: seatbelt (one backend, not the concept), permissions (the SDK's prompt layer, which this replaces)

**Profile**:
A named preset deciding what an agent is — its instructions, tools, model, Sandbox policy, and where it may act. varnick ships two: one for Userspace and one for Core.
_Avoid_: mode, persona, preset (the Agent SDK uses "preset" for its own system prompt)

**Custom Tool**:
A tool given to an agent as an in-process SDK MCP tool rather than a built-in. Runs in the host process, outside the Sandbox by construction — the sanctioned way to grant one narrow capability without widening a policy that applies to everything else.
_Avoid_: MCP server (a Custom Tool may be one; the term is about where the code runs)

**Secrets Store**:
Host-side storage the agent can never read. The agent authors code that names a secret; the host resolves the name when it runs that code. See [ADR-0006](./docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).
_Avoid_: vault, keychain, credentials (credentials are what authenticate the agent itself, which is a separate path)

### Changing Core

**Clone**:
A disposable `git clone` of the project under a temp root, where the Core Profile works. Not a linked worktree — a worktree's `.git` file points back into the denied path, so it cannot work under the Sandbox.
_Avoid_: worktree, checkout, sandbox (that is the enforcement, not the place)

**Escalation**:
A request from the Userspace agent for a change it cannot make, raised through a Custom Tool and queued for a human. Escalation is privilege escalation by construction — the Core Profile can rewrite the Sandbox policy — so it is always gated twice.
_Avoid_: elevation, handoff, delegation

**Collect**:
The host-initiated step that brings a Core Profile's branch out of its Clone and into the project. The only moment work crosses the boundary, and never agent-initiated.
_Avoid_: merge (Collect stops short of merging; the merge is a human's), sync, push

### Conversation

**Session**:
One durable conversation with an agent. Persisted twice — by the Agent SDK for resumption, and mirrored host-side so it survives a broken build, a crash, and a restart.
_Avoid_: chat, thread, conversation (all fine in the UI; `Session` is the persisted object)
