# 20 — Tell the running agent which secrets exist

**What to build:** The agent knows the names of the stored secrets, so it can write code that references one. Today it does not, and ADR-0006's premise — "the agent authors code that names a secret and never holds one" — is unwired at the naming end.

**Blocked by:** None.

**Status:** ready-for-agent

**Realizes:** no state path.

## What is true today

`describeSecretsForAgent` (`packages/harness/src/secrets.ts`) composes the agent-facing text from names alone, and is tested. Its only caller is `bun run secret brief`, which prints it to a terminal. `runAgentHost` opens the Session with no `systemPrompt` and no `appendSystemPrompt`, so **nothing puts those names in front of the running agent.**

The other half is wired and proven: ticket 12 resolves a named secret host-side at the moment Userspace code runs, and `drive.ts` drives a real integration end to end. So the mechanism works and the agent has no way to know it should use it.

Found by the close-out review. Ticket 10 built the store, ticket 12 built the resolution, and the sentence connecting them — "the agent is given the list of names" — is ticket 10's one unticked criterion.

## The design choice, which is why this is not a one-line fix

The names live in the Keychain, which only the host can read. The agent host runs inside the Sandbox. So the names have to cross, and the question is how:

- **In the spawn environment.** Simplest, and the credential already travels this way. Names are not secret, so nothing about this weakens containment.
- **Through the control channel**, like a Turn or a usage read. Costs more, and buys the thing the environment cannot: the list can change while the agent runs. `bun run secret add` in another process is exactly that case, and ticket 06 already had to solve it for the mirror by re-reading before every save.

The second is probably right for the same reason it was right there — a developer who adds a secret mid-session should not have to relaunch — but the first is defensible for v1 and honest if said out loud.

## Watch for

- **Names are not values.** Nothing in this ticket may put a value in a system prompt, an environment variable the agent can read, or a log. The value path is ticket 12's and it stays there.
- **A name is a hint, not an instruction.** `describeSecretsForAgent` already says the agent cannot read a value and must reference by name; whatever carries it should not re-word that.
- The copy now also says *where* a secret resolves — host-side, not in a renderer — because a Surface in the window reads `undefined`. Keep that.

- [ ] The running agent is told the names of stored secrets, and never a value
- [ ] A secret added while varnick is running becomes visible to the agent, or the ticket records that it does not and why
- [ ] The agent writing `process.env.NAME` in a Userspace module works end to end, driven the way `drive.ts` already drives ticket 12's integration
- [ ] Ticket 10's second criterion — "the agent is given the list of names" — is ticked, or restated to match what shipped

Covers story 17, and completes what ticket 10 left open.
