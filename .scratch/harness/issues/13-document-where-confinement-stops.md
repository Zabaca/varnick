# 13 — Say plainly where confinement stops

**What to build:** A reader of the README knows exactly what the boundary does and does not protect, before they walk away from an agent running unattended. Nothing here is a code change; it is the difference between a security claim and a security property, and it can only be written after something has measured the boundary.

**Blocked by:** 04 (the probes), 16 (the deny-list wording and the System.keychain question). The README may claim only what was measured — writing it earlier is how a documented boundary becomes a believed one.

**Status:** ready-for-agent

**Realizes:** no state path.

- [ ] The README states where confinement is **partial**: Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run. That is the point of the product and cannot be closed without abandoning it
- [ ] It states what the Sandbox does protect — home directory, other repositories, network — and that it does not protect the clone from the code the agent writes into it. Git is the undo
- [ ] It claims confinement only on macOS, unless the bubblewrap or Windows backend has actually been exercised. Neither has been
- [ ] Every claim traces to something ticket 04 measured. A claim with no probe behind it is cut rather than softened

Covers stories 8, 9.

## Comments

**Blocked in substance by ticket 16.** This ticket cannot be written honestly
until the Keychain question is settled: what confinement stops is currently
different from what every document says it stops. The measurement to write from
is in ADR-0003's correction section and in
`packages/harness/src/sandbox.boundary.test.ts`.

Two things to carry in when it is written, both already measured: three of the
four denied binaries execute, and `packages/userspace/package.json` stays
writable so a `postinstall` there runs on the host's next install (ADR-0002).

## Comments

**Blocked in substance by ticket 16.** This cannot be written honestly until the
Keychain question is settled: what confinement stops is currently different from
what every document says it stops. The measurement to write from is in ADR-0003's
correction section and in `packages/harness/src/sandbox.boundary.test.ts`.

Two things to carry in when it is written, both already measured: three of the
four denied binaries execute, and `packages/userspace/package.json` stays
writable so a `postinstall` there runs on the host's next install (ADR-0002).
