# 15 — Bridge the Harness to the renderer

**What to build:** Core's live actors can reach the Harness. Today they cannot, and every ticket that wires a real service hits the same wall at the same place: Core runs in the Tauri webview, the Harness runs on the host, and nothing carries a call across. After this, a live actor asks the host to do the work and gets an answer or a failure, and the actor that needs a filesystem, a kernel, or a subprocess stops being the actor that cannot have one.

**Blocked by:** None — can start immediately. Ticket 02 already built one of these by hand (`read_credential`), so the pattern exists and this generalises it.

**Status:** done

**Realizes:** nothing. No new state — this is the seam four other tickets are already leaning on, extracted once rather than improvised four times.

Found by building tickets 01, 02, 06 and 09 in parallel and watching three of them independently reach for a different workaround: a dynamic `import` the bundler is told to ignore, a hand-written Tauri command, a lazily-constructed store. Two of those work only because nothing has called them yet from a real webview. The third is the one that is actually right, and the reason it is right is that the Harness is host code — it opens sockets, reads the keychain, writes files, and spawns processes, none of which a renderer can do.

**The prefactor, made explicit:** this is expand–migrate, not a rewrite. Add the bridge beside what exists, move the live actors onto it one at a time, and delete the improvisations as each one moves. Nothing here changes a machine, a state, a guard, or a component.

- [x] A live actor calls the Harness without importing Node code into the browser bundle, and the build stays free of Node built-ins
- [x] A call that fails because there is no host reaches the actor's own failure state carrying that reason — the same legibility ticket 02 established for `no-host`, not an unhandled rejection
- [x] `checkSandbox`, `readCredential` and `persistSession` all go through it, and the `@vite-ignore` dynamic imports added by tickets 01 and 09 are gone
- [x] No secret value crosses the bridge in either direction. The credential precedent holds: the host answers with which store replied, never with what it held
- [x] The Rust host compiles and `cargo test` passes — it does today, and this ticket is where that stops being incidental

Covers no new stories; it is what stories 1, 11, 21 and 70 need in order to be true in the running app rather than in a test.

## Comments

**Done.** One long-lived Node process, started and owned by the Rust host,
newline-delimited JSON over stdio. Recorded as
[ADR-0008](../../../docs/adr/0008-the-harness-runs-as-one-long-lived-host-process.md)
— the decision passes all three ADR tests, and the reason the runtime is
long-lived is a correctness requirement rather than a latency one: srt's proxies
live in the process that called `initialize()`, so a process-per-call would
leave `checkSandbox` answering `ok` about a Sandbox that no longer exists.

The credential stays in Rust. `route_of` has an arm per capability and a closed
default, and the runtime refuses `read-credential` explicitly rather than
leaving it unhandled.

Rust tests went 7 to 20; `bun test` 99 to 140; `drive.ts` unchanged at 172,
which is the point — no machine changed. Bundle shrank and carries no Node
built-in.

**Left open, in ADR-0008 rather than here:** packaging the runtime for a bundled
application, and a test that drives the Rust half against the real runtime
process rather than against identical literals.
