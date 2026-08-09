# 42 — A states page you can find your way around

**What to build:** An index for `#/states`, and a link that addresses one card, so a ticket can point at a state rather than at forty screens.

**Blocked by:** 41.

**Status:** done.

**Realizes:** no state path.

## Why this exists

Twenty-four cards is past the point where a page can be read by scrolling it.
Without a map you cannot see what is on the page without paging through it, you
cannot get back to a card you passed, and you cannot tell anyone else where one
is.

The third is the one that bites here. `StatesPage`'s own doc comment has claimed
since it was written that this is *"the surface a ticket points at: `#/states →
turn.failed` resolves to a card rather than to a copy of the design"*. That was
true of the page and false of every link, because **there were no per-card
links**. A ticket saying "see `#/states`" was pointing at the whole thing.

## The problem underneath: one hash, two jobs

The obvious way to address a card is `href="#cold-start"`, which a browser
scrolls to for free. It cannot work here — this app routes on the hash, so an
anchor replaces the route and unmounts the page the card is on.

So the route swallows the card: **`#/states/cold-start`**. `routing.ts` is the
whole of it, pure and free of the DOM so `drive.ts` asserts it at the same seam
everything else uses. The parser matches longest-route-first, which nothing
needs today — it is what stops a route that prefixes another from becoming an
accident later, and it is asserted.

The card travels to the page as a **prop**, not read off `location` inside it.
Following an index entry must scroll, not remount: every card creates real
actors on mount, and a click that reset all twenty-four is not a link, it is a
reload. The scroll runs on the *second* animation frame, because cards grow as
their actors settle and a target measured before that lands somewhere else.

## What it does now

A sticky left nav (`232px`) beside the grid, holding a filter, a live count,
group chips, and one entry per card under its group heading. The linked card
takes an accent border.

- **The filter searches state paths as well as titles.** "What does `turn.failed`
  look like" is the question this page exists to answer, and a title search does
  not answer it.
- **The five section banners in `scenarios.ts` became data.** They were comments
  — `// -- Start-up ---` — and a comment cannot be rendered, so the index would
  have had to invent its own grouping beside them: two answers to how the page
  is organised, one of them quietly stale. `GROUPS` is exported and every
  scenario names one.
- **One predicate feeds the index and the grid**, so the nav cannot say "6 of 24"
  over a grid showing five. It lives in `scenarios.ts` rather than beside the
  page, because `drive.ts` asserts it and cannot import the page — `StatesPage`
  reaches `hooks.ts`, which reaches the Surface loader, which calls
  `import.meta.glob` and exists only under Vite. That constraint was already
  written down two modules away; this is the second thing it has decided.
- **Filtered-empty says something different from empty.** "No card matches *x* —
  every state is still on the page" rather than a blank column.

Deliberately **no scroll-spy**. An observer that rewrites the nav as the page
settles is a page that never settles, and everything about this surface exists
to hold still.

## What is asserted

Anchors are the classic thing that rots in silence: rename a scenario and the
entry still renders, still looks right, and goes nowhere — the page mounts,
nothing throws, coverage is unchanged. Thirty-nine new assertions in `drive.ts`:
every scenario is addressable and reads back off its own link, no two share an
id, every id survives being a URL segment, every card sits in a group the index
renders, every group has a card, and the filter both finds by state path and
**excludes** — a predicate agreeing with itself over the whole list is true of
any two functions that return everything.

## Watch for

`text-[15px]` on the page heading is off `DESIGN.md`'s type ramp and predates
this ticket. Left alone: the states page runs a compressed developer scale
(11 / 11.5 / 12 / 13 / 15) and moving one step of it in isolation would be
arbitrary. It wants a decision about the whole scale, not a patch.

- [x] Every card is addressable, and the link scrolls rather than remounting
- [x] The index and the grid cannot disagree about what is shown
- [x] Filtering by state path works, and finding nothing says so
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo test` green
