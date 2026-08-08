# 13 — Say plainly where confinement stops

**What to build:** A reader of the README knows exactly what the boundary does and does not protect, before they walk away from an agent running unattended. Nothing here is a code change; it is the difference between a security claim and a security property, and it can only be written after something has measured the boundary.

**Blocked by:** 04 (the probes). The README may claim only what was measured — writing it earlier is how a documented boundary becomes a believed one.

**Status:** ready-for-agent

**Realizes:** no state path.

- [ ] The README states where confinement is **partial**: Userspace code executes in the host process when it loads, so the agent's output reaches the host by being run. That is the point of the product and cannot be closed without abandoning it
- [ ] It states what the Sandbox does protect — home directory, other repositories, network — and that it does not protect the clone from the code the agent writes into it. Git is the undo
- [ ] It claims confinement only on macOS, unless the bubblewrap or Windows backend has actually been exercised. Neither has been
- [ ] Every claim traces to something ticket 04 measured. A claim with no probe behind it is cut rather than softened

Covers stories 8, 9.
