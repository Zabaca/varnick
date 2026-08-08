---
version: 1
slug: "packages-core-src-pages-designedpage-tsx"
primary_target: "packages/core/src/pages/DesignedPage.tsx"
related_targets: ["packages/core/src/pages/BarePage.tsx","packages/core/src/styles/app.css"]
---

# Chat surface — Core designed page

## Scope and mode

The chat that ships in Core: transcript, composer, the three harness conditions, and discovered Surfaces. Mode is **Operate** — the visitor completes a task, so state legibility and familiar affordance outrank expression. Related routes `#/bare` and `#/states` are the same machines rendered without design and parked per state; neither carries this brief's visual strategy.

## Audience, job, scene

One developer on their own machine. They scope a task, send it, and leave. The defining moment is not composing — it is **glancing back from across the room** and needing to know, without reading, whether it is still going, finished, or broken. Long sessions, often at night, in a room they control.

## Task and content

Send work; watch a turn resolve; interrupt when it goes wrong; see which Surfaces loaded and which failed. Content is mostly agent prose and tool activity at real reading length, which is why any form that cannot host a long transcript was rejected.

## Constraints

- Every control comes from `snapshot.can()`. Nothing binds `disabled` to `can({type:'START'})`, whose refusal fallback makes it permanently true; readiness comes from `canStartAgent()`.
- The three conditions — sandbox, credential, agent — are permanently visible, by the user's decision.
- Vermilion is the identity, so it cannot also be the alarm. Refusal and failure read through crease language: an unclosed square, a released fold.
- Anti-references, user-named: generic-AI, IDE chrome, terminal. Chat-app convention is permitted.
- No webfonts. Native system stack, appropriate to a desktop Operate surface.

## Chosen direction

**Orizuru Fold Sequence** — chosen by the user over the assigned Strip Chart, and over the category standard. One continuous sheet that carries every earlier crease; a session is the sheet, a turn is a fold, and the gold dot marks the active one.

Colour strategy is **Committed**: vermilion owns the rail as a whole field, sumi-washi owns the transcript field. Not cream-with-an-accent, which is where this world's soft rendition lands and is a named AI cluster.

The objection raised when this direction was offered — a fixed thirty-two-step sequence is the wrong shape for open-ended conversation — is resolved by letting the rail grow rather than terminate. Every earlier crease stays on the sheet, which is already what the machines do: an interrupted turn keeps the partial text it had already produced.

## Memorable moment

Interrupting. The fold is released, and the crease it had already made stays in the paper. The partial answer is not discarded — it is the shape the sheet now carries.

## Unresolved

- Where a failed Surface lives once there are many; the rail may not scale past a handful.
- Whether the crease lattice ground survives long sessions or becomes noise.
- Whether refusal-through-crease-language is legible enough without borrowing a second colour.
