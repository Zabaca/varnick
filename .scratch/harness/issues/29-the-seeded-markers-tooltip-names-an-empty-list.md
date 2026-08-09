# 29 — The seeded marker's tooltip names an empty list and points at the default mode

**What to build:** A seeded run's marker says something true when you open it. Today it says two things that stopped being true when the last actor was wired.

**Blocked by:** None.

**Status:** ready-for-agent

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
