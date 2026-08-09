# 32 — The window cannot say what the agent actually is

**What to build:** A panel beside the conversation that shows what the running agent reports about itself — version, model, permission mode, working directory, and the tools, skills, plugins, MCP servers, subagents and slash commands it actually loaded.

**Blocked by:** None.

**Status:** done.

**Realizes:** no new state path. The report is a fact in `HarnessContext`, not a state — nothing transitions on it, and `agent.running` already says whether there is a process.

## Why

**Configured is not the same as loaded, and varnick could not tell the two apart.** A Profile names a model, a tool set and a permission mode; every one of those is an intention until a process reads it. A tool dropped on the way to the SDK leaves the code saying one thing and the agent doing another, with nothing on screen that disagrees.

Ported from the sibling `forge` service, which built it after a profile declared two plugins, the SDK silently dropped them, and the only reason anyone found out was that the agent happened to read its own skill list and notice an absence. Nothing errored.

varnick has one more reason to want it. The Sandbox denies read on `$HOME`, so `~/.claude` — user settings, skills, plugins — is unreachable whether or not configuration is inherited. That is a deliberate property of [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md), and there was nothing on screen that showed it happening. **"No skills loaded" is not a bug report here; it is the boundary, visible.**

## The name

forge calls this the harness panel. That name cannot be used in this repo: **Harness** is Core's runtime half — the thing that *confines* this process — and two meanings for one word is what `CONTEXT.md` exists to prevent. It is a **Runtime Report**, and the term is in the glossary with the collision recorded.

## The one thing that was not obvious

**The `init` message arrives before any Turn exists.** The Session emits it when the Claude Code process starts, which is at spawn — and once per Session, not once per Turn. `serveTurns` drops messages with no Turn running, on purpose, so that a stray delta never becomes the next Turn's first word. Forwarded straight through, the report would have been dropped every time and the panel would have stayed empty for the life of the Session.

So the runtime holds the last report and replays it at the start of each Turn. A report arriving mid-Turn is emitted immediately. Both paths are tested, including the one that would have failed silently.

## Deliberately not built

- **The declared-versus-loaded column.** forge renders the repo's profile beside the runtime's answer and highlights the gap, which is the feature's whole origin. varnick declares no tool list to compare against — it passes no `allowedTools` for the Userspace agent — so a "declared" column here would be an empty column. It becomes worth building when a Profile has something to declare.
- **A toggle.** forge's panel opens and closes with ⌘J and remembers the choice. varnick's right-hand column is fixed at 320px, and this panel now shares it with the Surfaces. If the column becomes adjustable, the toggle belongs with that work rather than ahead of it.

## Watch for

- **Nothing here is or can be a credential.** `apiKeySource` is the SDK's name for which store answered — the same class of fact as Credential Source. The event is rebuilt field by field on the way across, like every other one, and a test asserts a smuggled key does not survive the crossing.
- **A report must never outlive the process it describes.** It is cleared when `agent.running` is left, by either door. A stale report is the exact failure this panel exists to catch, one level up.
- A report must never fail the Turn it describes: every field is optional on the way in and defaults to empty.

- [x] The runtime's `init` message reaches the window and is rendered
- [x] A report that arrives before the first Turn is not lost
- [x] The report goes away when the agent does — stop and crash both
- [x] Nothing on the wire is forwarded rather than rebuilt, and no field can carry a value
- [x] `#/bare` can send one without a runtime, and shows what is held
- [x] `bun run drive`, `bun test packages`, typecheck and lint are green

Found by the developer, reviewing forge and asking for this panel by name.
