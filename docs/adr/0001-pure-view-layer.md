# The view layer is pure

The states page renders every machine state by parking a real actor in it and handing that snapshot to the real component. For that to keep working once the app is integrated with live services, the component tree and the machine definitions must contain no I/O: components are functions of `(snapshot, send)`, and machines declare actor names and input/output shapes without importing any implementation. One machine is then rendered three ways — frozen actors and `FOREVER` delays for the states page, seeded actors for development, real actors in production — instead of a prototype copy that drifts from the shipped code.

## Consequences

- **Context must be JSON-serializable.** No class instances, promises, DOM nodes, or functions in machine context. Non-serializable context is what makes a state unreachable in the explorer, because no scenario can hand-author a `seed` for it.
- **No ambient time or randomness inside machines.** `Date.now()` and `Math.random()` make card renderings differ between runs and seeded data drift. Inject a clock, pass timestamps as event payloads, and use a seeded counter for ids.
- **Cross-cutting concerns live in the shell.** Auth, routing, and i18n are resolved by the shell that provides the actor and passes `snapshot`/`send` down — never read from inside a component. The states page is simply an alternate shell over the same component tree.
- **Live-only states are still machine states.** Offline, session-expired, conflict, and rate-limited get modelled, not branched on in the UI. An ad-hoc UI branch breaks purity at exactly the moment it matters.
- **The boundary is enforced, not conventional.** ESLint `no-restricted-imports` forbids `components/**` and `machines/**` from importing `services/**`. A convention without enforcement decays within a release.

The cost is indirection: every effect is injected rather than called where it is needed, and adding one means touching the machine's actor declaration and all three provisions. That is accepted because the alternative — a separate prototype that has to be kept in sync by hand — was the thing this architecture exists to avoid.
