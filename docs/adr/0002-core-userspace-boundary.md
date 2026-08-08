# Core and Userspace are separated by the sandbox policy, not by convention

The agent edits the clone it is running inside, so the code that holds the conversation is code the agent could otherwise break — and the conversation is what you would use to fix it. The sandbox policy therefore denies writes to `packages/core/**`, `vite.config.*`, and `package.json`, making the split kernel-enforced rather than a rule in `CLAUDE.md`. The agent's blast radius is Userspace; Core is changed through the escalation path in [ADR-0005](./0005-two-profiles-live-userspace-cloned-core.md).

## Consequences

- **Surfaces must be discovered, not registered.** A new Surface cannot require appending to an imports array in Core, because the agent cannot write Core. Discovery is filesystem-based — `userspace/surfaces/*` scanned at load. Getting this wrong blocks the product's main loop on day one.
- **The build-pipeline escape mostly closes as a side effect.** With `vite.config` and `package.json` scripts denied, an agent cannot reach the host by writing a Vite plugin or a `postinstall` script. What remains is application code the host runs — a real and knowingly accepted hole, since the whole point is that the agent's output becomes running code.
- **The protection is real but partial, and is described that way.** Userspace code executes in the host process when loaded. The Sandbox protects `$HOME`, other repositories, and the network; it does not protect the clone from the code the agent writes into it.
