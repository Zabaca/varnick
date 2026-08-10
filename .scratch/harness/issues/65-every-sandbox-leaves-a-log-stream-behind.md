# 65 — Every Sandbox leaves a `log stream` behind

**What to build:** The violation monitor dies with the process that started it.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path.

## Measured

Thirty-one orphaned monitors on this machine, all reparented to `launchd`:

```
$ ps -eo pid,ppid,etime,command | grep 'log stream --predicate.*_SBX'
  942  1  01-10:51:31   log stream --predicate (eventMessage ENDSWITH "…_SBX") --style compact
 5900  1  01-10:47:19   …
13102  1     14:59:20   …
                        … 31 in total, the oldest over a day old
```

`ppid 1` is the tell: the process that spawned each one is long gone and the
`log stream` outlived it. They accumulate one per Sandbox established — every
launch, every Preview, and every run of the containment probes, which establish
and release several.

## Why it matters more than a stray process

**It is the shape ADR-0003 is about.** Containment wraps the *process tree*, and
ticket 35 fixed the version of this that mattered most — every shutdown left a
sandboxed agent running. This is the same failure one process to the side: a
child that varnick spawned, that varnick does not reap, surviving into a state
where nothing knows it exists.

`log stream` is not free either. Each one holds a subscription to the unified log
with a predicate the kernel evaluates against every message. Thirty-one of them
is a background cost a developer will notice as battery and will never attribute
to varnick, because the process is called `log`.

**And it is a leak of exactly what varnick added to be careful.** The monitor
exists because srt watches the kernel for denials and varnick was not listening;
it went in so that a boundary failure has a voice. A watcher that outlives its
subject is that voice describing a Sandbox that no longer exists.

## Where to look

`watchSandboxViolations` in `packages/harness/src/sandbox.ts` spawns it, and
`SandboxViolationWatch.stop()` is meant to end it. The interesting question is
which paths never call `stop`:

- `releaseSandbox()` — the probes call it in a `finally`, so if the watch were
  released with the Sandbox there would be no orphans from the test suite, and
  there are.
- process exit — a runtime that is killed rather than asked to stop takes no
  cleanup path at all, which is why `watchForOrphaning` exists for the other two
  processes.

Both are worth measuring rather than assuming; the fix is likely in both.

## Watch for

- **Do not reap by name.** `pkill log` on a developer's machine is not varnick's
  to do, and `log stream` is a general-purpose tool somebody else may be running.
  What varnick may end is a pid it holds.
- The predicate embeds a per-Sandbox tag, so an orphan can be *identified* as
  varnick's without guessing — useful for a swept cleanup at startup, if that is
  the answer for the ones already out there.
- Whatever ships, releasing a Sandbox and killing the process that holds one must
  both end the watch. One of them alone leaves the other leaking.

- [ ] Releasing a Sandbox ends its violation watch
- [ ] A runtime that is killed leaves no monitor behind
- [ ] Running the containment probes leaves none behind either
- [ ] Monitors already orphaned on a developer's machine are dealt with, or the
      decision not to is written down
- [ ] Nothing is killed by name

Found while reaping a merged Worktree: the cwd probe correctly refused to remove
the directory, and the process standing in it was one of these.
