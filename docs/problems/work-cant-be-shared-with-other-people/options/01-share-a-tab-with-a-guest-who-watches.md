---
problem: work-cant-be-shared-with-other-people
title: Share one tab with a guest on a Tailscale-shared Mac, who watches it whole in their own Varnick, with Varnick setting up Tailscale through its API
summary: The user picks "Share this tab with…" and Varnick does the Tailscale side with the user's OK. Using the user's personal Tailscale API key, entered once and kept in the Keychain, it creates the invite to this Mac, and adds a Varnick-owned grant to the tailnet policy so the guest reaches only Varnick's guest port and the shared tab's proxied ports, not every port, Remote Login included. The policy is read with its ETag, validated, shown as a diff the first time, and saved with If-Match. The guest's Varnick, with the guest's own key, can turn on MagicDNS and allow their own login to reach the shared Mac. The guest then opens the tab whole, as a paired Mac opens a host's tab: live screens, file panes, web and app panes, and nothing else. They can't type, take over or change the layout. The host's Phone page server is the guest's only door, the relay scopes every request to the shared tab, and the guest interface is versioned apart from the peer protocol. Without a key, Varnick shows the policy snippet and the admin-console steps instead. Behind a Tab sharing switch in Settings › Experimental. Recommended, with option 02 (typing) only after this is in use. Rough effort is a spike of a day and a half on throwaway test tailnets, then about fourteen days.
status: proposed
---

## Solution

### Who a guest is

- **A person.** A guest is another person, running their own Varnick, to whom this Mac is shared through Tailscale's machine sharing. Any of their devices that reach this Mac through the share counts.
- **Not a peer or a device.** A guest is never added to the peer list or the device list, never reaches the relay over SSH, and never sees the Phone page.
- **How the host knows one.** `whois` on a guest's connection gives their node, with `Hostinfo.ShareeNode` set, and a user profile with a login name, a display name and an id. The guest test keys on `ShareeNode` alone.
- **What isn't a guest.** A node whose `Sharer` is set is the opposite case: another person's machine shared into this tailnet. It is quarantined and can't start connections. It is never a guest.
- **What changes in the code.** Today the page's checks and `PeerDevice.mayBeListed` refuse both kinds. The device rule stays as it is; the guest rule is new beside it.
- **How the host names them.** By the login `whois` reports, never by the email an invite was sent to: an emailed invite can be accepted by any account.

### Tailscale's machine sharing, as researched

From Tailscale's documentation, API reference and source, read by a research agent for this option. Not tried here. The spike checks the points marked.

- **Visible and one-way.** A shared machine is visible only to the person who accepted it. Sharing is one-way: the shared machine is quarantined in the guest's tailnet and can't start a connection to the guest.
- **Reach.** By default a guest reaches every port of the Mac, macOS Remote Login included. The owner's policy can narrow that with a grant whose source is `autogroup:shared` (or the guest's login), whose destination is this Mac, and whose ports are Varnick's. One Tailscale page contradicts this; the spike tests it.
- **Remote Login is the exposure.** Tailscale SSH on macOS runs only with the open-source tailscaled, so it hardly matters.
- **Serve.** `tailscale serve` forwards a guest's request with `X-Forwarded-For` and the identity headers, as it does a device's.
- **Names.**
  - The guest must use the Mac's full MagicDNS name (the machine's name, then the owner's tailnet's), which needs MagicDNS on in the guest's tailnet.
  - The Mac's IPv4 can differ in the guest's tailnet, so an address is never passed from one side to the other.
  - The guest's Varnick tells a shared-in Mac by its name's suffix differing from its own tailnet's.
- **What the guest learns.** The guest sees the owner's tailnet name, and the owner's account as the machine's owner. That can't be avoided, and the share sheet says so.
- **Invites.**
  - An invite goes by email or as a link, single-use or reusable.
  - An unused invite expires after 30 days. An accepted share never expires.
  - Both people must be an Owner, Admin or IT admin of their own tailnet.
  - A tagged device can't use a share.
  - With Tailnet Lock on, the shared node needs a signature in the guest's tailnet.
  - Whether a guest can share the machine on is unknown (the spike).
- **Cost.** Sharing is on every plan, and guests don't count as users.

### Varnick sets up Tailscale, with the user's OK

**The key.** Each side gives Varnick one personal Tailscale API key, entered once in Settings › Experimental under the switch. It is the only credential Varnick uses for Tailscale, for everything: invites, the policy, revocation and, on the guest's side, DNS (the user's decision: a single thing).
- **What it can do.** It acts as the user, with everything they can do in their tailnet. Settings says so plainly beside the field. Varnick uses it only for the calls below.
- **Kept in the Keychain** under Varnick's service name, as API keys are. It is never logged, committed, put on a command line or in an environment, or shown again.
- **It expires within 90 days.**
  - **Settings shows the expiry date,** read from Tailscale where the API gives it, else asked when the key is saved.
  - **Warnings.** Settings and the share sheet warn 7 days ahead.
  - **What lapses with it:** new invites, new shares and changes to the port rule. Shares already running keep working, since admission never depends on the key. A pane added to a shared tab after it lapses stays on its card for the guest, saying the port couldn't be allowed.
  - **Renewal** is pasting a new key.
- **Refused or expired.** The next call that needs the key fails once, with "Tailscale didn't accept Varnick's key: <reason>", and Varnick makes no further Tailscale call until a new key is saved.
- **No key.** The share sheet shows the copy-paste fallback instead:
  - make the invite in Tailscale's admin console, with the steps;
  - paste the policy snippet into the tailnet policy: the grant with the Mac's address in the owner's tailnet, the guest's login and the ports, as text to copy.

  Varnick then only checks, by `whois`, that the guest arrives.

**On the owner's side.**
- **The invite.** "Share this tab with…" offers New invite.
  - **Making it.** Varnick creates a single-use invite for this Mac's device through the device-invites endpoint, optionally sent by Tailscale to an email the user types. It shows the link to copy.
  - **Its state.** Pending invites are listed with Revoke, which deletes them. Once the invite is accepted and the person connects, the sheet lists them by their login.
  - **Revoking an accepted share.** Whether deleting an accepted invite also removes the share is a spike finding. If it doesn't, Varnick says the share stays and links to the admin console's sharing page.
- **The port rule.** Varnick keeps one block in the tailnet policy that is Varnick's.
  - **The block.** A single grant between two marker comments that name it as Varnick's and say edits inside are replaced: source the logins of the people with a live share on this Mac, destination this Mac's address in the owner's tailnet, ports Varnick's guest port (8444) and the shared tabs' proxied ports.
  - **Per Mac.** Each Mac that shares keeps its own block, named by the Mac.
  - **One block, not a rewrite.** Tailscale's API has no call that edits part of a policy (the spike confirms), so the edit is text: the marked block is replaced, or inserted at the top of the `grants` list (created if there is none), and nothing else is touched. HuJSON comments and the user's rules stay byte for byte.
- **Narrowing needs nothing broader.** A grant only adds access, so it narrows the guest only when no other rule lets shared users reach this Mac. Before saving, Varnick asks Tailscale's policy preview what a guest would reach (the spike checks that preview answers for a shared user).
  - **The default allow-all rule** admits everyone. Varnick offers to rewrite that one rule's source to the tailnet's own members and tagged devices, as a change to the user's own rule, shown in the diff.
  - **Any other rule** that admits shared users, Varnick names and leaves alone.
  - **Until the guest's reach is narrowed,** the share sheet refuses with the reason. The only way past is an explicit "Share anyway: Sam can reach every port of this Mac, Remote Login included".
- **Editing safely, every time:**
  1. Read the policy as HuJSON, with its ETag.
  2. Make the edit.
  3. Validate it with Tailscale's validate endpoint.
  4. The first time, and whenever the edit touches anything outside Varnick's block, show the diff and wait for the user's OK.
  5. Save it with If-Match on that ETag.

  A validation error or an ETag that no longer matches saves nothing, and says so: "Your tailnet policy changed while Varnick was editing it; nothing was saved. Try again." Varnick never retries a write by itself.
- **Kept in step.** The block follows the shares: a person's login leaves it when their last share on this Mac ends, a port when no shared pane uses it, and the block itself when the last share ends.
  - **When it writes.** Changes inside the block after the first OK are written without asking, at most once a minute, and Settings shows the last write and its result.
  - **Turning the switch off** makes one last write that removes the block, then no call. If that write fails, Settings says the block is still there and shows how to remove it by hand.

**On the guest's side.**
- **MagicDNS.** If the guest's tailnet has it off, the Mac can't be reached by name. With the guest's own key, Varnick offers to turn it on through the DNS preferences endpoint. It says first that this turns MagicDNS on for their whole tailnet.
- **Their own policy.** If the guest's own policy keeps their devices from the shared Mac (Varnick asks its preview), Varnick offers a marked grant in their policy, by the same safe edit: their login, the shared Mac's address in their tailnet, all ports, since the owner's side does the narrowing.
- **What Varnick can't do.** It can't make the guest an admin. Accepting a share needs them to be an Owner, Admin or IT admin of their tailnet. The empty state of "Shared with you" says so, and also that a tagged device can't use a share and that Tailnet Lock needs the shared node signed.

**What Varnick sends to Tailscale's API.**
- The policy file, read whole and written back whole with Varnick's block, and validated.
- This Mac's device id, for invites, with an email only if the user typed one.
- The DNS preference, on the guest's side.
- The key, in each request.

Nothing about tabs, panes, sessions or their content goes. The policy text is held in memory for the edit and never written to disk or logged. The privacy doc gets this list.

### Sharing a tab

- **What can be shared.** One tab whose host is this Mac, whole: its layout, every pane, and the panes added to it later. A view of another machine's tab can't be shared from here, only from its host.
- **Starting.** `!share` on the tab shown opens the share sheet in the panel.
  - **Who.** The people whose devices reach this Mac through a Tailscale share, by the login `whois` reports, with their devices under it. Pending invites sit below, and New invite above.
  - **Network status.** One line says what Tailscale lets them reach: "Tailscale lets Sam reach only Varnick on this Mac", or the reason it can't yet.
  - **Then** the user ticks one or more people and presses Share.
- **What the sheet says first:** "Sam can watch this tab: every pane's screen as it changes, the text of its file panes, its web and app panes (any page of those servers, not only the one shown) and the addresses of its web pages. Sam can't type, take over, change the tab or see your other tabs. Panes you add to this tab are shared too. Sam also sees your tailnet's name, and your Tailscale account as this Mac's owner."
- **When something is missing,** the sheet says what and refuses:
  - the Phone page server isn't serving;
  - Keep sessions running is off (the live screen reads zmx);
  - this Mac is tagged;
  - Tailscale doesn't answer.

  Web and app panes without Tailscale's operator setting stay on their cards for the guest, as for a paired Mac, and the sheet says so.
- **Stopping.** Any one of these ends the share at once:
  - Stop sharing in the tab's sharing bar or in the status menu;
  - `!share` on a shared tab, which offers Stop sharing;
  - closing the tab, or Done;
  - turning the switch off, which ends every share.

  The person's login leaves the port rule with their last share, so with the rule in force they reach nothing on this Mac. Varnick then offers to revoke their Tailscale share. It defaults to keeping it when the rule narrows them to nothing, and to revoking it when it doesn't.
- **Lasting.** A share lasts until it is stopped. It survives a restart of Varnick, since the page server and the shares file outlive it, and the indicator is back at launch.

### The indicator ("you're sharing")

- **In the tab:** a slim bar across its top, "Shared with Sam · watching now" or "· not watching", with Stop sharing. "Watching" means the guest has at least one live screen or proxied page open, which the page server reports.
- **In the tab strip:** a sharing mark on the tab.
- **In the status menu:** a line per shared tab, "Sharing <tab> with Sam", whose action is Stop sharing, above the usual items as notices are.

### What the guest sees

- **Adding the Mac.** In Settings › Peers, a "Shared with you" section lists the machines in this Mac's `tailscale status` whose name ends in another tailnet's suffix, and Add takes one, by its full name.
  - That is the only way a shared Mac is ever contacted, as Find Macs and Add are for peers.
  - A shared Mac that shares nothing with the guest says so on its row.
  - **When none is listed,** the empty state says what a share needs: an accepted invite, MagicDNS on (with the offer above), being an admin of their tailnet, a device that isn't tagged, and Tailnet Lock's signature.
- **The tab.** The session list shows each tab shared with the guest under a header "Shared by <the host's name>", as a paired Mac's tabs are listed. ↩ opens it whole in the host's layout:
  - Claude and terminal panes on their cards with the live screen, under "Watching <host>";
  - file panes with their text;
  - web and app panes through the host's port proxy, as for a paired Mac;
  - the Transcript as a plain card saying it stays on its Mac.
- **What it doesn't offer.** No Take over, no Start or Reconnect that starts anything, no split, divider, rename or file tree ("Only <host> changes this tab"), and no Done. ⌘W closes the view on the guest's Mac and tells the host nothing.
- **Where it doesn't appear.** A shared tab is never a board card and never in Recent, search or Completed.
- **When the share stops,** the next listing lacks the tab, the view closes, and a line says "<host> stopped sharing <tab>".

### What the guest never reaches

- **Other ports of the Mac.** With the port rule in force, Tailscale itself drops everything but Varnick's guest port and the shared tabs' proxied ports: Remote Login, other servers on the Mac, other panes' ports.
- **Other tabs.** The relay lists only the tabs shared with them, and refuses `status`, `watch` and `file` for any pane outside those tabs.
- **Other panes' ports, again.** The port proxy admits a guest only on the ports of the shared tabs' web and app panes, and there only GET, HEAD and websocket upgrades.
- **The Phone page.** Its files and `/api/*` answer a guest 403 with a note to open Varnick. A guest has only the guest routes.
- **Settings and everything else the relay answers:** projects, agents, apps, hosts, Recent, the search sync, starts, ends, done marks, arranging, upgrades and restarts.
- **SSH.** Varnick never adds a guest's key or a peer entry for them, and the port rule keeps Remote Login out of reach.

### How a guest differs from a paired Mac

| | Paired Mac | Guest |
|---|---|---|
| Whose | the user's own | another person's |
| Way in | SSH with the user's keys: a shell | HTTPS to the Phone page server over the tailnet, through Tailscale's machine sharing |
| Network reach | the user's own tailnet | Varnick's guest port and the shared tabs' proxied ports, by Varnick's grant |
| Who it is | the `by` it names; the SSH login is the credential | `tailscale whois` of the connection: `ShareeNode` set, and a login with a share |
| Sees | every open tab, Recent, search, projects, agents, apps, builds | only the tabs shared with them, while shared |
| Does | take over, type, split, rename, close, reopen, start, upgrade, restart | watches (option 02 adds take over and type) |
| Listed | mutual pairing | the host invites and shares per tab; the guest adds the host |
| Protocol | the peer protocol, one version on every machine | a guest interface with its own version, read across builds |
| Port proxy | every proxied port, every method | the shared tabs' ports, GET, HEAD and websockets |
| Board, Recent, search | yes | no |

## Trade-offs

- **Tailscale is the identity.** No key, link or password of Varnick's own: who calls is what `whois` says, unforgeable on the tailnet. In exchange the guest needs Tailscale, an admin role in their own tailnet and MagicDNS on.
- **The network door is narrowed, not just Varnick's.** Without the port rule a guest reaches every port of the Mac, Remote Login included. With it, Tailscale drops everything else before it reaches the Mac. Varnick refuses to share until that holds, unless the user explicitly shares anyway.
- **Varnick edits the user's tailnet policy.** Only its marked block, and the default allow-all rule if the user OKs it in a diff. It reads before writing, validates and saves with If-Match, so it never writes over someone else's edit. A policy shared with other admins sees Varnick's block, and the marker says what it is.
- **Varnick holds a powerful key.** A personal API key acts as the user, with everything they can do in their tailnet, for as long as it lives (90 days at most), kept in the Keychain. One key is simpler than a set of narrow ones, which is the user's choice. Settings says what it can do and when it expires.
- **The guest learns the owner's tailnet name and account.** Tailscale shows them, and the sheet says so before anything is shared.
- **An accepted share never expires in Tailscale.** Varnick's rule is what makes a finished share inert, and Varnick offers to revoke it.
- **Screens never pass through a third party in clear.** The live screen goes over the tailnet, end to end, as for a paired Mac.
- **Watching only keeps the blast radius to what is shown.** The guest reads screens (which can show secrets, as any screen share does), the tab's files shown in panes, and the tab's web and app servers. Typing would hand them the account (option 02).
- **A web or app pane is shared whole.** The guest can open any page of its server, not only the one shown, and a websocket can carry whatever the app accepts. For Scratch that would include every pane's scratch area in the project, which the narrowing below closes.
- **A second transport on the guest's side.** The guest's Varnick reaches a shared Mac over HTTPS where it reaches peers over SSH, behind the one seam that already sends every peer request.
- **No peer protocol bump.** The relay learns a new kind of asker from a file, and no request or reply changes shape. Every machine keeps its own commit.
- **Loopback mode stays weak.** On a Mac whose page server runs on loopback, a local process can already pose as a listed device, which reaches more than a guest does. Sharing is not refused there, and the sheet carries the page's own loopback note.
- **Alternatives considered:**
  - The guest as a peer over SSH with a forced command: it reuses every peer path, but puts another person's key in the user's account and trusts `by` from a channel that is a shell.
  - Carrying guests over the public-link relay of option 04: no Tailscale needed, but every screen and keystroke would cross Cloudflare in clear, and identity would rest on a token. That is under Later.
  - Leaving Tailscale's setup to the user by hand: it is the fallback without a key. The user chose Varnick doing it, with their OK, for the first build.

## User Stories

1. As the user, I want to share one tab with a colleague who runs Varnick, so that they can watch my Claude sessions, terminals and pages without a call.
2. As the user, I want Varnick to make the Tailscale invite and limit what the guest can reach on my Mac, after showing me what it will change, so that I don't edit my tailnet policy by hand.
3. As the user, I want Varnick never to save a policy change that fails validation or that would write over someone else's edit.
4. As the user without a Tailscale key in Varnick, I want the steps to make the invite in the console and the policy snippet to paste.
5. As the user, I want to be told exactly what they will be able to see before I share, my tailnet's name and account included.
6. As the user, I want sharing refused while the guest could still reach every port of my Mac, unless I say otherwise.
7. As the user, I want a bar in the shared tab, a mark on it and a line in the status menu while it is shared, so that I never forget it is open.
8. As the user, I want to see whether they are watching right now.
9. As the user, I want to stop sharing from the tab, from the status menu or by closing the tab, have it end at once, and have their network access go with it.
10. As the user, I want panes I add to the shared tab to be shared too, their ports included.
11. As the user, I want the guest unable to reach my other tabs, other apps' ports, my Phone page, my settings, my search or my Mac's other services, whatever they send.
12. As the user, I want to see when my Tailscale key expires, be warned ahead, know what stops working when it lapses, and renew it by pasting a new one, with running shares unaffected.
13. As the guest, I want Varnick to tell me what my tailnet needs (MagicDNS, my role), and to turn MagicDNS on for me if I say so.
14. As the guest, I want to add the shared Mac once and see what it shares with me in my session list.
15. As the guest, I want to open a shared tab whole, in its layout, with live screens and working Scratch and web panes.
16. As the guest, I want to be told when the share stops.
17. As either of us on a different Varnick build, I want sharing to keep working.
18. As the user with Tab sharing off, I want no guest admitted, no shared Mac contacted, no Tailscale API call and nothing of it in the UI.

## Implementation Decisions

### The switch

- **Settings › Experimental › Tab sharing,** off by default, one switch for both roles, as Problems board and Outline are. The Tailscale key, its expiry and the last policy write show under it while it is on.
- **Off, on the host:**
  - no `!share`, no sharing bar, mark or menu line;
  - no Tailscale API call after the last write that removes Varnick's block;
  - Varnick deletes the shares file when the switch goes off and at each launch while it is off, so the relay and the page server admit nobody;
  - the page server's guest routes then answer 404.
- **Off, on the guest's side:** no "Shared with you" section, no request to any shared Mac, no Tailscale API call, and any shared tab open closes. The list of shared Macs is kept for when it comes back on.

### The shares file (host)

- **Where.** One file in Varnick's support folder, owner-only, written only by the running Varnick, as the device file is.
- **What it holds.**
  - The guests: a lowercase UUID made the first time a person is shared with (the id in `by`), their Tailscale login, display name and user id, and the nodes seen for them.
  - The shares: a tab id and the guest ids, with when it began.
  - The pending invites Varnick made, by id.
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

- **Who is a guest.** `whois` on the caller gives a node with `Hostinfo.ShareeNode` set whose user is a guest in the shares file. That caller gets the guest routes and nothing else, with `by` set by the server alone, as for a device. A node with `Sharer` set is refused, as today.
- **The guest routes:**
  - a hello that names the guest interface's version and the host's name;
  - the shared tabs;
  - a file pane's text;
  - the panes' `status`;
  - the live-screen websocket the phone already uses, admitted for a guest.

  Each guest has its own caps on relay runs and open screens: enough for every pane of a tab at once, about eight.
- **No browser can call them.** They answer only a request that carries Varnick's own header and no `Sec-Fetch-Site`. A page open on the guest's Mac can't send the header without a preflight, which is never answered.
- **The guest interface has its own version.** Its shapes are the relay's tab and pane shapes, which only ever gain optional fields and send kinds and turns as words. The guest's Varnick refuses only a major version it doesn't know. A peer protocol bump doesn't change it.
- **Its status file** reports who is watching, per guest and tab, for the sharing bar, and the proxied ports of shared tabs, for the port rule, as the port proxy's status file reports ports.

### The port proxy (host)

- **Who it admits.** A guest node, for a port that belongs to a web or app pane of a tab shared with that guest (the proxy already maps ports to panes from the host's `tabs`).
- **What it lets through.** GET, HEAD and websocket upgrades, under the existing `Sec-Fetch` rules.
- **Ending.** A guest whose share stops loses their open sockets at the next look, as a removed device does.

### Scratch's own reach

- **The narrowing.** Scratch's Vite allows browsers only its own area, the packages it serves and Vite's client, instead of the whole scratch root and the app's folder.
- **What it no longer serves.** Dotfiles in the area, `.vite.log` among them.
- **Why here.** It matters to anyone who loads a Scratch from afar: a paired Mac, a device and now a guest. Option 04 relies on the same narrowing, and whichever option is built first makes it.

### Tailscale's API (both sides)

- **One small client in the app,** off the main actor with a deadline, as every network call is.
  - The tailnet is named `-` (the key's own).
  - It speaks only the calls above: the policy read, validate, preview and write; the device invites; the DNS preferences.
- **The policy edit is pure text logic with tests:**
  - find Varnick's markers, or the `grants` list, by a small HuJSON scanner that knows comments and strings;
  - replace or insert the block;
  - make the allow-all rewrite.

  It never reformats anything outside what it changes. A policy it can't scan is refused, not guessed at.
- **The diff** shown for the OK is the lines removed and added, with a few lines of context.
- **Every write** is read, edit, validate, then save with If-Match. A 412 or a validation error saves nothing, and Varnick shows the reason.
- **No key, an expired one or a refused one** stops all calls until a new one is saved, and the sheet shows the fallback.

### The guest's Varnick

- **Shared Macs** are a list of their own in UserDefaults (an id, the name, the full tailnet name), never the peer list. So nothing a shared Mac sends is ever answered as a peer's.
- **Found by name.** A shared-in Mac is told by its name's suffix differing from this tailnet's, and is always reached by its full name, never by an address.
- **One seam, two ways.** The peer manager already sends every request and opens every live screen for a host. For a shared Mac it does both over HTTPS to the page server's guest routes and websocket, and the existing host tab code shows the result.
- **Read-only.** Every control path refuses for a shared Mac's tab with "Only <host> changes this tab" (the lock a viewer already has), Take over isn't drawn, and ⌘W closes the view without sending anything.
- **Proxied pages** load only at the shared Mac's own full tailnet name, as for a paired Mac.
- **What is saved.** A shared tab open here is saved as another host's tab is, and is dropped at launch when its Mac no longer lists it.

### The spike (first ticket)

- **Where it runs.** On two throwaway test tailnets made for it, one for the owner and one for the guest, each with its own test account, and a test Mac shared from one to the other. Never on the user's real tailnet without the user's approval, given for that run.
- **What it records:**
  - how the guest's nodes look in the owner's `status` and `whois` (`ShareeNode`, `Sharer`, the profile), and whether the login and user id stay the same across reconnects and devices;
  - whether serve on 8444 and a proxy port answer a guest, with `X-Forwarded-For`;
  - the owner's name and certificate as the guest's Mac resolves them with MagicDNS on and off;
  - which ports the guest reaches with no grant, with Varnick's grant under the default allow-all, and with the allow-all rewritten, by the guest's login and by `autogroup:shared`;
  - whether policy preview answers for a shared user;
  - **the key:** that a personal API key makes invites, reads, validates and writes the policy and sets the DNS preferences, and whether the API gives its expiry date;
  - **the invites:** that creating, listing and deleting them works, and whether deleting an accepted invite removes the share;
  - **the ETag:** that a save with a stale ETag answers 412 and saves nothing, and that comments survive a read and write unchanged;
  - whether a guest can share the machine on.
- **Where the findings go.** Real names, logins, addresses and keys go in the problem's scratch folder, never in the repository. The test tailnets and keys are deleted afterwards.

### Recorded

- An ADR once accepted: a caller from outside the user's tailnet, which amends ADR 0011's and ADR 0035's "only the user's own nodes", and Varnick editing the tailnet policy through Tailscale's API.
- CONTEXT.md gains **Guest**.
- `docs/privacy-and-security.md` gains what Varnick sends to Tailscale's API and what a guest can reach. `docs/agents/where-it-breaks.md` gains the guest rules and the policy edit's rules.

## Testing Decisions

- **The policy edit, as pure functions with fixtures:**
  - insert into a policy with `grants`, with only `acls`, and with neither;
  - replace an existing block;
  - remove the block, and with it the markers;
  - comments, trailing commas and the user's rules byte for byte the same outside the block;
  - the allow-all rewrite only on the default rule's exact shape;
  - a policy the scanner can't read is refused;
  - markers that appear twice are refused.
- **The API client against a fake server:**
  - a 412 saves nothing and reports;
  - a validation error saves nothing;
  - 401 stops further calls;
  - no write happens without a first OK;
  - a write inside the block after the OK needs none, and is at most one a minute.
- **`bun test` in the page server:**
  - a `ShareeNode` node of a listed guest gets the guest routes;
  - a `ShareeNode` node of anyone else and a `Sharer` node get 403;
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
- **By hand, after a restart, on the spike's test tailnets:**
  - invite from Varnick, accept as the guest, approve the diff, and check from the guest that only Varnick's ports answer;
  - share a tab of a Claude pane, a terminal, a file and a Scratch, and watch it from the guest's Mac;
  - type on the host and see it on the guest's card;
  - split on the host and see the new pane arrive, its port added to the rule;
  - try every refused path from the guest;
  - Stop sharing, and see the guest's view close, their proxied page lose its socket and their login leave the rule;
  - expire or remove the key and check what lapses, then the fallback;
  - turn the switch off on each side and check that the block is gone, nothing of it shows and the shares file is gone.
- **Checks never run from a Claude session's own process.** No daemon or launchd change is involved, but a server started for a check runs in a pane.

## Out of Scope

- Typing, taking over and changing the layout (option 02).
- A file tree for guests (`files` stays for listed Macs).
- An expiry on a share.
- Narrower credentials, such as an OAuth client scoped to the policy and DNS (Later; the user chose one key).
- Guests without Tailscale, a browser viewer, a headless host's tabs (problem › Later).

## Further Notes

- **Build order with the Phone page work.** `phone-page-is-only-a-browser-tab` options 01 and 02 change the same server. This option needs no peer protocol bump, so it doesn't take part in the bump to 27 for the Esc mark. Whichever lands second rebases the server's routing.
- **Why a person and not a device.** The user shares with someone, not with a laptop. The rule's source is their login, so a share they pass on (if the spike finds they can) doesn't match it. If logins can't be a grant's source, the rule falls back to `autogroup:shared`, and the sheet says that it then covers everyone this Mac is shared with.
- **Where the effort goes.** About eight days for the sharing itself and six for Tailscale's API: the client and the key, the policy edit with its diff, invites, and the guest's side and the fallback.
- **Recommendation.** Build this first, watch-only, and use it. Option 02 adds typing on top without undoing any of it, and option 03 adds window and screen video on the same door.
