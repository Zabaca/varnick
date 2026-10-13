---
problem: work-is-tracked-by-session-not-tab
title: Web and app panes of another host's tab load through that host's port proxy
summary: On top of option 03, as decision 4 has it. Each host runs a reverse proxy in its Phone page server, the one Varnick process that runs between requests on a Mac and on the headless host alike. The proxy listens on the host's tailnet address, on the ports its open tabs' web and app panes use, with a `tailscale cert` certificate for the machine's name, and forwards port N to localhost:N. It forwards websockets and rewrites the Host header so dev servers' host checks pass. Another Mac's web pane loads `https://<host's tailnet name>:N/` in place of `http://localhost:N/`. The phone shows it in the tab's pane view. Only listed devices and paired machines may connect, and a request started by another site is refused. The host's listing gives each such pane's address (protocol 25). A spike first checks `tailscale cert` and the tailnet bind on each kind of host, and Scratch through the proxy.
status: accepted
---

## Solution

**The proxy (decision 4).** Each host runs one reverse proxy. It listens on the host's own tailnet address, and only there. It opens one listener per port that a web or app pane of the host's open tabs uses: an app pane's port, and the port of a web pane on localhost, 127.0.0.1 or ::1. It forwards each to the same port on localhost. Its certificate is the machine's own from `tailscale cert`, for its tailnet name, so one certificate serves every port.

**Where it runs.** In the Phone page server. That is the Varnick process that runs all the time on both kinds of host:
- on a Mac, in its own zmx session, outliving Varnick;
- on the headless host, as a systemd user unit.

The relay, which decision 4 named for a Mac, runs only for one request and exits. The server already does several things the proxy needs:
- it knows the host's tailnet name;
- it asks `tailscale whois` who is calling;
- it reads the listed devices;
- it maps the listed peers' addresses to tailnet nodes;
- it is Bun, which serves TLS and websockets.

A host that doesn't serve the Phone page doesn't proxy.

**What another machine sees.** The host's listing gives each web and app pane its proxied address, `https://<host's tailnet name>:N/` plus the pane's path. A Mac loads that address in the pane's web view, in place of option 03's card. The phone loads it in the tab's pane view. Navigating in that pane is the viewer's own browsing, and the host's pane keeps its own address.

**What goes through.** HTTP and websockets are forwarded both ways, bodies untouched. Only what a dev server checks is rewritten:
- the Host header, to localhost and the port;
- the Origin, when it is the proxied address itself;
- a redirect to localhost, back to the proxied address.

**Who gets in.** The proxy asks `tailscale whois` about the caller's own address. It admits a device the host lists, and a paired machine's node. A request that another site started is refused, as the Phone page's own `/api` refuses one.

## Trade-offs

- **A new door, on the ports the open tabs use, on the tailnet address.**
  - It amends ADR 0011, which allows one door (8444, through `tailscale serve`), and ADR 0007's "No listening port".
  - It is never public. Funnel reaches only serve mounts, and this is a plain listener on the tailnet address.
  - The user's custom apps have no sandbox and no login. Today only this machine reaches them. With this option, every device and paired machine it admits does too.
- **Storage is per port, cookies are per name.** Each app has its own origin, so its local storage is its own. But a cookie set by one port goes to every port of the same host name, as it does on 127.0.0.1 today (decision 4 rejected path prefixes partly for leaking these).
- **Rewriting Host and Origin** passes the DNS-rebinding checks of dev servers that keep to localhost: Vite's since 6.0.9 (Scratch's lock has 6.4.3), webpack's and Next's. An app that writes `http://127.0.0.1:N` into its own pages still breaks from afar: mixed content, and the wrong host.
- **A server bound to every address of the host** (0.0.0.0) holds the port on the tailnet address too. The proxy can't listen there, and the pane says why. The server is then reachable straight over plain HTTP, unchecked, as it already is (inferred).
- **It needs the Phone page server on the host.** A host with the page off keeps option 03's card for these panes.
- **`tailscale cert` and the bind are untested on these hosts.** A Mac host may refuse `tailscale cert` to a user who isn't root, as one refused `serve` to a socket (ADR 0011's note). Linux may need the user made an operator, or `TS_PERMIT_CERT_UID` set for tailscaled (inferred from Tailscale's docs). Hence the spike.
- **A protocol bump to 25,** for the proxied address in the listing.

## User Stories

1. As the user, I want a web pane of another Mac's tab, showing a dev server on its localhost, to load here.
2. As the user, I want Scratch, or any custom app, in a tab of the Ryzen or another Mac to load here and on the phone, with hot reload working.
3. As the user, I want each app to keep its own storage, so that two apps of one host don't mix.
4. As the user, I want nothing but my listed devices and paired Macs to reach those apps, and no other site open on my phone to reach them through it.
5. As the user, I want ports no open tab uses to stay closed to the tailnet.
6. As the user, I want a web pane whose page can't come through the proxy to say why, not to show a blank page.
7. As the user, on the phone, I want a tab's web or app pane in the tab's view, with a way to open it alone in a browser tab.

## Implementation Decisions

**Spike first** (one ticket, on each kind of host, nothing published or left running):
- **`tailscale cert`:**
  - as the user, on a Mac with the Tailscale app (its CLI needs `TERM`), on a Mac with Homebrew's tailscaled, and on the headless host;
  - where the files land, and how renewal is asked.
- **The bind:** Bun binding the tailnet address on a spare port, reached from the other Mac and the phone.
- **Scratch through it:** Vite's host check, its hot reload over `wss`, and a page from a second port beside it.
- **Fetch metadata:** whether a Mac's web view sends the `Sec-Fetch-Site` header.

The results go into this option's Further Notes before the rest is built.

**The listeners**
- **One per port the host's open tabs name:**
  - each app pane's port;
  - each web pane's port on localhost, 127.0.0.1 or ::1.

  They are read from the host's own `tabs` through its relay, as the server reads every list. It is read again every few seconds and when a page asks. A port no open tab names is closed within that time.
- **Bound to the host's tailnet addresses only,** IPv4 and IPv6, never every address. Port 8444 is never one of them.
- **A port already taken on the tailnet address** is skipped, and logged. The listing says that pane can't be proxied, and why.

**The certificate**
- From `tailscale cert` for the machine's tailnet name, at start and again before it expires (looked at daily). The files go in an owner-only folder.
- With no certificate the proxy listens nowhere, and the panes say why. Settings on a Mac, and the installer's report on the headless host, say so too.

**Who is let in**
- **`tailscale whois` on the connection's own address.** No forwarded header is trusted, since nothing sits in front.
- **Admitted:**
  - a device the host lists;
  - the node of a peer the host lists, found from its address as the page already finds the other hosts' nodes for its links.
- **Refused,** before anything is forwarded:
  - anyone else;
  - a whois that fails;
  - a request whose `Sec-Fetch-Site` says another site started it, unless it is a top-level navigation. This mirrors the page's own check on `/api`.

  The spike says whether a Mac's web view sends the header. If it doesn't, Origin and Referer decide.
- **Caps on what is open at once,** per caller and in all. They work as the page's own are counted. They are counted per proxied port, not shared with the page's terminals.

**Forwarding**
- **To 127.0.0.1 and then ::1** on the same port, HTTP and websockets both.
- **Rewritten:**
  - Host, to `localhost:<port>`;
  - Origin, when it equals the proxied address, to `http://localhost:<port>`;
  - a `Location` pointing at localhost, 127.0.0.1 or ::1 on that port, back to the proxied address.

  Nothing else is rewritten, and bodies are never touched.
- **Logs** keep to opens, closes, codes and the port: never a path, a query or a body.

**On the viewer**
- **The host's `tabs` gives each web and app pane its proxied address,** built from the host's own tailnet name. A Mac never builds the address from a peer's SSH address, which may be an alias.
- **A Mac's web pane loads the proxied address,** and option 03's card shows only when the listing says the pane can't be proxied. Reload and the address bar act on the viewer's own copy.
- **The phone's tab view** shows the page in a frame, with "Open alone" beside it. The page's content rules allow frames from the host's own name on the proxied ports.
- **Splits from afar** (option 03's decision 1) can then offer web and app panes too. The host runs the app, and the viewer loads it through the proxy.

**The protocol** goes to 25, for the proxied address and the reason a pane can't be proxied in `tabs`, with the Phone page's constant.

## Testing Decisions

- **`bun test` in the Phone page:**
  - the rewrite rules (Host, Origin, Location);
  - the admission rule;
  - the fetch-metadata rule;
  - which ports a `tabs` answer opens and closes.

  They are pure, beside the page's checks, like its existing ones.
- **A check against a throwaway port and a copy of the server,** like the page's existing check on a throwaway port. Never against the running page.
- **By hand,** after the spike and the user's restarts and upgrade:
  - **A dev server.** A dev server on Mac A's localhost:5173 in a web pane of a tab. On Mac B and on the phone it loads, and a change to a file hot-reloads it on both.
  - **Scratch.** Scratch in a tab of the Ryzen loads on Mac B, and its page updates as Claude writes it.
  - **An unlisted caller.** A tailnet node that is neither listed nor paired gets nothing on that port.
  - **A port not in use.** A port Mac A's tabs don't use is closed on its tailnet address.
  - **Closing.** Closing the web pane on Mac A closes its port within a few seconds.

## Out of Scope

- Sharing a browser's logged-in state between machines (decision 4: pixel streaming, kept for later if ever needed).
- Proxying any port that no open tab names, or a page outside the tailnet.
- Ports of web panes on an outside address: they load straight from wherever they are.

## Further Notes

- **Decided by the user, 2026-10-12, and not reopened here** (problem.md has the reasons): routing by port; one listener per host on its tailnet address; `tailscale cert`; and the rejection of routing by path prefix, routing by subdomain, one `tailscale serve` per pane and pixel streaming.
- **A correction to the decision's wording:** "the relay on a Mac" doesn't run between requests (verified: each request is one process that exits after its reply). The Phone page server is the process that does, on both kinds of host.
- **An ADR once accepted:** "Remote web and app panes go through a port proxy in each host's Phone page server". It amends ADR 0011 (one door) and ADR 0007 (no listening port).
- **CONTEXT.md:** **Phone page**, since the server now also proxies, and perhaps a term for the proxy.
- **where-it-breaks:** a Port proxy section for:
  - the admission rule;
  - the rewrites;
  - the certificate's renewal;
  - the listeners following the tabs;
  - "never 8444", and never every address.
- **Considered and not proposed:**
  - **SSH port forwarding from each Mac.** Macs already reach their peers over SSH, but the phone has no SSH, so the phone would need the proxy anyway, and there would be two ways.
  - **The proxy inside Varnick on a Mac.** The headless host has no Varnick, and the page server outlives a restart of Varnick.
- **Verified in the code at 0d1d161:**
  - apps listen on 127.0.0.1 at their `PORT`, and their pane loads `http://127.0.0.1:<port>/`;
  - Scratch is a Vite dev server on 127.0.0.1 (6.4.3 in its lock);
  - the page server runs in zmx on a Mac and as a systemd unit on the headless host;
  - it knows the host's tailnet name, runs whois and maps listed peers' addresses to nodes;
  - the relay is one process per request.
- **Inferred, not tested:**
  - Vite's host check and its hot-reload socket going to the page's own host (Vite's documentation);
  - that cookies ignore ports (the cookie standard);
  - that a bind on the tailnet address works under each kind of Tailscale here;
  - `tailscale cert` as the user;
  - whether a Mac's web view sends fetch metadata.
- **Decided by the user (2026-10-12),** when accepting this option, each the recommendation:
  1. **The proxy runs in the Phone page server** on both kinds of host.
  2. **Only the ports the host's open tabs name** are proxied.
  3. **Listed devices and paired machines** may connect.
