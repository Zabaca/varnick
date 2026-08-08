# 12 — Resolve secret names when the host runs built code

**What to build:** Code the agent wrote, referencing a secret by name, works when it runs — because the host substitutes the real value at the moment of execution, outside the agent's process. The agent that built the integration stayed blind to the value the whole time.

**Blocked by:** 10 (the store and the name list), 14 (something that runs Userspace code).

**Status:** done — see Comments for where resolution can and cannot reach today

**Realizes:** no state path.

**The seam, decided.** Resolution happens at the moment the host runs Userspace code. Splitting ticket 10 exposed that v1 had no such moment — rendering Surfaces had been cut — so a store would ship with no consumer and ADR-0006 would be a claim rather than a demonstrated property. Resolving instead when the host runs a plain script, with no Surface involved, was considered and rejected: the loader is already modelled, already proven by `drive.ts`, and already the thing the product is for. A minimal execution path came back into v1 as ticket 14, and this ticket hooks into it.

The open question in ticket 11 — whether the dev server can itself run inside the sandbox — touches the same seam and is worth answering alongside.

- [x] Resolution happens host-side at the moment a Userspace module runs, never inside the agent's process
- [x] An integration written by the agent works end to end
- [x] No secret value reaches the transcript, a log, or the Session mirror

Covers story 18, and completes 17.

## Comments

**Where resolution happens.** `importSurface`'s third argument, in
`packages/core/src/surfaces.ts`. `await load()` *is* the evaluation of a
Userspace module, so that call is the window: names are bound before it and
unbound in its `finally`. The implementation is `hostSecretResolution` in
`packages/harness/src/secret-resolution.ts`, on the host side, where the store
already is.

**The mechanism, which is one property descriptor.** A resolved secret is
defined on `process.env` as a **non-enumerable accessor**. `process.env.STRIPE_KEY`
reads it, because reading it is naming it. Nothing that walks the environment
sees it: `Object.keys`, `Object.entries`, spread, `JSON.stringify`,
`util.inspect` — and `agentEnvironment` in `packages/harness/src/agent.ts`, the
function that builds the environment Claude Code is spawned with, which walks
`Object.entries` and therefore *cannot* see one rather than having to remember
to skip it. A child process handed `process.env` does not receive one either;
measured, with a plainly-assigned variable beside it as the control. This is
ticket 02's move in another language: there, "the value cannot cross" is a
property of the type because `Secret` has no `Serialize`; here it is a property
of the descriptor. Both survive someone forgetting they exist.

**A Surface that prints its own secret: out of scope to prevent, deliberately.**
Code that names a secret can do anything with the string, including render it,
log it, or write it into a file the agent can then `cat`. Preventing that would
mean not resolving at all — the value has to reach the running integration or
there is nothing to resolve — and it is the same knowingly accepted hole
ADR-0002 already records one level up: application code the host runs is exactly
what the agent's output is for. What *is* prevented is every path a value takes
**without being named**: the environment copied wholesale, the environment the
agent's own process inherits, and a failure raised while the value was in hand.
That last one was a real leak and is now closed at the loader — a client that
rejects a request quotes what it rejected, and that sentence becomes the failed
Surface's message and then a transcript line, so `importSurface` redacts through
the resolution where the sentence is built rather than asking every caller to
remember.

**The finding: a Surface in the window cannot use a secret today, and the
renderer is why.** `actors/surface-loader.ts` supplies no resolution and there is
nothing it could supply. A resolution binds names into a `process.env`; the
renderer is a webview and has none, and the only route for a value to get there
is the bridge, which ticket 15's fourth criterion closed in both directions. That
criterion is right: `vite.config.ts` documents binding the dev server to a
tailnet with `VARNICK_HOST`, and a renderer holding every key the developer owns
would be one HTTP request from handing them out.

So ADR-0006's `process.env.STRIPE_KEY` is host semantics, and the code that uses
a secret has to run somewhere with a process around it. Today the only such
runner in the tree is `drive.ts`, which is where the end-to-end integration is
driven: a module written the way the agent writes one, on disk, naming a secret;
the real store; the real resolution; the real loader; and a real HTTP service on
loopback that answers 200 to exactly one bearer token. Same module without a
resolution: 401, with `Bearer undefined` on the wire.

**This is a product gap, not an implementation one, and it is not this ticket's
to close.** Closing it means deciding *where* a Userspace integration runs when
the Surface that shows its results is in the window — a host-side Userspace
runner reached over the bridge is the obvious shape, and it is a new capability
with its own scope line, not a widening of ticket 14's loader. Written down here
rather than improvised.
