---
problem: sessions-out-of-reach-from-the-phone
title: One page on one always-on Mac, reaching every host through the relay
summary: Option 01's server runs on one Mac only, the Mac Studio. It lists the sessions of the Studio and of every paired host in one place, and acts on another host by having the Studio's Launchy send the request over SSH, naming the phone as the controller. A terminal on another host is the Studio's pseudo-terminal running `ssh -t` to that host's relay attach, as a Mac's pane does. One address and one device list. Other hosts need nothing new but to accept a device that a listed peer vouches for. Everything depends on the Studio being up.
status: proposed
---

## Solution

**The hub.** The page server of option 01 runs only on the hub, a Mac chosen in Settings (the Studio). It is published there with `tailscale serve`, and holds the device list.

**The page lists every host,** grouped by Mac as the session list is: the hub's sessions and Recent, and each paired host's.

**Acting on another host.**
- For any other host, the hub's server asks its local relay to forward the request.
- The hub's running Launchy sends it over SSH, as it sends its own peer requests, with itself as `by` and the phone as the device the request is for.
- The host labels control, and origin when starting, with the device's id. It names the device from the request.

**Terminals.**
- A terminal on another host runs, in the hub's pseudo-terminal, the same `ssh -t -e none` to that host's relay `attach` that a Mac's pane runs, with take when the user pressed it.
- A terminal on the hub itself runs the local relay's attach, as in option 01.

**The rest is as in option 01:**
- the reconnect rules;
- what closing the tab and End do;
- the key bar and compose box;
- the Host and Origin checks.

## Trade-offs

- **One address and one device list for every host,** and every session in one list.
- **Linux hosts need only the relay over SSH,** which the Linux plan gives them. There is no Bun server and no serve mount there.
- **Everything depends on the hub.**
  - With the Studio asleep, restarting, or its Launchy down, the phone reaches no host at all, even hosts that are up.
  - Starting or resuming on another host needs the hub's Launchy running, since it holds the SSH connection.
- **Two hops for every terminal byte:** phone to Studio, then Studio to host. A drop on the hub's link to the host looks to the phone like its own.
- **Delegation in the protocol.** A host must accept "this device, vouched for by listed peer X".
  - Every host learns the device's id and name from requests, and must spare and name devices it never listed.
  - A host's rule for who may ask becomes "a listed peer, or a device a listed peer vouches for". That is more than option 01 adds, and on every host.
- **SSH channels.** Each phone terminal, and each live view, is a channel on the hub's shared connection to that host. OpenSSH allows ten per connection by default, and Tailscale SSH's limit isn't known (the live view's spike, step 7).
- **The Air as hub** would make the phone depend on a laptop's lid. Only an always-on Mac works as the hub.

## User Stories

As option 01, with story 1 reading: as a user away from my desk, I want one address on my phone to show the Claude sessions on all my hosts, so that I don't need to know which host runs what.

## Implementation Decisions

- **The hub** is chosen by a setting on one Mac. The others don't serve the page.
- **The device list** lives on the hub only, as in option 01.
- **Requests carry a new field:** the device's id and name. It is accepted only with `by` naming a listed peer. The control and origin labels name the device.
  - Each host keeps the names of the devices it has been told about, in a small file, so its cards can say "Controlled on Pixel 8a".
  - Its sweep spares a session labelled for one of those devices.
- **Forwarding.** A relay request lets the hub's server ask its own running Launchy to send a request to a peer for a device. It is accepted only from the hub's own relay, run on the hub.
- **Terminals on another host** use the SSH command the hub's Launchy builds for a pane today, so the SSH options and the shared connection are the same.
- **The protocol version goes up** for the device field and the forwarding request.

**Scope and ticket order:**
1. Devices on the hub, and the device field on every host.
2. The hub's server and its home page across hosts.
3. Terminals, local and over SSH.
4. Starting and resuming.
5. The live view.

## Testing Decisions

As option 01, from the hub, plus:
- a session on the Air driven from the phone through the Studio;
- the Studio asleep, which leaves the phone with nothing to open;
- more terminals and live views open at once than the SSH channel limit.

## Out of Scope

As option 01. Also: a second hub, and failing over to another Mac.

## Further Notes

- **Not recommended over option 01.** It trades every host standing alone for one address, and spreads the device concept across every host's protocol. Option 01's links between pages give most of the one-address benefit.
- **Choose it** if one address matters more to the user than reaching a host while the Studio is down, or to keep Bun and `tailscale serve` off the Linux host.
