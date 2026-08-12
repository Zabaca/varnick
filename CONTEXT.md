# varnick — domain model

varnick is a desktop harness for a coding agent: a sandbox, credential injection, a secrets store, and a durable session, wrapped around a chat. You clone it and build your own workspace inside it.

## Language

### The two spaces

**Core**:
The harness and the chat — the code that confines the agent, injects its credentials, resolves its secrets, and holds the conversation. The agent cannot write to it; see [ADR-0002](./docs/adr/0002-core-userspace-boundary.md). What the agent cannot *write* it still shares a realm with: a loaded Surface runs in Core's webview, with Core's globals and Core's bridge to the host ([ADR-0021](./docs/adr/0021-userspace-shares-cores-realm.md)).
_Avoid_: framework, platform, engine, shell (the shell is a surface, not the harness)

**Userspace**:
Everything built inside a clone of varnick that is not Core. The agent writes here freely, and a failure here must never take Core down with it. That separation is about *fault* and not about privilege — see [ADR-0021](./docs/adr/0021-userspace-shares-cores-realm.md), which records what a Surface can reach across the bridge and why nothing about a dynamic import makes it a trust boundary.
_Avoid_: plugins, extensions, user code (all imply an API contract varnick deliberately does not have)

**Surface**:
One built thing in Userspace with its own place in the window — a panel, a route, a view. Discovered from the filesystem rather than registered in Core, so adding one never requires a Core edit.
_Avoid_: page, screen, panel, widget, component (a Surface is composed of components; it is not one)

**Realm**:
One JavaScript world — a global object, a set of intrinsics and prototypes, and one origin. **Core and every loaded Surface share exactly one**, the webview's, so a Surface has Core's globals, Core's prototypes and Core's bridge to the host, and no `import()` changes that. The word earns an entry because the separation people read into **Userspace** is a realm boundary and there is not one: the split is about *fault*, and privilege is shared. See [ADR-0021](./docs/adr/0021-userspace-shares-cores-realm.md).
_Avoid_: context, scope, sandbox (the Sandbox confines a process, not a page), iframe (an iframe is one way to *get* a second Realm; today there is one)

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
**Replaces** the SDK's permission layer rather than sitting under it: `permissionMode: 'bypassPermissions'` with `allowDangerouslySkipPermissions: true`, so everything the agent may do is decided by `sandbox-policy.json` and nothing else. That was the design from the first line of this entry and **it was not implemented until it was measured** — `permissionMode` appeared once in the repository, in a containment probe, and the chat agent got the SDK's `'default'`, which prompts. varnick has no prompt surface, so every Write was refused while Read and Grep passed, and the product looked like a working agent that could investigate anything and change nothing. Found by an agent being refused in a **Worktree**, a path `denyWrite` does not name.
_Avoid_: seatbelt (one backend, not the concept), permissions (the SDK's prompt layer, which this replaces)

**Profile**:
A named preset deciding what an agent is — its instructions, tools, model, Sandbox policy, and where it may act. varnick ships **one**. It shipped two in the design: a Userspace Profile editing the live clone, and a Core Profile confined to a disposable checkout. They collapsed once the write boundary was read literally — `denyWrite` names absolute live-tree paths, so the same Profile edits Userspace in place and Core in a **Worktree** with no second configuration. See [ADR-0014](./docs/adr/0014-core-is-authored-in-a-worktree.md).
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

**Worktree**:
A git worktree under `.claude/worktrees/`, where Core is authored. Core's paths are denied at the live tree's absolute path, so a worktree's copy of them matches nothing and the agent writes them freely — a change becomes running code only when a human merges it and restarts. See [ADR-0014](./docs/adr/0014-core-is-authored-in-a-worktree.md).

The location is Claude Code's own default, and that is the point: `EnterWorktree` and subagent worktree isolation work unmodified. It is already inside the clone, already in `.gitignore`, and outside Vite's root.
_Avoid_: branch (a Worktree has one; it is not one), checkout, sandbox (that is the enforcement, not the place), **Clone** — a retired term for a disposable `git clone` under a temp root, built on the belief that a worktree could not work under the Sandbox

**Briefing**:
Something varnick tells the agent that the agent did not ask about, delivered outside a **Turn**. Today there is one — a merge landing — and it exists because the agent is the *author* of the branch and the only party in the conversation that does not otherwise find out: it goes on offering to preview a Worktree that no longer exists, and reasoning about a fix it believes is running.

**A report, never a command.** Nothing in a Briefing asks the agent to do anything, and that is the line that keeps it from becoming a second control channel: varnick already has one, and it carries requests the agent makes rather than instructions varnick issues. It is also composed host-side and relayed verbatim, like the secret names — the host writes the sentence, no layer below it authors prose.

Distinct from an **Unprompted answer**, which travels the other way: a Briefing is varnick speaking to the agent, an Unprompted answer is the agent speaking without being asked. The first often causes the second.
_Avoid_: notification, message, system prompt (it is neither the conversation's nor the model's), instruction, command (it asks for nothing)

**Preview**:
A second varnick launched from a Worktree so a Core change can be run before it is merged. Requested by the agent through a Custom Tool and spawned by the host, because a confined process cannot open a window: srt gates mach lookups by service name and varnick's policy names none, so `com.apple.windowserver.active` is unreachable.

**Its agent is confined by the policy in force in the live tree**, never by the one in the Worktree it is previewing, and its Credential is injected by the parent host rather than read a second time from the Keychain. So the agent may write any policy generator it likes and the running Preview is still fenced by the version a human merged. A Worktree sits inside the live clone, so that policy's `allowRead` and `allowWrite` already reach it — which is also what gives a Preview's agent the git it did not have.

It used to run under the policy its own tree generated, which was privilege escalation in three steps, and that case raised a native dialog. **Nothing is asked now, of anybody**: the dialog is deleted rather than made skippable, because one that fires on nothing teaches everyone to dismiss the next one. What is *not* closed is that a Preview's host is unconfined code the agent wrote — a confined process cannot open a window — so the guarantee is exactly that the parent host composes the Preview's environment, and the parent is running the code a human merged. See [ADR-0019](./docs/adr/0019-a-preview-is-confined-by-the-live-trees-policy.md), which records what would have to become true to need a dialog again.
_Avoid_: staging, sandbox, dev build, second instance (there may be several)

**Fence**:
The code that decides what the agent may do: `packages/harness/**`, which generates the Sandbox policy; `src-tauri/**`, which holds the Credential; and `sandbox-policy.baseline.json`, which is how a widening is told from varnick's own work. Named because three separate mechanisms key off the same list — the pending-worktree list's flag, the diff view's highlighting, and `denyWrite` itself. There was a fourth, the Preview dialog, and it went with the escalation it gated ([ADR-0019](./docs/adr/0019-a-preview-is-confined-by-the-live-trees-policy.md)). Of the three left, two are about *reading* a change before a human merges it and the third is the kernel refusing the write, which is the division the dialog straddled and is why it was the one that could be removed.

Distinct from Core, which is larger. `packages/core/**`, `vite.config.*` and `package.json` are Core and are not Fence: they are denied so a broken edit cannot take the conversation down, not because they decide the boundary. `sandbox-policy.json` is not Fence either, and for a subtler reason: it is the generated *output*, compared against the baseline and regenerated from the generator, both of which are.

The list lives once, as `FENCE_PATHS` and `isFencePath` in `packages/harness/src/fence.ts` — a pure function over one repository-relative path, with no imports, so the host-side listing and the webview's diff view ask the same question, and `fence.test.ts` holds it against the generated `denyWrite`. Separate glob lists would drift, and the drift is invisible: each caller goes on working, and the one that fell behind stops flagging a file the others still colour.
_Avoid_: privileged paths, boundary (the boundary is what the Fence produces), **Protected Path** — a real term below, and a larger list; calling the Fence "the protected paths" is now wrong rather than merely vague

**Protected Path**:
A path an unattended run may not merge: the Fence, plus `sandbox-policy.json`, `scripts/**` and `.githooks/**`, plus a `package.json` diff that changes `preinstall`, `postinstall` or `prepare`. Everything else the agent lands itself when the checks are green — `packages/core/**`, `vite.config.*`, the rest of that manifest, and Userspace.

**A third list, and none of the three derives from another.** The Fence is what may not be Previewed unconfined; this is what may not be landed unattended; `denyWrite` is what may not be written in the live tree. They answer different questions and have already disagreed on real entries in both directions — `sandbox-policy.json` is not Fence and is protected, `packages/core/**` is denied and lands. `PROTECTED_PATHS` and `unattendedLanding` live beside `FENCE_PATHS` in `packages/harness/src/fence.ts`, and the containment between the three is a test rather than a comment. See [ADR-0018](./docs/adr/0018-three-lists-three-questions.md).

The failure this naming exists to prevent is silent: a gate written as `touchesFence` looks correct and lands `scripts/**` at three in the morning.
_Avoid_: **Fence** (smaller), auto-merge list (it says what the answer is used for rather than what it is), blocked, forbidden (the paths are landed constantly — by a human)

Retired with the Clone: **Escalation**, a queued request for a change the agent could not make, and **Collect**, the host-initiated step that brought a branch out of a Clone. Both are `git merge` now. The gate needs nothing built, because landing a Core change means writing `packages/core/**` in the live tree and `denyWrite` refuses it — a mechanism rather than a policy, which is why a developer who deletes those entries gets agent-merges and that is their call.

### What the window runs

**Artifact**:
One built frontend, kept as a directory under `<clone>/.varnick/builds/` and named by an **id** — `local` for the one `bun run build` writes, a version for one a release cuts.

**Served**:
Which Artifact the window opens on, held as a one-line file named `served` beside them in the store. A fact on disk rather than a path inside a launch, because the three things that have to be possible are exactly the three a file makes possible: a release **writes** an Artifact without touching it, a promotion **rewrites** it, and a launch **reads** it. Absent is a real answer and means nothing is served — the ordinary state of a clone nobody has built yet.
_Avoid_: current, active, live (all three read as a status the store computes; this is a choice somebody wrote down)

A directory per id rather than one `dist`, because three things have to be possible at once: writing a build **without** serving it, switching which one is served, and still having the previous one when the new one will not start. `.varnick/` because that is already where varnick keeps per-clone machine state, and because an artifact is a build of one clone on one machine — never history, never committed.

**Previous**:
The Artifact that was **Served** before this one, held as a second one-line file named `previous` beside it. Written by whatever switches, at the moment it switches, and never inferred — a directory's modification time says when a build was *written*, and a build can be written weeks before anything serves it. Absent means there has never been a switch, which is the honest answer for a clone that has only ever served one build and not the same thing as an old Artifact the store happens to still hold.
_Avoid_: last, N-1, backup (nothing is copied for this; it is the build that was already there), rollback target (nothing rolls back — **Served** is left naming what failed)

**Fall back**:
Serving **Previous** because the **Served** Artifact will not start, with the window saying so. The host does it on its own, at launch, and changes nothing on disk: `served` goes on naming the Artifact that failed, because rewriting it would erase the evidence and make the next launch a launch with no problem in it. It is [ADR-0004](./docs/adr/0004-core-never-statically-imports-userspace.md)'s argument one level out — a broken Surface must not leave a window with no chat, and a broken build must not leave a developer with no varnick to fix it in.
_Avoid_: rollback, revert, downgrade (all three describe a change to what is served; nothing is changed), recover, self-heal

**Will not start**:
What the host is allowed to fall back over, and it is deliberately narrow: the Artifact has no `index.html`, or its `index.html` loads a script the Artifact does not contain. Both are certain before a port is bound. A build that comes up and throws is still the build the developer chose, and falling back over one would be the host overruling a promotion on evidence it does not have — a fallback on the wrong signal is worse than none at all.

A launch never rebuilds to escape this. Rebuilding would undo a promotion and present as the build reverting on its own, so the only store a launch builds for is one with no `served` file at all — a marker that exists and cannot be read is a choice the launch cannot make out rather than a choice nobody made.
_Avoid_: broken, invalid, corrupt (each describes the Artifact; this names what a launch can *decide* about it), crashed (that is the runtime failure this deliberately excludes)

The live tree's window is served from one of these, and a **Preview** is served by the dev server. That is the whole of the rule, and the reason for it is that work now lands in the live tree while nobody is watching: a watcher there would reload the window the developer left open, at whatever hour the merge happened. Live Surface hot-reloading is what that costs in the main window, and it is a recorded consequence rather than an oversight — see [ADR-0020](./docs/adr/0020-the-main-window-serves-a-built-artifact.md).
_Avoid_: bundle, dist, release (a release *produces* one; the artifact is the directory), build (fine as a verb, ambiguous as a noun)

### Conversation

**Session**:
One durable conversation with an agent. Persisted twice — by the Agent SDK for resumption, and mirrored host-side so it survives a broken build, a crash, and a restart. varnick displays the mirror and resumes from it, redactions and all; see [ADR-0009](./docs/adr/0009-resume-reads-the-mirror.md).

Both halves are read back, and they are keyed differently: the mirror by `LIVE_SESSION_ID`, which varnick chooses and never changes, and the agent's own store by a UUID the CLI mints per conversation. varnick records that UUID and hands it back as `resume` on the next launch. For seven launches it did not, and the window showed a full transcript over an agent that remembered none of it — which is why the runtime report carries whether this agent resumed, and why the window says so. There is deliberately no term for a *set* of Sessions: the product holds one.
_Avoid_: chat, thread, conversation (all fine in the UI; `Session` is the persisted object)

**Turn**:
One exchange: a prompt sent and the answer to it. The unit that can be interrupted, retried, and fail. A Session is a sequence of Turns; a Turn is never persisted separately from its Session.

A Turn *ending* is a fact the rest of the product can act on, and the Session announces it — answered, failed and interrupted are all endings, because an agent that committed and then fell over changed the world exactly as much as one that finished. A **Compaction** is not one: it rewrites the transcript mid-Turn without ending anything. Today the one listener is the `review` region; see `TURN_ENDED` under Event names.
_Avoid_: message (a Turn produces two), request, exchange

**Unprompted answer**:
An answer the agent produced without the developer sending anything — a subagent finishing, a background command's output. **It used to be discarded**: every SDK message arriving with no Turn in flight was dropped, so two complete answers were produced, recorded by the SDK and never seen, and when asked why it had not reported the agent correctly said it had. It now gets a Turn of its own, stamped `u`-numbered so Core can tell it from one varnick started, and joins the transcript under the **Cause** that produced it. No user message is fabricated for it: attributing a task notification to the developer would be a second lie in place of the silence it replaces.

**It arrives when it happens.** A first pass delivered it at the start of the next Turn — not lost, and useless to the person it is for, because a developer who is waiting is precisely the one who types nothing. So a pump runs for exactly as long as `agent.running` does, reading a queue of its own: the host sorts events by whether the stamp is `u`, so a Turn and the pump can never hold an event the other is waiting for. That is not tidiness — a host-side wait lasts up to fifteen seconds, so one already in flight when a Turn starts could otherwise swallow that Turn's first event.
_Avoid_: interruption, notification (that is the **Cause**, not the answer), push

**Cause**:
Why an agent said something nobody asked for, in three words — *"a subagent finished"*. Read off the message stream host-side, where the thing that prompted the answer arrives as an ordinary user message, and carried through unchanged. **Core renders it and never composes one**: a divider naming the wrong cause would be a transcript that lies in a new way, and an answer with no visible cause reads as the agent talking to itself.
_Avoid_: trigger, reason (a reason explains a decision; this names an arrival), source

**Tool call**:
One tool the agent used, held in the transcript as a fact rather than as a sentence — the name, what it was pointed at, what came back, and whether that went well. It arrives in two pieces, and both halves matter. The **call** is written the moment the runtime announces it, while the tool is still running, because a tool that takes four minutes is four minutes in which the only honest thing a window can show is that it is working. The **result** arrives later — sometimes after the Turn that made the call has ended — and is matched to the call by the runtime's own `tool_use_id`, never by the order results arrive in: a Session runs tools concurrently, so the n-th result is not the n-th call.

It used to be a line of text. varnick composed `⚙ Read(src/a.ts)` and appended it to the answer, so a tool the agent *called* was indistinguishable from a tool the agent *wrote about*, and what a tool returned existed nowhere in the product — the Turn read the runtime's `assistant` messages for the calls they announced and dropped the `user` messages carrying the answers. That line is still kept beside the fact, which is what lets a mirror written now still read as a conversation under `cat` and a mirror written before still load.

A tool call **ends the message above it**: the words the agent said before reaching for a tool are one entry, the call is the next, and the answer carries on underneath. That is what makes a Turn read as *said, did, said* rather than as one block of prose with tool lines buried in it. It is also the one thing in the transcript that is *changed* after it is written rather than appended to — see `withToolResult`, which is where that exception is argued.
_Avoid_: tool use (the runtime's word for the request half only), invocation, action, step

**Running task**:
One subagent or background task the runtime is running inside a **Turn**. Reported by the runtime and folded host-side into a set the panel replaces wholesale — the SDK sends `task_started`, `task_progress`, `task_updated` and `background_tasks_changed`, and varnick discarded all four until a `/code-review` ran four subagents for ten minutes behind one tool line and a spinner. **The live set is deliberately not kept**: it empties when the Turn ends, because a list of subagents that finished ten minutes ago describes nothing. What survives is a transcript line each one writes when it starts and finishes, which reaches the answer and therefore the Session mirror.
_Avoid_: job, worker, thread, child agent — the SDK calls it a task and its identifier is `task_id`; **Turn** (a task runs inside one and is not one)

**Compaction**:
Replacing earlier messages with a summary to free context. **Something the agent does to itself, which varnick hears about.** It was a Turn state once — varnick asked for one and watched it run — and that covered the compactions varnick asked for and none of the others: Claude Code has its own `/compact`, and an auto-compaction has no command at all, it happens because the window filled. Both rewrote the agent's context while the transcript kept every message that had stopped existing. There is no state for it now and nothing to fail, because varnick performs no act: a compaction that did not happen is a transcript that did not change.
_Avoid_: summarise (the mechanism), truncate, prune (both lose the fact that nothing is discarded blindly)

### State names

These are machine state names before they are UI words, and the two must not diverge. Every one below is addressable at `#/states`, and each card has its own address — `#/states/turn-failed` — so a ticket points at a state rather than at the page. The single state that is not addressable is named as such where it appears.

**Harness — `credential`**: `absent`, `minting`, `storing`, `reading`, `present`, `rejected`.
`absent` means no credential is available, whether or not a read was attempted; a read that failed also records why. It is also the first-run screen, and it has two ways out, neither of which needs a terminal. `storing` is a paste: the host writing the keychain item for the kind they chose. `minting` is varnick getting a subscription token for them — `claude setup-token` run on the host while a person signs in to Claude in their own browser. They are separate states because they are separate waits: a store is seconds with nothing for the developer to do, and a mint is minutes in which *they* are the actor, so the window has something to say for the whole of it — the URL to sign in at, which the flow prints as a fallback when it cannot open a browser itself. Both end by re-reading rather than by declaring the credential present, so one path establishes it whether it was stored a minute ago or a year ago; both come back to `absent` carrying why when they fail. Neither holds a value: a store carries the paste as its actor's input, and a mint never has the token on this side at all. `rejected` means one exists and the API refused it — a different problem with a different fix. A successful read also carries a Credential Kind, which is a fact and not a state.

**Harness — `sandbox`**: `unchecked`, `checking`, `available`, `unavailable`.
`unavailable` has no path forward except an explicit re-check. There is deliberately no state meaning "running without confinement".

**Harness — `agent`**: `down`, `startRefused`, `starting`, `running`, `crashed`.
`down` is stopped on purpose; `crashed` is stopped on its own and carries a reason. `startRefused` is a start that was asked for and declined, holding the refusal so it can be read.

**A message is only sent while this region is `running`.** Measured: an agent host exited on a terminal error while the Tauri host and the Harness runtime stayed up, so the runtime went on writing the Session mirror — and a message typed afterwards was appended to the transcript, saved, and answered by nobody. The transcript is the thing a developer trusts most on that screen, and a message in it that no process ever received is the one entry it must not hold. `agentCanAnswer` is the rule; the composer keeps the draft and says why, so a refusal costs a second rather than a sentence. It is a predicate rather than a guard because the two facts belong to two machines that may not learn each other's internals — whether a process exists is this region's, the draft is the Session's — and the surface holding both snapshots is where they meet, exactly as `canStartAgent` does.
_Avoid_: stopped, idle, dead, paused, blocked

**Harness — `review`**: `listing`, `listed`, `empty`, `listFailed`.
Which **Worktrees** hold commits the live tree does not, and what changed in each. **Produced host-side by running git, and never by the agent** — this is the mechanism that shows what the agent changed, and a report the agent composes is a report the agent can shade. Three read-only commands in `packages/harness/src/worktrees.ts`, routed to the Harness runtime because it is the process with a filesystem, reaching Core over the existing bridge.

It is the one region with no resting state before its work, and the omission is deliberate: the other three wait on something a person decides — read this credential, check the sandbox, start the agent — and nothing decides to list. So there is no `unlisted`, and the region is `listing` from the moment the machine exists, because *nothing the agent finished should wait unnoticed*.

**It lists again at the end of every Turn**, which is the same omission one step along: listing once on entry made the panel a snapshot of a filesystem that changes while varnick runs, and the thing changing it is the agent in the window beside it. A developer who has just watched an agent say "committed" should not then have to ask varnick to go and look. The end of a Turn is precisely when the answer may have changed and is a signal varnick already has — no poll, no watcher, and deliberately no timer; if end-of-Turn ever proves insufficient the next answer is a filesystem watch. *look again* stays, because an agent is not the only thing that can commit.

The wiring is the part worth knowing, because `review` is a region on the Harness and a Turn belongs to the **Session**, and neither may learn the other's internals. The Session **emits** `TURN_ENDED` — a fact about itself, addressed to nobody, naming no worktree and no event of the Harness's — and the Harness, which spawned it and holds the ref, subscribes at the spawn and sends *itself* the `LIST_WORKTREES` it already had. Not `sendParent`: a child that names its parent's vocabulary knows too much, and would throw in every rendering that creates a Session with no parent, which is most of `drive.ts` and every card on `#/states`. Not the owning hook either — each rendering hands the Session its own actors through `.provide()`, so a join written at one of those call sites is a join the other two silently do not have, and it would sit where `drive.ts` cannot reach it.

`empty` is a real state and not `listed` with a count of zero. Nothing pending and a listing that failed are different problems with different copy: one says everything has landed, the other says nobody can currently tell. A Worktree whose branch holds no commits yet is not pending at all: it is an agent that has started rather than one that has finished, and it is left out rather than shown with a zero on it.

`listFailed` carries git's own reason and **keeps whatever list it had**. It used to forget it, for the same reason a failed credential read forgets the Kind, and that was right while a failure was always the *first* failure — there was nothing to keep. Now that every Turn refreshes, most failures are failures to refresh, and a git that would not answer this time has said nothing about the branches it listed a minute ago; dropping them replaces a working answer with an error message. The two cases need no flag to tell them apart: a first listing enters with an empty list, so rows in `listFailed` can only have survived a listing that worked. They stay openable, and the surface says over them that nobody could check — which is where the old rule went. A stale answer must still never be presented as the current one; that is now something to *say* rather than something to prevent by forgetting.

Where it sits is part of the same claim. A pending Core change is code that will decide what the agent may do, waiting for a human, so it is a full-width band above the conversation rather than a panel in the scrolling column beside it. It renders nothing at all when it has nothing to show — `review.empty`, and a listing in flight with no rows behind it — because a permanent slot for the state it is in almost all the time is how it ended up below the fold, and because a band that appeared and vanished on every Turn would be motion the machines did not make. While the band is away, *look again* is the `/pending` command.

An entry also says **whether it will go in**, which is git's answer and not a state: `fast-forward` when the branch already contains the live tree, `clean` when the two diverged without clashing, `conflicts` with the file names, and `unknown` when nobody could tell. The fourth is not padding. `git merge-tree --write-tree` distinguishes *conflicted* from *broken* by exit code — 1 against anything else — and collapsing the second into either of the first two would put a merge control over a question nobody answered. It is a per-row answer rather than a failed listing, because one unreadable branch must not take the other rows off the screen. The listing carries one more fact beside the rows and not on them: whether the tree they would be merged **into** has uncommitted work in it, which decides whether any merge is offered at all.

An entry carries the branch, the path, how far ahead it is, the paths it changed and whether any of them is **Fence** — summaries, never hunks. A list that read every diff of every branch to draw a row would spend the whole of a large branch before showing anything, and this list is what a developer reads to *choose* the branch whose diff they want; `worktreeDiff` below fetches the contents of the one they opened. Path names are carried because they are cheap and because they are what makes the Fence flag auditable.

**Harness — `worktreeMerge`**: `unmerged`, `merging`, `merged`, `mergeFailed`, `restarting`.
Landing one of them. A fifth region rather than a child machine, and the reason is that **a merge's subject is destroyed by its own success**: the branch is deleted, the worktree removed, and the row it started from is gone from the next listing, so a child keyed to that row would be torn down at the moment its message matters most. What is left when a merge lands is a fact about *this varnick* — it is running the code from before the change it just accepted — which is a fact of the same kind as "the sandbox is unavailable", and belongs beside it.

The merge is the gate [ADR-0014](./docs/adr/0014-core-is-authored-in-a-worktree.md) rests on, and a button does not weaken it. The **host** performs the merge, because a human clicked, in a surface the agent cannot write. What is removed is the context switch, not the decision — and a gate a developer has to leave the application to pass is a gate they will pass carelessly, in a terminal, without the diff in front of them. Nothing the agent says can produce the call.

**Squash, always.** One commit on the live branch per Worktree, never a merge commit and never the branch's own history: a worktree's history is a working record and the live tree should carry what changed and why, once. That has a consequence the cleanup must know — after a squash the branch is **not** an ancestor of anything, so `merge-base --is-ancestor` answers *no* for every branch this feature ever merges. The content is checked instead, and `git branch -D` rather than `-d` follows from the same fact.

`unmerged` is named for the tree rather than for the region doing nothing: `idle` would say varnick is waiting, and it is not. It rests first, unlike `review`, for the reason `review` does not: **everything about a merge is decided by a person.** `merging` is one wait covering the squash, the commit, the check that it carried and the cleanup, because from the developer's side they are one act. `merged` is a resting state that says something — that a restart is owed — because a toast is a thing that scrolls past, and an agent reasoning about a fix it believes is live is worse off than one that knows it is not. `mergeFailed` carries git's own reason and offers the merge again; nothing was written, and the copy says so. `restarting` is a state because the restart can fail to *happen*: in the ordinary case the process is replaced mid-call and this frame is the last one drawn.

**A cleanup that could not finish is a success, not a failure.** The commit is on the live branch either way, so reporting it as a failure would invite a second merge of a branch that has already gone in. What is owed instead is a sentence about what is left, which the host composes and the window prints verbatim.

The one thing that decides whether the directory may be removed is **whether any process has it as its working directory**. Not the lock, which was measured unreliable in both directions: a lock naming a dead pid outlives the session that took it, because the lock is held by the `claude` process while the host outlives it and resumes — reaping on that killed a live agent — and a worktree with no lock at all is not empty either, because a session that ended in a restart leaves none behind while its agent is still standing there. `lsof` answers the real question, and a probe that could not run is not permission to delete. Removing the directory is not recoverable by the agent: the SDK treats a missing cwd as a terminal error before it can report the problem, ask, or step back to the clone root.

**Harness — `worktreeReap`**: `idle`, `reaping`, `reaped`, `reapFailed`.
Clearing away a Worktree whose work is already in the live tree. A sixth region rather than states inside `worktreeMerge`, because the two are about different moments and a developer is usually looking at both: a merge lands and reports that it could not remove the directory, and the reap that finally removes it happens after the Turn ends — while the merge's sentence, *you are running old code*, is still true.

**A landed Worktree stays on the list and changes what it offers.** `commits` is ancestry and a squash is nobody's ancestor, so a merged Worktree keeps every fact that put it there: the count never falls, git goes on calling the merge `clean`, and before this the row sat in the band for the rest of the repository's life offering a merge whose only outcome was a `git commit` with nothing to commit. So the listing asks the real question — *would merging again change anything* — and carries the answer as **`landed`**. Filtering those rows out instead would have been the other mistake: a full checkout left on disk that nothing in the product ever names again.

**A merge cannot clear up after itself, and the reason is structural.** The cleanup is refused while any process has the directory as its working directory; a merge is asked from inside a Turn; the agent host is that process and is alive by definition at that moment. So the merge's cleanup is guaranteed to be refused, the host exits when the Turn ends, and this is varnick asking again. `idle` rather than `unreaped` — unlike `unmerged`, there is no fact about the tree to name here: a Worktree either exists or it does not.

**Nothing is forced and nothing is killed.** Deleting a directory that is a live process's working directory is permitted and is not survivable in the way it looks — measured: the process keeps a vnode reference, so it does not die and it does not notice, `process.cwd()` goes on naming a directory that is gone, and every relative file operation fails with an ENOENT naming the *file* rather than the cause. Whatever was uncommitted in the checkout goes with it. So a held directory is left alone and its holders are named by pid, and `reaped` covers *nothing was removed* — that is a report, not a failure. `reapFailed` is the reap that could not be attempted, and the one that matters there is the refusal: **a branch whose content is not in the live tree is never removed**, whatever the row said, because a listing is as old as the last Turn and this ends in `worktree remove` and `branch -D`.

Unlike a merge, a reap needs no diff open. ADR-0014's gate is a human agreeing to a *change*; a reap removes a second copy of work the tree already holds, and requiring a read first would make tidying up two clicks and teach a developer to click through the first.

**Worktree diff — `worktreeDiff`**: `loading`, `loaded`, `failed`.
What one pending **Worktree** changed, read when a developer opens it. A child machine rather than a fifth region on the Harness, spawned by `OPEN_WORKTREE` and dropped by `CLOSE_WORKTREE`, for the three reasons a **Surface** is one: it has something to wait on, it can fail, and it must fail without disturbing the conversation running beside it. At most one is open, so opening a second is refused rather than leaving the first running unwatched — and a re-listing deliberately does not close it, because the list is a fact about a filesystem that changes while varnick runs.

`failed` is the only state with a retry, for the same reason a Surface's is: the state has a handler rather than the UI having hidden a button. It carries git's own reason, and `loaded` carries the text git printed rather than a parsed shape — Core parses it for the view, so nothing between git and the screen can drop a hunk while still answering the call. An **empty** diff is `loaded`, never `failed`: a branch ahead by a commit that changed nothing tracked is a real answer, and reporting it as a failure would say nobody could tell when somebody could.

Like the listing it comes from, the diff is **produced host-side by running git**, and never by the agent — one command more in `packages/harness/src/worktrees.ts`. It is the same argument as the list with a sharper edge: a listing the agent could shade hides a branch, and a diff the agent could shade hides a widening inside a branch somebody is about to merge. It is also the one call on this path carrying a field, and the field is a *selector*: the path is compared against what git itself listed, and the ref that reaches git's argv is the one git printed.

The view ships in **Core** and never as a Surface, for the reason the mechanism exists at all ([ADR-0014](./docs/adr/0014-core-is-authored-in-a-worktree.md)). A Fence hunk is told apart inside DESIGN.md rather than beside it: the diff spends no colour on added and removed lines — marker and tone carry those — which leaves colour meaning one thing on that screen, and Fence is `warn`, the colour of the build admitting something about itself. It is marked at three distances, the last of which is a 1px rule down the left of every hunk in a Fence file, because a marking that only works while the file's name is on screen does not work on a four-hundred-line diff.

**Session — `turn`**: `idle`, `answering.sending`, `answering.streaming`, `interrupting`, `failed`.
`answering` is a Turn in flight, and it is one state because it runs one actor. Its children say how far along the answer is: `sending` is posted with nothing back yet, `streaming` is output arriving. They were siblings once, and each invoked the Turn — so the first streamed token aborted the Turn and started it again. `interrupting` keeps the partial — an interrupted Turn still said something. A Session resumed on launch enters `idle`: a Turn in flight when the process died is an answer that stopped early, which is what an interrupt already is, and nothing observed a failure to report.

**Session — `persistence`**: `saved`, `saving`, `saveFailed`. Independent of `turn`, which is the point: a failed save must not cancel a Turn.

**Session — `composer`**: `typing`, `menu`. `menu` is derived from the draft, not toggled.

**Surface**: `loading`, `loaded`, `failed`. `failed` is the only state with a retry, because the state has no handler rather than because the UI hid a button.

The machine has a fourth, `unloaded`, and it is the exception to the line above: it is final, and the parent drops the actor ref when it unloads a Surface, so nothing is ever rendered in it and it has no card. It is exported from `surface.ts` as `SURFACE_UNCARDED_STATE_PATHS` so a brief that names it still fails the build.

### Event names

`READ_CREDENTIAL`, `STORE_CREDENTIAL`, `MINT_CREDENTIAL`, `MINT_URL`, `CHOOSE_CREDENTIAL_KIND`, `CREDENTIAL_REJECTED`, `CHECK_SANDBOX`, `START`, `STOP`, `RESTART`, `AGENT_EXIT`, `RUNTIME_REPORTED`, `DISCOVER_SURFACES`, `UNLOAD_SURFACE`, `LIST_WORKTREES`, `OPEN_WORKTREE`, `CLOSE_WORKTREE`, `MERGE_WORKTREE`, `RESTART_VARNICK`, `DISMISS_MERGE` on the Harness. `EDIT_DRAFT`, `SEND`, `STREAM_DELTA`, `INTERRUPT`, `RETRY_TURN`, `DISMISS_TURN_ERROR`, `COMPACTED`, `CLEAR`, `SAVE`, `RETRY_SAVE`, `SET_MODEL`, `SET_EFFORT`, `SET_COMMANDS`, `TASKS_REPORTED`, `TOOL_CALL`, `TOOL_RESULT`, `TOGGLE_RUNTIME`, `UNPROMPTED_ANSWER`, `MENU_MOVE`, `MENU_COMPLETE`, `MENU_DISMISS` on the Session. `RETRY`, `UNLOAD` on a Surface. `RETRY` on a **Worktree diff**, which is the only event it has: closing one is the parent's `CLOSE_WORKTREE`, because the parent owns the ref and a child that could close itself would leave the parent holding one that had stopped.

`OPEN_WORKTREE` carries the path of a Worktree the Harness is *already holding* — it names which of git's own answers to read, and does not get to say what the answer should be about. The guard checks it against the list in context, and the host checks again against git; neither check is the other's excuse. It is accepted in `review.listed` and in a `review.listFailed` that kept a list, which are the two states with rows on screen; the guard is what makes the second safe rather than a second rule. `COMMANDS_REPORTED` joins `RUNTIME_REPORTED` on the Harness: both are the runtime describing itself, and both are dropped when the agent is.

`MERGE_WORKTREE` carries the same selector `OPEN_WORKTREE` does and is checked the same way, with one condition on top that is not about git at all: **it is accepted only while a diff is open.** Ticket 50 marks Fence hunks at three distances so nobody lands one without having looked, and a merge control on a summary row would make that marking optional — you would land a Fence change having read a line that says `⚠ fence` rather than the hunk it warns about. The guard is what makes the control's position a rule rather than a habit of the view. Everything else the guard checks — that the entry is one the machine holds, that git said it will go in, that the live tree is clean — is an *affordance*: the host asks all three again at the moment of merging, on facts that are current, and neither side is the other's excuse. `RESTART_VARNICK` is offered from `merged` and nowhere else; `DISMISS_MERGE` is the way out that is not a restart, and it puts the band away without making the restart un-owed.

`LIST_WORKTREES` has two askers and one meaning. A developer sends it with *look again* or `/pending`; the Harness sends it to itself when the Session announces a Turn has ended. There is deliberately no second event for the automatic one — nothing new is being said — and the refusal that already stopped a second click from restarting a listing in flight is what stops a Turn ending from doing it too.

**`TURN_ENDED` is the one event nothing accepts.** It is *emitted* by the Session rather than sent to anybody: a fact about itself, with no recipient, no payload and no state that handles it. That is what lets the Harness act on the end of a Turn without the Session knowing there is a `review` region, a Worktree or a Harness at all. An emitted fact and an event are different things and the naming convention is the same — named for what happened, never for what somebody should do about it.

Two conventions hold: an event is named for what the user or the world did, never for the state it produces (`AGENT_EXIT`, not `CRASH`); and an event a machine will not accept in its current state has no handler rather than a disabled control.

`CLEAR` and `COMPACTED` are the two that changed sides, and they changed it the same way. Each was a command — varnick's own `/clear`, which emptied the transcript and told the agent to forget, and varnick's own `/compact`, which asked for a summary and waited in `turn.compacting` for it. Both are **reports** now: the runtime announces `conversation_reset` or produces a compaction summary, and the transcript follows.

The distinction is not pedantry. Claude Code has both commands, so either could be asked for in two places and only one of them was heard — and a compaction needs no asking at all, because the window fills up and the agent summarises itself. Listening covers however it was asked for, including when nobody asked, which is the case a command could never reach. It also settles where they are handled: a state may decide what to *do* with a fact and may not decline one, so both sit at the machine's root and are accepted mid-Turn, which is exactly when they arrive.

`TOGGLE_RUNTIME` sits at the same root and is the one event on the Session that is not about the conversation: it puts the runtime panel away, or brings it back, by flipping `runtimeHidden` on the context. Root-level for a different reason than a report — nothing has happened in the world — but with the same consequence, which is that no Turn state has standing to decline it. The panel holds a 320px column, the transcript is capped at its own prose measure, and on a laptop that column is what pushes the conversation below the measure it was designed for; so the moment somebody reaches for the width is the moment an answer is arriving, and a toggle refused during a Turn would be a control that worked only once nobody wanted it. **Nothing is persisted.** A reload starts with the panel shown, because carrying it across one means either a machine reading `localStorage`, which breaks [ADR-0001](./docs/adr/0001-pure-view-layer.md), or the host growing a preference store, which is a feature rather than a fix. It adds no state: whether the column is on screen is a field the surface reads, and the `<aside>` renders when it has something to hold — an unhidden panel, or a **Surface**, which is why hiding one of Core's panels never takes Userspace's output with it.

`STORE_CREDENTIAL` carries the one value in Core that must not survive the interaction. It is read by the store actor's input and never assigned into context, so the machine that carried it holds nothing afterwards — which is why `CHOOSE_CREDENTIAL_KIND` is a separate event: the kind is not secret, belongs in context where the view can read it, and says only which item a store would write. Which credential varnick *uses* is still resolved by the host from what it finds ([ADR-0011](./docs/adr/0011-varnick-takes-a-subscription-token-not-the-subscription.md)).
