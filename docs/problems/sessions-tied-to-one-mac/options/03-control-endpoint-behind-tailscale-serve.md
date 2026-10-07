---
problem: sessions-tied-to-one-mac
title: A Launchy endpoint behind `tailscale serve` for control; SSH only for the terminal
summary: Each Launchy serves a small HTTP API on loopback, published to the tailnet with `tailscale serve`, as the user's existing browser terminal publishes its Picker. Peers find each other, start sessions, take over, follow changes and pull search rows through it, with changes pushed instead of polled. SSH carries only the terminal bytes, through `ssh -t` to the host's zmx.
status: proposed
---

## Solution

Each Launchy listens on a loopback port, and `tailscale serve` publishes it on an HTTPS port of the Mac's MagicDNS name, as the existing browser terminal does. Peers call it directly: hello, start, take over, status, tabs, Recent and rows, and a stream of changes that each peer keeps open. The host's running Launchy starts and owns every session, as in option 01. A peer in control attaches through `ssh -t` to the host's zmx. Discovery can probe the endpoint on every macOS node in the tailnet without SSH.

## Trade-offs

- **Pushed, not polled.** A takeover, a /clear or an ended session reaches the other Mac at once over the open stream.
- **Cheap calls.** HTTPS on the tailnet with no SSH handshake per call.
- **Two ways in.** SSH for the terminal and a tailnet HTTPS port for control. The user chose SSH as the transport, and this adds a second door.
- **Weaker authentication.** Anyone on the tailnet reaches the port. The existing browser terminal found that the `Tailscale-User-Login` header can be forged by any local process when the service listens on loopback, so it trusts nothing beyond the tailnet. Launchy would need its own pairing secret on top.
- **Changes Tailscale's own settings.** `tailscale serve` settings persist in Tailscale on each Mac, beyond Launchy. A serve port can clash with another service, which that terminal's installer checks for: this Mac already serves the terminal on 8443. Funnel must be checked off.
- **A listener in Launchy,** with its request handling, port choice and the "is this port somebody else's" problem the terminal's installer had to solve.

## User Stories

As option 01, with changes on one Mac appearing on the other at once.

## Implementation Decisions

- Bind loopback only and publish through `tailscale serve` on its own HTTPS port, never the tailnet interface, as in the terminal's decision record.
- A pairing secret exchanged once over SSH and required on every request, since tailnet membership alone is weaker than the user's SSH keys.
- Everything else as in option 01.

**Scope and ticket order:** option 01's five tickets, with the first replaced by the endpoint, serve setup, a port-clash check and the pairing secret.

## Testing Decisions

As option 01, plus: a Mac without the pairing secret is refused; the serve port doesn't clash with the existing browser terminal's 8443; Funnel is off.

## Out of Scope

As option 01.

## Further Notes

- Not recommended: it adds a second way in that the user didn't ask for, and its main gain, pushed changes, can come later over option 01's SSH channel as a long-running watch request.
- Re-propose if polling over SSH proves too slow or too heavy with more than two Macs.
