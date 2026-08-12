# 13 — Read-allowlist gaps are reported as boundary failures

**What to build:** the containment probe's "no unintended denials" assertion
measures the boundary rather than the machine it runs on. Today it fails on this
developer's laptop for reasons that have nothing to do with varnick, which makes
a red suite the normal state and therefore no signal at all.

`containment.probe.test.ts:1463` asserts that no unexpected kernel denials were
reported. It gets `file-read-metadata /nix/var/nix/profiles/default` — a nix
installation on the machine, hitting a gap in the read allowlist. Two further
gaps were observed by separate agents during the same run:

```
file-read-metadata  /nix/var/nix/profiles/default    (causes the failure)
file-read-metadata  /opt/homebrew/bin/git
file-read-metadata  /opt/homebrew/bin/python3
```

None is a boundary being breached. Each is varnick's own message saying so, in
its own words: *"Nothing in sandbox-policy.json names that path, so this is a gap
in the read allowlist rather than the boundary holding."* The message is right.
The test treats it as a failure anyway.

## Why this is worth a ticket rather than a shrug

This failure was read as "flaky pre-existing noise" for the whole of an
autonomous run, by four separate agents and by the orchestrator, before anyone
established what it was. Two of them attributed it to the `~/.gitconfig` defect
(ticket 11), which is a different failure in the same file. That is the cost: a
test that is red for an environmental reason trains everyone who sees it to stop
reading it, and it absorbed a real defect's diagnosis on the way past.

It also breaks the thing the suite is for. `sandbox.boundary.test.ts` and
`containment.probe.test.ts` are where the containment claims are **measured**
rather than asserted — ADR-0013's whole argument. A measurement that is red on a
developer's machine for reasons unrelated to what it measures cannot gate
anything, which means the boundary is effectively ungated on the machine most
likely to change it.

## The decision this needs

Three shapes, and they are not equivalent:

- **Add the paths to the read allowlist.** Simple, but it is a widening, and it
  widens for every clone rather than for the machine that needed it. `/nix` and
  `/opt/homebrew` are package-manager roots that a developer's tooling writes.
- **Let the assertion distinguish a gap from a breach.** varnick already
  distinguishes them in the message it prints; the test does not. This is the
  smallest honest change and it keeps the machine-specific paths out of the
  policy.
- **Make the expected-denial set machine-derived** rather than a literal, so a
  laptop with nix and a laptop without both produce a green suite when the
  boundary holds and a red one when it does not.

The second is probably right and the third is probably better; neither should be
chosen without reading what the assertion is trying to say.

While here: decide whether the two tests are named for what they measure.
`the kernel denials reach varnick, and only the unintended ones are said out
loud` currently fails on the second clause for a reason the first clause makes
correct, which is a confusing thing for a name to do.

This is a Fence change and lands through a human merge.

**Blocked by:** None. Independent of ticket 11, which is a different failure in
the same file — that one is `~/.gitconfig`, this one is the read allowlist.

**Status:** needs-triage

- [ ] The containment probe passes on a machine with nix and homebrew installed, when the boundary holds
- [ ] It still fails when the boundary does not hold, and a test proves that direction rather than assuming it
- [ ] The distinction varnick already prints — allowlist gap versus boundary breach — is the one the assertion uses
- [ ] The chosen approach is recorded with its trade-off, since the obvious one is a widening
- [ ] Both test names say what they actually measure

## Do not close this on a green run

The failure is **intermittent in a full-suite run**. Measured on `main` at
`ce6bb4c`, same tree, three consecutive `bun test packages`:

```
run 1   839 pass   0 fail
run 2   838 pass   1 fail
run 3   838 pass   1 fail
```

It is also **not reliably intermittent**: ticket 18's author measured it 3/3 on
a branch that touches no policy file, on this same machine, where the
orchestrator had measured 0/1/1 on `main` an hour earlier. So neither a green run
nor a red one settles anything on its own.

Run the two files in isolation instead, where the result is consistent. A green
full-suite run is not evidence that this is fixed, and at least one agent this
run reported `0 fail` on a branch that had shown the failure minutes earlier and
correctly declined to claim credit for it.

Whatever closes this ticket needs to demonstrate the fix by making the probe
fail for the right reason and then pass — not by observing a green run.

## Comments

Surfaced independently by three agents during the autonomous-runs implementation
of 2026-08-11, each initially reading it as pre-existing flakiness. The
orchestrator measured it directly and found the full-suite result unstable while
the per-file result was consistent, which is what separated it from ticket 11.
