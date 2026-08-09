# 35 — Every shutdown left a sandboxed agent running

**What to build:** varnick ends the process tree it started, whichever way it is stopped — and a window that can reload and restart itself without a terminal.

**Blocked by:** None.

**Status:** done.

**Realizes:** no state path.

## The defect

Measured on the developer's machine mid-session: **36 orphaned harness processes**, the oldest five and a half hours old, with **19 sandboxed Claude Code processes** still running under them. Every one was a confined agent with a credential in its environment, attached to nothing.

`AgentProcess::drop` says in its own comment that *"varnick exiting must not leave a sandboxed agent tree behind it."* It never ran. All four managed values have a `Drop` that kills their children, and on macOS the event loop ends in `process::exit`, which unwinds nothing — so managed state is dropped on **no path at all**: not on ⌘Q, not on a signal, not on a crash. The intent was recorded and never executed, and nothing failed when it did not.

The agent tree is deliberately its own process group (`Command::process_group(0)`), so a signal to varnick's group never reaches it — only an explicit `kill_group` ends it. That decision is right and is what makes the absence of a teardown total rather than partial.

## Three layers, because one exit cannot be caught

- **⌘Q** — `Builder::build()` plus a run callback, tearing down on `RunEvent::Exit`. This is the only place an exit can be observed at all.
- **SIGTERM, SIGINT, SIGHUP** — what `kill` sends, and the exit this app took most often during development. The handler sets one `AtomicBool` and does nothing else, which is the whole of what is async-signal-safe; a watcher thread does the work and exits 143.
- **SIGKILL and crashes** — uncatchable, so the children watch instead. `packages/harness/src/orphan.ts` polls `process.ppid` and acts when it becomes `1`, which is a fact about the process table rather than a message anyone has to remember to send. The runtime calls `releaseSandbox()` — srt's proxies and the `log stream` violation monitor are separate processes and would survive its own exit — and the agent host sends `SIGKILL` to its **own process group**, which is exactly the wrapper, `sandbox-exec`, itself, and Claude Code.

`orphaned(0)` is deliberately false: nothing started this process, so nothing has left it.

## The measurement

Both hard cases, on the running app:

```
SIGTERM the app  →  57885 gone, 57894 gone
kill -9 the app  →  59986 gone, 59994 gone
```

Not a unit test, and it could not be: the assertion is about processes that no longer exist. What *is* unit-tested is the watch's logic, with the clock and the process table injected — this module exists because processes outlived their reason to run, so it is the last place to start more of them to observe one. Two file-reading tests assert both entry points still call it, because an entry point that quietly stopped would leak exactly what this prevents, silently, on the exits nobody tests.

## The window's own controls

There was no menu at all, so ⌘R had never done anything — not a regression, never implemented.

A **View** submenu now carries **Reload** (⌘R) and **Restart varnick** (⇧⌘R), appended to the default macOS menu rather than replacing it, because ⌘Q, Copy and Paste all come from the default.

**They are two different repairs and the labels must not blur them.** A reload restarts the renderer only — the runtime channel and the agent process are managed state in the host and survive it untouched — so it fixes a stuck window and does nothing for a stuck host. Restart replaces everything, and it is only reasonable to offer because the agent now resumes its conversation (ticket 33). A native menu rather than a key handler in the webview, deliberately: the case you need this in most is a window that is not answering, and a renderer that cannot paint cannot handle a keystroke either.

## Watch for

- **The agent's process group is load-bearing.** `process.kill(0, …)` in the agent host means "this group" — the tree. Changing it to this process alone strands `claude`.
- The `Drop` impls are kept. They still run on a desync and on an explicit teardown; they are simply no longer the only thing standing between a quit and a leak.
- The orphan watch is a **poll**. There is nothing to push — the parent is gone.

- [x] ⌘Q, SIGTERM and SIGKILL all end the runtime and the agent tree
- [x] The Sandbox is released rather than merely abandoned
- [x] ⌘R reloads the window and ⇧⌘R restarts the app
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo build` green

Found by counting processes while debugging something else.
