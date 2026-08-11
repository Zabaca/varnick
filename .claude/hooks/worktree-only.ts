#!/usr/bin/env bun
/**
 * A convention, not a fence: writes belong in a worktree, not in the live tree.
 *
 * This is a `PreToolUse` hook on the structured file tools. It is deliberately
 * not a security boundary and could not be one — it is registered in
 * `.claude/settings.json`, which the agent can edit, and it sees `Bash` not at
 * all, so a shell redirect goes straight past it. The kernel deny list in
 * `sandbox-policy.json` is what actually protects anything.
 *
 * What it is for is the other failure, which is the likely one across a long
 * unattended run: the agent writing a file it meant to write, in the tree it
 * did not mean to write it in. A denial here costs one tool call and carries the
 * instruction with it, so the recovery is "make a worktree" rather than "notice,
 * three commits later, that main moved".
 *
 * The repository root is derived from this file's own location rather than from
 * the working directory, because the working directory is exactly the thing in
 * question when the agent has already stepped somewhere unexpected.
 */
import { dirname, resolve } from 'node:path'

/** `<repo>/.claude/hooks/worktree-only.ts` → `<repo>`. */
const REPO = dirname(dirname(dirname(import.meta.path)))

/**
 * Paths in the live tree that are still the agent's to write.
 *
 * `.claude` carries the worktrees themselves and this hook's own configuration;
 * `.scratch` is the issue tracker, which is notes about the work rather than the
 * work. Both are things a worktree would make harder to no purpose — an issue
 * filed on a branch is an issue nobody reads.
 */
const EXEMPT = ['.claude', '.scratch']

const input = (await Bun.stdin.json()) as {
  tool_input?: { file_path?: string; notebook_path?: string }
}

const named = input.tool_input?.file_path ?? input.tool_input?.notebook_path
// No path to judge is not a violation. A tool shape this hook does not
// recognise should pass rather than block work on a guess about its arguments.
if (typeof named !== 'string' || named === '') process.exit(0)

const path = resolve(REPO, named)

const inRepo = path === REPO || path.startsWith(`${REPO}/`)
const inWorktree = path.includes('/.claude/worktrees/')
const exempt = EXEMPT.some((dir) => path.startsWith(`${REPO}/${dir}/`))

// Outside the repository entirely is not this hook's business: the sandbox
// already answers that, and answering it twice would mean two places to change
// when the answer moves.
if (!inRepo || inWorktree || exempt) process.exit(0)

console.log(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `${named} is in the live tree. Work happens in a worktree: create one under ` +
        `.claude/worktrees/ (EnterWorktree, or \`git worktree add\`), write there, commit, ` +
        `and hand over the branch. If this write really does belong in the live tree, ` +
        `say so and ask the developer to allow it.`,
    },
  }),
)
