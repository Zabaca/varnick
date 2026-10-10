# Security

Varnick runs programs as you, on your Macs, and can reach them from your other Macs and your phone.
This note says who can make it do that, what each setting allows, and one known weakness. It
describes the code as it is; where a statement rests on a design decision, the decision is in
[`docs/adr/`](docs/adr/).

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this
repository, then **Report a vulnerability**. Please don't open a public issue or pull request for
a vulnerability. No email address is published for reports.

## Skip permissions

Settings › **Skip permissions** starts Claude sessions with `--dangerously-skip-permissions`. Claude
Code then runs its tools, including shell commands and file edits, without asking, in whatever folder the session is
in and as the account that runs Varnick. Anything that can steer a session, such as a web page
Claude reads, a file in the repository, or a prompt, can then act with the account's rights.

- **It is off for a new install.** A Mac that ran an earlier Varnick keeps Skip permissions on, or whatever
  it had stored, and can turn it off in Settings.
- **A peer's start request carries the peer's own choice.** When one Mac starts a session on another, the
  request says whether to skip permissions, and the host follows it, whatever its own setting says. A
  peer you list already reaches the host's account over SSH, so this grants nothing SSH doesn't. The
  Linux relay's own default, for a session that doesn't say, is off.
- The Phone page can start sessions on its host too, through the host's relay, and its sessions follow
  the host's setting.

## Peers over SSH

Peers pair over SSH, with your own keys (ADR 0007). The boundary is:

- **The peer list.** A request other than `hello` is answered only to a Mac the receiver lists, and a Mac
  that isn't listed is never contacted, except by Find Macs and Add, which you start. The request names the
  Mac asking, and the list is checked against that name; the name is not a credential, the SSH login is.
- **The SSH keys.** Varnick runs the relay with `ssh` as the account you gave, with no password prompts
  (`BatchMode`) and a host key accepted on first contact and refused if it later changes. Whoever holds a key
  that logs in as that account can run the relay, and can do anything that account can do anyway.
- **The relay runs as you.** It is Varnick's own binary (or `varnick-peer` on a headless host) running as the
  account the SSH key logs in as, with that account's files and tools. It listens on no network port. On a
  Mac it talks to the running app through a socket that only the account can use.

Between paired Macs, two things are copied to each other, for Recent and search:

- **Your Claude prompts**, with each session's folder, title and agent and the last thing Claude wrote after each.
- **Your browsing-history archive**: full page addresses, titles, the names of your Chrome profiles, visit
  counts and last visits, the terms you searched, and each page's description. It is the sender's whole
  archive, sent in pieces.

The receiving Mac stores both in its own database until the Mac is removed from its peer list (or removes
it). Pair only Macs you would show that history to.

## The Phone page

The Phone page is a small web server that serves a host's sessions to your own devices.

- **It is off by default.** On a Mac, Settings › Serve the phone page turns it on. On a headless host, the
  installer's `--page` does.
- **It is published only with `tailscale serve`, to your tailnet** on HTTPS port 8444. Varnick and the
  installer never run `tailscale funnel`, and refuse to publish if Funnel is on for that port or its state
  can't be read.
- **Who is calling comes from Tailscale.** The server takes the first address in the `X-Forwarded-For` header
  that `tailscale serve` adds, asks Tailscale who owns that address (`tailscale whois`), and serves the page
  only to a device you listed on that host, by its tailnet node. Everything the page does is a request to the
  host's own relay, as that device. Changes need a `POST` with a matching `Origin`, and websockets are
  checked against it.
- **A listed device can do most of what a Mac peer can,** except the search sync, upgrades and restarts
  (those are for a listed Mac only): list sessions, start one in a project the host lists, take over and
  type in a terminal. Only list devices you control.

### Loopback mode is weaker. This is a known issue, to be fixed later

The server listens in one of two modes:

- **Socket mode:** on a Unix socket in a folder only your account can enter, so only your account can send it
  a request, and only `tailscale serve` does.
- **Loopback mode:** on `127.0.0.1:18444`. Any process on the Mac can connect to it, other user accounts on
  the Mac included, and can send an `X-Forwarded-For` header naming a listed device's tailnet address,
  the `Host` and `Origin` the page expects, and the rest. The server then treats the request as that device
  and answers it. A local process can pose as a listed device, start and drive sessions, and so get a
  shell as the account that runs Varnick. The tailnet's addresses and the page's name aren't secrets.

Varnick falls back to loopback when it can't serve a socket, for one of these reasons:

- **The Tailscale app's own command line** can't serve one.
- **An older standalone command line** can't.
- **No Tailscale command line was found**, or the one found didn't answer.
- **The Tailscale daemon refuses a socket to a user who isn't root** (the case for Homebrew's).

Settings names the reason when the page is on loopback, and the page itself shows a "Loopback mode" note.

Advice, until loopback mode is fixed:

- Use socket mode, by the remedy for the reason Settings names:
  - a refused socket: press **Use a socket** in Settings (the button shows only for this reason), and see
    ADR 0011 for the fix outside Varnick for a Homebrew-installed Tailscale daemon;
  - the Tailscale app's command line: updating the app does not help. Varnick uses the app's command line
    whenever the app is installed, so a standalone command line (such as Homebrew's) takes over only on a Mac
    without the app;
  - an older command line: install a newer one;
  - no command line found or none answering: install one where Varnick looks (the README lists the places).
- Or don't serve the page on a Mac that other people have accounts on, or run programs you don't trust.
- On a headless host the page always uses a socket.

### The administrator prompt

When Tailscale refuses to serve a socket to your user, **Use a socket** (and only that button) tries once
more with `tailscale serve` run as root through macOS's password prompt. It is the one place Varnick asks
for your password. The command is the same `serve` you would run with `sudo`, and it runs the `tailscale`
executable that Varnick found, as root, whoever owns that file. You can refuse it: cancel the prompt, or never press the button,
and the page stays on loopback with the weakness above. Nothing asks for a password by itself.

## Upgrades from origin/main

Settings › Peers can upgrade a Mac. **Upgrade** fetches `origin/main` in the checkout Varnick runs from,
fast-forwards to it and runs `make build`, which compiles and runs whatever that commit holds,
including the `Makefile`. A restart is separate and needs its own confirmation.

So anyone who can push to the repository a Mac fetches from can run code on that Mac, as its user, once
the user presses Upgrade (or Upgrade all, which asks once and lists each machine). A fork fetches
its own `origin`, not this repository: check which remote a checkout is using before you upgrade from it.
An upgrade leaves alone a checkout that isn't on `main` or has uncommitted changes to tracked files, and
refuses one whose `main` has commits `origin/main` lacks while `origin/main` has others, instead of building it.

The Linux installer works from the checkout it runs in, not from `origin`: it builds the committed
`Packages/VarnickPeer` as it is at that checkout's `HEAD`, on the host.

## Point at the screen

Settings › Listening › **Point at the screen** (off by default, and available only with Hey Varnick on and the
relevance filter on TypeSafe with a key) makes Varnick ask macOS for the Accessibility permission, which lets a
process read and drive any app's windows, and for Screen Recording, which lets it see anything on the
screen. Varnick only reads, and only the window in front, when you ask about the screen. Screen
Recording is used only when the window's elements don't have the thing or the window is a Chrome page,
and without it that step is skipped.

- **The permissions reach every pane.** macOS attributes every process in Varnick's panes to Varnick, sessions
  kept running in zmx included (seen in macOS's privacy log), so every Claude session and shell there gets
  Varnick's Accessibility and Screen Recording. A session started with Skip permissions can read and drive any
  app's windows and capture the screen without asking. A grant to zmx or to any other program a pane runs is
  never consulted. Turning the switch off does not revoke the permissions: only taking Varnick out of
  Settings › Privacy & Security › Accessibility and Screen Recording does, if that is not acceptable.
- **A signed rebuild keeps the permissions; an ad-hoc one may not.** Builds are signed ad hoc unless the Mac has a
  Developer ID Application identity (README, Build from a checkout). An ad-hoc build may not match the grants to the
  next build (not verified). A signed build keeps them: Accessibility and Screen Recording still applied
  from a pane after a rebuild and a restart, with System Settings untouched. So the grants no longer
  lapse at a rebuild: they stay with every pane session until you remove Varnick in Settings › Privacy &
  Security (ADR 0022). macOS may also ask again after some weeks whether Varnick may
  keep recording, and show its capture indicator (not verified).
- **What leaves the Mac.** Choosing TypeSafe is consent to send what a feature backed by it needs, so this
  list is what the feature needs, not a selection that spares your own names; the way to keep them from TypeSafe is
  the filter's On this Mac setting. Only with the filter on TypeSafe and a key: for a request about the screen, the
  words you said, the title of the window in front and, for up to its first 255 elements, the label, kind,
  nearby text and whether it is dimmed. Those are the window's visible text, not only that near its controls:
  a message list's subjects and senders, an open mail's body in Mail, a page's text in Safari, a file's name
  in a tab, an account's name in a sidebar. The elements never hold what is typed in a field, and a password
  field is not read at all. With Varnick's panel open and in front it is read first, as any window is, so the
  names it shows go too: the sessions' titles, folders, projects, agents and paired Macs' names, page
  titles and sites in a search's results, and problem titles on the board. A terminal pane's text is not
  among them. None of it goes to a model server. When the elements don't have the thing, and
  Screen Recording is granted, a picture of the window alone is taken into memory, read for text on this
  Mac and dropped: it is never written to disk, logged or sent. The text it finds does go, but only lines
  of at most 6 words and 60 characters, at most 150, with no positions, which is every short line in the
  window (a message list's subjects and senders, a chat's names). Lines inside a text or password
  field the elements find (a native one, or a web page's in Safari or an Electron app), and inside the field with focus, are dropped. **A field Varnick can't place is
  not, so typed text of 6 words or fewer there may reach TypeSafe:** a Chrome page's field, one in a canvas
  app, a remote desktop or a virtual machine, one past the limits of the read, or one that moved before the
  picture was taken. Do not use this with a password or other secret typed in such a field. See the README's
  Privacy section and ADR 0021.
- **The arrow** is drawn by Varnick, cannot take focus or clicks, and goes by itself.

## Screen access

Settings › Claude › **Screen access** (off by default) gives the Claude sessions started or restarted in
Varnick's panes while it is on a `varnick` MCP server with three tools, `look`, `point` and `click`, on this
Mac's screen (ADR 0023). It needs the same Accessibility and Screen Recording as Point at the screen.

- **A session can click for you, and nothing asks.** `click` shows the arrow on its target for a second
  and then presses the control or clicks at the point; there is no approval prompt, no per-pane switch and
  no list of apps to keep out. There is no `type`. A session started with Skip permissions runs the
  tool with no prompt of Claude Code's either; one without gets Claude Code's own prompt for an MCP tool
  you haven't allowed (inferred, not checked). Whatever can steer a session, such as a web page
  Claude reads, can then click as you in any app's window.
- **It adds little today, because every pane already has the permissions.** macOS attributes every
  process in Varnick's panes to Varnick (Point at the screen, above), so with Varnick granted a session can
  already read and drive the screen with `osascript`, `screencapture` or its own code. Screen access gives
  it a supported way, with the arrow before a click and a switch, not a boundary. The approval, per-pane
  switch and record it lacks wait until pane processes stop getting Varnick's permissions
  (`panes-share-launchys-permissions`).
- **What a session is shown goes to Anthropic,** with the session's context, and stays in its transcript on
  this Mac: the title of the window, its first 255 controls' labels, kinds and nearby text (the window's visible text) and, for a window that
  lists nothing or a Chrome page, short lines read from a picture of it on this Mac. Never a field's typed
  value or a password field; but **typed text of 6 words or fewer in a field Varnick can't place may be
  among the lines** (ADR 0021). Nothing goes to TypeSafe on this path.
- **The server only relays.** `Varnick --mcp` has no path that reads or acts: each call is one line on the
  socket only your account can open, and the running Varnick answers it. A paired Mac or a device cannot
  send one: the peer relay refuses any line without a known operation, and a screen request has none.
  Any process of yours on this Mac can open the socket and send one, a pane's included, naming any pane's
  id, which any process of yours can read; the pane id is a label, not a credential.
- **Varnick's own window is refused,** so is a session that another Mac or a device is in control of, and
  turning the switch off refuses every call at once.

## Other things Varnick fetches and runs

- **Downloads are pinned and checked.** The build checks the Metal shaders and zmx against SHA-256 digests
  in the `Makefile`; the installer does the same for zmx and Bun; the models are downloaded at fixed
  revisions from Hugging Face.
- **A model server.** With Server chosen for Search embeddings or Text generation, Varnick sends the
  searches and prompts typed, the text it embeds (for a Claude session, its prompts and Claude's last reply
  to each) to the server you name, over HTTP or HTTPS. It accepts only an address whose name resolves to the tailnet or this Mac, and follows no
  redirect and no system proxy; it does not pin the address between its check and the connection. A
  server can therefore read those texts and the key you give it. Name only a server you run.
- **TypeSafe.** With a key and the relevance filter on TypeSafe, searches and result descriptions leave the
  Mac, and so do the text of a spoken request after "Hey Varnick" and, as a typed search's, the search
  words and the title, site and page description of its first 20 pages. Words said before the request was
  finished may be sent and then discarded. With Point at the screen on, a request about the screen also
  sends the window's title and its controls' descriptions, Varnick's own panel's names included when it is in
  front, and after a miss its short lines of recognised text (above). See the README's Privacy section.
