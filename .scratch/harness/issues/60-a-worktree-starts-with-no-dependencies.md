# 60 — A Worktree starts with no dependencies, and each agent solves it again

**What to build:** An agent that enters a Worktree can run the tests without first rebuilding `node_modules` by hand.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## The gap

`node_modules` is gitignored, and a Worktree is a fresh checkout. So every
Worktree begins with no dependencies at all — no `bun test`, no `typecheck`, no
`drive.ts`, nothing that would tell an agent whether its change works.

Nothing in varnick provisions them, so the agent improvises. Measured on the
ticket-55 subagent, in the middle of unrelated work:

```
17 symlinks, across three node_modules directories
  <worktree>/node_modules                 -> live tree
  <worktree>/packages/core/node_modules   -> 14 packages linked one at a time
  <worktree>/packages/harness/node_modules
```

`react`, `react-dom`, `xstate`, `@xstate`, `typescript`, `vite`, `@vitejs`,
`tailwindcss`, `@tailwindcss`, `tailwind-merge`, `clsx`,
`class-variance-authority`, `@types` — each its own tool call, each a guess at
what the next command would need. Bun's isolated layout puts dependencies both
at the workspace root *and* per package, so linking the root alone is not
enough and the agent discovered that by failing.

This is not a one-off. It happens on **every** Worktree, and
[ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md) makes a
Worktree the required path for every Core change. The cost is paid by whoever
enters one, forever, and it is paid in the middle of the work rather than up
front.

## The same shape as ticket 54, on the other runtime

Ticket 54 is a Preview rebuilding 348 crates because the Worktree has its own
`CARGO_TARGET_DIR`. This is that finding on the Bun side: **a Worktree costs
setup that nothing provides.** The two are worth fixing together — one place
decides what a new Worktree gets, and it should hand over both.

Treat them as one job with two halves rather than two unrelated chores, because
the wrong version of each fix is the same wrong idea: copy everything.

## The shape of the answer

Whatever creates the Worktree provisions its dependencies. Two candidates,
and the measurement decides:

- **Link, as the agent did** — the root and each package's `node_modules`
  pointed at the live tree's. Instant, no disk, and correct as long as the
  dependency set is the same. It is: `package.json` is on the deny list, so the
  agent cannot change what is installed from inside a Worktree.
- **Install** — `bun install` in the Worktree. Honest but slow, duplicates the
  store, and **may not be possible at all**: the Sandbox's egress allowlist
  decides whether a registry is reachable, and that has never been tested from
  inside a Worktree. Measure before assuming; do not widen the allowlist to make
  it work.

The link approach is the one to try first, and its limitation is worth writing
down rather than discovering later: a Worktree whose branch changes
`package.json` gets the live tree's dependencies, not its own. That branch
cannot come from the agent, but it can come from a human, and the failure should
say so rather than producing a confusing type error.

## Watch for

- **Do not commit the links.** `.gitignore` already covers `node_modules`; a
  provisioning step that stages anything has gone wrong.
- **Removing the Worktree must not follow a link out into the live tree.** `git
  worktree remove` and any cleanup in ticket 56 delete a directory that now
  contains symlinks to the real dependency store. Verify this explicitly — the
  failure mode is deleting the live tree's `node_modules`, which is silent until
  the next build.
- The Preview path (`launch_preview`) needs the same provisioning and gets it
  from the same place. A Preview that cannot resolve `react` is a Worktree that
  was never set up.
- This is host-side work. The agent should arrive to a working Worktree rather
  than being taught a recipe for building one — a skill step that says "link
  these fourteen packages" is the same cost moved into prose.

- [ ] A newly created Worktree can run `bun test` without manual setup
- [ ] It can run `typecheck` and `drive.ts` too
- [ ] The root and every package's `node_modules` are provisioned, not just the root
- [ ] Nothing provisioned is ever staged or committed
- [ ] Removing a Worktree leaves the live tree's `node_modules` intact
- [ ] A Preview launched from a Worktree starts without manual setup
- [ ] Whether `bun install` works inside the Sandbox is measured and recorded, without widening the egress allowlist

Found watching a subagent spend its opening tool calls on `ln -s` instead of on
ticket 55.
