# 20 — Tell the running agent which secrets exist

**What to build:** The agent knows the names of the stored secrets, so it can write code that references one. Today it does not, and ADR-0006's premise — "the agent authors code that names a secret and never holds one" — is unwired at the naming end.

**Blocked by:** None.

**Status:** done — the control channel, not the environment. See Comments for what settled it and for the one link no test on this machine takes.

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

- [x] The running agent is told the names of stored secrets, and never a value
- [x] A secret added while varnick is running becomes visible to the agent, or the ticket records that it does not and why — **it becomes visible**, on the next Turn, without a relaunch
- [x] The agent writing `process.env.NAME` in a Userspace module works end to end, driven the way `drive.ts` already drives ticket 12's integration
- [x] Ticket 10's second criterion — "the agent is given the list of names" — is ticked, or restated to match what shipped

Covers story 17, and completes what ticket 10 left open.

## Comments

### What was built

The names cross as a fifth `ControlRequest` kind, `describe-secrets`, on the
channel the agent host already holds:

`SecretsStore.names()` → `read-secret-names` on the Harness runtime →
`HarnessRuntime::secret_names` in Rust → `control_line_for` writes one line →
`parseControlRequest` inside the Sandbox → the agent host holds the list →
a `UserPromptSubmit` hook composes `describeSecretsForAgent` into
`additionalContext`, per Turn.

`src-tauri/src/bridge.rs` asks the runtime for the names immediately before
every `run-turn`, and before nothing else: an interrupt stops an answer and asks
the agent for nothing, and a compaction summarises what has already been said.
Both steps are unchecked — a runtime that will not answer, or an agent that is
not running, leaves the agent knowing whatever it last knew, and the Turn still
succeeds or refuses on its own account. A Turn is what the developer asked for;
an unnameable secret makes it a poorer answer, never a failed one.

### What settled the choice, which was not the ticket's argument

The ticket framed this as freshness versus cost, and expected the environment to
be defensible for v1 if the limitation were written down. It is narrower than
that: **the environment has no route to anywhere that could ever be refreshed.**
`appendSystemPrompt` is part of the Agent SDK's `initialize` control request and
is fixed for the life of a session — there is no `setSystemPrompt`, and
`reinitialize()` re-sends the request the session was opened with rather than a
new one. So the environment route could only ever have produced a launch-time
snapshot in a system prompt, with no upgrade path short of the work done here.
The thing that *can* change per Turn is a hook's `additionalContext`, and
filling one needs a channel into the confined process. That is the control
channel or nothing.

Ticket 06's precedent held exactly as the ticket predicted, and it is the same
sentence in a different place: re-read the store rather than trust the snapshot
taken at start-up.

### Names are not values, asserted rather than observed

Four places, each an assertion rather than a comment:

- `parseControlRequest` rebuilds the request out of `kind` and `names`. A line
  carrying `values`, or a `STRIPE_KEY` field, or a nested `secrets` object,
  arrives as names alone — `turn.test.ts` and `agent.test.ts` send all three.
- `control_line_for` does the same in Rust, and the test compares the whole
  parsed line rather than listing the field names a value must not use.
- `read-secret-names` is answered from `store.names()`. `runtime.test.ts` takes
  the assertion on the serialised reply line, over a real store holding a real
  value, because the line is what actually crosses.
- `bun run drive` collects every reply, control line and brief that crossed and
  greps the lot for both values at the end — so the claim is taken over
  everything at once rather than in the places someone thought to look.

Neither `read-secret-names` nor `describe-secrets` is on `route_of`, so the
renderer can neither ask what a developer's keys are called nor tell the
confined agent that a secret exists which does not.

### The copy is carried, not reworded

The `UserPromptSubmit` hook calls `describeSecretsForAgent` and does nothing
else to the text, so the sentences saying a value cannot be read and that
resolution happens host-side survive intact. `drive.ts` asserts both are in what
the agent is handed, because an agent told the second half differently writes
the renderer version of an integration and reads `undefined` with nothing to
explain why.

### The one link no test here takes

That the SDK delivers an in-process `UserPromptSubmit` hook's
`additionalContext` to the model. Everything up to and including the composed
brief is driven; the last hop is the SDK's own contract and would need a real
credential and a real Session to measure. varnick opens a real Session in
exactly one place — the containment probes, which are attestation-gated for
this reason — so it is recorded here rather than measured.
