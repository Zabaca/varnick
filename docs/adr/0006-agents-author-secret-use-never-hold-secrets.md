# The agent authors code that uses secrets; it never holds one

A Secrets Store the agent can read is just a config file with extra steps. The agent instead writes code that *names* a secret, and the host resolves that name to a value when it runs the code — so `process.env.STRIPE_KEY` appears in the Userspace the agent builds while no secret value ever enters the sandbox.

## Consequences

- **Egress substitution was considered and rejected for local use.** Anthropic's Managed Agents give the sandbox an opaque placeholder and swap in the real value at the network boundary, which works because they own the egress proxy. Locally that means building and maintaining a proxy, and any client that validates credential format before making a request breaks on the placeholder.
- **The built application runs outside the sandbox, and that is what makes this work.** The agent is confined; the code it produces is not. Secrets are available to the running application and never to the process that wrote it.
- **Secrets and credentials are separate paths.** A credential authenticates the agent itself and is injected by Tauri's main process ([ADR-0003](./0003-containment-wraps-the-process-tree.md)); a secret is used by code the agent writes. Conflating them puts an agent credential where Userspace code can read it.
