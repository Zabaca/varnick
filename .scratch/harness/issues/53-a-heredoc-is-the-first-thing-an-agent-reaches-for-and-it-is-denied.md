# 53 — A heredoc is the first thing an agent reaches for, and it is denied

**What to build:** An agent writing a multi-line string through `bash` succeeds, without widening the Sandbox.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## What happens

The agent tried to commit with the ordinary idiom:

```
git commit -F - <<'MSG'
...
MSG
```

and reported: *"Heredoc needs `/tmp`, which the Sandbox denies. Writing the message to a file instead."* It wrote `COMMIT_MSG.txt` into the worktree, committed with `-F`, and deleted it — a good workaround that it had to invent, mid-task, having already had one failure.

The policy is why. `/tmp` is in `allowRead` and **not** in `allowWrite`:

```
allowWrite: <clone>, /var/folders/vf/…/T, /private/tmp/claude-501, /private/tmp/claude-*-cwd
```

So the shell can read `/tmp` and cannot create the temporary file a heredoc needs.

## Why this is worth a ticket rather than a shrug

A heredoc is not an exotic construct. It is how every agent writes a commit message, a config file, or a patch through `bash`, and it fails with an error about `/tmp` that says nothing about the Sandbox. The agent recovered here; the cost was a wasted Turn and a workaround in a transcript a developer will read as noise.

This is the same family as ticket 27 — *bash cannot create its scratch directory* — and it should be settled with it rather than opened cold beside it. Read that ticket first.

## The question to answer, not a decision already taken

`TMPDIR` already points at `/var/folders/vf/…/T`, which **is** writable. So the interesting question is why the shell reached for `/tmp` at all — whether `TMPDIR` is absent from the agent's environment, or bash ignores it for heredocs on this platform. Measure that before changing any policy.

If the answer is a missing environment variable, this is an `agentEnvironment` fix and the Sandbox does not move — which is much the better outcome and is the one to try first.

## Watch for

- **Do not add `/tmp` to `allowWrite` to make this go away** without establishing that the environment route cannot work. `/tmp` is world-writable and shared with every other process on the machine; the temp roots already granted are not.
- Whatever ships, a developer reading the transcript should not have to learn this by watching an agent fail at it.

- [ ] A `bash` heredoc succeeds inside the Sandbox
- [ ] Why it failed is recorded — environment or policy — with the measurement
- [ ] If the fix is environmental, `allowWrite` is unchanged
- [ ] Ticket 27's finding is folded in rather than left beside this one

Found by driving the loop: the agent hit it while committing its own work.
