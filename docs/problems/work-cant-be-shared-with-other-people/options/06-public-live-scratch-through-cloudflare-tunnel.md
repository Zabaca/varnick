---
problem: work-cant-be-shared-with-other-people
title: A live public link for a Scratch through a Cloudflare Tunnel (cloudflared) from the Mac
summary: Option 04's Scratch public front, links, confirm and indicator, but carried by Cloudflare's own tunnel daemon, cloudflared, run by Varnick in zmx, instead of a connector and Durable Object written here. A wildcard hostname on the links domain goes through the tunnel to a router on the Mac that picks the link by its hostname. A Worker can still sit in front for the offline page and expiry. It spares writing a tunnel protocol, at the price of a large downloaded binary, a long-running third-party daemon, a tunnel credential on the Mac, and a new dependency. Not recommended unless option 04's protocol proves hard. Rough effort is about six days on top of the public front.
status: proposed
---

## Solution

- **The same public front as option 04,** and the same link shape: `https://<id>.<links domain>/`.
- **The tunnel.** cloudflared runs in zmx under a fixed name while a link is live, with one named tunnel whose ingress sends the links domain's wildcard to a router on the Mac. The router picks the link by its hostname and forwards to that pane's public front.
- **The edge.** A small Worker in front answers stopped and expired links, the offline page and the edge limits. Without it, viewers of a Mac that sleeps get Cloudflare's own error page.
- **cloudflared is a pinned download,** fetched, checked and signed the way `make build` handles zmx and Bun, and shipped in the app.

## Trade-offs

- **For: mature proxying.** cloudflared already carries HTTP and websockets, with reconnects. Nothing like option 04's framing protocol is written here.
- **A new dependency.** A third-party binary of tens of megabytes (inferred) to pin, fetch, sign inside a notarized app and keep patched. `CODING_STANDARDS.md` would have to list it, and every release carries it.
- **A long-running daemon from a download.** That is the pattern that once had macOS's XProtect kill a Claude session's process (the orchestrator's rules). Its spikes must run outside a session, and its behaviour under XProtect on users' Macs is a risk this repository hasn't taken.
- **A tunnel credential on the Mac.** A token that lets its holder serve on the tunnel's hostnames. It is more powerful than option 04's per-link connect token, and lives as long as the tunnel.
- **Two moving parts at the edge.** The tunnel's ingress and the Worker in front, against option 04's one Worker.
- **Same exposure as option 04.** The public front, the confirm and Cloudflare seeing the traffic in clear are unchanged.

## User Stories

As option 04's.

## Implementation Decisions

- Option 04's public front, confirm, indicator, switch and expiry.
- **Each tunnel credential** is kept in the Keychain and handed to cloudflared at its start, never on its command line.
- **The router** listens on loopback only, and refuses a hostname that isn't a live link's.
- **The Worker in front** keeps the expiry and the stop, as option 04's object does, without a connector socket.

## Testing Decisions

- As option 04's for the public front and the Worker.
- **By hand,** with cloudflared started by Varnick in zmx, never from a session's process: a link serves, survives sleep, and stops.

## Out of Scope

As option 04's.

## Further Notes

- **What would make it the better choice.** The spike of option 04 finding that its framing over a Durable Object can't carry a dev page well (latency, message limits, hibernation). Then cloudflared's own transport, with option 04's Worker kept in front, is the fallback.
