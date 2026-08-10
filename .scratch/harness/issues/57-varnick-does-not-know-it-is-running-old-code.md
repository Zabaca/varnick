# 57 — varnick does not know it is running old code

**What to build:** varnick notices when the checkout has moved past what it is running, says which half is stale, and offers the right control.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** `staleness.current`, `staleness.behind`. Names to be settled with the implementation.

## The gap

Nothing in varnick knows what code it is running. A merge lands, a developer
pulls, an agent's branch is squashed in — and the window carries on, showing a
conversation about a change that is not in the process it is talking to.

This is not only a merge-button concern, which is why it is its own ticket:
the developer commits in a terminal, and the same silence follows.

[ADR-0005](../../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md)
required an explicit restart after a Core merge and ticket 46 made a *Core*
change reload the window rather than hot-swap it. Neither tells anyone that a
restart is **owed**. The rule is honoured by whoever remembers it.

## The two halves are stale differently, and that is the whole design

- **The webview** — `packages/core/**`. In `bun tauri dev` a change here already
  triggers a full reload (ticket 46), so it is rarely behind. On a built app it
  is behind until relaunch.
- **The host** — `packages/harness/**`, `src-tauri/**`. The Node runtime and the
  Rust host are started once, at launch. Nothing reloads them, ever. **This is
  the half that is silently stale**, and it is the half that decides what the
  agent may do.

So the answer is not one boolean. Compare the launch commit against the current
`HEAD`, and ask what the paths between them touch:

- only `packages/core/**` → a reload is enough, and in dev has probably happened
- anything under `packages/harness/**` or `src-tauri/**` → **restart owed**
- nothing → current

## What it should say

Name the state rather than nagging. *"Running `b98d86f`, checkout is at
`c1d2e3f` — the harness changed. Restart to pick it up."* with the control
beside it. Restart varnick is already on the View menu and Shift+Cmd+R already
works; this ticket is about knowing to press it, not about a new mechanism.

The sharpest case is the one that motivated this: the agent authors a Core
change, it is merged, and until the restart **the agent is reasoning about a fix
it believes is live and is not**. An agent that knows it is running old code is
better off than one that does not, which is why ticket 56 sends it a report.

## Watch for

- **Read the launch commit once, at launch.** Deriving it later from a file's
  mtime or a rebuilt binary is guessing; capturing it at start is a fact.
- A dirty working tree is not the same as being behind, and should not be
  reported as it. Uncommitted work is ordinary.
- **Do not poll git.** The same trigger ticket 55 uses — the end of a Turn — plus
  whatever ticket 56's merge does, covers every case varnick causes. A developer
  committing in a terminal is covered by the next Turn.
- This must not become a second place that decides what **Fence** means. The
  restart-owed test is "did the host's code change", which is a different and
  larger question than Fence: `packages/core/**` is Core and not Fence, and
  `src-tauri/**` is both.

- [ ] varnick records the commit it launched at
- [ ] A checkout that has moved is reported, with both shas
- [ ] A change under `packages/harness/**` or `src-tauri/**` says a restart is owed
- [ ] A change under `packages/core/**` alone does not demand a restart
- [ ] The restart control is offered where the message is, not in a menu the developer has to find
- [ ] A dirty tree alone reports nothing
- [ ] Every new state path is named in `CONTEXT.md` and has a card

Asked for while merging the first agent-authored Core change: *"after a merge we should be able to detect the running app is behind and offer a reload/restart button."*
