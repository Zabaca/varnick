---
problem: work-is-tracked-by-session-not-tab
title: Web and app panes of another host's tab load through that host's port proxy
summary: On top of option 03, as decision 4 has it. Each host runs a reverse proxy in its Phone page server, the one Varnick process that runs between requests on a Mac and on the headless host alike. The proxy listens on the host's tailnet address, on the ports its open tabs' web and app panes use, with a `tailscale cert` certificate for the machine's name, and forwards port N to localhost:N. It forwards websockets and rewrites the Host header so dev servers' host checks pass. Another Mac's web pane loads `https://<host's tailnet name>:N/` in place of `http://localhost:N/`. The phone shows it in the tab's pane view. Only listed devices and paired machines may connect, and a request started by another site is refused. The host's listing gives each such pane's address (protocol 25). A spike first checks `tailscale cert` and the tailnet bind on each kind of host, and Scratch through the proxy.
status: shipped
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

**When a port opens.** Only while its server answers on localhost and nothing else answers on the tailnet address at that port. It closes when the server stops answering. The spike found that a listener opened before then collides with a server bound to every address: on Linux the server can't start, and on a Mac the proxy takes its tailnet traffic.

**Who gets in.** The proxy asks `tailscale whois` about the caller's own address. It admits a device the host lists, and a paired machine's node. Of what a browser asks, it lets through only the proxied page's own requests and navigations: a page loaded whole, or loaded into a frame by a page of the same site, as the phone's tab view does. Any other request a page starts is refused, from another port of this host too.

## Trade-offs

- **A new door, on the ports the open tabs use, on the tailnet address.**
  - It amends ADR 0011, which allows one door (8444, through `tailscale serve`), and ADR 0007's "No listening port".
  - It is never public. Funnel reaches only serve mounts, and this is a plain listener on the tailnet address.
  - The user's custom apps have no sandbox and no login. Today only this machine reaches them. With this option, every device and paired machine it admits does too.
  - Its certificate is the one serve already keeps for 8444, so the machine's name is already in the public certificate logs, and the proxy adds nothing there (the spike).
- **Storage is per port, cookies are per name.** Each app has its own origin, so its local storage is its own. But a cookie set by one port goes to every port of the same host name, as it does on 127.0.0.1 today (decision 4 rejected path prefixes partly for leaking these). The Phone page sets no cookies (verified), so no app reaches one of its.
- **Rewriting Host and Origin** passes the DNS-rebinding checks of dev servers that keep to localhost. Vite's passed in the spike (6.4.3, Scratch's), hot reload included; webpack's and Next's are inferred from their documentation. An app that writes `http://127.0.0.1:N` into its own pages still breaks from afar: mixed content, and the wrong host. So does Vite's fallback socket, tried when the proxied one fails: it goes to `127.0.0.1:N`, which on a viewer is the viewer's own.
- **Requests between two ports of a host break,** where they work on localhost: a page on one port fetching from another (open question 4).
- **A server bound to every address of the host** (0.0.0.0 or ::, as Node's default `listen(port)` and `next dev` bind) answers on the tailnet address itself, over plain HTTP and unchecked, as it already does (inferred). The proxy leaves its port alone, and the pane says why.
- **On Linux, a server that binds every address and restarts within a few seconds can fail to start:** the proxy still holds the tailnet address at its port until it sees the server has stopped. Started again after that, it starts.
- **It needs the Phone page server on the host.** A host with the page off keeps option 03's card for these panes.
- **`tailscale cert` needs the user to be Tailscale's operator,** or tailscaled run with `TS_PERMIT_CERT_UID` for the user, on Linux and on a Mac with Homebrew's tailscaled alike (the spike). Setting either takes root, once per host. The Tailscale app's CLI on a Mac is untested.
- **A protocol bump to 25,** for the proxied address in the listing.

## User Stories

1. As the user, I want a web pane of another Mac's tab, showing a dev server on its localhost, to load here.
2. As the user, I want Scratch, or any custom app, in a tab of the Ryzen or another Mac to load here and on the phone, with hot reload working.
3. As the user, I want each app to keep its own storage, so that two apps of one host don't mix.
4. As the user, I want nothing but my listed devices and paired Macs to reach those apps, and no other site open on my phone to reach them through it.
5. As the user, I want ports no open tab uses to stay closed to the tailnet.
6. As the user, I want a web pane whose page can't come through the proxy to say why, not to show a blank page.
7. As the user, on the phone, I want a tab's web or app pane in the tab's view, with a way to open it alone in a browser tab.
8. As the user, I want a dev server I start after opening its pane to start as it would without the proxy.

## Implementation Decisions

**Builds on option 03,** not on option 01 and the resume fix alone. Today a host lists only its Claude panes to other machines (verified), so no web or app pane of another host shows anywhere for the proxy to serve. Option 03 brings the three things this option uses:
- `tabs`, which lists web and app panes with their addresses and ports: the proxy reads its ports from it, and it carries the proxied address;
- a Mac's view of a host's tab, whose card for web and app panes this option replaces;
- the phone's tab view, which this option frames the app into.

Start from option 03's branch, or from main once option 03 is merged. Only the host half (the rules, listeners, certificate and admission in the page server) needs nothing of option 03. It could be a first ticket from main, with its ports given by hand in its throwaway check, but nothing reaches a viewer before `tabs` does.

**The spike ran on 2026-10-12,** with throwaway code since removed. It ran on the Ryzen (Linux, tailscaled under systemd) and on a Mac with Homebrew's tailscaled, both with Bun 1.3.14: a minimal Bun proxy in front of Vite 6.4.3, reached with curl, a Bun websocket client and an offscreen WKWebView. Its findings are in the decisions below, marked (the spike). Its notes, which name the real hosts, stay in the problem's scratch folder. No Mac with the Tailscale app could be reached, and what is left is in Testing Decisions.

**The listeners**
- **One per port the host's open tabs name:**
  - each app pane's port;
  - each web pane's port on localhost, 127.0.0.1 or ::1.

  They are read from the host's own `tabs` through its relay, as the server reads every list. It is read again every few seconds and when a page asks. A port no open tab names is closed within that time.
- **Opened only when, at a look, all of these hold:**
  - **The port is 1024 or above.** A lower one needs root (the spike).
  - **`tailscale serve` doesn't publish it.** tailscaled holds each serve port on the tailnet address, 8444 always, so the bind fails, though `lsof` as the user doesn't show the port held (the spike, on both hosts).
  - **Its server answers on localhost,** 127.0.0.1 or ::1. On Linux, while the proxy holds the tailnet address at a port, a later bind of every address at that port fails, for Bun, Node and Python alike (the spike). So a listener opened before its server would keep the server from starting.
  - **Nothing answers on the tailnet address at that port,** found by connecting there. On a Mac a bind there succeeds over a server bound to every address, and the more specific bind wins: the proxy would take that server's tailnet traffic and turn its plain HTTP into TLS (the spike). So a failed bind can't be the check, on either kind of host.
- **Closed** when no open tab names the port, or when its server stops answering on localhost: at the next look, or at once when a forward finds localhost refusing.
- **Bound to the host's tailnet addresses only,** IPv4 and IPv6, never every address. Port 8444 is never one of them.
- **A port that isn't opened** is logged, and the listing says that pane can't be proxied, and why: below 1024, published by serve, its server not running, or a server already on every address.
- **The listing learns this from the page server** (picked; the relay reads nothing of the page server's today, verified). The relay answers `tabs` whether the page server runs or not (option 03). So at each look the page server writes its tailnet name, the ports it holds and why each other one isn't held to a file in its owner-only folder, and the relay reads that into `tabs`. No file, or one older than a minute, means the page server isn't running, and the listing says so.

**The certificate**
- **From `tailscale cert` for the machine's tailnet name,** the files written to the page server's owner-only folder. It hands back the certificate tailscaled already keeps for serve's 8444, at once (the spike).
- **Renewal.** Asked daily with a minimum validity. tailscaled renews its cached certificate itself, so asking costs nothing (the spike). A new certificate goes in by stopping each listener, letting its open connections finish, and serving the port again with it. Bun 1.3.14's reload of TLS options says it succeeded and keeps serving the old certificate. A websocket open across the swap kept working (the spike).
- **Access needs the user to be Tailscale's operator,** or tailscaled run with `TS_PERMIT_CERT_UID` for the user. Anyone else is refused (the spike). Each host checks it and says how to set it, since setting it takes root:
  - the headless host's installer, as it already says how to turn linger on (it runs as the user, verified);
  - a Mac's Settings, while the page is on.
- With no certificate the proxy listens nowhere, and the panes say why. Settings on a Mac, and the installer's report on the headless host, say so too.

**Who is let in**
- **`tailscale whois` on the connection's own address,** passed as the bare IP, an IPv6 one too (tailscaled's local API refuses an IPv6 address followed by a port without brackets, the spike). No forwarded header is trusted, since nothing sits in front.
  - It shares the page's whois, cached a minute per address (picked: what the page does today).
  - tailscaled's local socket answered the same question in 0–2 ms on both hosts, as the user and with no operator (the spike). It can take the CLI's place if spawning it ever shows.
- **Admitted:**
  - a device the host lists;
  - the node of a peer the host lists, found from its address as the page already finds the other hosts' nodes for its links.
- **Refused,** before anything is forwarded:
  - anyone else;
  - a whois that fails;
  - a browser's request the fetch-metadata rule refuses.
- **The fetch-metadata rule** (corrected by the spike). A Mac's web view sends `Sec-Fetch-Site`: `none` for a page it loads, `same-origin` for the page's own requests and its hot-reload socket. Another port of the same host arrives as `same-site`, not `cross-site`, and so does every host of the tailnet, since `ts.net` is on the Public Suffix List (found in a copy of the list). Refusing only `cross-site` would let any app on any port reach every other. Let through only:
  - `same-origin`, as the Phone page's own check on `/api` has it;
  - a top-level navigation, whatever started it;
  - a navigation into a frame, from the same site or origin. The phone's tab view frames the app inside the 8444 page, and that arrives as `same-site`, a navigation, into an iframe.

  Framing by another page of the tailnet is left as a small clickjacking surface on the user's apps. Without the header, the Origin, when sent, must be the proxied address itself; a client that sends neither (curl) goes through, as on the page.
- **Caps on what is open at once,** per caller and in all. They work as the page's own are counted. They are counted per proxied port, not shared with the page's terminals.

**Forwarding**
- **To 127.0.0.1 and then ::1** on the same port, HTTP and websockets both.
- **A websocket's upstream is opened before the browser's upgrade is answered,** so the subprotocol the server picked (Vite's `vite-hmr`) goes back in the answer (the spike).
- **Rewritten:**
  - Host, to `localhost:<port>`: Vite answers 403 without it (the spike);
  - Origin, when it equals the proxied address, to `http://localhost:<port>`, for webpack's and Next's checks. Vite's hot reload trusts its own token, and passed with the Origin untouched (the spike);
  - a `Location` pointing at localhost, 127.0.0.1 or ::1 on that port, back to the proxied address.

  Nothing else is rewritten, and bodies are never touched.
- **A server that doesn't answer** gets the viewer a 502 with the reason.
- **Logs** keep to opens, closes, codes and the port: never a path, a query or a body.

**On the viewer**
- **The host's `tabs` gives each web and app pane its proxied address,** built from the host's own tailnet name. A Mac never builds the address from a peer's SSH address, which may be an alias.
- **A Mac's web pane loads the proxied address,** and option 03's card shows only when the listing says the pane can't be proxied. Reload and the address bar act on the viewer's own copy.
- **A load refused at once, of a pane the listing says is proxied,** means the host's page server has stopped since: the tailnet answers a closed port with a reset rather than a hang (the spike). The pane says the Phone page server isn't running there, in place of WebKit's error.
- **The phone's tab view** shows the page in a frame, with "Open alone" beside it. The page's content rules allow frames from the host's own name on the proxied ports. An app that forbids framing shows nothing there, and Open alone covers it.
- **Splits from afar** (option 03's decision 1) can then offer web and app panes too. The host runs the app, and the viewer loads it through the proxy.

**The protocol** goes to 25, for the proxied address and the reason a pane can't be proxied in `tabs`, with the Phone page's constant.

## Testing Decisions

- **`bun test` in the Phone page:**
  - the rewrite rules (Host, Origin, Location);
  - the admission rule;
  - the fetch-metadata rule, with the headers the spike saw: `none` for a page load, `same-origin` for its own requests, `same-site` for another port and for the phone's frame;
  - which ports a `tabs` answer opens and closes, with each condition: below 1024, a serve port, a server not answering on localhost, an answer on the tailnet address.

  They are pure, beside the page's checks, like its existing ones.
- **A check against a throwaway port and a copy of the server,** like the page's existing check on a throwaway port. Never against the running page. It also swaps the certificate with a hot-reload socket open. It runs from a shell with no `HTTPS_PROXY`: through a proxy, a request arrives from the proxy's node, as one did in the spike.
- **By hand,** after the user's restarts and upgrade:
  - **A dev server.** A dev server on Mac A's localhost:5173 in a web pane of a tab. On Mac B and on the phone it loads, and a change to a file hot-reloads it on both.
  - **Scratch.** Scratch in a tab of the Ryzen loads on Mac B, and its page updates as Claude writes it.
  - **An unlisted caller.** A tailnet node that is neither listed nor paired gets nothing on that port.
  - **A port not in use.** A port Mac A's tabs don't use is closed on its tailnet address.
  - **Closing.** Closing the web pane on Mac A closes its port within a few seconds.
  - **A server started after its pane,** bound to every address (Node's default), on the Ryzen: it starts, and loads on Mac B once it answers.
  - **A server already on every address, on Mac A:** the proxy leaves its port alone, the pane on Mac B says why, and the server's own traffic is untouched.
  - **The page server stopped** on Mac A: the pane on Mac B says so.
- **By hand, what the spike couldn't reach:**
  - **A Mac with the Tailscale app,** the sandboxed build (the Air may run it): `tailscale cert` as the user, with `TERM` set, where its sandbox lets it write the files, and a bind on its tailnet address.
  - **Chrome on the phone:** the app in the tab view's frame, and hot reload over `wss` there and opened alone. A Mac's WebKit did both.
  - **A Mac with the firewall on:** whether macOS asks about the page server's Bun when a listener opens.
  - **`tailscale serve` set later on a port the proxy holds:** what serve does then, and that the proxy gives the port up at its next look, the pane saying why.

## Out of Scope

- Sharing a browser's logged-in state between machines (decision 4: pixel streaming, kept for later if ever needed).
- Proxying any port that no open tab names, or a page outside the tailnet.
- Ports of web panes on an outside address: they load straight from wherever they are.
- Requests between two ports of a host, if open question 4 goes as recommended.

## Further Notes

- **Decided by the user, 2026-10-12, and not reopened here** (problem.md has the reasons): routing by port; one listener per host on its tailnet address; `tailscale cert`; and the rejection of routing by path prefix, routing by subdomain, one `tailscale serve` per pane and pixel streaming.
- **A correction to the decision's wording:** "the relay on a Mac" doesn't run between requests (verified: each request is one process that exits after its reply). The Phone page server is the process that does, on both kinds of host.
- **An ADR once accepted:** "Remote web and app panes go through a port proxy in each host's Phone page server". It amends ADR 0011 (one door) and ADR 0007 (no listening port).
- **CONTEXT.md:** **Phone page**, since the server now also proxies, and perhaps a term for the proxy.
- **where-it-breaks:** a Port proxy section for:
  - the admission rule, and why `same-site` isn't enough here;
  - the rewrites, Host above all;
  - the certificate's renewal, by serving again, since Bun's reload keeps the old one;
  - the listeners following the tabs and their servers, and how a bind behaves on Linux and on a Mac;
  - never a serve port (8444 always), never below 1024, never every address;
  - Vite's fallback socket, which goes to the viewer's own 127.0.0.1;
  - every proxied app being same-site with the page, so the page keeps to same-origin checks and sets no cookies.
- **Considered and not proposed:**
  - **SSH port forwarding from each Mac.** Macs already reach their peers over SSH, but the phone has no SSH, so the phone would need the proxy anyway, and there would be two ways.
  - **The proxy inside Varnick on a Mac.** The headless host has no Varnick, and the page server outlives a restart of Varnick.
- **Verified in the code at 0d1d161:**
  - apps listen on 127.0.0.1 at their `PORT`, and their pane loads `http://127.0.0.1:<port>/`;
  - Scratch is a Vite dev server on 127.0.0.1 (6.4.3 in its lock);
  - the page server runs in zmx on a Mac and as a systemd unit on the headless host;
  - it knows the host's tailnet name, runs whois and maps listed peers' addresses to nodes;
  - the relay is one process per request.
- **Verified in the code at 1e6c606:**
  - a host lists only its Claude panes to other machines;
  - the relay reads nothing of the page server's;
  - the page sets no cookies, and its own check on `/api` lets only `same-origin` through;
  - the headless host's installer runs as the user, and only says how to turn linger on.
- **Also found by the spike:** relative and absolute asset paths both load, since the app sits at its origin's root; the tailnet IPv6 address binds and answers too.
- **Inferred, not tested:**
  - that cookies ignore ports (the cookie standard);
  - that webpack's and Next's checks pass with Host and Origin rewritten (their documentation);
  - that a server bound to every address answers on the tailnet address today.
- **Decided by the user (2026-10-12),** when accepting this option, each the recommendation:
  1. **The proxy runs in the Phone page server** on both kinds of host.
  2. **Only the ports the host's open tabs name** are proxied.
  3. **Listed devices and paired machines** may connect.
- **Open question, from the spike,** with a recommendation:
  4. **Requests between two ports of a host.** On localhost a page on one port can fetch from another, since Vite's default CORS allows any localhost origin. Through the proxy that fails twice: the browser calls the request `same-site`, which the fetch-metadata rule refuses, and the Origin is the proxied address, for which the other port's Vite sends no `Access-Control-Allow-Origin`.
     - **Recommended: say it breaks,** in the custom-apps skill and in where-it-breaks. A page that needs a second server reaches it through its own dev server's proxy (Vite's `server.proxy`), which keeps it same-origin, so it works from afar unchanged.
     - **Rejected: the proxy rewrites between the host's ports.** An Origin that is another of this host's proxied addresses would go in as that port's localhost origin, an `Access-Control-Allow-Origin` naming a localhost port would come back as its proxied address, and the fetch-metadata rule would let `same-site` through when its Origin is one of them. It fixes only pages that build the other port's address from their own host name: one that writes `localhost:5198` breaks from afar anyway. Images and stylesheets from the other port carry no Origin, so they stay refused. And it widens the rule the spike just tightened, so every open app could call every other with the phone's or another Mac's identity.
- **Departures found while building (2026-10-12), for the user to confirm:**
  - **The page server asks `tabs` and `hosts` as the host's own id,** which the relay now answers for those two requests and no others, treating it as a device. The proxy has no device or paired Mac of its own to ask as; an anonymous request was the other way and was not taken.
  - **The status file is keyed by pane,** so the relay never works out which port a pane names: the page server does, once. The saved tabs' date (`VARNICK_PROXY_TABS`) says whether the relay need be asked at all, which keeps an idle host near free.
  - **A headless host cannot split a page or an app from afar,** and the request is refused with that reason: its tabs hold Claude sessions and terminals, and it has no browser or custom apps. It lists no web or app pane, so its proxy is idle. Splits of a Mac host's tab can add a page (its address typed in the split picker) or one of that Mac's custom apps (listed by a new `apps` request).
  - **The operator is checked at the first look, not when a port is first wanted,** so Settings shows the command before any pane; the installer warns about a headless host as it does for linger.
  - **The certificate is asked for at the first look and then hourly while no port is wanted** (each minute while one is, a day after a success), where the spec asks for it daily with a minimum validity.
  - **A caller who is removed (a device unlisted, a Mac unpaired) loses its open websockets and streamed responses** at the next look, not only its next request.
  - **Every port closes after a minute of the relay failing,** so a pane closed meanwhile can't keep its port open for good.
  - **A socket may have 8 MB waiting to go to the server,** and is closed past that.
  - **A viewer finds the proxied address's name from `tailscale status`,** by the peer's saved address, rather than trusting the listing or building it from the `ssh` address.
