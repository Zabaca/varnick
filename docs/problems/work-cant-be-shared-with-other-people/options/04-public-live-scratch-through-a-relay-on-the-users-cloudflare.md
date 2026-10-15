---
problem: work-cant-be-shared-with-other-people
title: A live public link for a Scratch, served from the Mac through a relay Worker on the user's own Cloudflare account
summary: A Share button in a Scratch pane's bar, after a confirm that lists every file viewers will be able to read, makes a link like https://<26 random characters>.<links domain>/ that serves the running page, hot reloads included. Each link has its own origin and an expiry (a day by default, a week at most). It can be stopped from the pane or the status menu, and shows a viewer count while live. Viewers reach a Cloudflare Worker with one Durable Object per link. Varnick's connector on the Mac keeps an outbound websocket to that object and carries their requests to Scratch's own public front: a second local listener that serves GET, HEAD and Vite's hot-reload socket for the page's own files and packages only, with the Mac's folder paths and source maps taken out. No inbound port, no tailnet name in public, no new binary. The relay is code in this repository that each user deploys to their own account, keyed from the Keychain. Behind a Public links switch in Settings › Experimental. Recommended for the public half. Rough effort is a spike of a day, then about eight days.
status: proposed
---

## Solution

### The parts

1. **Scratch's public front.** Scratch opens a second listener on 127.0.0.1 at a port Varnick gives it, which serves what the world may see of its page and nothing else. Only an app whose manifest offers public links gets that port, and only Scratch does.
2. **The connector,** Varnick's, in Bun. It holds one outbound websocket per live link to the relay and carries each viewer's requests and hot-reload socket to the app's public front. It runs in zmx, as the Phone page server does, so a restart of Varnick doesn't drop the links.
3. **The relay.** A Cloudflare Worker with one Durable Object per link, deployed by the user to their own account. It holds:
   - the links themselves;
   - Varnick's control calls: create, list and stop;
   - the connector's websocket;
   - the edge limits;
   - the offline and stopped pages;
   - the viewer count.
4. **Varnick's side:** the switch and the relay's settings, the Share button, the confirm, the indicator and the lifecycle.

### Sharing

- **The button.** A Scratch pane's address bar gets a Share button, beside Reload, while the switch is on. A pane started before the switch was on says "Reload this pane to share it", since its server was started without the public port.
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
  - closing the pane, closing the tab or Done;
  - the expiry;
  - turning the switch off.

  A stopped link is dead for good. Sharing again makes a new one.
- **Kept across interruptions.** A link outlives Mac sleep, a restart of Varnick and a reload of the pane: the same link comes back when the Mac does.

### The link

- **Its shape.** `https://<id>.<links domain>/`, where the id is 128 random bits written as 26 lowercase base32 characters (a DNS label).
- **Unlisted, not private.** It can't be guessed, and anyone who has it can watch.
  - **Who else sees it.** The hostname crosses the network in DNS lookups and in TLS's server name, so a network between a viewer and Cloudflare can see it (inferred). The path and everything after stay inside TLS.
- **Its own origin.** Each link is a subdomain of its own, so one link's page can't read another's storage, and none shares an origin with varnick.com.
  - **Certificates and routing.** A wildcard DNS record and one Worker route cover every link. Cloudflare's free certificate covers one level of wildcard on a zone (inferred).
- **Its headers.** The relay adds `X-Robots-Tag: noindex, nofollow`, `Referrer-Policy: no-referrer` and `X-Content-Type-Options: nosniff`, answers `/robots.txt` itself with "disallow everything", and sets no cookie.

### What viewers see when the Mac isn't there

- **The Mac asleep, offline or between restarts,** or the app's server down. A page load gets the relay's own short page: "This page is served live from its author's Mac, which isn't reachable right now. It will come back by itself." It retries every 10 seconds. Module requests get 503.
- **A page already open.** Vite's client loses its socket, polls, and reloads once the link answers again (inferred from Vite's client; checked in the spike).
- **Stopped or expired.** 410 with "This link was stopped" or "This link expired". Before closing the viewers' sockets, the relay sends each one Vite's own "full reload" message, so open pages land on that page instead of keeping the last picture.
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
  - source maps: `.map` requests, inline `sourceMappingURL` trailers and source-map headers are stripped.
- **The Mac's paths are hidden.** In every text response and every hot-reload message, the real paths of the scratch root, the app's folder and the home folder are replaced with neutral prefixes, and mapped back on requests. Error overlays, module addresses and the placeholder then name no account or project.
- **The hot-reload socket.** It passes Vite's messages to viewers. From viewers it passes only Vite's ping and invalidate messages, each capped in size and rate. Anything else is dropped.
- **Host and Origin** are rewritten to the local server's, as the port proxy does (ADR 0035), so Vite's host check and its hot-reload token work unchanged. Vite's client takes its socket's host, port and protocol from the page's address by default, so `wss://<link>/` on 443 needs no `hmr` settings (inferred; checked in the spike).
- **For every use, not only public:**
  - **Narrowed reach.** Scratch's Vite gets `fs.strict` and an allow list of its own area, the packages and Vite's client. This is option 01's narrowing, built here if option 01 isn't.
  - **A Vite floor.** The public front refuses to start under a minimum patched Vite version, read from the installed package, and the pane says why. Vite has had dev-server file-read bugs. The catalog's committed lockfile pins it (6.4.3 at this commit), and Varnick's installed copy installs frozen to it.

## Trade-offs

- **Live, as asked.** Viewers see each change Claude makes, through Vite's own hot reload.
- **Nothing listens on the Mac.** The connector dials out, so no port opens, no tailnet name goes public and Funnel stays off (ADR 0011).
- **The edge is ours.** Per-link origins, expiry, stop, rate limits, the offline page and the viewer count are code in this repository, not a third party's switches.
- **We write a small tunnel protocol.** Requests, responses in chunks and websockets are framed over one socket, on both ends, in TypeScript. That is the main cost, and what option 06's cloudflared would spare.
- **Cloudflare sees the traffic in clear.** TLS ends at Cloudflare, on the user's own account. For a page meant to be public that is acceptable. For tab sharing it is not, which is why option 01 stays on the tailnet.
- **Dev mode is chatty.** A dev page loads its modules one by one, so a first load is tens to a couple of hundred requests, each a round trip to the Mac. Expect a slower first load than localhost. The spike measures it.
- **The page's source is public by design.** Everything in the area and every file added while live. The confirm lists it, and a long-lived link would multiply the exposure, so the longest expiry is a week.
- **A third-party server can't be reached from the page.** The public front proxies nothing. A page that reads from another local server works on the Mac and not for viewers.
- **Cost (inferred, to be checked on the account).** The free Workers plan allows about 100,000 requests a day, and Durable Objects are on it now. A first load counts once at the Worker and once at the object per module, so a few hundred viewer loads a day fit. Beyond that the paid plan's base fee applies.

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
10. As the user, I want the relay on my own Cloudflare account, with its key in my Keychain and nowhere else.
11. As the user with Public links off, I want no relay connection, no connector, no public port and no button.

## Implementation Decisions

### The switch and the relay's settings

- **Settings › Experimental › Public links,** off by default.
- **While on,** it shows two settings under it:
  - **the relay's address,** UserDefaults;
  - **the relay key,** the Keychain under Varnick's service name, as API keys are. It is shown as saved or not, never echoed, never logged, never on a command line or in an environment.
- **Off:**
  - no Share button, badge or menu line;
  - no public port given to apps started from then on;
  - no connector (ended if running);
  - no call to the relay.

  Turning it off first stops every live link, one call each. A link that can't be stopped then goes offline, since its connector is gone, until its expiry.
- **At a launch with the switch off,** Varnick ends any connector left in zmx and makes no call.

### Credentials

- **The relay key** lets its holder create, list and stop links on the user's relay, and nothing else. The Worker keeps only a hash of it, as a Worker secret.
- **A connect token per link,** issued by the relay with the link. It is good only for that link's connector socket, until the link stops or expires. Varnick writes it into the connector's owner-only file of live links, beside the link's id, port and expiry. The relay key never reaches the connector.
- **Cloudflare's own credentials** never touch Varnick. The relay is deployed through the repository's existing deploy setup, as varnick.com's Worker is. Its secrets are set there and never committed.

### The relay

- **A second Worker beside the site's,** with its own routes:
  - the control and connect paths on the relay's address;
  - the wildcard of the links domain for links.
- **One Durable Object per link,** named by the link's id and first made by the connector's socket, so it lives near the Mac (inferred).
- **What the object holds:** the expiry, the stop, the connector socket and the viewers' sockets. It uses Cloudflare's hibernating websockets, so an idle link costs little.
- **Limits at the edge:**
  - GET, HEAD and websocket upgrades only;
  - no request bodies;
  - a few headers forwarded from an allow list, viewers' cookies and authorization never;
  - per link, about 1,200 requests a minute and 50 viewer sockets;
  - per address, a lower request rate.
- **The viewer count** is the number of open hot-reload sockets (one per open page), sent to the connector when it changes.

### The connector

- **Started by Varnick in zmx** under a fixed name while any link is live, through the same runner as the Phone page server. It stops when none is.
- **What it reads.** Its file of live links, every few seconds, reconciling its sockets with it, with backoff on reconnects.
- **What it writes.** A status file per link (connecting, live, offline and why, viewers, expiry), as the port proxy writes its own, which the bar and the menu read.
- **Generic limits, whatever the app:**
  - request heads at most 16 KB;
  - responses at most 16 MB, in chunks;
  - at most 32 requests in flight per link;
  - viewers' socket messages small and rate-capped.
- **Its log** holds the method, a class of path, the status and the time, never a body or a full path.

### The app's side

- **The manifest.** An optional `public` entry says, in a line, what viewers can read, and names the folder the confirm lists, from the two values Varnick already gives the app: the project and the pane it was split from. An app without the entry gets no public port and no button.
- **The port.** Varnick gives such an app a second port, `PUBLIC_PORT`, saved with the pane as its port is (a new optional field of the pane's record), so it is stable across reconnects.
- **The rules are the app's.** Only the app knows its server, so the rules in "What viewers can reach" are Scratch's own code, reviewed with the catalog. Varnick's connector adds only the generic limits.
- **Documented in one place.** The `custom-apps` skill documents the entry and the port.

### The lifecycle

- **Create.** Share → the confirm → Varnick asks the relay to create a link (the key, the expiry) → it writes the live link for the connector → it starts the connector if needed → it shows the link.
- **Stop.** Varnick tells the relay, then removes the link from the file. A stop that can't reach the relay is retried at the next launch while the switch is on.
- **The pane's server exiting** leaves the link offline, not stopped. Closing the pane stops it.

### The spike (first ticket)

Run in a pane, never from a Claude session's own process:
- deploy a throwaway relay on the user's account;
- serve a Scratch through it;
- check hot reload (Vite's token, `wss` on 443, the default host and port);
- try the known `/@fs/` bypass patterns against the public front;
- time a first load and an update on a phone network;
- read the Durable Object's usage.

Real addresses and figures stay in the problem's scratch folder.

### Recorded

- An ADR once accepted: the first public surface, the relay on the user's account and the app's public port.
- CONTEXT.md gains **Public link**.
- `docs/privacy-and-security.md` gains a section.

## Testing Decisions

- **`bun test` on the public front's rules,** as pure functions:
  - methods;
  - every path class, allowed and refused, including encoded and doubled slashes and Vite's `?raw`, `?import` and `?url` queries on `/@fs/`;
  - dotfiles;
  - the path rewrite both ways;
  - source-map stripping;
  - the socket's message filter.
- **`bun test` on the connector's framing:** chunked responses, websockets, the caps, and a reconnect.
- **The Worker's own tests:**
  - expiry and stop;
  - the 410 page and the reload message to open sockets;
  - limits;
  - a link id that isn't one;
  - the control calls refused without the key.
- **By hand, after a restart, with a phone on mobile data as the viewer:**
  - share, watch an edit arrive, sleep the Mac and wake it, stop, let one expire;
  - read the page's source and network panel in a desktop browser for any home path or project name;
  - turn the switch off and see that no connector runs and nothing of it shows.

## Out of Scope

- A Varnick-hosted relay for every user, and links for other apps or web panes (problem › Later).
- Password-protected links.
- Choosing which files are public (the whole area is, live).
- A static copy (option 07).

## Further Notes

- **The links domain is the user's choice.**
  - **Recommended: a zone of its own.** A wildcard there is covered by the free certificate, the links are never same-site with varnick.com, and a link a browser's safe-browsing list flags can't take varnick.com with it.
  - **First-level subdomains of varnick.com** work too. They make the links same-site with it, so a page could set cookies for varnick.com, which today sets none.
- **For every Varnick user later,** the same relay would need accounts, quotas, abuse reports and takedowns, and the links domain on the Public Suffix List. That is why this option is the user's own account first.
- **With option 07,** a Freeze button could later put a built copy at the same kind of link, served by this relay from storage, for when the Mac must be off.
