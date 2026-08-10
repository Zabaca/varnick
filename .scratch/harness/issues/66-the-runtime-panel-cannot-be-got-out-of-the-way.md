# 66 — The runtime panel cannot be got out of the way

**What to build:** A toggle that hides the runtime panel, and gives the column back when there is nothing else in it.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

**Realizes:** no state path. A root-level event and one context field; `SESSION_STATE_PATHS` does not change.

## The gap

The runtime panel holds a permanent 320px column. It is read about twice a
session — once on a fresh clone, to see what the agent actually loaded, and again
when something is wrong — and for the rest of the session it is a description of
the agent sitting where the agent's output should be.

On a laptop this is not cosmetic. The transcript is capped at `var(--prose)`, and
with the column present the available width falls below that measure, so the
conversation is narrower than the width it was designed for because of a panel
nobody is currently reading.

## What to build

**A `TOGGLE_RUNTIME` event on the Session machine's root**, beside `TOOL_CALL`
and `TOOL_RESULT`, flipping a `runtimeHidden: boolean` on the context that
defaults to `false`. Root-level for the same reason those two are: it is a fact
about the window, and no Turn state has standing to decline it. A developer
hiding a panel while the agent is mid-answer must not be told the window is busy.

`SessionInput` accepts `runtimeHidden` so a scenario can seed either reading.

**The affordance lives in the composer's status line**, beside the model and
effort chips, not in the panel's own header. The panel is what is being hidden,
so a control inside it disappears with it — and the status line is the only
chrome on the surface that is visible unconditionally, whatever the panel and the
Surfaces are doing.

**The column renders when it has something to hold.** An unhidden runtime panel,
or at least one Surface. With the panel hidden and no Surfaces, the `<aside>` is
not in the document at all and the conversation takes the full width. With
Surfaces loaded it stays, holding them — hiding a Core panel must not take
Userspace's output with it (ADR-0004).

## Testing

`drive.ts`, the actor seam. Three assertions carry it:

- `TOGGLE_RUNTIME` is accepted while a Turn is in flight
- it flips, and flips back — a toggle that only turns on is the bug this catches
- a Session seeded `runtimeHidden: true` reports it

A states-page card for the hidden reading, so the collapsed layout is something
that was looked at rather than only reachable by clicking in the live app.

## Out of scope

Persisting the setting across a reload. A reload starts with the panel shown.
Persisting means either the machine reading `localStorage`, which breaks
[ADR-0001](../../../docs/adr/0001-pure-view-layer.md), or the host carrying a
preference store, which is a feature rather than a fix. Recorded in the spec so
the next person does not rediscover it as an oversight.

A View-menu item or accelerator. The status-line toggle is the whole affordance.
