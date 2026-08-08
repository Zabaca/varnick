# Containment probes against a real sandboxed process

**Status:** ready-for-agent

**Realizes:** nothing new on the states page. This is the evidence for 01 and 04, and the only test in the project that can fail in a way the machines cannot detect.

Seam 2 from the spec. A mocked sandbox proves nothing about the one claim the product rests on, and the `Read`/`Grep` hole in the SDK's own sandbox option was found only by running the real thing and reading the output.

Assert, against a live agent process under the real policy:

- a probe file outside the boundary is unreadable by `Bash`, `Read`, `Grep` **and** `Glob` alike — the last three are the ones that walked past the SDK's option
- each denied binary reports as not found
- a non-allowlisted host is unreachable; an allowlisted host is reachable
- the run fails rather than proceeding when the sandbox cannot be established

Prior art is `zbc/packages/agent` — `sandboxed.test.ts` and `e2e/smoke.ts` are the closest existing examples, and its ADR-0002 is the record of what happens when containment is asserted from documentation instead of measured.

**Done when** the suite runs on a real machine and its output is quoted in the PR. Slow and machine-dependent is accepted; a fast version of this test is a version that proves nothing.

Covers stories 1, 2, 5, 6, 7, 10.
