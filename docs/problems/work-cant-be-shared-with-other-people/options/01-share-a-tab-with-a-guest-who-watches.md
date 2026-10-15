---
problem: work-cant-be-shared-with-other-people
title: Share one tab with a guest on a Tailscale-shared Mac, who watches it whole in their own Varnick
summary: The user shares this Mac with another person through Tailscale's machine sharing, then shares one tab with them from Varnick. The guest adds the Mac in their own Varnick and opens the tab whole, as a paired Mac opens a host's tab. They see the live screens, file panes and web and app panes, and nothing else. They can't type, take over or change the layout. The host's Phone page server is the guest's only door, on routes of their own, with the relay checking every request against the shared tab and the port proxy opening only that tab's ports. The guest's Varnick reaches the host over HTTPS, never SSH, on a guest interface versioned apart from the peer protocol, because a guest runs another person's build. Behind a Tab sharing switch in Settings › Experimental on both Macs. Recommended, with option 02 (typing) only after this is in use. Rough effort is a spike of half a day, then about eight days.
status: proposed
---

## Solution

### Who a guest is

A **guest** is another person, running their own Varnick, whom the user has given this Mac through Tailscale's machine sharing. Varnick never sets up the Tailscale share. It reads it: the guest's devices appear in this Mac's `tailscale status` as nodes shared in by another user.

A guest is a person, not a device: any of their devices that reach this Mac through the share counts. A guest is never a peer and never a device. They are never added to the peer list, never reach the relay over SSH, and never see the Phone page.

### Sharing a tab

- **What can be shared.** One tab whose host is this Mac, whole: its layout, every pane, and the panes added to it later. A view of another machine's tab can't be shared from here, only from its host.
- **Starting.** `!share` on the tab shown opens a share sheet in the panel. It lists the people who reach this Mac through a Tailscale share, by their Tailscale name with their devices under it. The user ticks one or more and presses Share.
  - **What it says first:** "Sam can watch this tab: every pane's screen as it changes, the text of its file panes, its web and app panes (any page of those servers, not only the one shown) and the addresses of its web pages. Sam can't type, take over, change the tab or see your other tabs. Panes you add to this tab are shared too."
  - **When nobody is listed:** "Nobody reaches this Mac through a Tailscale share yet. Share this Mac from Tailscale's admin console; the person appears here once they accept."
  - **When something is missing,** the sheet says what and refuses: the Phone page server isn't serving, Keep sessions running is off (the live screen reads zmx), or Tailscale doesn't answer. Web and app panes without Tailscale's operator setting stay on their cards for the guest, as for a paired Mac, and the sheet says so.
- **Stopping.** Any one of these ends the share at once:
  - Stop sharing in the tab's sharing bar or in the status menu;
  - `!share` on a shared tab, which offers Stop sharing;
  - closing the tab, or Done;
  - turning the switch off, which ends every share;
  - the person losing the Tailscale share, which leaves their devices refused by `whois`.
- **Lasting.** A share lasts until it is stopped. It survives a restart of Varnick, since the page server and the shares file outlive it, and the indicator is back at launch.

### The indicator ("you're sharing")

- **In the tab:** a slim bar across its top, "Shared with Sam · watching now" or "· not watching", with Stop sharing. "Watching" means the guest has at least one live screen or proxied page open, which the page server reports.
- **In the tab strip:** a sharing mark on the tab.
- **In the status menu:** a line per shared tab, "Sharing <tab> with Sam", whose action is Stop sharing, above the usual items as notices are.

### What the guest sees

- **Adding the Mac.** In Settings › Peers, a "Shared with you" section lists the nodes of other users that this Mac's `tailscale status` shows (a shared-in machine), and Add takes one. That is the only way a shared Mac is ever contacted, as Find Macs and Add are for peers. A shared Mac that shares nothing with the guest says so on its row.
- **The tab.** The session list shows each tab shared with the guest under a header "Shared by <the host's name>", as a paired Mac's tabs are listed. ↩ opens it whole in the host's layout:
  - Claude and terminal panes on their cards with the live screen, under "Watching <host>";
  - file panes with their text;
  - web and app panes through the host's port proxy, as for a paired Mac;
  - the Transcript as a plain card saying it stays on its Mac.
- **What it doesn't offer.** No Take over, no Start or Reconnect that starts anything, no split, divider, rename or file tree ("Only <host> changes this tab"), and no Done. ⌘W closes the view on the guest's Mac and tells the host nothing.
- **Where it doesn't appear.** A shared tab is never a board card and never in Recent, search or Completed.
- **When the share stops,** the next listing lacks the tab, the view closes, and a line says "<host> stopped sharing <tab>".

### What the guest never reaches

- **Other tabs.** The relay lists only the tabs shared with them, and refuses `status`, `watch` and `file` for any pane outside those tabs.
- **Other panes' ports.** The port proxy admits a guest only on the ports of the shared tabs' web and app panes, and there only GET, HEAD and websocket upgrades.
- **The Phone page.** Its files and `/api/*` answer a guest 403 with a note to open Varnick. A guest has only the guest routes.
- **Settings and everything else the relay answers:** projects, agents, apps, hosts, Recent, the search sync, starts, ends, done marks, arranging, upgrades and restarts.
- **SSH.** Varnick never adds a guest's key or a peer entry for them.

### How a guest differs from a paired Mac

| | Paired Mac | Guest |
|---|---|---|
| Whose | the user's own | another person's |
| Way in | SSH with the user's keys: a shell | HTTPS to the Phone page server over the tailnet, through Tailscale's machine sharing |
| Who it is | the `by` it names; the SSH login is the credential | `tailscale whois` of the connection: a shared-in node of a guest's Tailscale user |
| Sees | every open tab, Recent, search, projects, agents, apps, builds | only the tabs shared with them, while shared |
| Does | take over, type, split, rename, close, reopen, start, upgrade, restart | watches (option 02 adds take over and type) |
| Listed | mutual pairing | the host shares per tab; the guest adds the host |
| Protocol | the peer protocol, one version on every machine | a guest interface with its own version, read across builds |
| Port proxy | every proxied port, every method | the shared tabs' ports, GET, HEAD and websockets |
| Board, Recent, search | yes | no |

## Trade-offs

- **Tailscale is the identity.** No key, link or password of Varnick's own: who calls is what `whois` says, unforgeable on the tailnet, and a share ends when the Tailscale share does. In exchange the guest needs Tailscale and the user shares a whole machine.
- **A whole machine is shared at the network level.** The person's devices reach every port this Mac serves on the tailnet (inferred). Varnick's own doors admit them only as guests, but any other server on the Mac answers them as it answers the user's own devices. Remote Login listening on the tailnet is reachable too, though it still needs a key. The sheet says so, and the spike finds out whether the tailnet policy can narrow it.
- **Screens never pass through a third party in clear.** The live screen goes over the tailnet, end to end, as for a paired Mac.
- **Watching only keeps the blast radius to what is shown.** The guest reads screens (which can show secrets, as any screen share does), the tab's files shown in panes, and the tab's web and app servers. Typing would hand them the account (option 02).
- **A web or app pane is shared whole.** The guest can open any page of its server, not only the one shown, and a websocket can carry whatever the app accepts. For Scratch that would include every pane's scratch area in the project, which the narrowing below closes.
- **A second transport on the guest's side.** The guest's Varnick reaches a shared Mac over HTTPS where it reaches peers over SSH, behind the one seam that already sends every peer request.
- **No peer protocol bump.** The relay learns a new kind of asker from a file, and no request or reply changes shape. Every machine keeps its own commit.
- **Loopback mode stays weak.** On a Mac whose page server runs on loopback, a local process can already pose as a listed device, which reaches more than a guest does. Sharing is not refused there, and the sheet carries the page's own loopback note.
- **Alternatives considered:**
  - The guest as a peer over SSH with a forced command: it reuses every peer path, but puts another person's key in the user's account and trusts `by` from a channel that is a shell.
  - Carrying guests over the public-link relay of option 04: no Tailscale needed, but every screen and keystroke would cross Cloudflare in clear, and identity would rest on a token. That is under Later.

## User Stories

1. As the user, I want to share one tab with a colleague who runs Varnick, so that they can watch my Claude sessions, terminals and pages without a call.
2. As the user, I want to pick the person from those Tailscale already lets reach this Mac, so that I set up nothing else.
3. As the user, I want to be told exactly what they will be able to see before I share.
4. As the user, I want a bar in the shared tab, a mark on it and a line in the status menu while it is shared, so that I never forget it is open.
5. As the user, I want to see whether they are watching right now.
6. As the user, I want to stop sharing from the tab, from the status menu or by closing the tab, and have it end at once.
7. As the user, I want panes I add to the shared tab to be shared too.
8. As the user, I want the guest unable to reach my other tabs, other apps' ports, my Phone page, my settings or my search, whatever they send.
9. As the guest, I want to add the shared Mac once and see what it shares with me in my session list.
10. As the guest, I want to open a shared tab whole, in its layout, with live screens and working Scratch and web panes.
11. As the guest, I want to be told when the share stops.
12. As either of us on a different Varnick build, I want sharing to keep working.
13. As the user with Tab sharing off, I want no guest admitted, no shared Mac contacted and nothing of it in the UI.

## Implementation Decisions

### The switch

- **Settings › Experimental › Tab sharing,** off by default, one switch for both roles, as Problems board and Outline are.
- **Off, on the host:** no `!share`, no sharing bar, mark or menu line. Varnick deletes the shares file when the switch goes off and at each launch while it is off, so the relay and the page server admit nobody. The page server's guest routes then answer 404.
- **Off, on the guest's side:** no "Shared with you" section, no request to any shared Mac, and any shared tab open closes. The list of shared Macs is kept for when it comes back on.

### The shares file (host)

- **Where.** One file in Varnick's support folder, owner-only, written only by the running Varnick, as the device file is.
- **What it holds.** The guests: a lowercase UUID made the first time a person is shared with (the id in `by`), their Tailscale user id and name, and the nodes seen for them. The shares: a tab id and the guest ids, with when it began.
- **Who reads it.** The relay and the page server read it fresh on every request. A file that can't be read admits nobody.
- **When an entry goes.** It is removed when a share stops, and a guest with no share left is removed with it.

### The relay (host)

- **A third kind of asker.** Beside a listed Mac and a listed device there is now a guest: an id the shares file holds. The page server is the only thing that runs the relay with a guest's id.
- **What a guest may ask.**
  - `tabs` lists only the tabs shared with them. They are told what a device is told, and also without folders, conversation ids or work links.
  - `status` and `watch` are answered only for pane sessions of those tabs, checked against the host's own listing.
  - `file` is answered only for a file pane of those tabs, under the existing rules.
  - Everything else is refused as unlisted.
- **The check is the relay's,** so the rule stays where every other caller's is. The page server checks the same first, to refuse early.
- **No headless host.** A headless host has no shares file and answers no guest.

### The page server (host)

- **Who is a guest.** `whois` on the caller gives a node shared in (`ShareeNode`) whose user is a guest in the shares file. That caller gets the guest routes and nothing else, with `by` set by the server alone, as for a device.
- **The guest routes:** a hello that names the guest interface's version and the host's name, the shared tabs, a file pane's text, the panes' `status`, and the live-screen websocket the phone already uses, admitted for a guest. Each guest has its own caps on relay runs and open screens: enough for every pane of a tab at once, about eight.
- **No browser can call them.** They answer only a request that carries Varnick's own header and no `Sec-Fetch-Site`. A page open on the guest's Mac can't send the header without a preflight, which is never answered.
- **The guest interface has its own version.** Its shapes are the relay's tab and pane shapes, which only ever gain optional fields and send kinds and turns as words. The guest's Varnick refuses only a major version it doesn't know. A peer protocol bump doesn't change it.
- **Its status file reports who is watching,** per guest and tab, for the sharing bar, as the port proxy's status file reports ports.

### The port proxy (host)

- **Who it admits.** A guest node, for a port that belongs to a web or app pane of a tab shared with that guest (the proxy already maps ports to panes from the host's `tabs`).
- **What it lets through.** GET, HEAD and websocket upgrades, under the existing `Sec-Fetch` rules.
- **Ending.** A guest whose share stops loses their open sockets at the next look, as a removed device does.

### Scratch's own reach

- **The narrowing.** Scratch's Vite allows browsers only its own area, the packages it serves and Vite's client, instead of the whole scratch root and the app's folder.
- **What it no longer serves.** Dotfiles in the area, `.vite.log` among them.
- **Why here.** It matters to anyone who loads a Scratch from afar: a paired Mac, a device and now a guest. Option 04 relies on the same narrowing, and whichever option is built first makes it.

### The guest's Varnick

- **Shared Macs** are a list of their own in UserDefaults (an id, the name, the full tailnet name), never the peer list. So nothing a shared Mac sends is ever answered as a peer's.
- **One seam, two ways.** The peer manager already sends every request and opens every live screen for a host. For a shared Mac it does both over HTTPS to the page server's guest routes and websocket, and the existing host tab code shows the result.
- **Read-only.** Every control path refuses for a shared Mac's tab with "Only <host> changes this tab" (the lock a viewer already has), Take over isn't drawn, and ⌘W closes the view without sending anything.
- **Proxied pages** load only at the shared Mac's own full tailnet name, as for a paired Mac.
- **What is saved.** A shared tab open here is saved as another host's tab is, and is dropped at launch when its Mac no longer lists it.

### The spike (first ticket)

With a second Tailscale account and a test Mac shared to it, record:
- how the guest's nodes look in the host's `status` and `whois`, and whether their user id is stable;
- whether serve on 8444 and a proxy port answer them, with the address in `X-Forwarded-For` for serve;
- the host's name and certificate as seen from the guest;
- what other ports of the Mac they reach, SSH included, and whether the sharer's policy can narrow that;
- whether Tailscale SSH admits them.

Real names and addresses go in the problem's scratch folder, never in the repository.

### Recorded

- An ADR once accepted: a caller from outside the user's tailnet, which amends ADR 0011's and ADR 0035's "only the user's own nodes".
- CONTEXT.md gains **Guest**.
- `docs/privacy-and-security.md` and `docs/agents/where-it-breaks.md` gain sections.

## Testing Decisions

- **`bun test` in the page server:**
  - a shared-in node of a listed guest gets the guest routes, and a shared-in node of anyone else gets 403;
  - a guest gets 403 on the page's files and `/api/*`;
  - a guest route refuses a request with `Sec-Fetch-Site` or without Varnick's header;
  - the proxy admits a guest on a shared tab's port and refuses another port, and refuses POST;
  - a guest's sockets close when the share goes.
- **The relay's rules, as pure functions with tests:**
  - `tabs` for a guest holds only shared tabs, without folders, conversation ids or work links;
  - `watch`, `status` and `file` outside the shared tab are refused;
  - every other op is refused;
  - an unreadable shares file admits nobody.
- **Scratch:** with the narrowing, a page still loads with hot reload on this Mac and through a paired Mac's port proxy, and `/@fs/` into another pane's area and `/.vite.log` answer 403 or 404.
- **By hand, after a restart, with the spike's two accounts:**
  - share a tab of a Claude pane, a terminal, a file and a Scratch, and watch it from the guest's Mac;
  - type on the host and see it on the guest's card;
  - split on the host and see the new pane arrive;
  - try every refused path from the guest;
  - Stop sharing and see the guest's view close and their proxied page lose its socket;
  - turn the switch off on each side and check that nothing of it shows and the shares file is gone.
- **Checks never run from a Claude session's own process.** No daemon or launchd change is involved, but a server started for a check runs in a pane.

## Out of Scope

- Typing, taking over and changing the layout (option 02).
- A file tree for guests (`files` stays for listed Macs).
- An expiry on a share.
- Guests without Tailscale, a browser viewer, a headless host's tabs (problem › Later).
- Setting up the Tailscale share from Varnick.

## Further Notes

- **Build order with the Phone page work.** `phone-page-is-only-a-browser-tab` options 01 and 02 change the same server. This option needs no peer protocol bump, so it doesn't take part in the bump to 27 for the Esc mark. Whichever lands second rebases the server's routing.
- **Why a person and not a device.** The user shares with someone, not with a laptop. The shares file keeps the nodes seen, so if the spike finds user ids unstable, it falls back to nodes picked one by one in the sheet.
- **Recommendation.** Build this first, watch-only, and use it. Option 02 adds typing on top without undoing any of it, and option 03 adds window and screen video on the same door.
