# Core never statically imports Userspace

A React error boundary catches a render error and does nothing about a build error: if Core statically imports a Userspace module with a syntax error, the bundle does not compile, nothing loads, and the next launch is a blank window with no chat — losing the conversation that could fix the breakage. Core therefore loads Surfaces through dynamic `import()` inside a try/catch, so a broken Userspace module is a failed Surface with a visible error rather than a dead application.

## Consequences

- **Enforced by lint, not by discipline.** A `no-restricted-imports` rule forbids static imports from `userspace/**` inside `packages/core/**`. Conventions decay; this one has to hold on the day the agent writes something that does not compile.
- **Every Surface renders its own failure.** The loader catches, reports which module failed and why, and leaves the rest of the window alive.
- **Pairs with [ADR-0001](./0001-pure-view-layer.md).** That invariant keeps state out of the view layer; this one keeps Core's fate out of Userspace's hands. Together they are what makes the chat survivable — the transcript is durable, and the thing rendering it does not depend on code the agent just changed.
