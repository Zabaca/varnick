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

## The answer, measured: `bun install`, not links

A spike ran all four candidates against the real suite. Numbers first, because
they settle it:

| approach | tests loaded | result |
| --- | --- | --- |
| bare Worktree | 442 / 620 | 9 fail, 7 errors — cannot resolve `@anthropic-ai/*` |
| link root `node_modules` only | 442 / 620 | identical — no help at all |
| link root + all four packages | 620 / 620 | 618 pass, **1 fail** |
| `bun install --frozen-lockfile` | 620 / 620 | **619 pass, 0 fail** |

`bun install --frozen-lockfile` took **155 ms** for 462 packages and cost
**12 MB** of real disk. The apparent size is 478 MB; APFS `clonefile` makes it
copy-on-write, and the figure is a free-space delta measured before and after,
not an estimate. It is faster to run than the seventeen symlinks an agent makes
by hand, and it needs no network with a warm cache.

**So the intuition that linking is the cheap option was wrong twice over.** It
is not cheaper, and it does not work.

### Why linking fails, and it is the interesting part

The single failure under linking is `containment.probe.test.ts:300` — *"a file
outside the boundary is unreachable by Bash, Read, Grep and Glob alike"*. It
fails because the resolved module path is
`/Users/…/varnick/node_modules/.bun/zod@4.4.3/…`, in the **live tree**.

Linking places a Worktree's dependencies outside that Worktree's own Sandbox
boundary. Host-side `bun test` does not care, because it is unconfined. Anything
running *inside* the Sandbox rooted at the Worktree — **every Preview** — cannot
read them. Linking fixes the test command and breaks the thing
[ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md) exists for,
and it breaks it in a way no test run from the live tree would ever reveal.

Linking the root alone, worth stating separately, does nothing whatsoever: bun's
isolated layout resolves workspace dependencies from each package's own
`node_modules`, so the four package directories are the load-bearing ones.

### Where it runs

**Host-side, in whatever creates the Worktree.** The agent could not do this
itself even if asked: bun's cache is `~/.bun/install/cache`, and the Sandbox
denies `$HOME`. That is not an obstacle to route around — provisioning happens
before the agent arrives, outside the Sandbox, which is where it belongs.

A cold cache would need the network, and the host has it. Nothing in the egress
allowlist needs widening, because nothing about this runs confined.

## Watch for

- **Do not commit the links.** `.gitignore` already covers `node_modules`; a
  provisioning step that stages anything has gone wrong.
- **`git worktree remove` refuses a Worktree with an installed `node_modules`**
  unless forced — it is untracked content. The spike used `--force` and the live
  tree's 239 `.bun` entries were intact afterwards, checked. Ticket 56's cleanup
  needs the same flag and the same check.
- The symlink hazard the earlier draft warned about is gone with the approach,
  but keep it in mind if anyone reintroduces links: deleting a Worktree that
  links out would take the live tree's `node_modules` with it, silently, until
  the next build.
- The Preview path (`launch_preview`) needs the same provisioning and gets it
  from the same place. A Preview that cannot resolve `react` is a Worktree that
  was never set up.
- This is host-side work. The agent should arrive to a working Worktree rather
  than being taught a recipe for building one — a skill step that says "link
  these fourteen packages" is the same cost moved into prose.

- [ ] A newly created Worktree can run `bun test` without manual setup
- [ ] It can run `typecheck` and `drive.ts` too
- [ ] The full suite passes in a fresh Worktree, containment probes included
- [ ] Nothing provisioned is ever staged or committed
- [ ] Removing a Worktree leaves the live tree's `node_modules` intact
- [ ] A Preview launched from a Worktree starts without manual setup
- [ ] Provisioning failure is reported, not silent — a Worktree with no
      dependencies should say so rather than producing resolution errors later

Found watching a subagent spend its opening tool calls on `ln -s` instead of on
ticket 55.
