---
problem: work-cant-be-shared-with-other-people
title: A live public link for a Scratch, served from the Mac through a relay Worker on the user's own Cloudflare account
summary: Accepted by James on 2026-11-08, with links on first-level subdomains of varnick.com. A Share button in a Scratch pane's bar, after a confirm that lists every file viewers will be able to read, makes a link like https://<26 random characters>.varnick.com/ that serves the running page, hot reloads included. Each link has its own origin, same-site with varnick.com, and an expiry (a day by default, a week at most). It can be stopped from the pane or the status menu, and shows a viewer count while live. Viewers reach the link relay, a Worker beside the site's with one Durable Object per link, on a wildcard route. The deploy setup declares that route with the zone's DNS records and checks the zone before and after every apply, so the route can't take the apex, www or any later host. Varnick's connector on the Mac keeps an outbound websocket to the link's object and carries viewers' requests to Scratch's own public front. The front is a second local listener that serves GET, HEAD and Vite's hot-reload socket for the page's own files and packages only, with the Mac's folder paths and source maps taken out. No inbound port, no tailnet name in public, no new binary, and nothing that needs a paid plan. Behind a Public links switch in Settings › Experimental. A spike first (about 2 to 2.5 hours of agent time and 45 minutes of the user's), then about 20 to 23 hours of agent building.
status: accepted
---

## Solution

### The parts

1. **Scratch's public front.** Scratch opens a second listener on 127.0.0.1 at a port Varnick gives it. It serves what the world may see of the page and nothing else. Only Varnick's installed copy of a catalog app whose manifest offers public links gets that port, and today only Scratch's manifest does.
2. **The connector,** Varnick's own, written in Bun. It holds one outbound websocket per live link to the link relay and carries each viewer's requests and hot-reload socket to the app's public front. It runs in zmx, as the Phone page server does, so a restart of Varnick doesn't drop the links.
3. **The link relay.** A Cloudflare Worker beside varnick.com's site Worker, with one Durable Object per link, deployed through the repository's deploy setup. It is called the link relay here because "relay" already names Varnick's peer relay (CONTEXT.md). It holds:
   - the links themselves;
   - Varnick's control calls: create, list and stop;
   - the connector's websocket;
   - the edge limits;
   - the "not a link", offline and stopped pages;
   - the viewer count.
4. **The zone, declared.** The deploy setup declares varnick.com's DNS records: the apex and www as they are, the wildcard, and the link relay's own name. It checks the live zone before and after each apply, so the wildcard route serves no host but a link.
5. **Varnick's side:** the switch and the link relay's settings, the Share button, the confirm, the indicator and the lifecycle.

### Sharing

- **The button.** While the switch is on, a Scratch pane's address bar gets a Share button beside Reload. It appears only on the Mac that runs the app, never on another machine's tab shown here.
  - **A pane started before the switch was on** says "Restart Scratch to share it", with a Restart button, because its server was started without the public port. Restart ends the app's server and starts it again with both ports. Reload alone wouldn't do: it reloads the page, and restarts the server only after the server has exited.
- **Only the user shares.** No tool of a Claude session, no `!` command and no request from a paired Mac or the phone creates, lists or stops a link.
  - A Scratch pane that a session opened with `pane_open`, or that the phone added to this Mac's tab, is shared like any other: by the user's click here.
  - The tab listing that paired Macs and the phone read carries nothing of a link, so the peer protocol doesn't change.
- **The confirm,** in the pane, before anything is created:
  - **The files.** Every file in the Scratch's area that viewers will be able to read, with sizes and a total. Data files come first and are flagged: JSON, CSV, TSV, SQLite, spreadsheets, text, anything over 256 KB, and any name with `secret`, `token`, `key` or `env` in it. Dotfiles are listed apart as never served.
  - **What it says:** "Anyone with the link can read these files, the page's source included, and every file Claude adds here while the link is live, until it expires or you stop it. Viewers can't change anything."
  - **The expiry:** 1 hour, 1 day (the default) or 1 week.
  - Share.
- **Then** the link is copied to the clipboard and shown in the bar.
- **The indicator while live:**
  - in the pane's bar, a Live badge with the number watching, Copy link and Stop;
  - in the tab strip, a mark on the tab;
  - in the status menu, a line per live link, "Public: <tab name> · 2 watching", whose action is Stop.
- **Stopping, by any of:**
  - Stop in the bar or the status menu;
  - closing the pane (by the user, or by `pane_close` for a pane a session opened), closing the tab, or Done;
  - the expiry;
  - turning the switch off.

  A stopped link is dead for good. Sharing again makes a new one.
- **Kept across interruptions.** A link outlives Mac sleep, a restart of Varnick and a reload of the pane: the same link comes back when the Mac does.

### The link

- **Its shape.** `https://<id>.varnick.com/`. The id is 128 random bits written as 26 lowercase base32 characters (`a` to `z` and `2` to `7`), a DNS label of exactly that shape. The link relay answers every other name below varnick.com that reaches it with its own "not a link" page (404). So a host it was never meant to serve shows that page, never a link's offline page.
- **Unlisted, not private.** It can't be guessed, and anyone who has it can watch.
  - **Who else sees it.** The hostname crosses the network in DNS lookups and in TLS's server name, so a network between a viewer and Cloudflare can see it (inferred). The path and everything after it stay inside TLS.
  - **Not in certificate logs.** The zone's certificate covers every first-level name through its wildcard (verified on 2026-11-08: the certificate served for www names `varnick.com` and `*.varnick.com`). Links never get a certificate of their own, so no link's name is ever logged publicly.
- **Its own origin, same-site with varnick.com.** Each link is its own subdomain, so one link's page can't read another link's storage or varnick.com's. But varnick.com isn't a public suffix, so browsers treat every link, the site and the link relay's own name as one site. "Same site with varnick.com" below says what follows from that.
- **Routing.**
  - One proxied wildcard DNS record and one Worker route, `*.varnick.com/*`, cover every link.
  - The route doesn't match the apex. Where a more specific route names a host, that route wins (Cloudflare's documented rule, as known to the planner; the deploy proof checks it). So the site's `varnick.com/*` and `www.varnick.com/*` routes keep the apex and www.
- **Its headers.** The link relay adds:
  - `X-Robots-Tag: noindex, nofollow`, `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`;
  - `Origin-Agent-Cluster: ?1`.

  It also answers `/robots.txt` itself with "disallow everything", drops every `Set-Cookie` the Mac sends, sets no cookie of its own, and redirects plain http to https.

### Same site with varnick.com

On 2026-11-08 James chose first-level subdomains of varnick.com over a zone of the links' own, knowing that links are then same-site with varnick.com. What follows, and what the link relay and the site are held to:

- **Cookies.** A link's page can use script to set a cookie for the whole of varnick.com. Every link, the site and the link relay's name then receive it.
  - The link relay drops viewers' `Cookie` headers on the way to the Mac and every `Set-Cookie` on the way back, but it can't stop a page's script.
  - **So nothing on varnick.com reads a cookie.** The site sets none today and must not start. The link relay's control calls take the key in a header, never in a cookie.
  - A cookie that varnick.com ever needs is a `__Host-` cookie, which no subdomain can set or overwrite.
- **Cookie flooding.** A link's page could set so many cookies on varnick.com that a viewer's browser sends requests too large for Cloudflare. That browser then can't load varnick.com or any link until its cookies are cleared. Accepted: the pages are the user's own, and the only third-party code in them is the packages the user's Scratch installs.
- **Same-site requests.** A request from a link's page to varnick.com, another link or the link relay's name carries `Sec-Fetch-Site: same-site`, and SameSite cookie rules don't stop it.
  - Nothing on varnick.com treats `same-site` as trusted, as the port proxy doesn't (ADR 0035).
  - The link relay's control calls answer without CORS headers, so a page can send one but never read the answer. Without the key, every call is refused.
- **`document.domain` and processes.** `Origin-Agent-Cluster: ?1` keeps any link's page from relaxing its origin to varnick.com. A browser may put a site's pages in one process, so a link and the site may share one. Nothing secret is on the site's pages.
- **Reputation.** If a safe-browsing list flags a link, the warning can spread to varnick.com itself, the page users download Varnick from. Links are unlisted, marked noindex and live a week at most, which keeps that unlikely. It is the cost James accepted.
- **Later, for every Varnick user.** A link relay for every user would need a links domain on the Public Suffix List, and varnick.com can't be one. Such a relay would use another domain, and the links made here would stay where they are.

### Hosts the link relay must never take

- **Today** (read from Cloudflare's API, read-only, on 2026-11-08):
  - the zone has two DNS records, the apex and www, both proxied to Cloudflare's discard address;
  - it has two routes, both to the site's Worker;
  - no custom domains, no mail records, and no other Worker on the zone.

  So nothing on varnick.com would be shadowed today. The zone is on Cloudflare's Free plan.
- **The rule:**
  - every proxied name in the zone other than the wildcard has a route or custom domain of its own, more specific than the wildcard;
  - no route but the link relay's is a wildcard;
  - no name in the zone has the link id's shape.

  Routes and DNS records change only through the deploy setup, never by hand. On 2026-06-26, a wildcard route added by hand on another zone of the account took over a live subdomain, and nothing had declared that route.
- **The reserved names** are the names the zone file declares: today the apex, www, and the link relay's own name, `links`. A name added later is declared there, with a route of its own, before anything serves it.
- **The checks:**
  - **Offline, in the repository's checks (a `make check-` target).** It reads the zone's declared records and every Worker's routes, and checks that the rule holds and that the link relay's routes are exactly the wildcard and its own name.
  - **Before every apply of the zone or the link relay, in the deploy setup.** A guard instance runs first, because the link relay's instance depends on it, and stops the apply when it fails. It reads the live zone's records, routes and custom domains, read-only, and fails on anything the files don't declare, naming it. A record or route added by hand therefore fails the apply.
  - **After the link relay's apply: its deploy proof, which fails the apply.**
    - The apex and www answer with the site's page, byte for byte.
    - A made-up name answers with the link relay's "not a link" page.
    - The link relay's own name answers.
    - If the apex or www fails, the apply says so and says how to take the wildcard route off at once: apply the link relay with links off, which drops that route.

### What viewers see when the Mac isn't there

- **The Mac asleep, offline or between restarts, or the app's server down.** A page load gets the link relay's own short page: "This page is served live from its author's Mac, which isn't reachable right now. It will come back by itself." It retries every 10 seconds. Module requests get 503.
- **A page already open.** Vite's client loses its socket, polls, and reloads once the link answers again (inferred from Vite's client; checked in the spike).
- **Stopped or expired.** 410 with "This link was stopped" or "This link expired". Before closing the viewers' sockets, the link relay sends each one Vite's own "full reload" message, so open pages land on that page instead of keeping the last picture.
  - **What stays with viewers.** Copies they saved themselves.

### What viewers can reach (Scratch's public front)

- **Methods.** GET and HEAD, and a websocket upgrade only for Vite's hot-reload and ping sockets. Anything else is 405.
- **Paths:**
  - the page's own files in its area;
  - Vite's own module paths (its client, the React refresh runtime, its virtual ids and the optimized dependencies);
  - `/@fs/` only inside the area, the scratch root's packages and Vite's client folder.

  Everything else is 404: other panes' areas, the project, the home folder, the app's own folder.
- **Never served:**
  - dotfiles, `.env*` and `.vite.log` included;
  - source maps: `.map` requests are refused, and inline `sourceMappingURL` trailers and source-map headers are stripped.
- **The Mac's paths are hidden.** In every text response and every hot-reload message, the real paths of the scratch root, the app's folder and the home folder are replaced with neutral prefixes, and mapped back on requests. Error overlays, module addresses and the placeholder then name no account or project.
- **The hot-reload socket.** It passes Vite's messages to viewers. From viewers it passes only Vite's ping and invalidate messages, each capped in size and rate. Anything else is dropped.
- **Host and Origin** are rewritten to the local server's, as the port proxy does (ADR 0035), so Vite's host check and its hot-reload token work unchanged. Vite's client takes its socket's host, port and protocol from the page's address by default, so `wss://<link>/` on 443 needs no `hmr` settings (inferred; checked in the spike).
- **For every use, not only public:**
  - **Narrowed reach.** Scratch's Vite gets `fs.strict` and an allow list of its own area, the packages and Vite's client. This is option 01's narrowing, built here if option 01 isn't.
  - **A Vite floor.** The public front refuses to start under a minimum patched Vite version, read from the installed package, and the pane says why. Vite has had dev-server file-read bugs. The catalog's committed lockfile pins Vite (still 6.4.3 at fbbfc6a), and Varnick's installed copy installs frozen to it.

## Trade-offs

- **Live, as asked.** Viewers see each change Claude makes, through Vite's own hot reload.
- **Nothing listens on the Mac.** The connector dials out, so no port opens, no tailnet name goes public and Funnel stays off (ADR 0011).
- **The edge is ours.** Per-link origins, expiry, stop, rate limits, the offline page and the viewer count are code in this repository, not a third party's switches.
- **We write a small tunnel protocol.** Requests, responses in chunks and websockets are framed over one socket, on both ends, in TypeScript. That is the main cost.
- **Cloudflare sees the traffic in the clear.** TLS ends at Cloudflare, on the user's own account. That is acceptable for a page meant to be public. It is not acceptable for tab sharing, which is why option 01 stays on the tailnet.
- **Dev mode is chatty.** A dev page loads its modules one by one, so a first load is tens to a couple of hundred requests, each a round trip to the Mac. Expect a slower first load than localhost. The spike measures it.
- **The page's source is public by design:** everything in the area, and every file added while the link is live. The confirm lists it, and since a long-lived link would multiply the exposure, the longest expiry is a week.
- **The page can't reach a third-party server through the link.** The public front proxies nothing. A page that reads from another local server works on the Mac and not for viewers.
- **Same-site with varnick.com,** James's choice. It binds the site and the link relay to the rules in "Same site with varnick.com", and a flagged link can reach the site's reputation. A zone of the links' own would have avoided both.
- **The zone becomes declared state.** The deploy setup takes on varnick.com's DNS records, and checks the zone on every apply. A host added by hand now fails the next apply instead of being silently taken.
- **Cost: nothing here needs a paid plan.** Inferred from Cloudflare's published plans, as known to the planner; the spike reads the real usage.
  - **The zone is on the Free plan (verified).** A proxied wildcard record, a wildcard Worker route, the first-level wildcard certificate (verified: it is served now) and websockets all work on it.
  - **Durable Objects are on Workers Free** when they use SQLite storage, which the link relay's class does.
  - **The account is most likely on Workers Paid already.** It runs a Worker of a kind only Workers Paid allows (inferred from its Durable Object namespaces; the deploy credential can't read billing).
    - The link relay's requests then count against that plan's monthly allowance, which the account's other Workers share. A few hundred viewer loads a day stay well inside it.
    - Usage beyond the allowance is billed on that plan, and spending it is James's call. The link relay's usage shows on its own in the dashboard.
  - **On Workers Free, two limits would bite:** 100,000 requests a day (a first load counts once at the Worker and once at the object per module) and 10 ms of CPU per request. The spike measures both.
  - **Hibernation keeps idle links cheap.** The connector's keepalive and viewers' pings get the object's automatic replies, which don't wake it, so an idle link costs no duration.

## User Stories

1. As the user, I want to press one button in a Scratch pane and get a public link, so that I can send a live prototype to anyone.
2. As the user, I want to see exactly which files will be readable, data files first, before the link exists.
3. As the user, I want the link to expire by itself, and to choose how soon.
4. As the user, I want to see that a link is live, and how many are watching, in the pane and in the status menu.
5. As the user, I want to stop a link at once, and have open pages leave the content when I do.
6. As the user, I want closing the pane or the tab to stop its link.
7. As a viewer, I want the page to update as the author works.
8. As a viewer, I want a clear page, not a browser error, when the author's Mac is asleep, and the page back by itself when it wakes.
9. As the user, I want my account name, home folder and project names kept out of what viewers receive.
10. As the user, I want the link relay on my own Cloudflare account, with its key in my Keychain and nowhere else.
11. As the user with Public links off, I want no link relay connection, no connector, no public port and no button.
12. As the user, I want varnick.com and every host I add to it later never taken by a link, and a deploy that refuses when the zone holds something nobody declared.
13. As the user, I want only my own click to make a link, never a Claude session's tool or another device.

## Implementation Decisions

### The switch and the link relay's settings

- **Settings › Experimental › Public links,** off by default.
  - It joins Problems board, Outline, Tasks and Answer with Varnick's own steps there.
  - Its row's text is at most three sentences and points to its section of the privacy document (CODING_STANDARDS).
- **While on,** it shows two rows under it, the way Answer with Varnick's own steps shows its own:
  - **the link relay's address,** in UserDefaults and empty by default. This repository's link relay answers at `https://links.varnick.com`;
  - **the link relay's key,** in the Keychain under Varnick's service name, as API keys are. The row shows whether a key is saved, read with `Keychain.exists` as the ElevenLabs key's row is. The key is never echoed, never logged, and never put on a command line or in an environment.
- **Off:**
  - no Share button, badge or menu line;
  - no public port given to apps started from then on;
  - no connector (ended if running);
  - no call to the link relay.

  Turning the switch off first stops every live link, one call each. A link that can't be stopped then goes offline, since its connector is gone, until its expiry.
- **At a launch with the switch off,** Varnick ends any connector left in zmx and makes no call.

### Credentials

- **The link relay's key** lets its holder create, list and stop links on the user's link relay, and nothing else. The Worker keeps only a hash of it, as a Worker secret.
- **A connect token per link,** issued by the link relay with the link. It is good only for that link's connector socket, until the link stops or expires.
  - Varnick writes it into the connector's owner-only file of live links, beside the link's id, port and expiry. This is the way the Phone page server is handed its push key (`OwnerOnlyFile`).
  - The link relay's key never reaches the connector.
- **Cloudflare's own credentials never touch Varnick.**
  - The link relay and the zone are deployed through the repository's deploy setup, as the site's Worker is. Their secrets are kept there, encrypted, never committed in clear.
  - Declaring the zone's records needs DNS write access on the zone, which the site's deploy never needed. The zone's first apply shows whether the deploy credential has it. If it doesn't, widening the credential is the maintainers' step and is not described here.

### The link relay

- **A second Worker beside the site's,** deployed through the same setup, with two routes:
  - `*.varnick.com/*` for links;
  - `links.varnick.com/*` for Varnick's control calls and the connector's socket.

  It answers control and connect calls only on its own name, and serves links only on a name of the link id's shape.
- **The zone, declared.** The deploy setup gains zbc's zone module and declares varnick.com's records, all proxied to the discard address:
  - the apex and www exactly as they are, so the first apply changes nothing of them;
  - the wildcard `*`;
  - `links`.

  The module reports any record the file doesn't declare, and deletes nothing unless told to.
- **The guard and the proof:** as in "Hosts the link relay must never take".
- **One Durable Object per link,** named by the link's id, with SQLite storage. The connector's socket creates it first, so it lives near the Mac (inferred).
- **What the object holds:** the expiry, the stop, the connector socket and the viewers' sockets.
  - It uses Cloudflare's hibernating websockets.
  - Keepalive pings on either side get the object's automatic replies, which don't wake it.
- **Limits at the edge:**
  - GET, HEAD and websocket upgrades only;
  - no request bodies;
  - a few headers forwarded from an allow list, and never viewers' cookies or authorization;
  - per link, about 1,200 requests a minute and 50 viewer sockets;
  - per address, a lower request rate, counted in the object, with no paid Cloudflare product.
- **The viewer count** is the number of open hot-reload sockets (one per open page), sent to the connector when it changes.

### The connector

- **Started by Varnick in zmx** under a fixed name while any link is live, the way `PhonePageRunner` runs the Phone page server:
  - attached on a pty and then detached, never `zmx run`;
  - left alone by the launch sweep, by Quit and by Keep sessions running.

  It stops when no link is live.
- **What it reads.** Its file of live links, every few seconds. It reconciles its sockets with the file, with backoff on reconnects.
- **What it writes.** A status file per link (connecting, live, offline and why, viewers, expiry), as the port proxy writes its own. The bar and the menu read it.
- **Its forwards to 127.0.0.1 stay off any HTTP proxy in its environment,** as the port proxy's do. Bun reads the proxy variables once, when it starts.
- **Generic limits, whatever the app:**
  - request heads at most 16 KB;
  - responses at most 16 MB, in chunks;
  - at most 32 requests in flight per link;
  - viewers' socket messages small and rate-capped.
- **Its log** holds the method, a class of path, the status and the time, never a body or a full path.

### The app's side

- **The manifest.** An optional `public` entry says, in a line, what viewers can read. It names the folder the confirm lists, built from the two values Varnick already gives the app: the project and the pane it was split from.
  - The entry counts only in Varnick's installed copy of a catalog app (`AppCatalog.isInstalledCopy`), whose rules are reviewed with the catalog.
  - A project's own app, or a renamed copy, gets no public port even with the entry.
  - `make check-apps` checks the entry's shape.
- **The port.** Varnick gives such an app a second port, `PUBLIC_PORT`. It is saved with the pane as `appPort` is, in a new optional field of the pane's record, and picked and kept the same way (`settlePort`), so it stays stable across reconnects. The port proxy never opens it, since the proxy serves only a pane's own port (ADR 0035).
- **The rules are the app's.** Only the app knows its server, so the rules in "What viewers can reach" are Scratch's own code, reviewed with the catalog. Varnick's connector adds only the generic limits.
- **Documented in one place.** The `custom-apps` skill documents the entry and the port.

### The lifecycle

- **Create.** Share → the confirm → Varnick asks the link relay for a link (with the key and the expiry) → it writes the live link for the connector → it starts the connector if needed → it shows the link.
- **Stop.** Varnick tells the link relay, then removes the link from the file. A stop that can't reach the link relay is tried again at the next launch while the switch is on.
- **The pane's server exiting** leaves the link offline, not stopped. Closing the pane stops it.
- **Restart Scratch** (a pane started before the switch) ends the app's zmx session, confirms it is gone as a Claude pane's Restart does, and starts the app again with both ports.

### The spike (first ticket)

It answers whether a live dev page works, and is fast and cheap enough, through a link relay, before anything is built. It touches neither varnick.com's zone nor Varnick's code.

- **Where its code lives.** In the problem's scratch folder, which is gitignored: it is never committed and never on a branch. It has four throwaway pieces:
  - **a link relay:** one Worker with one SQLite Durable Object, serving a single link at the Worker's own workers.dev address, with a connect secret made for the spike, and no control calls, limits or pages;
  - **a connector:** a Bun script that dials the object's socket and carries requests, responses in chunks and websockets to a local port;
  - **a public front:** a Bun script in front of a running Scratch pane's Vite, with the path rules, the refusal of dotfiles and source maps, and the path rewrite;
  - **a sample page** in a Scratch area: React and one chart package. It includes a stamp module that each save rewrites, and the page shows its own load timings, its request count and how long ago each stamp was written.
- **How it is deployed.**
  - On the account's workers.dev subdomain, under a throwaway Worker name, with no route and no DNS record. So it can't reach any host of varnick.com or of another zone.
  - Before the deploy, the account's Worker names are listed, and the throwaway name must not be among them, because a deploy under an existing name would replace that Worker.
  - The deploy credential is read into the pane's environment only, never into a file or a log.
  - At the end, the Worker is deleted and its deletion is checked.
- **Where it runs.** In a terminal pane of Varnick, with the commands typed by the user. Never from a Claude session's own process: XProtect once killed a Claude process that ran installs and a downloaded binary (ADR 0013). The agent writes the scripts, plus one command per step for the user. The agent then reads the pane and the result files, and the user reads the figures off the sample page.
- **What is timed,** each three times, keeping the median:
  1. **a first load** with the browser's cache empty, up to the page's load event, with the count of requests. Measured three ways: the Mac's browser at localhost (the baseline), the Mac's browser through the link relay, and a phone on mobile data through the link relay;
  2. **a reload** with the cache warm, the same three ways;
  3. **an update:** from a save to the change shown, ten saves. Timed on the Mac's browser through the link relay (one clock for both ends), and by eye on the phone;
  4. **a return:** the connector stopped for 30 seconds, then started again. How long an open page takes to come back by itself, and what a new load gets in the meantime;
  5. **usage,** after a fixed run of ten first loads, twenty updates and one idle hour with one page open: the Worker's and the object's requests, the object's duration, and the CPU time per request, from the account's dashboard.
- **Also checked:**
  - hot reload with no `hmr` settings (Vite's token, `wss` on 443, the default host and port);
  - the known `/@fs/` bypass patterns against the public front: encoded and doubled slashes, backslashes, encoded `..`, and `?raw`, `?import`, `?url` and `?inline` with their doubled forms;
  - every response the desktop viewer received (saved as a HAR), searched for the home folder, the account name and the project name.
- **Pass, each:**
  - an edit reaches both viewers without a reload, either with no `hmr` settings or with one setting the public front can carry;
  - a first load on the phone on mobile data, cold, takes 5 s or less. From 5 to 15 s it passes, with the figure sent to James. Over 15 s it fails;
  - an update takes 1 s or less on the Mac through the link relay;
  - an open page comes back by itself within 30 s of the connector's return;
  - no bypass pattern reads a file outside the allowed set, and no response names the home folder, the account or the project;
  - an idle hour costs close to no duration, CPU per request stays under 10 ms, and the requests per first load leave room for a few hundred loads a day inside Workers Free's daily allowance.
- **A fail** stops the work before the next ticket. The figures go to James, with what would have to change.
- **Recorded:** the verdicts and the timings in this option's Further Notes. The throwaway addresses, the Worker's name and anything about the account go only in the problem's scratch folder.
- **Size:** about 2 to 2.5 hours of agent time (the four pieces, the steps and the write-up) and about 45 minutes of the user's (the deploy, the runs, the phone on mobile data, the deletion).

### Recorded

- **A new ADR,** with the first build ticket. It covers:
  - the first public surface;
  - the link relay on varnick.com beside the site;
  - same-site links, and what the site and the link relay are held to;
  - the zone declared in the deploy setup, with its guard and its proof;
  - the app's public port.
- **CONTEXT.md** gains **Public link** and **Link relay**, the second kept apart from Varnick's peer relay.
- **`docs/privacy-and-security.md`** gains a section.
- **`docs/agents/where-it-breaks.md`** gains Public links: the connector, the public port, the zone's rule.
- **The site's deploy notes** say that the zone is now declared, and how to add a host.

## Testing Decisions

- **`bun test` on the public front's rules,** as pure functions:
  - methods;
  - every path class, allowed and refused, including encoded and doubled slashes and Vite's `?raw`, `?import` and `?url` queries on `/@fs/`;
  - dotfiles;
  - the path rewrite both ways;
  - source-map stripping;
  - the socket's message filter.
- **`bun test` on the connector's framing:** chunked responses, websockets, the caps, a reconnect, and forwards that ignore a proxy set in the environment.
- **The Worker's own tests:**
  - expiry and stop;
  - the 410 page and the reload message to open sockets;
  - limits;
  - a name that isn't a link's shape gets "not a link", and control and connect calls answer only on the link relay's own name;
  - `Cookie` never reaches the connector, and `Set-Cookie` never reaches a viewer;
  - `Origin-Agent-Cluster` and the other headers on every answer, and plain http redirected to https;
  - the control calls refused without the key, with no CORS headers.
- **The deploy check's own tests,** offline:
  - today's files pass;
  - each of these fails: a declared proxied name with no route of its own, a name of the link id's shape, a second wildcard route, and a link relay route beyond its two;
  - the guard fails against a recorded listing of a zone that holds an undeclared record, route or custom domain.
- **By hand, after the first apply of the zone and the link relay:** the proof's three checks pass, and the zone module reports no undeclared record.
- **By hand, after a restart, with a phone on mobile data as the viewer:**
  - share, watch an edit arrive, sleep the Mac and wake it, stop, let one link expire;
  - read the page's source and network panel in a desktop browser for any home path or project name;
  - restart a Scratch pane that was started before the switch, and share it;
  - turn the switch off and see that no connector runs and nothing of it shows.

## Out of Scope

- A link relay hosted for every Varnick user, and links for other apps or for web panes (problem › Later).
- A links domain of the links' own (James chose varnick.com).
- Password-protected links.
- Choosing which files are public: the whole area is, live.
- A static copy (option 07, rejected).
- Any change to the site's page.

## Further Notes

- **Accepted by James on 2026-11-08,** over options 05 (Funnel), 06 (cloudflared) and 07 (a static copy), which are rejected for that reason.
- **The links domain** is first-level subdomains of varnick.com, `https://<id>.varnick.com/`, chosen by James on 2026-11-08 over a zone of the links' own, knowing that links are same-site with varnick.com. "Same site with varnick.com" and "Hosts the link relay must never take" record the consequences, and what this spec does about them.
- **Checked against main at fbbfc6a (2026-11-08). What moved since the option was written, and what changed here:**
  - **Scratch's server and its pinned Vite 6.4.3:** unchanged since the option was written.
  - **Settings › Experimental** now holds Problems board, Outline, Tasks, and Answer with Varnick's own steps (with rows of its own while on). Automations and Panel access have left it, and a row's text is now at most three sentences. The switch's rows follow both.
  - **A session can open a Scratch pane with `pane_open`, and the phone can add one to a Mac's tab.** Hence "Only the user shares".
  - **The port proxy keeps its forwards off an HTTP proxy in the environment** (2026-10-14). The connector does the same.
  - **The Phone page server is now handed a push key in an owner-only file.** The connector's tokens are handed over the same way.
  - **The peer protocol is at 35.** This option changes none of it.
  - **The site and the deploy setup** are unchanged since the option was written. The zone was read live (above).
  - **Corrected:** Reload doesn't restart a running app server, it reloads the page. So a pane started before the switch now offers Restart Scratch.
  - **Renamed:** "relay" became "link relay" throughout, to keep it apart from Varnick's peer relay.
  - **Narrowed:** a manifest's `public` entry now counts only in Varnick's installed copy of a catalog app.
- **Assumptions, each open to overturning:**
  - the link relay's own name is `links`;
  - its address is a setting, empty by default, rather than built in;
  - the cut-offs for the spike's pass and fail.
- **Unverified:**
  - that a more specific route wins over the wildcard on this zone. The deploy proof checks it on the first apply;
  - whether the deploy credential can write the zone's DNS;
  - the account's Workers plan;
  - everything the spike measures.
- **Slices.** The tickets come later, from `/to-tickets`:
  1. the spike;
  2. Scratch's public front, with its rules and its tests;
  3. the link relay, the declared zone, the offline check, the guard and the proof. Its first apply changes the live zone, so it waits for James's go;
  4. the connector and its runner;
  5. Varnick's side.

  Each slice's docs go with it, and the ADR goes with slice 2.
- **Size, in agent time:** about 20 to 23 hours of building after the spike, plus 3 to 4 hours of review and a fix round.
  - Scratch's public front: about 3.5 hours.
  - The link relay and its object: about 4.5 hours.
  - The zone and the checks in the deploy setup: about 2.5 hours.
  - The connector and its runner: about 3.5 hours.
  - Varnick's side: the switch and its rows, the manifest entry and the port, Share, the confirm and Restart, the indicator, and the lifecycle. About 5.5 hours.
  - Docs: about 1.5 hours.
  - On top, the user's time:
    - about 30 minutes for the first apply of the zone and the link relay, more if the deploy credential needs DNS write access;
    - then a restart, and a hand test of about an hour with a phone.
  - Wall clock: about three working days of agent time.
