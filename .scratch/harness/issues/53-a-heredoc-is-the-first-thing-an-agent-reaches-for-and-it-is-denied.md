# 53 — A heredoc is the first thing an agent reaches for, and it is denied

**What to build:** An agent writing a multi-line string through `bash` succeeds, without widening the Sandbox.

**Blocked by:** None — can start immediately.

**Status:** done — an environment fix, and the cause was not the one this ticket guessed. See the measurement at the foot.

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

- [x] A `bash` heredoc succeeds inside the Sandbox
- [x] Why it failed is recorded — environment or policy — with the measurement
- [x] If the fix is environmental, `allowWrite` is unchanged
- [x] Ticket 27's finding is folded in rather than left beside this one

Found by driving the loop: the agent hit it while committing its own work.

## What it actually was

**`srt` sets `TMPDIR=/tmp/claude`, and that path is in neither list.** It is
baked into the wrapped command itself — `env TMPDIR=/tmp/claude … sandbox-exec
…` — so every process inside the Sandbox inherits a temporary directory the
kernel refuses. Measured by asking a wrapped shell what it had, which is probe
9c:

```
probe 9c — a heredoc needs somewhere to put a file
  $TMPDIR as srt leaves it        exit 0 — /tmp/claude
  $TMPPREFIX, zsh's default       exit 0 — /tmp/zsh
  zsh heredoc, as inherited       exit 1 — zsh:1: can't create temp file for here document: operation not permitted
  bash heredoc, same environment  exit 0 — hello
  zsh heredoc, varnick's values   exit 0 — hello
  write /private/tmp directly     exit 1 — touch: /private/tmp/… Operation not permitted
```

Three things in that block are worth more than the fix.

**It is shell-specific, which is why it read as random.** `bash` and `sh` write
a here-document to a pipe and never touch the filesystem — both pass under the
same policy at the same moment zsh fails. Only zsh needs a file. Claude Code's
Bash tool runs the developer's login shell, which on macOS is zsh.

**`TMPPREFIX` is a second variable, not a consequence of the first.** zsh does
not derive it from `TMPDIR`; it defaults to the literal `/tmp/zsh` and consults
it first for here-documents. Setting only `TMPDIR` leaves the heredoc exactly as
broken as it was, which is the version of this fix that would have looked right
and shipped nothing.

**The question this ticket asked was the wrong one.** It asked whether `TMPDIR`
was *absent*. It is present and wrong, which no amount of looking at
`agentEnvironment` would have shown — the value is added below varnick, by the
wrapper, after the environment varnick built.

## What shipped

`agentEnvironment` sets both variables to a directory inside the clone
(`.varnick/tmp`, gitignored, created at launch beside `.varnick/claude`), for the
same reason `CLAUDE_CONFIG_DIR` and `BUN_CACHE_DIR` are set there: the value that
reaches the agent should be varnick's, not whatever the layer below left.

**`allowWrite` is unchanged**, which was this ticket's third criterion and the
right outcome. Granting `/tmp/claude` would have bought a fixed name directly
under a world-writable directory, shared with every user on the machine, to fix
a variable.

## Ticket 27's finding, folded in

`/tmp/claude-<uid>` stays granted and is a **different path for a different
reason**: it is Claude Code's own scratch, it does not honour `TMPDIR`, and
without it no Bash command runs at all. Two temporary directories, two reasons,
and neither replaces the other. The comment on `allowWrite` in `sandbox.ts` said
"Claude Code does not honour `TMPDIR`" and a reader could take that as "`TMPDIR`
is not worth setting"; it now says which claim it is making.

## Watch for

- **This probably explains more than a heredoc.** Anything inside the Sandbox
  that writes to `$TMPDIR` has been writing to a denied path all along — the
  suspected cause of the test failures ticket 60's spike was chasing. Worth
  re-measuring the suite inside the fence now that the variable is right.
- A Worktree gets the live clone's `.varnick/tmp`, because the agent host's
  clone root is the clone. That is correct today and worth remembering if the
  agent host is ever launched *for* a worktree.
