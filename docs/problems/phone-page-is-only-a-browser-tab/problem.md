---
title: The Phone page is only a browser tab; it can't be installed, and it never tells the phone that a session needs the user
description: The Phone page opens in the phone's browser as an ordinary tab. It can't be added to the Home Screen as an app with its own icon and full screen, and it has no service worker, so a host that can't be reached shows the browser's error page. Nothing reaches the phone when a Claude session on any host finishes its turn, stops on a dialog or fails. The user finds out only by opening the page and looking, tab by tab, host by host.
impact: Away from the desk, a session waiting on a permission dialog or a question sits idle until the user happens to open the page, as it does at the desk today (sessions-finish-unnoticed). The page is the only way to reach sessions from the phone, and reaching it means finding a browser tab and its address for each host. On an iPhone, Web Push exists only for a web app on the Home Screen, so the two halves of the request can't be split there.
severity: mid
evidence: The user's request of 2026-10-14, relayed by the coordinator ("I wish I could install the mobile app as a PWA and also support push notifications"). Code and docs read at 904d138 (main) on 2026-10-14; nothing was run, served, installed or sent. The browser and push-service facts below come from Apple's, WebKit's, Google's and the Web Push RFCs' published documentation as known to the planner, not re-read for this problem and not tested on a phone. They are marked inferred.
status: open
---

## What the user wants

1. **Install the Phone page as an app** on the phone: an icon on the Home Screen that opens the page full screen, without the browser's bars.
2. **Push notifications** to the phone when a session needs the user, without the page open.

## Why this is its own problem

`sessions-finish-unnoticed` is the same pain at the desk: nothing says when a turn ends or Claude waits on the user. Every one of its options leaves "a push to the phone" out of scope, and its notices live in Varnick's Mac app. This problem is kept apart because:

- **Install has nothing to do with notices.** It is a change to the Phone page alone, and worth having without push.
- **Push lives somewhere else.** It lives in the Phone page server (ADR 0011), which runs on a headless host too, where there is no Varnick app to raise a notice.
- **Its concerns are its own.** A third party carries every push (Apple's or Google's push service). It needs a signing key, subscriptions per device and one sender per host. And iOS ties push to install.

What the two problems share is *when* to tell the user and in what words. That is `sessions-finish-unnoticed` option 01's table (Done, Needs you, Stopped on an error, the starting-point and Esc rules) and option 02's wording. The options here reuse them by reference, so the Mac and the phone say the same thing.

## Today

Verified in the code and docs at 904d138 unless marked.

### How the page is served

- **The origin.** `https://<the host's MagicDNS name>:8444/`, one per host (ADR 0011).
  - The page server is Bun, on an owner-only Unix socket, or on loopback where the host's Tailscale can't serve a socket (the Air's and the Studio's).
  - `tailscale serve` publishes it on HTTPS port 8444, tailnet only. Funnel is never on.
- **The certificate** is Tailscale's for the machine's name, issued by a public authority. ADR 0035 notes that the name is already in the public certificate logs because of 8444.
  - So the page is a secure context in any phone browser with no trust setup. The user loaded it on the Pixel 8a on 2026-10-06 with no warning.
  - Service workers, the manifest and Web Push all need a secure context, and the page already has one (inferred from the browsers' rules, not tried).
- **How the phone reaches the host.** Over the tailnet, so the Tailscale app on the phone has to be connected.
  - The MagicDNS name resolves only there. Off the tailnet the page doesn't load at all.
  - On the tailnet the host is reached from any network, through Tailscale's relays when no direct path exists (inferred from Tailscale's design, not measured here).
- **Who is calling.** `tailscale whois` on the address serve forwards gives a node, and the node must be in the host's `devices.json`, owned by the user and untagged. The page has no login and sets no cookie.
  - An unlisted device gets 403 on every path, so the page's files are refused to it too.
  - A change must be a POST from the page's own Origin. `/api/*` answers only `Sec-Fetch-Site: same-origin`, and websockets are checked the same way.
- **Headers.** Every reply is `no-store`, because replies carry prompts and titles. The content policy is `default-src 'none'` with `script-src 'self'`, and names no `manifest-src`, `img-src` or `worker-src`.
- **Each host's page stands alone.** Home links to the other hosts' pages ("Other hosts"), but each one is its own origin, so what the browser keeps for one (storage, permissions, a service worker, an install) is that host's alone.

### What the page has toward an app

- No manifest, no service worker, no icons, no `apple-touch-icon` and no theme colour. The server serves a fixed list of files, and none of these is among them.
- The page routes by its address's fragment: `#t=<tab>&p=<pane>` opens a tab at a pane, `#new` the new-session view. A notification could open a session through that.
- **The phone it was made on.** The page was built and tested on Android Chrome only (the Pixel 8a). It has never been opened on an iPhone. The terminal's keyboard rules (the key bar on one line at 360px, the grid keeping its rows when the keyboard comes up, `overflow: clip`) were all tuned in a Chrome tab, not in a standalone window.

### What the page server knows about turns

- **`tabs` carries each Claude pane's turn.** The relay's `tabs` reply carries, for each Claude pane, its turn word and how many seconds ago it began. It sends them to a device too: what is hidden from a device is another controller's id, the work links and the done mark.
- **The page drops it.** It shapes panes without the turn, so the phone shows no turn.
- **The server already asks `tabs` as the host itself,** for the port proxy (ADR 0035).
  - On a Mac each ask is a whole Varnick process, so the proxy asks only when the saved tabs file's date changes, and every 5 minutes.
  - A turn change doesn't touch that file. Turn changes are written to each pane's own turn file by Claude Code's hooks (ADR 0010).
- **What the reply can't say:**
  - Whether a waiting turn came from the user pressing Esc. The reader derives that from the transcript, and `sessions-finish-unnoticed` option 01 would keep it local.
  - Whether a turn ended on an API error. The `failed` word is option 01's, not built.

### Where secrets live

- **In the Keychain.** API keys (ElevenLabs among them) are kept by Varnick under its own service name. They are readable without a prompt by a Developer ID build (ADR 0022). An ad-hoc build is asked again after a rebuild.
- **As a file.** The port proxy's TLS key comes from `tailscale cert` and is kept as a file in the page server's owner-only folder, on a Mac and on a headless host alike.
- **How the server is configured.** Only from its environment, which Varnick sets when it starts the server in zmx and the installer sets in the systemd unit. On a Mac the environment goes to the process, not on its command line.

## What the browsers and push services do

Inferred from published documentation, none of it tried here.

### Install

- **Android Chrome** offers Install for a secure page with a manifest that has a name, a start address, `standalone` display and icons of 192 and 512 pixels. A service worker isn't required any more.
  - Installing makes a WebAPK, which Google's servers build from the manifest and icons Chrome sends. Whether that works for an address Google can't reach is unverified. The fallback is a Home Screen shortcut that still opens standalone.
- **iOS Safari** has no install prompt. The user adds the page with Share › Add to Home Screen.
  - With `standalone` display it opens without Safari's bars.
  - It keeps its own storage, apart from Safari's, and takes its icon from `apple-touch-icon`.
- **Each origin is its own app,** so each host's page installs separately.

### Web Push

- **The protocol is standard on both platforms:**
  - the browser subscribes with the sender's public key (VAPID, RFC 8292) and gets an endpoint on its vendor's push service: Google's FCM for Chrome, Apple's for Safari;
  - the sender POSTs to the endpoint a payload encrypted to the subscription's own keys (RFC 8291, `aes128gcm`), with a token signed by its private key.
- **What the push service can't see.** The payload is encrypted end to end, so the push service can't read it.
- **What it does see:**
  - the endpoint, which names one browser install;
  - when each push is sent, and its size;
  - the sender's address;
  - the TTL and Urgency headers, and a Topic if one is sent;
  - the sender's public key and the token's `sub` contact, both in the clear.
- **A payload is at most about 4 KB.**
- **On iOS (16.4 and later), push is for a Home Screen web app only,** not for a page in Safari. Permission must be asked from a tap inside the installed app.
- **Every push must show a notification.**
  - On iOS a few silent ones get the subscription revoked.
  - On Android Chrome shows a generic one in their place.
  - So a push can't silently withdraw an earlier notification.
- **Android Chrome takes push in an ordinary tab,** with no install. Permission is per origin, asked after a tap.
- **Notifications can be grouped.** A notification's `tag` makes a newer one replace an older one with the same tag. Whether iOS honours `tag` and `getNotifications` is unverified.
- **The app badge.** iOS shows the number set by `setAppBadge` on a Home Screen app that has notification permission. Android ignores it, and shows its own dot for standing notifications.

### Away from the network the host is on

- **Delivery doesn't need the tailnet.** The host sends to the push service over its own internet connection, and the phone receives through its vendor's channel. So a push arrives with Tailscale off on the phone, or on mobile data.
- **Acting on it does.** Opening the session it names needs the page, so it needs the tailnet and the host awake.
- **A host that is asleep or offline sends nothing.** A closed lid pauses the sessions anyway (`closed-lid-pauses-sessions`).

## Unverified

- Whether Chrome makes a WebAPK for an origin Google's servers can't reach, or falls back to a shortcut.
- Whether a service worker's fetch to its own page counts as `same-origin` for `Sec-Fetch-Site`, so `/api/*` answers it. Expected: yes.
- How long iOS lets a push event run before it must show its notification, and so whether a short fetch over the tailnet fits in it.
- Whether iOS honours a notification's `tag`, `renotify` and `getNotifications`.
- How the page's terminal and key bar behave in a standalone window on Android, and anywhere on iOS.
- What one `tabs` ask costs on a Mac in time and CPU. ADR 0035 treats it as a whole Varnick process, which is the only figure there is.
