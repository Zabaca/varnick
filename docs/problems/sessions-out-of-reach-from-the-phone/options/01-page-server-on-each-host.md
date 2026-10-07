---
problem: sessions-out-of-reach-from-the-phone
title: A small page server on each host, in front of that host's own relay
summary: Each host runs a Bun server, the phone page, on a Unix socket only the user can open, published on port 8444 of its MagicDNS name with `tailscale serve`, tailnet only. The page lists the host's sessions and Recent, starts and resumes sessions, shows the live view and carries the terminal, and does all of it through the host's own relay, run locally in the phone's name. The phone is a device in a new list beside the peers. It is identified by its tailnet node, has an id for the control and origin labels, and is never contacted. Launchy runs the server on a Mac, and a systemd user unit runs it on Linux.
status: accepted
---

## Solution

### The server

A small Bun server ships in Launchy's repo. On each host it listens on an owner-only Unix socket in Launchy's Application Support folder. It is published with `tailscale serve` on HTTPS port 8444, tailnet only, by Launchy on a Mac and by the installer on Linux (ADR 0011's note of 2026-10-06 has the rules). Nothing listens on TCP.

The server decides nothing about sessions. Every list and every action is a request to the host's own relay, run on the host with the phone's id as the asker. So the rules the relay and the host's Launchy enforce for a peer Mac hold for the phone as they are:
- one controller, through `launchy-control`;
- on `end`, the session ends or is released, by its `launchy-origin`;
- nothing is resumed by itself.

### The phone as a device

Each host keeps a list of the devices allowed to use its page, beside its peers. A device has three things:
- an id, a UUID like a peer's;
- the tailnet node it is;
- a name.

The server finds the calling node from the address serve forwards, through the local `tailscale whois`. It answers only a node that is listed and not tagged.

The relay and the running Launchy accept a listed device wherever they accept a listed peer, except for the search sync's requests. A device is never contacted: no hello, no SSH, no rows.

### The page

- **Home:** the host's open Claude sessions, with title, folder, agent and who is in control; its Recent; and New session. It links to the other hosts that serve the page.
- **Opening a session.** One this phone controls opens straight in the terminal. Any other opens on the live view with Take over, as a Mac's card does.
- **New session:** projects, most recent first; the agents of the chosen project; a big prompt box; Start.
- **Terminal:** xterm.js filling the screen, with a key bar and a compose box for typing to Claude.

### The terminal

The server carries a websocket to the relay's `attach`, which it runs in a pseudo-terminal of Bun's own at the phone's grid.

- **Taking control.** Take over is `attach` with take. The page sends it only right after the user pressed Take over, Start or Resume. A reconnect never takes.
- **Closing the tab ends only the phone's zmx client,** whether the user closed it or Android dropped it in the background.
  - The session keeps running, still labelled for the phone.
  - Every Mac shows "Last controlled on Pixel 8a" with Take over, as for a Mac whose link dropped.
- **End** on the page sends `end`, and the host decides. A session the phone started ends. Any other is released to the host.

### Install

- **On a Mac,** a setting turns the page on. Launchy then runs the server in zmx, under a fixed name the launch sweep leaves alone, as it runs app servers. So a Launchy restart doesn't drop the phone, and there is no LaunchAgent.
- **On Linux,** a systemd user unit, installed by the Ryzen's installer.
- **`tailscale serve`** is run by Launchy on a Mac and by the installer on Linux, for 8444 only (ADR 0011's note). Launchy's Settings says whether it is published.

## Trade-offs

- **Every rule stays the relay's.** There is no second implementation of take, end or release. The phone is one more id in labels Launchy already reads.
- **It works on Linux** with Bun and the relay, which a Linux host needs anyway. Bun is on the Ryzen, and nothing in the server is macOS-only.
- **Each host stands alone.** Any host that is up can be reached, with no hop through another Mac. But each host has its own address, linked from the others' pages, and the phone is added on each host.
- **No TCP listener, and no port clash:** a Unix socket behind serve. The Studio's and the Air's Tailscale can't serve a socket (Spike › Results), so those two run on loopback, with the existing browser terminal's weaker posture (below).
- **A new component to keep working:**
  - the Bun server;
  - xterm.js, pinned in the repo;
  - Bun's pseudo-terminal, which is new in Bun.
- **The phone stays in control after the tab closes.** Taking the session back at a Mac is one press of Take over, as after a lost link. Letting go on every disconnect instead would fire each time Android backgrounds the tab.
- **The protocol changes:**
  - devices are accepted as askers;
  - `status` and `sessions` replies carry the controller's name, so a Mac can say "Pixel 8a".
  - The version goes up.
- **Tailscale's serve settings change on each host,** by Launchy or the installer. They persist in Tailscale, outside Launchy.

## User Stories

1. As a user away from my desk, I want to open one address on my phone and see the Claude sessions running on my Mac Studio, so that I know what is going on there.
2. As a user, I want each session to say which Mac or phone is in control, and whether it still has the session open, so that I know whether taking it over interrupts anyone.
3. As a user, I want to watch a session live on the phone without taking it over, so that I can see whether Claude is waiting on me.
4. As a user, I want Take over on the phone to move control to the phone, so that I can answer Claude's question or permission prompt.
5. As a user at my Mac, I want a session my phone controls to show "Controlled on Pixel 8a" with Take over, so that I can take it back with one key.
6. As a user, I want the phone to rejoin the session by itself when I come back to the browser, but never take it back from a Mac that took it meanwhile, so that switching apps costs nothing and displaces nobody.
7. As a user, I want closing the tab to leave the session running, so that a closed tab never ends work.
8. As a user, I want End on the phone to end a session I started from the phone, and to hand any other back to its host still running, as closing a pane does on a Mac.
9. As a user, I want to start a session from the phone by tapping a project, optionally an agent, and typing or dictating a prompt, so that starting work takes little typing.
10. As a user, I want the project I used last, and the agent I used with it, preselected, so that the usual case is one tap and a prompt.
11. As a user, I want to resume a session from the host's Recent with one tap, so that I can carry on a finished conversation.
12. As a user, I want a session started from the phone to show on the host as a background tab, controlled on the phone, so that I find it at my desk.
13. As a user typing on the phone, I want keys for Esc, Tab, Shift+Tab, the arrows, Ctrl+C and Enter, and a box to write a whole message in before sending it, so that I can drive Claude Code with a soft keyboard.
14. As a user with a Linux host, I want the same page there, so that the Ryzen's sessions are as easy to reach as the Macs'.
15. As a user, I want only the devices I added on a host to use its page, nothing of it reachable off the tailnet, and other websites in my phone's browser unable to drive it.
16. As a user, I want to add my phone on a host by picking it from my tailnet's devices, so that I never type an id.
17. As a user, I want this installed without a LaunchAgent on my Macs, so that nothing is installed behind macOS's back.

## Implementation Decisions

### Devices

- **What a device is:** an id (a UUID, made when it is added), its tailnet node's stable id, and a name. The list is per host. The peer list doesn't change.
- **Where the list lives.** In a JSON file in Launchy's Application Support folder, owner-only, written by the running Launchy.
  - Not in UserDefaults, because the page server isn't Launchy and a Linux host has no Launchy app.
  - The relay reads it the way it reads the search database's path file.
  - On Linux it is edited by hand, or by whatever the Linux plan provides.
- **Adding and removing.** Settings › Peers gets a Devices section.
  - Add lists the tailnet's online devices that aren't tagged and aren't paired Macs, from `tailscale status --json`, which Find Macs already reads.
  - Remove takes a device off the list.
- **Who may ask.** The relay accepts a `by` that names a listed device wherever it accepts a listed peer, and so does the running Launchy for `start`, `resume` and `end`.
  - The search sync's requests stay for peers only: `rows`, and `pages` once `history-tied-to-one-mac` builds it.
  - A device never sends hello.
- **The launch sweep** spares a session labelled for a listed device, as it spares one labelled for a listed peer.
- **Names.**
  - The host names a device from its list, on its own card and in the session list.
  - `status` and `sessions` replies gain the controller's name, so a Mac with a pane for that session says "Controlled on Pixel 8a" rather than "another Mac".

### Who is calling

- **The address.** The server reads the caller's tailnet address from `X-Forwarded-For`, which serve sets. It looks the address up with the local `tailscale whois`, cached for a minute per address, and matches the node's stable id against the device list.
- **What isn't used.** Tagged nodes are refused. `Tailscale-User-Login` isn't used: it names the user, who is the same for the phone and every Mac.
- **An unlisted device** gets a page that says so, with its tailnet name and where to add it ("Add phone-1 in Launchy › Settings › Peers on Mac Studio"). It sees no sessions.
- **Why the address can be trusted.** Only because the server listens on a Unix socket that only the user can open.
  - On a host where it has to listen on loopback instead, any local process could claim to be the phone. That is the existing browser terminal's posture, which is acceptable on a single-user host.
  - The page says when it is in that mode.

### Requests and checks

- **Host.** Every request's `Host` must be the host's MagicDNS name with the port, or it is refused. That stops DNS rebinding through the loopback fallback.
- **Origin.**
  - Every request that changes something is a POST with a JSON body, and its `Origin` must be the page's own. Every websocket upgrade is checked the same way.
  - The server sends no CORS headers.
  - The phone's tailnet identity goes with every request its browser makes, so these checks are what keep another site open on the phone from driving the page.
- **No caching.** Replies are `no-store`, since they carry prompts and titles.
- **Names and text.**
  - Session names must be `launchy-<uuid>`.
  - Prompts and all other user text go to the relay inside its base64 JSON argument.
  - The relay is spawned with an argument list, never through a shell.
- **Logs** leave out prompts, titles and screens.

### The page

- **Home.**
  - Open sessions come from `sessions`, with who is in control and whether it has a client, named through the new field. Recent comes from `recent`.
  - Pull to refresh, and a refresh whenever the page becomes visible.
  - Links to the paired Macs' pages, from a list Launchy writes for the server (their MagicDNS names); on Linux, from the unit's configuration. A host that doesn't serve the page says so when the link is opened.
- **Opening a session.**
  - Labelled for this phone: straight to the terminal, attached without take.
  - Otherwise: the live view, once it is built, reading "Controlled on X" or "Last controlled on X", with Take over. With the host itself in control it reads "Controlled on Mac Studio".
- **New session.**
  - Projects come from `projects`, most recently used first, with a filter box. The last answer is kept on the phone and shown while a fresh one loads.
  - Agents come from `agents` for the chosen folder, shown as chips. None is picked by default, except the agent last used with that project.
  - The prompt box is large, focused on open, and takes dictation from the keyboard's microphone. Start works with an empty prompt, as on a Mac.
  - Start sends `start` with a new id the server picks, the folder, the agent and the prompt. Skip permissions is left unset, so it follows the host's setting. The terminal then opens with take, as a Mac's pane does after starting a session on a peer.
  - The host adds a background tab for the session, controlled on the phone, with the phone as its origin.
- **Resume.** A Recent row sends `resume` with a new id, and the terminal opens with take. The host refuses a conversation it has open in a running session. The page then offers that session's row instead, as a Mac does.
- **Terminal.**
  - xterm.js, pinned and kept in the repo with the server, sized to fill the screen at a readable font. Landscape works.
  - A key bar: Esc, Tab, Shift+Tab, ↑, ↓, ←, →, Ctrl+C and Enter.
  - A compose box: a native text field to write or dictate a whole message in. It is sent as a paste followed by Enter, so autocorrect and dictation work as in any app.
  - A header with the session's title and host, and End.
- **End** asks first, sends `end`, and says what the host did: "Ended", or "Handed back to Mac Studio, still running" when the reply says `released`.

### The terminal channel

- **One websocket per open terminal.**
  - Its first message names the session, the grid, and whether to take.
  - The server checks the device and the name, runs the relay's `attach` in a pseudo-terminal at that grid, and carries bytes both ways.
  - Resizes follow.
- **Take** is set by the page only right after the user pressed Take over, Start or Resume. A reconnect never sets it.
- **Closing.**
  - When the websocket closes, the server closes the pseudo-terminal. That ends the phone's zmx client and nothing else.
  - When the client exits instead, because another Mac took over or the session ended, the server closes the websocket with the reason it read from `status`.
- **Reconnecting.**
  - While the page is visible, a closed socket reconnects after 1, 2, 5 and 10 seconds, then every 30.
  - When the page becomes visible again, it reconnects at once.
  - Nothing is sent while the page is hidden.
- **Each reconnect asks `status` first:**
  - Labelled for this phone: it attaches without take, and zmx redraws the screen for the new client.
  - Labelled for another Mac or device, or for the host: the live view with Take over, saying "Taken over on X" once.
  - Gone: "Session ended", with Resume when Recent has the session.

### The live view on the phone

- **The channel.** The accepted `watch` channel, unchanged. The server runs the relay's `watch` for the device and forwards its frames over a websocket. The reader is registered like any other, so "Last controlled on" stays right.
- **Drawing.**
  - Each frame is drawn at its own grid in a read-only xterm.js, which takes no input and is never focused.
  - The frame is scaled to the phone's width, with pinch to zoom.
  - A Mac's wide grid is small text on a phone. Take over repaints the session at the phone's own grid.
- **When it runs:** only while the page is visible, as the user decided for the Macs. On return, the first frame is a fresh snapshot.
- **Until `watch` is built,** a session the phone doesn't control shows only its row, with Take over and no screen.

### Running the server

- **On a Mac.** A setting in Settings › Peers, Serve the phone page, off by default.
  - **When it's on,** Launchy runs the server in zmx, under a fixed name that isn't a pane's, so the launch sweep doesn't match it.
  - Its environment gives it the socket's path, the device file and the relay's link.
  - It survives Launchy restarting, as an app server does.
  - Launchy restarts it when the server's files differ from the ones it was started with, and ends it when the setting is turned off.
  - **Launchy publishes the port** (it was by hand until 2026-10-06; the rules are in ADR 0011's note), and Settings says Published, Publishing or why not.
- **On Linux.**
  - A systemd user unit, installed by the Ryzen's installer.
  - It sets `KillMode=process`, because the pseudo-terminals and their zmx clients are the server's children.
  - Linger must be on, as it is on the Ryzen.
  - The installer publishes 8444 to the unit's socket once the page answers (ADR 0011's note). Where the relay lives is for the Linux plan to say.
- **The port.**
  - 8444 on every host. 8443 on the Air and the Studio, and 443 on the Ryzen, are the existing browser terminal's.
  - A port of its own, rather than a path under the existing browser terminal's one, gives the page its own origin and needs no base path.
- **The fallback.** Where a host's tailscaled can't serve the socket, the server listens on a fixed port of 127.0.0.1 instead, with the same Host and Origin checks, and the page says it's in that mode. That is the case on the Studio and the Air (Spike › Results).
- **Funnel stays off.** Settings warns if 8444 isn't tailnet only, and nothing ever runs `tailscale funnel`.

### State and protocol

- **New state:**
  - the device file;
  - the list of the other hosts' pages, which Launchy writes for the server;
  - a setting in UserDefaults for the Mac's server, off by default.
- **`sessions.json` doesn't change.** A session started from the phone is an ordinary record on the host, with the device's id as its `origin`.
- **The protocol version goes up once,** for devices as askers and for the controller's name in `status` and `sessions` replies. If the live view's `watch` lands in the same release, one bump covers both.

### Scope and ticket order

1. **Devices:**
   - the device file, and Settings › Peers › Devices;
   - the relay and the app accepting a listed device, and the sweep sparing one;
   - names in the replies and on the card;
   - the protocol bump.
2. **The page server and home:**
   - the socket, the whois lookup, and the Host and Origin checks;
   - the home page with sessions and Recent;
   - the Mac setting that runs the server in zmx, and the serve status in Settings.
3. **The terminal:**
   - the websocket and pseudo-terminal bridge, taking only after a press, and the reconnect rules;
   - the key bar, the compose box and End.
4. **Starting and resuming:** projects, agents, the prompt and Start; Resume from Recent.
5. **The live view on the phone,** after `frozen-screen-not-live`'s tickets.
6. **Linux:** the unit and its instructions, after `sessions-hosted-only-on-macs`.

## Testing Decisions

### Pure seams for the first tests

There is no test target yet. These are the seams to test first:
- matching a whois answer to the device list, whether listed, unlisted or tagged;
- the Host and Origin check;
- what a reconnect does for a given `status`: attach, live view, or ended;
- the relay's check of who asks, with peers and devices.

### By hand

After `make build` and a restart the user does, on the Studio first.

**Setup and access**
- Turn the setting on: `zmx ls` lists the server's session. Settings shows Published, and `tailscale funnel status` shows 8444 as tailnet only.
- Before the phone is added: the page names the phone, says where to add it, and lists nothing. A Mac's browser that wasn't added gets the same.
- Once it's added: the Studio's sessions and Recent are listed, with who controls each.

**Control**
- On the phone, take over a session the Studio's own pane is typing in. The Studio's pane shows "Controlled on Pixel 8a". The Air, with a pane for it, says the same.
- Type in it:
  - a sentence with autocorrect;
  - dictation through the compose box;
  - Esc to interrupt Claude, Shift+Tab, and an arrow-key menu;
  - Ctrl+C.
- Switch apps for one minute, then for ten, and come back. The terminal is back, without take.
- Take over on the Studio while the phone is in another app. On return, the phone shows the live view and "Taken over on Mac Studio".
- Close the tab. The session runs on, the Studio shows "Last controlled on Pixel 8a", and Take over there works.

**Starting and ending**
- Start from the phone with a project, an agent and a prompt. A background tab opens on the Studio, controlled on the phone.
- End it on the phone. The session ends, the tab closes, and it is in Recent.
- Take over a session the Studio started, then End it on the phone. The page says "Handed back to Mac Studio", and the Studio's pane goes live.

**Robustness and security**
- Restart Launchy on the Studio while the phone is in a terminal. The terminal keeps working, since both the server and the session are in zmx.
- From another site in the phone's browser, a form POST and a websocket to the page's address are both refused. A throwaway page served on another port is enough.
- `tailscale funnel status` shows 8444 as tailnet only.

## Out of Scope

- Off-tailnet access, Funnel, and any login of Launchy's own.
- Notifications when a session waits on the user.
- Images from the phone.
- Panes other than Claude's.
- Adding the phone on every host at once. It is added on each host.

## Further Notes

### Recommendation

Recommended. It has the existing browser terminal's shape, which the user asked for, with Launchy's relay where the existing browser terminal's wrapper calls zmx. So every rule already written for Macs applies to the phone, and nothing in it is Mac-only. What it gives up is option 03's single address, and the links between the hosts' pages cover most of that.

### Considered within this option

- **ttyd for the terminal,** as the existing browser terminal uses it, with this server as its Picker. It is proven and on every host. Bun's pseudo-terminal keeps one process, and one place that decides who asks and what runs. ttyd is the fallback if spike step 2 fails. Against it:
  - ttyd takes its command's arguments from the URL, so a reconnect would repeat whatever the URL said, take included.
  - The device it serves would have to reach the wrapper some other way.
  - It adds a second process and listener per host.
  - Its page needs patching for a phone, as the existing browser terminal's was.
- **The relay binary as the server,** a Swift HTTP and websocket server in relay mode. Foundation on Linux has no server, Network.framework isn't on Linux, and Launchy takes no new dependencies. Bun has the server, the websockets and the pseudo-terminal, and is on every host.
- **Any untagged device of the user, instead of a list.** No setup, and the same boundary as the existing browser terminal, which already gives every device on the tailnet a shell on every host. The peer list's rule is "only what I added", and the device list keeps it (open question 2).
- **Tailscale app capabilities,** with `--accept-app-caps` and a grant in the tailnet policy, to say which devices may use the page. That moves the list into the tailnet policy, edited in Tailscale's admin console rather than in Launchy, and still needs the headers trusted. Worth it if a second person joins the tailnet.
- **A plain child process of Launchy for the server,** instead of zmx. Simpler, but every Launchy restart, frequent while it is being developed, would drop the phone's terminal. In zmx the server survives, as app servers do.
- **A path under the existing browser terminal's port** (`/launchy` on 8443). One fewer port, but the page would share an origin with the existing browser terminal, and ttyd's base-path rule shows what a prefix costs.
- **Letting go of control when the phone disconnects,** after a grace period. Open question 1.

### Risks

- **The Air's Tailscale and a Unix socket.** Its daemon is a system extension and can't use a socket: the Air runs the loopback fallback (Spike › Results).
- **Bun's pseudo-terminal is new.** Spike step 2 checks it with zmx, and ttyd is the fallback.
- **Typing on Android.** xterm.js and Gboard can disagree about composition and backspace, which is why the compose box is the main way to type. Spike step 3 shows how bad the bare terminal is.
- **The phone left in control.** After the phone was used, a Mac's pane needs Take over, even with the tab long closed (open question 1).
- **Each host's page is its own origin,** so what the phone remembers (the last project, cached lists) is kept per host.

### Verified and inferred

- **Verified,** read-only on 2026-10-05:
  - everything under Today in the problem;
  - the hosts' tools, ports and serve mounts;
  - that `Bun.Terminal` exists in Bun 1.3.14 on the Air and the Ryzen.
- **Inferred:**
  - what serve passes to the server, and that it replaces copies the browser sent;
  - that a Unix socket target works on the Studio and the Ryzen, whose tailscaled runs as root;
  - how Bun's pseudo-terminal behaves;
  - how Android treats a backgrounded tab.

### Records

Accepting this needs an ADR covering:
- a page server per host, behind `tailscale serve`;
- a second way in beside SSH, for the user's own devices, which changes ADR 0007's "No listening port" consequence for that one door;
- devices as controllers.

CONTEXT.md gains Device, and the page's name, through `/domain-modeling`. Its In control and Card entries speak of Macs only, and would cover devices too.

### Open questions

1. **When the tab closes, does the phone stay in control or let go?** Recommendation: stay in control, as a Mac whose link dropped does. The phone can't tell closing from backgrounding, so letting go would happen every time the tab is backgrounded, and the phone would have to take over again each time it comes back.
2. **Which devices may use the page:** a list per host, or every untagged device of the user? Recommendation: the list, like the peer list.
3. **Port 8444 on every host?** Recommendation: yes.
4. **The live view on a phone:** fit the width with pinch to zoom, or the Macs' rule of the whole grid however small? Recommendation: fit the width, since a Mac's whole grid is unreadable on a phone.
5. **The page's name in CONTEXT.md.** Recommendation: "Phone page".

### Spike

By hand. Nothing here touches Launchy's sessions or the existing browser terminal's mounts.

1. **What serve passes, and whether it reaches a Unix socket.** On the Studio, then on the Air, in Terminal.app:
   ```
   S="$HOME/Library/Application Support/Launchy/phone-spike.sock"; rm -f "$S"
   SOCK="$S" ~/.bun/bin/bun -e 'Bun.serve({ unix: process.env.SOCK, fetch: r => Response.json({ url: r.url, headers: Object.fromEntries(r.headers) }) })' &
   sleep 1; chmod 600 "$S"
   tailscale serve --bg --https=8449 "unix:$S"
   tailscale serve status
   ```
   - On the phone, open `https://<host>.example.ts.net:8449/`. Note `x-forwarded-for` (100.64.0.4 is expected), `tailscale-user-login` and `host`, and whether any header names the device.
   - From the other Mac, run `curl -s -H 'Tailscale-User-Login: forged' -H 'X-Forwarded-For: 1.2.3.4' https://<host>.example.ts.net:8449/`. Serve should have replaced both headers.
   - If the page doesn't load, note serve's error. On the Air, that means the loopback fallback there. If the cause is the space in the path, try a socket in a folder without one, and note that too.
   - Clean up with `tailscale serve --https=8449 off`, `kill %1` and `rm -f "$S"`. `tailscale serve status` should show only the existing browser terminal again.
2. **Bun's pseudo-terminal with zmx.** On the Studio, in Terminal.app, with a throwaway zmx folder:
   ```
   export ZMX_DIR=/tmp/zmx-phone-spike; mkdir -p "$ZMX_DIR"
   Z="$(dirname "$(readlink "$HOME/Library/Application Support/Launchy/launchy-peer")")/zmx"
   Z="$Z" ~/.bun/bin/bun -e '
     const p = Bun.spawn([process.env.Z, "attach", "spike"], { terminal: { cols: 48, rows: 30, data: (t, d) => process.stdout.write(d) } });
     setTimeout(() => p.terminal.write("stty size\r"), 1500);
     setTimeout(() => p.terminal.resize(60, 20), 3000);
     setTimeout(() => p.terminal.write("stty size\r"), 3500);
     setTimeout(() => p.terminal.close(), 5000);'
   "$Z" ls
   ```
   - Expected: `30 48`, then `20 60`. After the close, `zmx ls` lists `spike` with `clients=0`.
   - The `terminal` option follows Bun's documentation. If Bun refuses it, its error is the result.
   - Clean up with `"$Z" kill spike; rm -rf /tmp/zmx-phone-spike`.
3. **Typing on the phone.** The existing browser terminal is already on the Studio. On the phone, open `https://alexs-macbook-pro.example.ts.net:8443/`, open a session named `phonespike`, and run `claude` in it.
   - Type a sentence with Gboard, using autocorrect, swiping and the microphone. Try backspace, and Enter to send.
   - Note which of Esc, Tab, Shift+Tab, Ctrl+C and the arrows can be sent at all.
   - Switch to another app for one minute, then for ten, and come back. Note whether the terminal comes back by itself, how long it takes, and whether the screen is right.
   - Type `exit` to end the session.

#### Results, 2026-10-06

Run over SSH with a throwaway Bun server (`/tmp/phone-spike` on each host, its own `ZMX_DIR`, under `nohup`), on port 8449. The Studio's existing browser terminal mounts on 8443 were taken down first (decision 2). The phone test is the user's and still to come.

**Unix socket behind serve**
- **The Studio's Tailscale can't do it.** Homebrew's 1.92.2 refuses `unix:<path>` ("non-localhost target … must include a scheme"), and its daemon has no Unix-socket proxy at all. The Ryzen's 1.98.8 serves one, a path with a space included; the Air's 1.102.3 lists it in `--help`. So the Studio runs the loopback fallback until its Tailscale is upgraded, which the user decides. Settings' serve check has to tell "too old for a socket" from "not set up".
- **Over a socket, serve sends `Host: localhost`.** The browser's host comes only in `X-Forwarded-Host`, so the Host check reads that header on a socket and `Host` on loopback. Over loopback serve keeps the browser's `Host` and sets `X-Forwarded-Host` too.
- **Where the socket lives.** Bun has no mode for the socket, so it is chmodded after it is bound, and Launchy's Application Support folder is 0755. The socket belongs in an owner-only (0700) folder, which closes that window.
- **The Air's Tailscale can't serve a socket either** (ticket 04, 2026-10-06). Its 1.102.3 app accepts `serve --bg --https=8449 unix:<path>` without an error and `serve status` shows the mount, but every request answers 502 from serve and never reaches the server. The same server on loopback, published with `serve … http://127.0.0.1:<port>`, answered correctly, so the socket is the cause. It fails in `~/Library/Application Support/Launchy/phone-check/`, in a path with no space under the home folder, and in `/tmp`, so it isn't the space in "Application Support". So the Air runs the loopback fallback like the Studio, and Settings can't tell "works" from "doesn't" by `serve status` alone.

**What serve passes** (both modes, checked from the Air with curl)
- `X-Forwarded-For` is the caller's tailnet address. Serve replaces forged `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto` and `Tailscale-User-*`, and drops `Tailscale-App-Capabilities` (no `--accept-app-caps`).
- Identity is `Tailscale-User-Login`, `-Name` and `-Profile-Pic`, the same user for every device. No header names the device. `tailscale whois --json <ip>` works as the user, not root, on the Studio and the Ryzen, and gives the node's name, stable id and tags.
- `Origin` passes through untouched, so the Origin check works: a websocket with a foreign Origin was refused.
- Websockets work through serve, on a socket (the Ryzen) and on loopback (the Studio).

**Bun's pseudo-terminal with zmx** (the Studio and the Ryzen)
- `Bun.spawn([zmx, "attach", name], { terminal: { cols, rows, data } })` works as documented. `stty size` read `30 48`, then `20 60` after `terminal.resize(60, 20)`.
- `terminal.close()` ends only the zmx client (exit 129, SIGHUP). The session stays, `clients=0`, and a new client gets the screen redrawn.
- Through serve and a websocket, a page's input reached the shell, resizes followed, and closing the socket left the session running. Headless Chrome on the Air loaded the page, its xterm.js 6 modules ran, and the terminal attached at the fitted grid.
- A server started under `nohup` over SSH outlives the SSH session.

**Typing on the phone:** works. The user tested the page on the Pixel 8a (2026-10-06): Gboard typing, the key bar, paste, Claude in the terminal, coming back after switching apps, and rotation all worked.

## Decided by the user, 2026-10-05

1. **Option 01 is accepted.**
2. **The existing browser terminal can go.** The user doesn't use it (8443 on the Air and the Studio, 443 on the Ryzen), so its `tailscale serve` config may be taken down. That frees 8443 and 443 for the phone page and its spike. The port stays 8444 unless the user picks another. A credential proxy on these hosts keeps running.
3. **The open questions keep the planner's recommendations** until the user says otherwise:
   - the phone stays in control when the tab closes;
   - a device list per host decides who may use the page;
   - the live view fits the width, with pinch to zoom;
   - the page is called "Phone page" in CONTEXT.md.
4. **Sequenced after the Ryzen's relay** (sessions-hosted-only-on-macs option 01, ticket 2), so one page serves both kinds of host. Decision 2 already lets the Studio's existing browser terminal's `tailscale serve` come down.
