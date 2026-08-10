# 51 — The agent could investigate anything and write nothing

**What to build:** The agent's writes are decided by the Sandbox policy and by nothing else. Done — this ticket is the record of a defect found by using the product, not a plan.

**Blocked by:** None.

**Status:** done

**Realizes:** no state path.

## What was wrong

`CONTEXT.md` has said since the Sandbox was first defined that varnick **replaces** the Agent SDK's permission layer: *"Avoid: permissions (the SDK's prompt layer, which this replaces)."* [ADR-0003](../../../docs/adr/0003-containment-wraps-the-process-tree.md) is the whole argument for why — containment belongs around the process tree, at the kernel, rather than at a prompt.

It was never turned off. `permissionMode` appeared exactly once in the repository, at `agent.ts:1105`, in the containment probe. The chat agent's `query()` set neither it nor `canUseTool`, so the SDK applied its documented default — `'default'`, which *"prompts for dangerous operations"* — against a product with no prompt surface and no registered callback.

**Every prompted tool use was refused.** `Read`, `Grep` and a read-only `Bash` pass that check, which is why this survived: the agent investigated freely, explained itself well, and could not write a file. It read as a sandbox that was slightly too tight rather than as a second boundary nobody had configured.

## How it was found, which is the part worth keeping

Not by a test. By driving the loop tickets 45–50 exist for: asking the agent for a Core change and watching the Session mirror while it worked.

It went to a **Worktree** unprompted — `CLAUDE.md` was enough, which is a separate result and a good one — and was refused there anyway. A worktree is a path `denyWrite` does not name, so the refusal could not be the Sandbox, and the agent said so itself before anyone asked.

Two walls stood where the design describes one, and the kernel had been getting the credit for months. The four ADRs, eleven containment probes and the boundary tests were all measuring the wall that was real; nothing was measuring whether it was the *only* one.

## The fix

`agentPermissionOptions()` in `packages/harness/src/agent.ts`, spread into the chat agent's `query()` beside `sandbox: { enabled: false }` — two halves of one sentence, kept together because separating them is how one of them went missing.

```ts
permissionMode: 'bypassPermissions',
allowDangerouslySkipPermissions: true,   // the SDK refuses the first without the second
```

Narrower modes were considered and rejected in the function's own comment. `'dontAsk'` needs an allowlist of tools and paths maintained beside `sandbox-policy.json` and free to disagree with it — and two boundaries that can disagree is how the first stops being believed. `'acceptEdits'` covers `Edit` and not `Bash`, confining an agent to nothing but its own choice of tool.

## What it costs, stated rather than buried

Everything the agent may do is now decided by `sandbox-policy.json` and nothing else. A mistake there is no longer caught by a second layer, because there is no second layer.

That is the design, not a regression — it is why the policy is denied to the agent, why the baseline records what varnick generated, and why the probes run real operations instead of reading the file back. But it is worth writing down that the margin for error in that one file just became the whole margin.

## What this suggests looking at next

**Nothing asserted that the agent could write.** Every containment assertion in this repository is of the form "this is refused". Not one is of the form "this is permitted", and the product's entire value is in the second kind. A probe that writes a file in Userspace and a file in a Worktree, and requires both to succeed, would have failed from the first day.

- [x] The chat agent runs with the SDK's permission layer off
- [x] `permissionMode` and `allowDangerouslySkipPermissions` are asserted as a pair, so a half-applied fix cannot pass
- [x] The narrower modes are refused by name, with the reason
- [x] `CONTEXT.md`'s Sandbox entry says what is actually configured
- [ ] A containment probe asserts a **permitted** write, in Userspace and in a Worktree — not yet written, and it is the assertion that would have caught this
