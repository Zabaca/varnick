---
version: 1
slug: "chat-surface"
primary_target: "packages/core/src/components/chat-surface.tsx"
related_targets: ["packages/core/src/pages/DesignedPage.tsx","packages/core/src/pages/StatesPage.tsx"]
---

# Chat surface — varnick

The one surface v1 ships. A Claude Code session in a window, with the confinement
around it stated in the same voice as the transcript.

## Mode

**Operate.** The visitor completes a task: they describe work, the agent does it,
they read what happened. Scanability, consistency and the real usage scene outrank
expression. Brand lives in precise details — the chip line, the refusal copy, the
places the surface stays quiet.

Persuasion is not this surface's job and never becomes it. There is no landing
page in this product; the repository README is where anyone is convinced.

## Audience

Developers who already use Claude Code and are cloning varnick to build their own
Workspace inside it. They know the transcript grammar before they arrive. That is
the whole reason the world is brainless rather than an invented vocabulary: the
first screen should cost them nothing to read.

Second audience, same screen: the author, using it daily as the thing being built.

## Direction

**brainless, vendored** — pinned by the user, replacing the Orizuru Fold Sequence
outright rather than polishing it. The fold vocabulary read as confusing where it
meant to read as considered, and v1 of varnick is a Claude Code client that says
so.

- Ground `#1a1b26`, foreground `#c0caf5`, dim `#8b8fa3`, faint `#565f89`
- Green `#4ea96f`, amber `#e0af68`, red `#f7768e`, cyan `#7dcfff`
- Monospace throughout, because this is a terminal, not a costume
- Full-width shell; only prose is capped, at 110ch — a transcript interleaved
  with tool output, diffs and paths is not an essay

Colours are read off the vendored components rather than invented, so the app and
the transcript are one surface instead of two.

## The memorable moment

**A refusal that reads as a rule.** When the sandbox cannot be established the
surface says the agent will not run unconfined and offers to try again — no
fallback, no degraded mode, no apology. It is the only moment in the product where
the harness speaks in its own right, and it is the reason the product exists.
Everything else about the surface is deliberately unremarkable.

## What the surface does not do

- **No status furniture.** Harness state is silent while it holds. A permanent row
  of green dots reporting on seeded actors is a claim the build cannot back;
  `#/bare` shows full machine state at all times and that is what it is for.
- **No control the machines will not accept.** Every command in the menu is
  filtered through `snapshot.can()`, so the surface cannot drift into advertising
  capability the product lacks.
- **No unmarked invention.** While actors are stubs, one marker beside the plan
  usage says so, and it reads `UNIMPLEMENTED` rather than being maintained by
  hand.
- **No Surfaces aside.** The narrow aside in the original direction contract was
  cut during the visual gate, and it stays cut. v1 runs one Userspace module; it
  does not arrange several, and a permanent sidebar is the affordance that would
  promise otherwise. Where a running module appears is a decision for whoever
  builds the second one.

## Where it is reviewed

`#/states` — nineteen cards, each the same component driven by a real actor parked
in one state. Any visual change is judged there, not only on the live page, because
the live page shows one state at a time and the failures are in the other eighteen.
