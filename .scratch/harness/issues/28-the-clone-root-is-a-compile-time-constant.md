# 28 — The clone root is a compile-time constant, and nothing says so

**What to build:** A decision about where the agent works, and whatever follows. Today that directory is never chosen, passed, or configurable — it is inherited from a path baked into the Rust binary when `cargo build` ran.

**Blocked by:** None.

**Status:** decided — **reading two: the agent's directory becomes configurable.** The developer chose this with the reversibility stated: it is the harder of the two to undo, because once someone runs more than one root, taking it away breaks their setup, and four subsystems would have to give the parameter back.

**Realizes:** no state path.

## The chain, which is entirely implicit

```rust
fn project_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))   // src-tauri/
        .parent()                                // the repo root
```

`env!` is a compile-time macro, so that path is frozen into the binary at build time. Confirmed rather than reasoned — the literal appears twice in `src-tauri/target/debug/varnick`:

```
/Users/uptown/Projects/zabaca/varnick/src-tauri
```

**It is not where the process is run.** Launch that binary from any directory and it still names the one above. The two coincide in development only because `bun tauri dev` is `cargo run`, which recompiles in the checkout every time, so the build path and the working directory are never different — which is exactly why this has never been noticed.

The direction is also the reverse of the intuition: the host does not *read* a working directory, it **sets** one. From there nothing passes the root anywhere — it propagates by being that working directory:

1. `bridge.rs` spawns the Harness runtime with `.current_dir(project_root())`.
2. `runtime.ts` calls `establishSandbox()` with **no argument**.
3. `sandbox.ts` defaults `cloneRoot = input.cloneRoot ?? process.cwd()`.
4. `wrapAgentCommand` uses `sandbox.cloneRoot`, correctly refusing to choose its own.

Step 4 is careful — its comment says "the clone the Sandbox was established for, not one chosen here", and that is right. The problem is upstream: nobody ever chose it, so the care at the end is protecting a value that arrived by accident.

## Three consequences

- **There is no override.** `VARNICK_HARNESS_ENTRY` and `VARNICK_HARNESS_RUNNER` exist for the runtime's entry and interpreter. Nothing exists for the root. You can redirect which script runs, and not which tree the agent works in.
- **A packaged application would name the build machine's path.** [ADR-0008](../../../docs/adr/0008-the-harness-runs-as-one-long-lived-host-process.md) already records that the runtime entry "resolves relative to the repository, which is right for `bun tauri dev` and wrong for a bundled application", and names `VARNICK_HARNESS_ENTRY` as the escape hatch. The clone root has exactly the same problem and no escape hatch, and the ADR does not mention it.
- **Moving the checkout after building breaks it**, and the failure is a Sandbox established for a directory that no longer exists rather than anything that says so.

## The question, which is a product question

**Reading one: this is correct.** `CONTEXT.md` defines **Workspace** as "the environment a person builds around themselves inside their clone", and `PRODUCT.md` says you clone varnick and build inside it. One clone, one workspace, one root. On that reading the only defect is that a load-bearing decision is expressed as a compile-time constant and a working directory instead of being stated, and the fix is small: name it, say why, and let ADR-0008 record it beside the packaging note it already has.

**Reading two: a harness should point at a directory you choose.** Then the root becomes input — a launch argument, a setting, or something the window asks for — and the careful comment at step 4 becomes load-bearing rather than decorative, because there would finally be more than one possible answer.

The two readings are not close together, and the second is considerably more work than it looks: the Sandbox policy, the Session mirror's location, Surface discovery and the Core/Userspace write boundary are all written against "the clone", and each would need to say which clone.

- [x] The choice is recorded in a new ADR — this is a change to what varnick *is*, not a note on how it starts, and `CONTEXT.md`'s **Workspace** definition ("the environment a person builds around themselves inside their clone") has to say whether a Workspace is still one per clone — [ADR-0012](../../../docs/adr/0012-the-clone-root-is-an-input.md); `CONTEXT.md` now says one per clone and therefore not one per machine
- [x] The four subsystems written against "the clone" each say *which* root: the Sandbox policy, the Session mirror's location, Surface discovery, and the Core/Userspace write boundary — three follow the chosen root; Surface discovery names the *build* root and says so, because `import.meta.glob` resolves at transform time and cannot take a variable
- [x] Whatever supplies the root is validated before a Sandbox is established for it — a root that does not exist must be a legible refusal, not a Sandbox for a missing directory — checked in the host before the spawn and in `establishSandbox` before a policy is generated
- [x] Whichever it is, the root is *named* rather than inherited from a working directory — a function that says where the agent works and why, with the compile-time constant behind it if that is the answer — `packages/harness/src/clone-root.ts` and `clone_root` in `src-tauri/src/bridge.rs`; the compile-time constant is still the default
- [x] ADR-0008's packaging consequence mentions the root alongside the runtime entry, since they are the same problem and only one is written down
- [x] If it stays fixed, moving the checkout produces a legible failure rather than a Sandbox for a missing directory — it did not stay fixed, and a moved checkout is now the same refusal as a bad `VARNICK_CLONE_ROOT`

Found while answering a question about where the agent's directory comes from, which is its own small finding: nobody could tell from reading the code without following four hops.

## What it took, and what it did not settle

`VARNICK_CLONE_ROOT`, read once by the Tauri host and passed to the runtime as an argument. A launch flag was rejected because `bun tauri dev` is `cargo run` under the Tauri CLI and Tauri's argv is contested; a setting in the window was rejected because `SandboxManager.initialize()` returns early once a Sandbox exists, so the control would work once and then silently do nothing; a setting in the clone was rejected because the agent can write its own clone.

Three things are open, and each is named in ADR-0012 rather than left to be found:

- **Surface discovery follows the build root, not the chosen one.** Vite's `import.meta.glob` is a transform-time scan. With a second root the agent writes Surfaces into that tree and the window keeps showing this one's. Closing it means a run-time Userspace loader, which ADR-0004 constrains.
- **A second root's agent cannot open the Agent SDK.** `agentSdkEntry()` resolves it from the runtime's own installation — the build root — and the policy reads back exactly the chosen clone out of the denied `$HOME`. Not fixed here: the fix is either resolving the SDK from the chosen root or putting a path outside the clone on `allowRead`, and the second widens the boundary.
- **Two roots are isolated for writes and not for reads.** `allowWrite` is the chosen clone, so a second root cannot write the first. Reads are allow-by-default outside `denyRead`, which covers `$HOME` and the region holding it — so a clone under a home directory is unreadable from another root and a clone outside one (`/opt`, `/srv`, `/Volumes`) is readable. That is ADR-0003's fourth correction reached by a second route; ticket 18 is what closes it.
