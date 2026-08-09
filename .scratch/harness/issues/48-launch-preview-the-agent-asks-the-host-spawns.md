# 48 — launch_preview: the agent asks, the host spawns

**What to build:** The agent asks for a Preview of a worktree and the developer gets a window. If that worktree edits the Fence, a native dialog shows the hunks first.

**Blocked by:** 46 — a Preview that cannot take its own port collides with the varnick that launched it.

**Status:** ready-for-agent

**Realizes:** no state path. The Preview is a host process; nothing in Core transitions on it in v1.

## Why a Custom Tool and not a capability

**A confined process cannot open a window.** srt gates mach lookups by service name and varnick's policy names none, so `com.apple.windowserver.active` is unreachable. This is not a gap to close — widening it would put the developer's window server inside the agent's reach for no gain. The agent asks the host, which is what **Custom Tool** already means in `CONTEXT.md`: one narrow capability granted in the host process rather than a policy widened for everything.

The work happens outside the Sandbox, so the tool's own surface is the security boundary.

## The dialog, and the one thing it is for

A Preview runs unconfined, and it must: it reads the Keychain to resolve a Credential. So there is a three-step path from confined to unconfined — the agent edits `sandbox.ts` in a worktree, calls this tool, and the host spawns a varnick whose fence the agent wrote, whose own agent then runs under it.

The dialog stands in that path and nothing else does. Everything else in this amendment is a convenience; this is not.

- **It raises only for Fence changes** — `packages/harness/**`, `src-tauri/**`, `sandbox-policy.baseline.json`. `packages/core/**`, `vite.config.*` and `package.json` are Core and launch silently. A dialog on every Core preview is a dialog nobody reads by the second week, which is worse than no dialog.
- **It is native, drawn by the Rust host.** Userspace renders in the same window and the agent writes Userspace freely, so a Surface could draw a convincing fake and train the developer to click through. Userspace cannot draw a native dialog at all.
- **It shows the hunks.** [ADR-0005](../../../docs/adr/0005-two-profiles-live-userspace-cloned-core.md) found this and it survives its own supersession: approving a request means approving a sentence the agent wrote, and that sentence is exactly what prompt injection produces.

## Watch for

- **The tool takes a worktree name, never a command, never a path.** It is a host-side process spawn driven by agent input, which is a shell out of the Sandbox if it is shaped carelessly. Validate the name against the worktrees git itself reports, and refuse anything else — `../..`, an absolute path, a name with a separator in it. **The refusals are the tests that matter**; a passing happy path proves nothing here.
- The Preview is spawned with `VARNICK_CLONE_ROOT` at the worktree, so build root and clone root are the same and ticket 30 does not apply. Do not route this through a second root.
- Its Session mirror is keyed per clone root already ([ADR-0012](../../../docs/adr/0012-the-clone-root-is-an-input.md)), so the Preview's conversation stays out of the developer's. Confirm rather than assume.
- A fresh worktree has no `node_modules`. Decide where `bun install` happens and say so; it is not a surprise to discover at launch.
- No test may open a dialog or spawn a real Preview.

- [ ] The agent calls the tool with a worktree name and a window appears
- [ ] A worktree touching only `packages/core/**` launches with no dialog
- [ ] A worktree touching `packages/harness/**`, `src-tauri/**` or the baseline raises a native dialog before launching
- [ ] The dialog shows the changed Fence hunks, not a summary
- [ ] Declining the dialog launches nothing and tells the agent it was declined
- [ ] A worktree name that is not one git reports is refused, and the refusal is asserted for `../..`, an absolute path, and a name containing a separator
- [ ] The Preview's Session does not appear in the launching varnick's transcript
