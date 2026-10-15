---
title: Nothing in Varnick can be shown to another person, not a tab or a window to another Varnick user and not a Scratch page to the world
description: Every way into Varnick is for the user's own machines. Paired Macs reach each other over SSH with the user's keys, and the Phone page and the port proxy admit only the user's own listed devices and paired Macs, refusing any node shared in from another tailnet. So the user can't let a colleague who also runs Varnick watch a tab (its Claude sessions, terminals, Scratch and web panes) as a paired Mac can, or show them a window of another app. A Scratch page, the live page Claude builds beside a session, runs as a Vite dev server on the Mac's localhost, and nobody outside the user's own devices can open it.
impact: Showing work to someone means a screen share in a call, which shows one window at the user's resolution and nothing the other person can look around in. A Scratch page (a prototype, a chart, a diagram) can't be sent to anyone as a link, so it is screenshotted or rebuilt elsewhere. Both are the user's own requests.
severity: mid
evidence: The user's request of 2026-10-14, relayed by the coordinator, with three additions the same day (the public Scratch link serves the live dev server, so viewers keep getting hot reloads; each feature ships behind an experimental switch of its own; a window or the screen can be shared as video). kiruna-labs/petal (Apache-2.0) read for ideas on window capture and encoding, not code. Code and docs read on main on 2026-10-14, from 60b476a to e9a01dc. Nothing was run, served, shared or deployed. Facts about Tailscale's machine sharing, Cloudflare and Vite marked inferred come from their published documentation and source as known to the planner, not re-read for this problem and not tried.
status: open
---

## What the user wants (2026-10-14)

1. **Share a tab with another Varnick user.** "It's just like the remote share we have": viewing, and perhaps taking over, another person's tab the way paired Macs view and take over each other's tabs today.
   - The whole tab: its layout, its Claude sessions and terminals, its Scratch and web panes.
   - A Scratch pane needn't look exactly the same. Loading it through the host's port proxy, as another Mac loads a host's app pane, is fine.
   - The likely way in is Tailscale's machine sharing (one device shared into another person's tailnet), with Varnick treating that person as a guest.
2. **Share one window, or the screen, as video with another Varnick user,** shown in a pane of their Varnick.
   - It covers what tab sharing can't reproduce: a browser on a private or logged-in page, or any app outside Varnick.
   - The likely shape: ScreenCaptureKit, one window at a time where possible; VideoToolbox H.264; sent across the tailnet on the same guest path as tab sharing, so no public relay yet.
   - View only first. A pointer and annotations come later.
   - Ordered after tab sharing.
3. **A public URL for a Scratch, at the press of a button.** "I'd love the ability to share a Scratch publicly: a button I press and it creates a public URL."
   - **Live:** the link serves the running dev server, so viewers see each change as Claude makes it. A static snapshot is not what the user wants.
4. **Each behind an experimental switch,** off by default, one switch per feature. A switch that is off means no connection, no guest admitted and no UI, not a hidden button.

A web viewer for whole tabs (a guest watching in a browser instead of Varnick) is not wanted now ("let's not worry about the web today"). It is under Later.

## Why this is its own problem

- **`sessions-hosted-only-on-macs`** is about the user's own Linux host running sessions. Nothing there lets another person in.
- **`custom-apps-must-be-written-first`** is about where apps come from (the catalog). A public link touches the custom-app contract (a manifest field, a second port), but the need is reaching people, not getting apps.
- **`work-is-tracked-by-session-not-tab`** (options 03 and 04, shipped) built what a guest would see: a tab lives on its host and opens whole elsewhere, and web and app panes load through the host's port proxy. Both are for the user's own machines.
- **`phone-page-is-only-a-browser-tab`** (options 01 and 02, accepted) changes the same page server a guest would come through. Its protocol 27 is for the Esc mark. The options here say where they meet it.

The three requests share one problem because each turns a door that is closed to everyone but the user into one that opens for someone else, on the user's say-so, and both need the same answers: who gets in, to what, how the user sees that it is open, and how it closes.

## Today

Verified in the code and docs unless marked.

### Who gets in, and how

- **Paired Macs** reach each other over SSH with the user's own keys (ADR 0007). The relay answers every request but a hello only to a Mac the host lists. The list is checked against the `by` the request names; the SSH login is the credential, so a paired Mac has the account anyway.
- **Devices** (the phone) reach the host's Phone page server on port 8444 of its tailnet name, published by `tailscale serve`, tailnet only (ADR 0011). The server finds the caller with `tailscale whois` and sets `by` itself. Only the user's own untagged nodes may be listed (`PeerDevice.mayBeListed`, and `mayBeListed` in the page's checks): a node shared in from another tailnet, or owned by another user, is refused as "not own".
- **The port proxy** in the same server opens one TLS listener per port a web or app pane of an open tab uses, on the host's tailnet addresses (ADR 0035). It admits a listed device, or a node of the user's own that is a paired Mac, by whois on the connection itself, and never a tagged or shared one.
- **Funnel is never on.** Nothing in Varnick or the installer runs `tailscale funnel`, and publishing the page fails closed if Funnel is on for its port (ADR 0011's note).
- **The relay doesn't scope by tab.** A listed Mac or device may `watch`, `screen` or `attach` any pane session by name, and `take` any tab. Scope today is "everything on this host, or nothing".
- **The protocol is all or nothing too.** Every Mac and the headless host must run one protocol version (26 now), and a mismatch blocks every request but `upgrade` and `restart`. `PROTOCOL_VERSION` in the page server must equal it.
- **Loopback mode** is a known weakness: where a Mac's Tailscale can't serve the page on a socket, the server listens on loopback and any local process, another account's included, can send the forwarded address it trusts and pose as a listed device (`docs/privacy-and-security.md`).

### What a tab shows elsewhere

- **A host's tab opens whole on another Mac** in the host's layout (ADR 0034). Claude and terminal panes show their live screen on a card, read by `watch` from the host's zmx. A file pane is read by the host's `file` request (inside the tab's folders, at most 1 MB, text only). A web or app pane at a local address loads through the port proxy. The Transcript stays on its Mac.
- **The phone shows a tab one pane at a time,** through the page server's own routes and its live-screen websocket, which carries the relay's `watch` frames as JSON.
- **Who can change it.** Only the machine in control changes the layout. Take over takes every Claude and terminal pane of the tab.
- **What the listing carries.** Pane titles, kinds, turns, folders (absolute paths), conversation ids, work links (stripped for a device), web pane addresses and proxied addresses.

### Scratch

- **A custom app,** not a built-in. Varnick's Swift code knows nothing of its layout. It is in the catalog, and Varnick's own installed copy installs frozen to the committed lockfile, which pins Vite 6.4.3 at this commit.
- **One Vite dev server per pane,** started by Varnick with `PORT`, `VARNICK_PROJECT`, `VARNICK_SPLIT_FROM` and `VARNICK_APP_DATA`. It listens on 127.0.0.1 only. Its root is the pane's scratch area under the project's `.varnick/scratch/`, and the page's packages sit in the scratch root above it.
- **What it lets a browser read.** Vite's `fs.allow` is the whole scratch root (every pane's area in that project, and the packages) and the app's own folder. No `server.proxy` is set, so the page reaches nothing else through it.
- **What it writes beside the page.** The area holds `.vite.log`, which Vite's default deny list doesn't cover (inferred from Vite's documented defaults: `.env`, `.env.*`, certificates, `.git`).
- **Paths in what it serves.** The placeholder page names the area's absolute path. Modules outside the root are served at `/@fs/` plus their absolute path (inferred), and React's dev transform writes source file paths into the code (inferred). So what a browser receives names the account's home folder and the project.
- **A pane of another machine's tab** loads a Scratch through the host's port proxy, the whole dev server, so a viewer can read any file Vite allows, not only the page shown.

### Capturing the screen

- **Varnick already captures with ScreenCaptureKit,** for the text step of pointing at the screen (ADR 0021) and Screen access's `look` (ADR 0023). It lists shareable content and takes single images. It doesn't stream yet.
- **It holds the Screen Recording grant** as Varnick, by team and bundle id (ADR 0022). A grant takes effect after a restart of Varnick.
- **What a display capture includes.** Screen access's display capture leaves nothing out, Varnick's own windows included (ADR 0023).
- **Nothing encodes or decodes video yet.** VideoToolbox isn't used, and there is no WebRTC library. The app targets macOS 14.

### Experimental switches, credentials and the menu bar

- **Settings › Experimental** holds two switches, Problems board and Outline, each a `Settings` property written to UserDefaults, off by default. The `!` command list leaves out the commands of a switch that is off. `CODING_STANDARDS.md` asks for a switch of its own for each experimental feature. So the mechanism the user asked for exists, and needs no option or ADR of its own.
- **API keys** are kept in the login Keychain under Varnick's service name (`Keychain`).
- **The status menu** lists standing notices above its usual items, and the menu-bar icon carries a dot for them.
- **Web and app panes** have an address bar with Reload and Close. Claude and terminal panes have none.

### varnick.com

- **One Worker,** in `site/`, serves one constant page on `varnick.com/*` and `www.varnick.com/*` routes. It sets no cookie. It is deployed through `deploy/`, as `site/README.md` describes.
- The coordinator reports that R2 is available on the account. Not checked here.

## What Tailscale's machine sharing does

Inferred from Tailscale's documentation and source as known to the planner. None of it tried here.

- **The unit is a machine.** The user shares a node with another person by invite from the admin console, and it appears in that person's tailnet. Sharing is one-way: the person's devices can connect to the shared machine, and the shared machine can't connect to theirs.
- **How each side sees the other.** On the shared machine, the person's devices appear in `tailscale status --json` as peers with `ShareeNode` set, owned by a user who isn't the machine's. `whois` on their connection names the node and its user. Varnick already reads `ShareeNode` (`Tailscale.status`), and refuses such nodes by rule.
- **What they reach.** Without a policy that narrows it, the person's devices reach every port the shared machine serves on the tailnet: the Phone page, the port proxy's ports, SSH if Remote Login listens there, and any server bound to every address. Whether the sharer's tailnet policy can narrow a sharee to some ports is unverified.

## Unverified

- Whether a sharee's user id, as the shared machine sees it, stays the same across reconnects and devices, so it can name a person.
- Whether `tailscale serve` on 8444 forwards a sharee's connection, with its address in `X-Forwarded-For`, and whether the port proxy's TLS listeners answer one.
- What the shared machine's MagicDNS name is on the guest's side, and whether its Tailscale certificate (issued for its own name) is valid for the address the guest uses.
- Whether Tailscale SSH on a shared Mac admits a sharee by default.
- How Vite's client behaves behind a relay on port 443 (its HMR token, host and port taken from the page's address), and how long a dev page of unbundled modules takes to load through one.
- The cost of a Durable Object relay on the user's Cloudflare plan.
- Whether WebRTC's connection checks succeed over a one-way machine share, where the shared Mac can't open a path to the guest.
- Whether macOS's own content picker returns a filter Varnick can add exclusions to, and whether it spares the recurring screen-capture prompt of recent macOS.
- The frame rate, bitrate and delay a shared window gets over a direct tailnet path and through Tailscale's relays.

## Later

- **A web viewer for whole tabs:** a guest, or the user, watching a tab in a browser instead of Varnick.
- **A Varnick-hosted relay for every Varnick user,** with accounts, quotas, abuse handling and a links domain on the Public Suffix List.
- **Guests who aren't on Tailscale,** carried by the same relay as public links.
- **Public links for other apps and for web panes.**
- **Sharing a headless host's tab.** It has no Settings and no shares file.
- **The guest pointing and drawing on a shared window,** then remote control, which would need Accessibility on the host and a consent prompt per request.
- **Audio** with a shared screen.
