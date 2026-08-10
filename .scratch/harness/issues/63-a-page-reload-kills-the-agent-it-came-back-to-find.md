# 63 — A page reload kills the agent it came back to find

**What to build:** A webview reload rejoins the agent that is already running,
rather than killing it and starting another.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no new state path. `agent.routing` already has a `running`
target; nothing live ever reaches it.

## The defect

**Reloading the page terminates the running agent and every subagent under it.**
Not a stale view, not a dropped subscription — the process tree is killed and a
new one is spawned in its place. Mid-Turn, the work is gone.

Three links, each reasonable alone:

**Core comes back believing no agent exists.** The `agent` region routes on
`context.enterAgent` (`packages/core/src/machines/harness.ts:899`). The live
input at `packages/core/src/hooks.ts:172` passes `{ policy, sessionInput }` and
nothing else, so `enterAgent` is null and the region falls through every guard to
`{ target: 'down' }`. Only `data/scenarios.ts` ever sets that field — it exists
for the states page, and live start-up has no equivalent.

**Core then starts one, unprompted.** `packages/core/src/pages/DesignedPage.tsx:129`
fires `START` as soon as the credential is present, the Sandbox is available and
the agent reads `down`. It never asks the host whether a process is already
running, because until now "down" and "no process" were the same thing.

**The host kills the old one to honour that.** `src-tauri/src/agent.rs:519`:

```rust
kill_group(state.group.take());
state.generation += 1;
state.exit = None;
state.turn = None;
```

followed by `self.events.restart()`. `kill_group` takes the whole process group —
the srt wrapper, `sandbox-exec`, Claude Code, and every subagent beneath it — and
the queue restart discards anything the dying agent had already said that nobody
had read yet.

That last part is right on its own terms: a spawn *should* replace, and a delta
from a replaced agent must not land in the new one's transcript. The bug is that
a reload asks for a spawn at all.

## The second, independent loss

**A Turn in flight is not in the mirror, so resume cannot bring it back.** Every
mirror write is a Turn boundary: `saveTranscript` at
`packages/core/src/machines/session.ts:523` (answered), `:539` (failed) and
`:589` (interrupted). `SEND` appends the user's message to context and does not
save.

So between pressing send and the Turn settling, the prompt and every accumulated
delta exist only in webview memory. `restoreSession` reads a mirror that has
never heard of them, and the developer loses their own question along with the
answer.

**These are two defects, not one.** Fixing the reload so it rejoins does not fix
this, because the agent host can also die on its own — it has, repeatedly, on
read-allowlist gaps. Fixing the mirror does not fix the reload, because a
restored transcript over a killed agent is a transcript with no one to continue
it.

## Why it is worse than it looks

**ADR-0009 says the Session is durable host-side, and ADR-0014 leans on that.**
ADR-0014:105 excludes `packages/core/**` from hot-swap and sends a full page
reload instead, on the stated grounds that "a full reload is safe here because
the Session is durable host-side and resumes from the mirror". That is true
between Turns and false during one.

Which means **the mechanical rule ADR-0014 introduced can fire mid-Turn and kill
the agent that asked for the change.** ADR-0005's remembered restart at least
happened when a human chose the moment. Nothing today defers the reload until the
Turn settles.

## The shape of the answer

The host already knows. `agent.rs` holds the group, the generation and the exit;
`await-agent-exit` answers immediately for a process that has already gone. What
is missing is a way for a freshly loaded Core to *ask* — something like
"is an agent running, and what is its pid" — and an `enterAgent` computed from
that answer at start-up, exactly the way `sessionInput` is computed from
`restoreSession`.

Two constraints worth stating before anyone designs it:

- **Do not make spawn idempotent.** Replacing on spawn is correct and load-bearing
  (ADR-0003 — containment wraps the process tree). The fix belongs at the caller
  that should not have asked, not at the kill that was asked for.
- **A rejoined agent must still be contained.** Core does not get to conclude
  "already running, therefore fine". Whatever answers the question must answer it
  from the host's own record of the process it spawned under the Sandbox, not
  from a pid Core remembered.

For the mirror half, the question is what a save during `answering` costs. A
write per delta is not it. A write when the user's message is appended, plus one
on a coarse interval or on the partial crossing a size, would bound the loss to
seconds without making the mirror a hot path.

## Watch for

- **The reload must not defeat itself.** If Core rejoins rather than spawns, a
  developer whose agent is genuinely wedged loses the restart they got for free.
  Restart stays available and deliberate.
- Check the same path for the Preview's agent, which is spawned separately.
- ADR-0009 and ADR-0014 both need a sentence once this lands — the durability
  claim they rest on is narrower than either says.
- Ticket 57 (varnick does not know it is running old code) shares a cause here:
  both are about what survives a change to Core.

- [ ] Reloading the page while the agent is running leaves that process alive
- [ ] Its subagents survive too
- [ ] The window shows the agent as running, without a second spawn
- [ ] A Turn in flight when the page reloads is not silently lost
- [ ] The user's own prompt survives a reload taken between send and answer
- [ ] A deliberate restart still replaces the process, tree and all
- [ ] A rejoined agent is one the host spawned under the Sandbox, not one Core
      assumed

Found by asking why a refresh cost a running `/code-review`, and reading the
three files between the reload and the `kill_group`.
