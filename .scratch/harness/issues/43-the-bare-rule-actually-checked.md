# 43 — The bare rule, actually checked

**What to build:** The claim that the bare rendering is design-free is a thing that can fail, rather than a thing that is said.

**Blocked by:** None.

**Status:** done.

**Realizes:** no state path.

## Why this exists — and why it is not the ticket it started as

This began as "port the prototypes' skin split": in `~/Projects/zabaca/prototypes`
a bare page is not a page at all but a **skin** — `components/skin.ts` exports
`BARE` and `DESIGNED` keyed by the same named slots, the two renderings share one
layout, and `bare-skin.test.ts` enforces that the bare table has no colour, no
radius, no shadow and no motion, and that the pane geometry survives the swap.

**That port does not transfer, and it took reading varnick's bare page to see
why.** The prototypes' bare rendering mirrors its designed one function for
function and adds an instrument band. varnick's bare page has no chat in it at
all — it is *only* instruments: seed toggles, a `<dl>` of every context field,
an event-button bank per machine filtered through `can()`, and the transition
log. There is no shared layout for a skin to hold constant, so a skin table
would not be preserving a geometry; it would be inventing one, and the change
would be a redesign of what the bare page *is*, on the strength of another
repository's decision rather than a defect here.

CLAUDE.md was checked rather than assumed on this point. Its "same code" claim
is about the **states** page — *"this is what lets the states page and the live
app be the same code"* — and that is true today. The bare page it describes as
"the design-free behavioural surface", which is exactly what it is.

## What did transfer

The *move*, which is the valuable part: **the rule was stated where it could not
fail.** `bare.css` opens by saying it — *"no design system on purpose. Native
controls, hairline borders, no colour system … anything prettier here would
start covering for gaps in the machines"* — and nothing was reading that
sentence. The prototypes' own test file names this failure exactly: author
discipline wearing the language of enforcement.

The rule has in fact been kept. The scan passes on the code as it stands, which
is the point — the cost is not a defect today, it is that losing it costs
nothing tomorrow, one plausible edit at a time, each looking like an
improvement.

## What it does now

Seventeen assertions in `drive.ts`, beside the ADR-0004 import scan and for the
same second reason: `packages/core/**` is denied to the agent by the Sandbox
policy, so this is a rule the agent cannot switch off.

- **Seven banned things**, checked in `bare.css` *and* in `BarePage.tsx` — hex
  colours, computed colours (`rgb`/`hsl`/`oklch`/`color-mix`), **design tokens**
  (`var(--…)`, the sharpest of them, because reaching for one `var(--fg-dim)` is
  how a design-free page stops being one), corner radii, shadows, motion, and
  filters. Comments are stripped first, so a stylesheet explaining why it has no
  shadow does not trip a guard on the word.
- **The structural half, which is stronger than any class-name rule**: the bare
  rendering may import no designed component and no design stylesheet. Policing
  colour catches a page that reaches for one; it does not catch the shorter
  route, which is importing the component library and becoming the designed page
  with a different heading.
- **And the rule a ban cannot express**: with colour gone, a refused control must
  still be distinguishable. `.refused` is a dashed border — a device made of
  shape rather than palette — and it is asserted, so deleting it is a decision
  rather than a tidy-up. This is the same instinct as the prototypes' mandatory
  depth ramp.

**Falsified before being trusted.** A `var(--accent)` and a `border-radius` were
added to `bare.css` and the suite went red on exactly those two lines; the
injection was then reverted. A source scan that has never failed is
indistinguishable from one that cannot.

## Left open

The full skin split is still available and is a real decision rather than a
cleanup: it would give varnick a bare rendering of the *chat*, which it does not
have, and would let a reviewer judge composer-to-transcript layout with the
design removed. It also means threading a skin through `ChatSurface` and every
component under it. Worth doing deliberately, not as a side effect of a review.

- [x] Every banned device fails the suite, in the stylesheet and in the page
- [x] The bare rendering cannot quietly become the designed one by import
- [x] The scan was made to fail before it was believed
- [x] `bun test packages`, `bun run drive`, typecheck, lint and `cargo test` green
