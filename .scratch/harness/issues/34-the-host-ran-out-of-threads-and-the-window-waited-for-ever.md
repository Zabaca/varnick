# 34 — The host ran out of threads and the window waited for ever

**What to build:** A host that cannot be starved of threads by its own waiting calls, and a runtime call that fails rather than hangs.

**Blocked by:** None.

**Status:** done.

**Realizes:** no state path. Every state involved already existed; what changed is that the calls behind them can now finish.

## The defect

The window sat for ever on "Reading the conversation…" — the first bridge call the app makes. Nothing failed, nothing logged, and no state was reachable from there.

`harness_call` was `#[tauri::command(async)]` on a **synchronous** function. That reads like "run this off the main thread" and is not what it does: tauri hands a sync body to `async_runtime::spawn`, which is `tokio::spawn` on the multi-thread runtime, so each blocking call occupied one of `num_cpus` **worker** threads rather than a slot in the 512-wide blocking pool.

Three call kinds block: `await-agent-exit` until the agent dies, `next-turn-event` for its poll, and every runtime call for a pipe round trip. The first is the one that accumulates — the renderer issues a fresh one on every entry to `agent.running`, and it was unbounded, so each agent restart and each page load left another thread parked for the life of a process that can run all day. `sample` showed **eleven** parked in `await_exit` and not one executing the read the window was waiting for.

## Two wrong diagnoses, recorded so they are not proposed again

- **"Every Turn is a fresh conversation."** Read off a screenshot of two consecutive prompts that had a restart between them. It sent the investigation at the empty `session_id: ''` on queued user messages, which is optional on `SDKUserMessage` and was never the cause.
- **"The blocking pool is exhausted."** The pool is 512 and eleven waiters cannot exhaust it — but the waiters were never in that pool. The stack frames say `tokio::runtime::blocking::pool`, which is how tokio spawns *worker* threads too, and reading that as "the blocking pool" is what made the first count look harmless. The mechanism is real and the arithmetic was wrong.

## What it does now

- **The bridge answers on the blocking pool.** `harness_call` is an `async fn` whose body runs in `tauri::async_runtime::spawn_blocking`. `AppHandle` replaces the `State` arguments, because a `State` borrows the invocation and cannot cross into a blocking closure.
- **The wait for an exit is bounded.** `EXIT_WAIT` is 30 seconds against a wall-clock deadline, answering `STILL_RUNNING`; `liveAgentExit` re-asks, the same arrangement `next-turn-event` already had. The actor's contract is unchanged — it still resolves once, with a real reason — so nothing about `AGENT_EXIT` or the machines moved. Waiters now stop accumulating at all, which is the property worth having even with the pool fix.
- **A runtime that stops answering fails instead of deadlocking.** `HarnessRuntime::call` held the channel lock across an untimed `read_line`, so one hung request took every later call with it. The read is now a thread posting whole lines to an `mpsc` channel, waited on with `RUNTIME_WAIT` (90s) — long enough for `check-sandbox` to establish srt, finite in every case. A timeout answers `runtime-lost`, which already drops and respawns the channel.

The hang was reachable in one step from a real handler: `read-session` opens the Secrets Store, which shells out to `/usr/bin/security` with no timeout and no kill. A locked keychain or an unanswered access prompt stalled the pipe permanently.

## Watch for

- **`#[tauri::command(async)]` on a sync fn is a trap and reads like the opposite.** Anything added to this bridge blocks by default; the pool is what makes that safe.
- The two halves of `still-running` are one string in two languages. `bridge.test.ts` reads `agent.rs` and asserts they agree — if they drift, `liveAgentExit` returns it as though it were a reason the process ended and the machine leaves `agent.running` for a crash that never happened.
- `RUNTIME_WAIT` is not a latency policy. Raise it if a legitimate answer needs longer; do not remove it.

- [x] A blocking bridge call no longer occupies a worker thread
- [x] `await-agent-exit` returns within a bounded time and the actor re-asks
- [x] A runtime that never answers produces `runtime-lost` rather than a dead app
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo build` green

Found by the developer, whose window would not start.
