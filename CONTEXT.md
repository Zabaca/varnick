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
Host-side storage the agent cannot read. The agent authors code that names a secret; the host resolves the name when it runs that code. See [ADR-0006](./docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).

It is worth knowing *why* it cannot, because the obvious answer is wrong and was believed for a while: not because `/usr/bin/security` is denied — that binary still runs, and the Security framework links in-process anyway — but because the Keychain file lives under `$HOME`, which `denyRead` covers. The protection is real and kernel-enforced, and it is incidental to where Apple puts the file. Widening `allowRead` over `$HOME` would remove it silently. See the first correction in [ADR-0003](./docs/adr/0003-containment-wraps-the-process-tree.md).
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
One durable conversation with an agent. Persisted twice — by the Agent SDK for resumption, and mirrored host-side so it survives a broken build, a crash, and a restart. varnick displays the mirror and resumes from it, redactions and all; see [ADR-0009](./docs/adr/0009-resume-reads-the-mirror.md). There is deliberately no term for a *set* of Sessions: the product holds one.
_Avoid_: chat, thread, conversation (all fine in the UI; `Session` is the persisted object)

**Turn**:
One exchange: a prompt sent and the answer to it. The unit that can be interrupted, retried, and fail. A Session is a sequence of Turns; a Turn is never persisted separately from its Session.
_Avoid_: message (a Turn produces two), request, exchange

**Compaction**:
Replacing earlier messages with a summary to free context. Named as its own Turn state because it can fail, and when it fails the conversation is explicitly unchanged.
_Avoid_: summarise (the mechanism), truncate, prune (both lose the fact that nothing is discarded blindly)

### State names

These are machine state names before they are UI words, and the two must not diverge. Every one below is addressable at `#/states`; the single state that is not is named as such where it appears.

**Harness — `credential`**: `absent`, `reading`, `present`, `rejected`.
`absent` means no credential is available, whether or not a read was attempted; a read that failed also records why. `rejected` means one exists and the API refused it — a different problem with a different fix.

**Harness — `sandbox`**: `unchecked`, `checking`, `available`, `unavailable`.
`unavailable` has no path forward except an explicit re-check. There is deliberately no state meaning "running without confinement".

**Harness — `agent`**: `down`, `startRefused`, `starting`, `running`, `crashed`.
`down` is stopped on purpose; `crashed` is stopped on its own and carries a reason. `startRefused` is a start that was asked for and declined, holding the refusal so it can be read.
_Avoid_: stopped, idle, dead, paused, blocked

**Harness — `subscription`**: `unread`, `reading`, `read`. Plan usage across the rolling windows. A failed read leaves whatever was last known and never invents a figure.

**Session — `turn`**: `idle`, `answering.sending`, `answering.streaming`, `interrupting`, `compacting`, `failed`.
`answering` is a Turn in flight, and it is one state because it runs one actor. Its children say how far along the answer is: `sending` is posted with nothing back yet, `streaming` is output arriving. They were siblings once, and each invoked the Turn — so the first streamed token aborted the Turn and started it again. `interrupting` keeps the partial — an interrupted Turn still said something. A Session resumed on launch enters `idle`: a Turn in flight when the process died is an answer that stopped early, which is what an interrupt already is, and nothing observed a failure to report.

**Session — `persistence`**: `saved`, `saving`, `saveFailed`. Independent of `turn`, which is the point: a failed save must not cancel a Turn.

**Session — `composer`**: `typing`, `menu`. `menu` is derived from the draft, not toggled.

**Surface**: `loading`, `loaded`, `failed`. `failed` is the only state with a retry, because the state has no handler rather than because the UI hid a button.

The machine has a fourth, `unloaded`, and it is the exception to the line above: it is final, and the parent drops the actor ref when it unloads a Surface, so nothing is ever rendered in it and it has no card. It is exported from `surface.ts` as `SURFACE_UNCARDED_STATE_PATHS` so a brief that names it still fails the build.

### Event names

`READ_CREDENTIAL`, `CREDENTIAL_REJECTED`, `CHECK_SANDBOX`, `START`, `STOP`, `RESTART`, `AGENT_EXIT`, `READ_SUBSCRIPTION`, `DISCOVER_SURFACES`, `UNLOAD_SURFACE` on the Harness. `EDIT_DRAFT`, `SEND`, `STREAM_DELTA`, `INTERRUPT`, `RETRY_TURN`, `DISMISS_TURN_ERROR`, `COMPACT`, `CLEAR`, `SAVE`, `RETRY_SAVE`, `SET_MODEL`, `SET_EFFORT`, `SET_COMMANDS`, `MENU_MOVE`, `MENU_COMPLETE`, `MENU_DISMISS` on the Session. `RETRY`, `UNLOAD` on a Surface.

Two conventions hold: an event is named for what the user or the world did, never for the state it produces (`AGENT_EXIT`, not `CRASH`); and an event a machine will not accept in its current state has no handler rather than a disabled control.
