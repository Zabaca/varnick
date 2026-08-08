# 04 — Probe the containment against a real sandboxed process

**What to build:** Evidence that the boundary in tickets 01 and 03 is the boundary the product claims. A probe suite runs a real agent under the real policy and reports what it could and could not reach. Until this exists, the confinement claim rests on documentation — which is exactly how the `Read`/`Grep` hole in the SDK's own sandbox option went unnoticed.

**Blocked by:** 03 (needs a real agent process under the real policy).

**Status:** ready-for-agent

**Realizes:** no state path — this is the evidence for 01 and 03, and the only test in the project that can fail in a way the machines cannot detect.

Seam 2 from the spec. Prior art is `zbc/packages/agent` — its `sandboxed.test.ts` and `e2e/smoke.ts` are the closest existing examples, and its ADR-0002 is the record of what happens when containment is asserted rather than measured.

- [ ] A probe file outside the boundary is unreadable by `Bash`, `Read`, `Grep` **and** `Glob` alike — the last three are the ones that walked past the SDK's option
- [ ] Each denied binary reports as not found
- [ ] A non-allowlisted host is unreachable; an allowlisted host is reachable
- [ ] The run fails rather than proceeding when the sandbox cannot be established
- [ ] The suite's actual output is quoted in the PR, not summarised

Slow and machine-dependent is accepted. A fast version of this test is a version that proves nothing.

Covers stories 1, 2, 5, 6, 7, 10.
