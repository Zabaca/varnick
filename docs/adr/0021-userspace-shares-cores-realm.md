# Userspace shares Core's realm

**Status:** accepted

## Context

[ADR-0004](./0004-core-never-statically-imports-userspace.md) is read as
containment and is not. It is worth separating the two things it could mean,
because only one of them is true:

- **Fault isolation.** A Userspace module that does not compile fails at its own
  dynamic `import()`, inside a try/catch, and becomes a failed Surface with its
  reason under it rather than a blank window with no chat. ADR-0004 gives this,
  a lint rule holds it, and it is not in question here.
- **Privilege isolation.** A Surface can do less than Core can. ADR-0004 gives
  none of this, and the mechanism it is made of cannot be extended to give it.

A Surface is a component in Core's webview. Vite's `import.meta.glob` in
`packages/core/src/actors/surface-loader.ts` rewrites the scan into dynamic
importers, and `loadUserspaceSurface` evaluates one into the same document Core
renders in — same origin, same realm, same globals, same React. The bridge to
the host is one of those globals:

```ts
const internals = (globalThis as { __TAURI_INTERNALS__?: TauriInternals }).__TAURI_INTERNALS__
return { call: (request) => internals.invoke(CALL_COMMAND, { request }) }
```

`tauriHarnessBridge()` in `packages/harness/src/bridge.ts` is a convenience over
that global, not a gate in front of it. Nothing distinguishes a call made by
Core's machines from one made by a Surface, and nothing can, because they are
the same realm invoking the same command. Tauri's capability system scopes
commands to windows; there is one window, and this tree has no
`src-tauri/capabilities/` at all.

The answer parsers beside that call — `credentialAnswer`, `okAnswer`,
`transcriptAnswer`, each rebuilding a reply field by field — are Core's
discipline about what *Core* holds. A Surface that calls `invoke` directly is
handed the host's reply unrebuilt.

## What a Surface can reach today

Read rather than run. `route_of` in `src-tauri/src/bridge.rs` is the whole of
what the renderer may ask for — thirteen kinds answered by the host, eight by
the Harness runtime — and all twenty-one are named below rather than the
interesting ones, because a list of the interesting ones is how two of these
were missed the first time this was written.

**Nine answer a question.** `read-credential`, `await-agent-exit`,
`read-session`, `read-commands`, `list-worktrees` and `read-worktree-diff` leave
the world as they found it. `next-mint-event`, `next-turn-event` and
`next-unprompted-event` read a queue by draining it, which is the difference
that matters below.

**Twelve change something.** `check-sandbox` establishes the Sandbox rather than
reporting on one. `store-credential`, `mint-subscription-token` and
`cancel-mint` write or start or stop an authentication. `spawn-agent`,
`stop-agent`, `run-turn` and `interrupt-turn` are the agent's process and what is
said to it. `persist-session` writes the mirror. `merge-worktree` and
`reap-worktree` are git in the developer's clone, and `restart-varnick` replaces
this process image.

**No answer on this bridge returns a Credential, and that is structural rather
than lucky.** `read-credential` answers `Reading { source, kind }`, and `Secret`
in `src-tauri/src/credential.rs` has no `Serialize` at all, so there is no shape
for a value to cross in even if that line were wrong. `store-credential`
carries one *in* and answers `{ ok: true }`. A mint's two polls carry an
authorize URL and an outcome; the token goes from the pty into `Secret` and into
the keychain without leaving the host. `read-secret-names`, `describe-secrets`,
`wrap-agent-command`, `read-fence-diff` and `launch-preview` are absent from the
route list entirely, each with a unit test asserting the absence.

Two reads are worth stating exactly:

- `read-session` returns the mirror, which is redacted on the way in
  (`packages/harness/src/session.ts`). What a Surface can read back is the
  record, `[redacted]` where a value was.
- `next-turn-event` and `next-unprompted-event` are the live stream and are
  **not** redacted — redaction happens on the way to disk. This is the same text
  the window is already showing, so it exposes nothing new to the machine; but
  a poll *takes* the event off the queue, so a Surface reading them is a Surface
  the transcript loses messages to. That is not a leak. It is a way to break the
  chat that requires no cleverness at all.

**The twelve that change something are where the gap stops being theoretical**,
and they are not equally interesting. Starting, stopping and interrupting the
agent are a nuisance; `run-turn` is a prompt, so a Surface can put words in the
agent's mouth, which is the agent prompting itself laundered through the window.
`store-credential` cannot read a credential back but can replace the one the
developer stored. None of that reaches what varnick is protecting. Three are
worth taking one at a time, and the third is the one that ends well.

**`persist-session` writes the mirror, and nothing stands in front of it.** The
mirror is the copy that survives a build the agent just broke, which is the
whole of [ADR-0009](./0009-resume-reads-the-mirror.md) — and `persist` in
`packages/harness/src/session.ts` replaces the transcript for a Session id with
whatever passes shape validation. Redaction still runs on the way in, so this
cannot be used to *write* a secret to disk; what it can do is overwrite the
record. There is no guard here to be in the wrong place, because there is no
guard: the call is trusted for the same reason every call on this bridge is,
which is that Core is the only thing expected to make it.

**`merge-worktree` and `restart-varnick` are ADR-0014's gate.**

[ADR-0017](./0017-the-host-performs-the-merge-a-human-still-decides-it.md) asked
the right question — *can anything the agent says cause this call* — and its
first argument is that the control lives in Core, which the agent cannot write,
and that "a Surface cannot draw it — a Surface is Userspace, and Userspace has
no route to a Harness event." That is true of the **event**, and a Surface does
not need one. `invoke('harness_call', { request: { kind: 'merge-worktree', path } })`
skips the machine.

The guard goes with the machine. `mergeable` in
`packages/core/src/machines/harness.ts` refuses unless the open diff is *this*
Worktree's, which is a good guard placed where it cannot be a boundary: an
XState guard decides which events a machine accepts, not which commands a
process will run. The path check does not close it either — it is a selector
compared against git's own listing where git runs, and the agent's own Worktree
is in that listing. Nor does the deny list: the merge is performed by the
Harness runtime, which is the unconfined process, which is the entire point of
ADR-0017. `denyWrite` is about the agent's process tree and no part of it is
involved here.

So the sequence is: the agent authors Core in a Worktree, which is the sanctioned
path ([ADR-0014](./0014-core-is-authored-in-a-worktree.md)); the agent writes a
Surface, which is ordinary Userspace work; a developer opens the Surface, which
is the product's main loop; the module calls merge and then restart at module
scope. ADR-0014 rests on *a human merges it and restarts*, and neither half of
that sentence was satisfied by a person.

Two qualifications, so this is not read as larger than it is. Loading is lazy —
`loadUserspaceSurface` evaluates a module when a Surface is opened, so somebody
has to open it once. And `mergeWorktree` refuses a dirty live tree and an
unmergeable branch; neither is a security check, but both mean the sequence is
not silent in every state.

**`reap-worktree` is the destructive route the realm gap does not reach, and it
is the most useful thing on this list.** It sits one line from the merge in
`route_of` and ends in `worktree remove` and `branch -D`, so the obvious reading
is that a Surface can force-delete the agent's own finished, unmerged branch.
**It cannot.** `reapWorktree` calls `contentLanded` before it removes anything
and throws if the answer is no; `contentLanded` in
`packages/harness/src/worktrees.ts` proves the answer with
`merge-tree --write-tree HEAD <ref>`, refusing unless merging the branch into
the live tree produces exactly `HEAD`'s own tree, and returning `false` on every
error path so the only direction it can be wrong in is leaving the worktree
alone.

That check is in the runtime, on the far side of the bridge, and it therefore
holds against a caller no machine ever saw. **The difference between reap and
merge is not how dangerous they are — it is where the guard lives.** Reap's is
host-side and survives; merge's is an XState guard in Core and does not. The one
route that already got this right is the shape the rest of the list would have
to take, and it needs no second realm to say so.

One more fact about the realm rather than the bridge: `src-tauri/tauri.conf.json`
sets `"csp": null`, and the webview is not a confined process — srt wraps the
agent subprocess, not the host and not the runtime. So the realm has the network.
Exfiltration is out of scope for varnick and is stated as never covered, by the
spec and by `sandbox.ts`'s own policy comment, and this ADR does not reopen it.
It is named because "a Surface can reach the bridge" and "a Surface can reach the
network" are one fact about one realm.

## Why the next attempt must not be another lint rule

A dynamic `import()` is a scheduling decision, not a trust one. It says when a
module is fetched and evaluated and nothing about what it may touch once it is:
the module gets the realm's globals, its prototypes, its `fetch`, and
`__TAURI_INTERNALS__`. The try/catch catches a throw. A module that does not
throw is simply code running in Core's page.

The lint rule is the same class of thing one step earlier. `no-restricted-imports`
decides what *Core's source* may name at build time; it says nothing about what
Userspace's source may name, and reaching a global names nothing.

The in-realm repairs fail together and for one reason. Freezing globals, deleting
`__TAURI_INTERNALS__` once Core has captured it, wrapping `invoke` in a proxy
that inspects its caller — each is code in the realm, and code in the realm runs
before it, beside it, or through a reference taken earlier. There is no ordering
that makes one realm two.

## What closing it would take

A second realm, with the bridge mediated across it. Surfaces in an `<iframe>` on
a distinct origin, or in a Worker with no Tauri global, reaching Core only by
`postMessage` — and Core deciding, per message, which kinds it will forward. The
value is not the boundary alone: it is that "which kinds may a Surface send"
becomes a list somebody wrote in Core rather than a consequence of what the host
happens to route.

**Not now.** It changes how every Surface loads and what a Surface can be — a
component in Core's tree, sharing React and the machines, is most of what makes
one cheap to write — and it needs an answer for the Surface that legitimately
wants Core's data. This ADR records the limit; it does not buy it.

**And there is a cheaper thing that is not the same thing.** `reap-worktree`
shows that a route can carry its own precondition on the host's side of the
wire, where a caller the machine never saw still meets it. Moving a guard there
is one route's worth of work rather than a new loader, and it is what should be
reached for when a particular route stops being tolerable. It closes routes, not
the realm: a Surface still shares Core's globals and its network, and the next
route added arrives undefended unless somebody remembers. That is a reason to
prefer it as first aid and not to mistake it for the boundary.

## The condition that makes closing it urgent

**A bridge route that answers with something worth having.** Everything above
rests on the current route list and not on the design. The day a route returns a
token, a secret value, an OAuth response, or a decrypted anything — or the day a
`SecretResolution` reaches the renderer, which `surface-loader.ts` refuses today
for a neighbouring reason — the exposure is immediate and total, and it needs no
change in Userspace to take.

The rule that follows is worth keeping in the same sentence as `route_of`:
**every kind added to that list is a capability granted to Userspace, not to
Core.**

## Consequences

**ADR-0004's containment claim is bounded, in writing.** It is linked from
ADR-0004 and from the Core and Userspace entries in `CONTEXT.md`, so a reader
arriving at either does not take the crash boundary for a privilege boundary.

**ADR-0017's first argument is narrower than it reads, and its conclusion holds
for a different reason.** Nothing the agent *says* can cause a merge; that is
still true, and it is what the argument establishes. What can cause one is code
the agent *wrote*, running in the window, which that ADR did not consider — the
agent is an author of running code as well as a speaker, and the second role is
the whole product. The merge gate holds today because the sequence is a
deliberate act by an agent that has no reason to attempt it, which is a
statement about behaviour rather than about mechanism.

**Reviewing a Surface is reviewing privileged code.** Not a new rule so much as a
newly stated one: a Surface is Userspace by ownership and Core by privilege, and
the only thing standing between the two is that nobody has written the module.
