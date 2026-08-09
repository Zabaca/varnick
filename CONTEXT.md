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

One per clone, and therefore **not** one per machine: the clone varnick works in is chosen at launch (`VARNICK_CLONE_ROOT`, defaulting to the tree varnick was built in), so one machine can hold several. That used to be true by construction and stated nowhere, which is what made the Session mirror machine-wide and would have put two Workspaces' conversations in one file. See [ADR-0012](./docs/adr/0012-the-clone-root-is-an-input.md), which also records the one thing that does not yet follow the chosen root: Surface discovery, which names the tree varnick was built from.
_Avoid_: instance, install, project. **Note:** `zbc` uses this word for a disposable clone the agent is confined to — the opposite scope. In varnick, that is a **Clone**.

### Confinement

**Harness**:
Core's runtime half: the sandbox, credential injection, the Secrets Store, and session durability. Independently useful, kept as a package inside the clone rather than a published dependency so it stays editable.
_Avoid_: runtime, SDK, framework

**Runtime Report**:
What the agent's Claude Code process says it is, in its own words — version, model, permission mode, working directory, and the tools, skills, plugins, MCP servers, subagents and slash commands it loaded. Read from the Agent SDK's `init` message, held by the Harness runtime and replayed at the start of every Turn, because `init` is sent once per Session and arrives before any Turn exists to carry it.

It exists because **configured is not the same as loaded** and nothing in varnick could tell the two apart: a Profile is an intention until a process reads it, and a tool that never arrived leaves the code saying one thing and the running agent doing another. Ported from the sibling `forge` service, which calls it the harness panel — a name that cannot be used here, because **Harness** already means Core's runtime half.

Names and counts only. It is not a Credential and has no field one could arrive in; `apiKeySource` is a store's name, the same class of fact as Credential Source. It is a fact rather than a state — nothing transitions on it — and it is dropped when the agent stops, because a description of a process that no longer exists is the exact mistake it was built to catch.
_Avoid_: harness (taken), capabilities, manifest, profile (the Profile is what was asked for; this is what happened)

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
Host-side storage the agent cannot read. The agent authors code that names a secret; the host resolves the name when it runs that code. It learns the names because the host tells it — a control request on the channel the agent host already holds, sent before every Turn, so a secret added while varnick is running is nameable without a relaunch. See [ADR-0006](./docs/adr/0006-agents-author-secret-use-never-hold-secrets.md).

It is worth knowing *why* it cannot, because the obvious answer is wrong and was believed for a while: not because `/usr/bin/security` is denied — that binary still runs, and the Security framework links in-process anyway — but because the Keychain file lives under `$HOME`, which `denyRead` covers. The protection is real and kernel-enforced, and it is incidental to where Apple puts the file. Widening `allowRead` over `$HOME` would remove it silently. See the first correction in [ADR-0003](./docs/adr/0003-containment-wraps-the-process-tree.md).
_Avoid_: vault, keychain, credentials (credentials are what authenticate the agent itself, which is a separate path)

**Credential**:
What authenticates the agent itself — distinct from a Secret, which is what the agent's code uses. Read by the Tauri host, held only there, and injected into the agent subprocess. Nothing about it crosses into the webview except two facts about the reading.

**Credential Kind**:
Which of the two things the Credential is: an `api-key` (an Anthropic API key) or a `subscription` (a Claude subscription token from `claude setup-token`). Decided by the host from what it resolved, never configured, and it decides which variable the agent is spawned with — which is now the whole of what it decides. varnick never reads Claude Code's own credential store; see [ADR-0011](./docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md).

It used to decide a second thing, "whether plan usage exists to read", and nothing on screen turns on it any more. A `claude setup-token` session reports no plan — Claude Code treats it as API authentication — so the strip that read it could never populate, and it was cut with its region and its actor. The Kind is still a real fact about a real credential; it simply has no appearance.
_Avoid_: auth mode, provider, account type

**Credential Source**:
Which store answered — `keychain` or `env`. Orthogonal to Kind: either Kind can come from either Source.

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
One durable conversation with an agent. Persisted twice — by the Agent SDK for resumption, and mirrored host-side so it survives a broken build, a crash, and a restart. varnick displays the mirror and resumes from it, redactions and all; see [ADR-0009](./docs/adr/0009-resume-reads-the-mirror.md).

Both halves are read back, and they are keyed differently: the mirror by `LIVE_SESSION_ID`, which varnick chooses and never changes, and the agent's own store by a UUID the CLI mints per conversation. varnick records that UUID and hands it back as `resume` on the next launch. For seven launches it did not, and the window showed a full transcript over an agent that remembered none of it — which is why the runtime report carries whether this agent resumed, and why the window says so. There is deliberately no term for a *set* of Sessions: the product holds one.
_Avoid_: chat, thread, conversation (all fine in the UI; `Session` is the persisted object)

**Turn**:
One exchange: a prompt sent and the answer to it. The unit that can be interrupted, retried, and fail. A Session is a sequence of Turns; a Turn is never persisted separately from its Session.
_Avoid_: message (a Turn produces two), request, exchange

**Compaction**:
Replacing earlier messages with a summary to free context. Named as its own Turn state because it can fail, and when it fails the conversation is explicitly unchanged.
_Avoid_: summarise (the mechanism), truncate, prune (both lose the fact that nothing is discarded blindly)

### State names

These are machine state names before they are UI words, and the two must not diverge. Every one below is addressable at `#/states`; the single state that is not is named as such where it appears.

**Harness — `credential`**: `absent`, `minting`, `storing`, `reading`, `present`, `rejected`.
`absent` means no credential is available, whether or not a read was attempted; a read that failed also records why. It is also the first-run screen, and it has two ways out, neither of which needs a terminal. `storing` is a paste: the host writing the keychain item for the kind they chose. `minting` is varnick getting a subscription token for them — `claude setup-token` run on the host while a person signs in to Claude in their own browser. They are separate states because they are separate waits: a store is seconds with nothing for the developer to do, and a mint is minutes in which *they* are the actor, so the window has something to say for the whole of it — the URL to sign in at, which the flow prints as a fallback when it cannot open a browser itself. Both end by re-reading rather than by declaring the credential present, so one path establishes it whether it was stored a minute ago or a year ago; both come back to `absent` carrying why when they fail. Neither holds a value: a store carries the paste as its actor's input, and a mint never has the token on this side at all. `rejected` means one exists and the API refused it — a different problem with a different fix. A successful read also carries a Credential Kind, which is a fact and not a state.

**Harness — `sandbox`**: `unchecked`, `checking`, `available`, `unavailable`.
`unavailable` has no path forward except an explicit re-check. There is deliberately no state meaning "running without confinement".

**Harness — `agent`**: `down`, `startRefused`, `starting`, `running`, `crashed`.
`down` is stopped on purpose; `crashed` is stopped on its own and carries a reason. `startRefused` is a start that was asked for and declined, holding the refusal so it can be read.
_Avoid_: stopped, idle, dead, paused, blocked

**Session — `turn`**: `idle`, `answering.sending`, `answering.streaming`, `interrupting`, `compacting`, `failed`.
`answering` is a Turn in flight, and it is one state because it runs one actor. Its children say how far along the answer is: `sending` is posted with nothing back yet, `streaming` is output arriving. They were siblings once, and each invoked the Turn — so the first streamed token aborted the Turn and started it again. `interrupting` keeps the partial — an interrupted Turn still said something. A Session resumed on launch enters `idle`: a Turn in flight when the process died is an answer that stopped early, which is what an interrupt already is, and nothing observed a failure to report.

**Session — `persistence`**: `saved`, `saving`, `saveFailed`. Independent of `turn`, which is the point: a failed save must not cancel a Turn.

**Session — `composer`**: `typing`, `menu`. `menu` is derived from the draft, not toggled.

**Surface**: `loading`, `loaded`, `failed`. `failed` is the only state with a retry, because the state has no handler rather than because the UI hid a button.

The machine has a fourth, `unloaded`, and it is the exception to the line above: it is final, and the parent drops the actor ref when it unloads a Surface, so nothing is ever rendered in it and it has no card. It is exported from `surface.ts` as `SURFACE_UNCARDED_STATE_PATHS` so a brief that names it still fails the build.

### Event names

`READ_CREDENTIAL`, `STORE_CREDENTIAL`, `MINT_CREDENTIAL`, `MINT_URL`, `CHOOSE_CREDENTIAL_KIND`, `CREDENTIAL_REJECTED`, `CHECK_SANDBOX`, `START`, `STOP`, `RESTART`, `AGENT_EXIT`, `RUNTIME_REPORTED`, `DISCOVER_SURFACES`, `UNLOAD_SURFACE` on the Harness. `EDIT_DRAFT`, `SEND`, `STREAM_DELTA`, `INTERRUPT`, `RETRY_TURN`, `DISMISS_TURN_ERROR`, `COMPACT`, `CLEAR`, `SAVE`, `RETRY_SAVE`, `SET_MODEL`, `SET_EFFORT`, `SET_COMMANDS`, `MENU_MOVE`, `MENU_COMPLETE`, `MENU_DISMISS` on the Session. `RETRY`, `UNLOAD` on a Surface.

Two conventions hold: an event is named for what the user or the world did, never for the state it produces (`AGENT_EXIT`, not `CRASH`); and an event a machine will not accept in its current state has no handler rather than a disabled control.

`STORE_CREDENTIAL` carries the one value in Core that must not survive the interaction. It is read by the store actor's input and never assigned into context, so the machine that carried it holds nothing afterwards — which is why `CHOOSE_CREDENTIAL_KIND` is a separate event: the kind is not secret, belongs in context where the view can read it, and says only which item a store would write. Which credential varnick *uses* is still resolved by the host from what it finds ([ADR-0011](./docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md)).
