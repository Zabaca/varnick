---
problem: work-cant-be-shared-with-other-people
title: A live public link for a Scratch through Tailscale Funnel on the Mac
summary: Option 04's Scratch public front, Share button, confirm and indicator, but published by Varnick turning on Tailscale Funnel for one port of this Mac, with the link's secret as a path. No Cloudflare and no relay code, and TLS ends on the Mac. In exchange, every link carries this Mac's machine name and tailnet name in public, Funnel is a switch for the whole machine on a few fixed ports, every link shares one origin, the page has to be served under a path prefix, and Varnick would start running `tailscale funnel`, which ADR 0011 rules out. Not recommended. Rough effort is about four days on top of the public front.
status: proposed
---

## Solution

- **The same public front as option 04.** Scratch serves the public front on a local port. In front of it, a small router in Varnick's connector serves each live link under `/<random id>/` and refuses everything else.
- **Funnel.** Varnick runs `tailscale funnel` for one of the ports Funnel allows (443, 8443 or 10000), pointed at that router. It turns it off when the last link stops, and when the switch goes off.
- **The link.** `https://<this Mac's full tailnet name>/<26 random characters>/`: the machine's name, then the tailnet's.
- **Under a path prefix.** Scratch's Vite has to serve the page under that prefix (its `base`), so each link needs its own Vite server, or the front rewrites every absolute path the page asks for.
- **Expiry, stop and the viewer count** are kept by the router on the Mac. With the Mac asleep there is nothing to answer, so viewers get a connection error, not an offline page.

## Trade-offs

- **For:**
  - no third party beyond Tailscale;
  - no relay to write, deploy or pay for;
  - traffic is encrypted to the Mac itself.
- **The names go public.** Every link names the machine and the tailnet in public, where they are now only in certificate logs. Anyone with one link knows where the Mac answers.
- **Machine-wide.** Funnel is on for a port of the whole machine, and needs the funnel attribute in the tailnet's policy (inferred).
- **Against ADR 0011.** It reverses the rule that Varnick never runs `tailscale funnel`, which the Phone page's fail-closed checks rest on. A mistake in the serve configuration becomes public instead of tailnet-only.
- **One origin for every link.** Links on one hostname share storage, and any other funneled path shares their origin.
- **Path prefixes fight Vite.** Each link needs its own `base`, so a second Vite server per link or a rewrite of every absolute path. Option 04 avoids this with a hostname per link.
- **Nothing answers while the Mac sleeps.** No offline page, and no way to tell viewers a link was stopped.

## User Stories

As option 04's, except stories 8 (an offline page) and 9 (the Mac's names never appear), which this option can't meet.

## Implementation Decisions

- Option 04's public front, confirm and indicator, unchanged.
- **The router in the connector** listens on loopback only, and Funnel is its only way in. It refuses every path but a live link's prefix.
- **Funnel is Varnick's alone.** Varnick changes only the one Funnel port it turned on, by ADR 0011's ours-or-the-user's rule, and fails closed when Funnel's state can't be read.
- **ADR 0011's note would be amended,** and the privacy doc's statement that Varnick never runs Funnel changed.

## Testing Decisions

- As option 04's for the public front.
- **By hand:** Funnel goes on with the first link and off with the last. A path that isn't a live link gets 404. The Phone page's 8444 stays tailnet-only throughout.

## Out of Scope

As option 04's.

## Further Notes

- **Why it is on record.** It is the smallest way to a public URL on a Mac that already runs Tailscale, and the obvious first idea. Option 04 costs a relay, and in return keeps the Mac's names private, gives every link its own origin and answers while the Mac sleeps.
