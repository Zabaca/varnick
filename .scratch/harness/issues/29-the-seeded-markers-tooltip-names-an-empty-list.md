# 29 — The seeded marker's tooltip names an empty list and points at the default mode

**What to build:** A seeded run's marker says something true when you open it. Today it says two things that stopped being true when the last actor was wired.

**Blocked by:** None.

**Status:** done — the tooltip branches on whether anything is actually unimplemented, and both branches are asserted in drive.ts.

**Realizes:** no state path.

Found while clearing ticket 21's D18 — not fixed there, because that pass was a comment and dead-code sweep and this is rendered text a developer reads.

## What it renders

`SeededMarker` in `packages/core/src/components/chat-surface.tsx:663`. It shows only in seeded mode, which is right and is the whole of what ticket 21's D15 pass confirmed. Opening it renders, verbatim:

> These actors have no live implementation yet:
>
> *(nothing — `UNIMPLEMENTED.join(', ')` over an empty list)*
>
> Machines, states and refusals are real; the services behind them are stubs. Append `?actors=live` to fail on the first one that is missing.

Both halves are stale:

- `UNIMPLEMENTED` is `[]`. A heading with a colon and nothing after it reads as a rendering failure rather than as "none".
- `?actors=live` is the **default** now — `resolveActorMode` returns `live` unless the URL says `?actors=seeded`. A developer who followed that instruction would be told to add the parameter that is already implied, and there is no missing actor for it to fail on.

## Why this is worth a ticket rather than a line

The marker exists to stop the build claiming more than it does, and this is the marker itself claiming something that is not so. It is also the one screen a stranger with a fresh clone is most likely to open first, because it is the only thing on the page that looks like an explanation.

- [ ] An empty `UNIMPLEMENTED` renders as a sentence rather than as a heading with nothing under it
- [ ] The way back to a live run is named correctly — remove `?actors=seeded`, not add `?actors=live`
- [ ] Whatever it says with a non-empty list still reads, because the list is the thing that is allowed to change
- [ ] Driven, so the empty case is not a case only a human ever sees


## Comments

Fixed by moving the copy decision out of the component. `seededDetail` lives in
`actors/index.ts` beside `UNIMPLEMENTED`, because `chat-surface.tsx` cannot be
imported outside Vite — a branch inside it is a branch `drive.ts` cannot reach.
Same shape as `canStartAgent`: the rule is testable and the component renders it.

The marker itself was not touched and still gates on `mode` alone. That is
deliberate and documented at the component: a list-driven marker goes quiet on
the last wiring while a seeded surface is still rendering invented figures,
which is the claim it exists to prevent.

What changed is what it says once the list is empty. It claimed "These actors
have no live implementation yet:" over nothing, then advised appending
`?actors=live` — the default since every actor was wired, and an instruction
naming no actor it could fail on. It now says seeded was a choice rather than a
gap, and points at `?actors=seeded`, the flag that is actually set.

Both branches are asserted, because only one of them can be reached by running
the app today — the empty case is what ships, and the populated case is what
would ship again the moment an actor is added without an implementation.
