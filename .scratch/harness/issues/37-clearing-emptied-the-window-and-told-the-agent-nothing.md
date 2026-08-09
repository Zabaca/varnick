# 37 — Clearing emptied the window and told the agent nothing

**What to build:** `/clear` clears the conversation — both halves of it — and the agent knows where it is standing.

**Blocked by:** None.

**Status:** done.

**Realizes:** no new state path. `CLEAR` is the same transition it always was, with one more action on it.

## Two defects, found in the same five minutes

### The agent did not know its working directory

It ran `pwd` to find out, and it was right to: nothing had told it. varnick called `query()` with `cwd`, `env`, hooks, sandbox and `resume` — and no `systemPrompt`. **The SDK does not give you Claude Code's prompt by default; it is a preset you opt into**, and the SDK's own words say what that preset uniquely carries: *"per-user dynamic sections (working directory, auto-memory, git status)"*. The live session's transcript has no `<env>` block and no `Working directory:` line anywhere.

So the agent had been running without Claude Code's system prompt entirely — not only the working directory, but its tool conventions and working style with it. Not a decision anyone made: the SDK's default is a bare agent, varnick took the default, and nothing said so.

`systemPrompt: { type: 'preset', preset: 'claude_code' }` is the whole fix. `excludeDynamicSections` is deliberately left off — stripping the working directory back out is exactly what this repairs.

**`settingSources: []` is untouched**, and `CLAUDE.md` is still not loaded as a memory file. That is ADR-0010's isolation: memory files come with the project source and so do hooks, which the agent can write, so loading them runs agent-authored code at start-up. `VARNICK_INHERIT_CLAUDE_CONFIG=1` is the existing way out for anyone who wants it. Reading `CLAUDE.md` with the `Read` tool works and carries none of that risk.

### Clearing was half a clear

`CLEAR` emptied varnick's transcript and said nothing to the agent, which went on holding every word of it. **An empty window over a full memory** — and the developer found it the only way it could be found, by clearing and discovering the agent still knew.

**Ticket 33 did not cause this; it removed the coincidence that hid it.** While the agent forgot everything on every launch, an empty window and an empty agent happened to agree. Resume made the memory real, and the half-clear underneath became something a person could see.

## What it does now

`CLEAR` carries a second action, `forgetAgentContext`, declared as a no-op on the machine and supplied at the same seam the actors are (ADR-0001). A seeded run keeps the no-op — there is no agent to tell, and a seeded clear reaching for the bridge would be a browser tab calling a host it does not have.

Live, it sends `clear-session` across the bridge; the agent host prompts the CLI's own `/clear` on the Session that is already open, for the reason the compaction constant gives — the Session's context is what is being reset, and only the process holding it can do that. Nothing crosses that boundary but the instruction: the request has no Turn id (a clear is not part of one) and no prompt (the command is a constant in `turn.ts`).

**The confirmation is a fact rather than a promise.** The CLI answers `conversation_reset` with a new conversation id; the agent host records it — so the resume pointer follows the clear rather than pointing at the conversation it was told to forget — and the runtime panel shows it. A clear that did not reach the agent leaves the old id on screen.

## Watch for

- **A clear must not claim the Turn slot.** It was briefly added to the list of requests that set `state.turn` in the Rust host, which would have detached a running Turn from its own exit reason. A clear is not a Turn.
- The failed-turn `CLEAR` gets the same pair of actions as the idle one. A conversation abandoned after an error is exactly one someone wants gone from both sides.
- Fire-and-forget on purpose: no agent running is an ordinary reason for this to do nothing, and it is not a failed clear.

- [x] The agent knows its working directory without running a command
- [x] `/clear` empties the transcript and the agent's memory of it
- [x] The resume pointer follows a clear rather than outliving it
- [x] The states page and any seeded run keep the no-op
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo build` green

Found by the developer, who tried to clear and could not.
