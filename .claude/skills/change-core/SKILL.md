---
name: change-core
description: How to change varnick's own Core — the harness, the host, the chat. Use when a request touches packages/core, packages/harness, src-tauri, vite.config or the root package.json, or when a write to any of those is refused.
---

# Changing Core

varnick is the application you are running inside. You can change it, and the
way you do that is not the way you change anything else.

Read [CONTEXT.md](../../../CONTEXT.md) for what `Core`, `Fence`, `Worktree` and
`Preview` mean, and [ADR-0014](../../../docs/adr/0014-core-is-authored-in-a-worktree.md)
for why this shape rather than another. This file is the procedure.

## The rule

**Core is authored in a git worktree. Never in the live tree.**

The Sandbox denies writes to `packages/core/**`, `packages/harness/**`,
`src-tauri/**`, `vite.config.*`, `package.json` and `scripts/**` — but it names
those as *absolute paths in the live tree*, so the same paths inside a worktree
match nothing and you may write them freely.

That is not a loophole. It is the design: what you write in a worktree is text
until a human merges it, so you can change anything at all and nothing you write
becomes running code without someone reading it first.

## The four beats

### 1. Make a worktree

Use `EnterWorktree`. It lands under `.claude/worktrees/`, which is where the
review list and `launch_preview` both look.

Name it for the change, not for a ticket number — a developer scanning the list
should be able to tell what it is.

### 2. Write, then **commit**

Commit as soon as the change stands up, and commit again as you go.

This matters more than it sounds. The review list counts commits, so **work you
have not committed does not appear in the developer's window at all.** You can
write four files that change what agents are allowed to do and the surface built
to show exactly that will show nothing. If you stop mid-task with uncommitted
work, it is as if you did nothing.

(`launch_preview` compares against the live tree's `HEAD` and *does* see
uncommitted work, so the two disagree today. Ticket 52 is fixing the list. Until
then: commit.)

A multi-line commit message through a heredoc fails — the shell cannot write to
`/tmp` under the Sandbox. Write the message to a file in the worktree, use
`git commit -F`, and delete it.

### 3. Preview it when it is worth seeing

`mcp__varnick__launch_preview` takes the **name** of a worktree under
`.claude/worktrees/` — one path component, not a path. It starts a second
varnick from that worktree, in its own window.

Use it when the change is something to *use* rather than read: anything that
alters the chat, the window, a state machine, the way the agent behaves. Skip it
for a change whose whole story is in the diff.

If the worktree touches **Fence** — `packages/harness/**`, `src-tauri/**`,
`sandbox-policy.baseline.json` — the developer gets a native dialog showing
those hunks and has to approve before anything launches. Expect it, say so
before you call the tool, and do not treat a decline as an error to retry.

First preview of a worktree compiles Tauri and takes minutes. Say so, rather
than leaving them watching a window that has not appeared.

### 4. Stop at the merge

**You cannot merge, and you should not try.** Landing the change means writing
`packages/core/**` in the live tree, and the kernel refuses it. That refusal is
the gate this whole arrangement is built around, not a bug to work around.

Hand over the branch name and say what the developer should look at. They merge,
they restart, the change is live.

## If a write is refused

Work out which wall you hit before changing your approach:

- **In the live tree, under a Core path** — expected. Move to a worktree.
- **In a worktree** — not the Sandbox. A worktree is not a denied path, so
  something else refused you. Say so plainly rather than assuming the Sandbox
  and working around it.
- **Anywhere else** — read `sandbox-policy.json`. It is generated, it is
  commented, and it explains itself. Its comments are more reliable than
  guessing from an error message.
