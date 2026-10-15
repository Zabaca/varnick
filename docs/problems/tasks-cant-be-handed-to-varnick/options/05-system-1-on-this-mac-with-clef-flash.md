---
problem: tasks-cant-be-handed-to-varnick
title: System 1 on this Mac, Clef-flash, the model the pilots actually ran, so tasks need no TypeSafe
summary: Option 01's System 1 seam gets a second backend, Clef-flash 4-bit on this Mac. The pilots' calibration (the 0.7 bar, the rankings) was measured on it, not on Jev. Two ways in. (a) Varnick's own MLX port of Clef-flash and its joint head, as Laya was ported (ADR 0006). It downloads at a pinned revision, takes about 7.2 GB in use and 0.2 to 1.1 s a call on an M3 Ultra Mac. (b) A Clef server the user runs on this Mac or the tailnet, reached at an address as ADR 0014's model servers are. Varnick never starts it. Either way, nothing about a task goes to TypeSafe, though pages still go to Anthropic through Claude. Later. Build (b) first if option 01's follow-up test 2 shows Jev too slow, too costly or unavailable, and (a) only to ship it to others.
status: proposed
---

## Solution

- **The choice.** A System 1 row under Settings › Models, offering TypeSafe (Jev) or On this Mac (Clef). With On this Mac, tasks never call TypeSafe, whatever the relevance filter is set to.
- **(a) In Varnick.**
  - Clef-flash 4-bit (the public `mlx-community/clef-flash-4bit`) is ported to MLX in Swift: its language model and the joint head that answers every question from one forward pass, with no generation.
  - It downloads at a pinned revision, checked by hash.
  - It loads on the first task, and unloads after the task, or after a few idle minutes.
- **(b) A server.** An address, on loopback or the tailnet only, taking the same request Varnick would send TypeSafe. The pilots' local Clef server took requests of that kind. Whether its shape matches TypeSafe's is unverified. Varnick never starts, installs or keeps it running.
- **The bar.** Clef's 0.7 bar is the pilots' own measurement, so it carries over unchanged. Jev's would be re-measured (option 01, follow-up test 2).

## Trade-offs

- **For:**
  - **no TypeSafe allowance or key;**
  - **System 1's view of every page stays on the user's machines;**
  - **the calibration the pilots measured.**
- **Slower than Jev's clock.** The pilots' real Clef time was about twice their simulated figures: 0.5 s a turn at p50, about 1.1 s with 20 options. Time is linear in the request's tokens: 28 ms plus 0.88 ms per token on an M3 Ultra Mac (agent-lab clef-flash-local). Smaller Macs are slower (unmeasured).
- **Memory.** About 7.2 GB at its peak, beside Gemma, the embedder and the reranker. Resources would show it as an on-device model.
- **(a) is a port to own.** Laya's port took its own ADR and a parity check, and Clef is larger with a different head. **(b) is a service the user runs.**
- **Hosted Clef on the user's own Cloudflare (Workers AI)** answered a 20-page request in 0.75 s at p50, 1.17 s at p90 and once 10.75 s, over 200 requests (agent-lab clef-flash-local, the earlier rows it compares with). That puts a third party back in, so it isn't proposed.

## User Stories

1. As the user, I want tasks to run with System 1 on my Mac, so that I need no TypeSafe allowance and pages reach only Claude.
2. As the user, I want to point Varnick at a Clef server I already run, so that I can use it before a port exists.

## Implementation Decisions

- The backend sits behind option 01's System 1 seam. The questions, the state's text and the bar are shared, so a task behaves the same on either backend apart from speed.
- (a): its own ADR, like ADR 0006, and a parity check against the reference: the same answers to four decimals on recorded requests, as clef-flash-local did between runs.
- (b): `ModelServer`'s rules. Tailnet and loopback addresses only, no redirects, and a fallback to Jev, then to Claude, when the server is away.

## Testing Decisions

- The loop's five practice-shop tasks with Clef in Varnick, in real time and not on Jev's clock. Run by the user, or by agent-lab against the same model.
- Load time and peak memory, cold and warm, on the user's Macs.

## Out of Scope

- Clef in other features (the route, the judge, the relevance filter). That would be its own problem.
- Gemma as System 1. Its probabilities were measured not to separate right from wrong in the screen-pointing eval.

## Further Notes

- The pilots' System 1 was this model, so (b) is also the quickest way for the user to try option 01 while the Jev allowance is used up.
