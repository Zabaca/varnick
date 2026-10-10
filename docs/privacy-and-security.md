# Privacy and security

Varnick works on your own data, mostly on your Mac, and runs programs as you: on this Mac, on your other Macs
and from your phone. This page says what it reads and sends, and who can make it act as you. It describes the
code as it is; where a statement rests on a design decision, the decision is in [`docs/adr/`](adr/). To report a
vulnerability, see [the end of this page](#reporting-a-vulnerability).

## What stays on your Mac

- **Your Chrome history.** Varnick reads the History of every Chrome profile and copies it into a local archive
  that only grows, with every profile's bookmarks beside it.
- **Your Claude Code transcripts.** It reads every transcript under `~/.claude/projects`, to list your sessions
  and make your prompts searchable, and keeps the last thing Claude wrote after each prompt (cut at 1,000
  characters), which only the search by meaning reads.
- **What you say and hear, while Listening is on.** It records the microphone and the Mac's system audio and
  writes what it transcribes, on this Mac, to the day's transcript file.
- **Pictures of the screen.** When it reads a window from a picture, the picture is never written to disk,
  logged or sent.

## What leaves your Mac

Out of the box, two things:

- **Requests to the pages in your history,** one each and without cookies, to read and store each page's own
  description. They go to the sites you visited.
- **Model downloads from Hugging Face,** when you ask, at fixed revisions.

Everything else leaves only when you turn it on.

### Paired Macs

Between Macs you have paired, Varnick copies, for Recent and search:

- **Your Claude prompts,** with each session's folder, title and agent, and the last thing Claude wrote after each.
- **Your whole browsing-history archive:** full page addresses, titles, the names of your Chrome profiles, visit
  counts and last visits, the terms you searched, and each page's description.

The other Mac keeps them until you remove it from the peer list (or it removes this one). Pair only Macs you
would show that history to.

### TypeSafe

Choosing TypeSafe for the relevance filter is consent to send what a feature backed by it needs, Varnick's own
panel and the names of your sessions and projects included. To keep things private, set the filter to **On this
Mac** or leave it off (it is off by default): then none of this happens.

- **Searches.** Each search, with the title, site and page description of up to 20 results. Never full addresses
  or tags.
- **Hey Varnick.** The text you say after "Hey Varnick" goes to TypeSafe's Jev to choose where to look, with no
  titles, names or results. The request is then searched and filtered as a typed search is (above). This starts
  before you have quite finished, so words said so far may be sent and then discarded.
- **Point at the screen** (off by default). A request about the screen also sends the title of the window in
  front and, for each of its first 255 elements, the label, kind, nearby text and whether it is dimmed. That is
  the window's visible text, not only the text near its controls: a message list's subjects and senders, an open
  mail's body, a page's text in Safari, a file's name in a tab, the account's name in a sidebar. With Varnick's
  panel open and in front, it is read first like any window, so its session titles, folders, projects, agents,
  Macs' names, page titles and sites, and problem titles go too. A terminal pane's text is not among them. The
  elements never hold what is typed in a field, and a password field is not read.
- **Short lines read from a picture.** If the elements don't have the thing, or the window is a Chrome page, and Screen
  Recording is granted, a picture of that window alone is read for text on this Mac, and its short lines go too: at most 6 words and
  60 characters each, at most 150, with no positions. Lines inside a field the elements find (a native one, or a
  web page's in Safari or an Electron app) and inside the field with focus are dropped. **A field Varnick can't
  place is not, so typed text of 6 words or fewer there may reach TypeSafe:** a Chrome page's field, a canvas
  app's, a remote desktop's or a virtual machine's, one past the limits of the read, or one that moved before
  the picture was taken. Don't use this with a password or other secret typed in such a field (ADR 0021).

None of this goes to a model server.

### Anthropic, through Screen access

With Screen access on (off by default), the Claude sessions started or restarted after you turn it on can read
the window in front, or one they name. What they read goes to Anthropic with the session and stays in its
transcript on this Mac: the window's title, its first 255 controls' label, kind and nearby text and, for a
window that lists nothing or a Chrome page, its short lines read from a picture (the same limits as above). The
same caveat holds: typed text of 6 words or fewer in a field Varnick can't place may be among the lines. Nothing
on this path goes to TypeSafe. Varnick's own panel is never read.

### A model server you name

With Server chosen for Search embeddings or Text generation (Settings › Models), Varnick sends the server the
searches you type, the prompts typed in the panel, and the text of every page and session it embeds, which for
a session includes Claude's last reply to each prompt (paired Macs' sessions included). With Hey Varnick on, the
words you say go to the embedding server with the request's search words, and the request with the titles,
sites, folders and descriptions of the results it reads out go to the Text generation server; words said
before you finished may be sent and then discarded.

Varnick accepts only an address whose name resolves to your tailnet or this Mac, over HTTP or HTTPS, and follows
no redirect and no system proxy. It does not pin the address between its check and the connection. The server
can read all of this and the key you give it (kept in the Keychain), so name only a server you run.

### Peers and the Phone page

They talk to the hosts and devices you list, over SSH and Tailscale (below).

## What can act as you

### Skip permissions

Settings › **Skip permissions** starts Claude sessions with `--dangerously-skip-permissions`: Claude Code then
runs its tools, shell commands and file edits included, without asking, in the session's folder and as your
account. Anything that can steer a session, such as a web page Claude reads, a file in the repository or a
prompt, can then act with your account's rights.

- **It is off for a new install.** A Mac that ran an earlier Varnick keeps what it had stored, and can turn it
  off in Settings.
- **A peer's start request carries the peer's own choice,** and the host follows it whatever its own setting
  says. A listed peer already reaches the host's account over SSH, so this grants nothing SSH doesn't. The
  Linux relay's default, for a request that doesn't say, is off.
- The Phone page's sessions follow the host's setting.

### Peers over SSH

Peers pair over SSH, with your own keys (ADR 0007). The boundary is:

- **The peer list.** A request other than `hello` is answered only for a Mac the receiver lists, and an unlisted
  Mac is never contacted except by Find Macs and Add, which you start. The list is checked against the name the
  request gives; that name is not a credential, the SSH login is.
- **Your SSH keys.** Varnick runs the relay with `ssh` as the account you gave, with no password prompts
  (`BatchMode`), accepting a host key on first contact and refusing it if it later changes. Whoever holds a key
  that logs in as that account can run the relay, and could do anything that account can anyway.
- **The relay runs as you,** with your files and tools. It is Varnick's own binary (`varnick-peer` on a headless
  host), listens on no network port, and on a Mac talks to the app through a socket only your account can use.

### The Phone page

- **It is off by default** (Settings › Serve the phone page; on a headless host, the installer's `--page`).
- **It is published only with `tailscale serve`, to your tailnet,** on HTTPS port 8444. Varnick and the
  installer never run `tailscale funnel`, and refuses to publish if Funnel is on for that port or its state can't be read.
- **Who is calling comes from Tailscale.** The server asks Tailscale (`tailscale whois`) who owns the address
  `tailscale serve` forwards, and serves only a device you listed on that host. Everything the page does is a request to the host's own relay,
  as that device. Changes need a `POST` with a
  matching `Origin`, and websockets are checked against it.
- **A listed device can do most of what a Mac peer can:** list sessions, start one in a project the host lists,
  take over and type in a terminal. Not the search sync, upgrades or restarts. List only devices you control.

**Known weakness: loopback mode.** The server listens either on a Unix socket in a folder only your account can
enter (socket mode), or on `127.0.0.1:18444` (loopback mode). In loopback mode any process on the Mac, other
accounts' included, can send the headers the server trusts, pose as a listed device, and so start and drive
sessions: a shell as you. Tailnet addresses and the page's name aren't secrets. This is to be fixed.

Varnick falls back to loopback when it can't serve a socket: the Tailscale app's own command line can't, an older
standalone one can't, none was found or answered, or the Tailscale daemon refuses a socket to a user who isn't
root (Homebrew's does). Settings names the reason, and the page shows a "Loopback mode" note. Until it's fixed:

- **A refused socket:** press **Use a socket** in Settings (ADR 0011 has the fix outside Varnick for a Homebrew
  daemon). It runs the same `tailscale serve` as root, through macOS's password prompt: the one place Varnick asks
  for your password, and it runs the `tailscale` executable Varnick found, whoever owns that file. Cancel the
  prompt and the page stays on loopback.
- **The Tailscale app's command line:** updating the app doesn't help. Varnick uses it whenever the app is
  installed, so a standalone command line takes over only on a Mac without the app.
- **An older command line:** install a newer one. **None found or answering:** install one where Varnick looks
  (the [guide](guide.md#requirements) lists the places).
- Or don't serve the page on a Mac other people have accounts on, or that runs programs you don't trust. A
  headless host always uses a socket.

### Upgrades from origin/main

Settings › Peers › **Upgrade** fetches `origin/main` in the checkout Varnick runs from, fast-forwards to it and
runs `make build`, which runs whatever that commit holds, the `Makefile` included. So anyone who can push to the
repository a Mac fetches from can run code on it as you, once you press Upgrade (or Upgrade all, which asks once
and lists each machine). A fork fetches its own `origin`: check which remote a checkout uses before upgrading it.
An upgrade leaves alone a checkout that isn't on `main` or has uncommitted changes to tracked files, and refuses
one whose `main` and `origin/main` have each moved on. A restart is separate and asks again.

The Linux installer builds the committed `Packages/VarnickPeer` at its own checkout's `HEAD`, not `origin`'s.

### Screen permissions reach every pane

Point at the screen and Screen access ask macOS for Accessibility, which lets a process read and drive any app's
windows, and Screen Recording, which lets it see anything on the screen. macOS attributes every process in
Varnick's panes to Varnick, sessions kept running in zmx included, so **every Claude session and shell there gets
both**. A session started with Skip permissions can read and drive any app and capture the screen without
asking. A grant to zmx or to another program a pane runs is never consulted.

Turning either switch off doesn't revoke the permissions; removing Varnick from System Settings › Privacy &
Security does. A signed build keeps them across rebuilds (ADR 0022); an ad-hoc one may not (not verified). macOS
may also ask again after some weeks whether Varnick may keep recording (not verified).

Point at the screen itself only reads the window in front, and only when you ask about the screen. The arrow it draws can't
take focus or clicks, and goes by itself.

### Screen access clicks without asking

Screen access (ADR 0023) gives the sessions started or restarted while it is on a `varnick` MCP server with
`look`, `point` and `click`.

- **A session can click for you, and nothing asks.** The arrow shows on the target for a second, then the click
  happens: no approval prompt, no per-pane switch, no list of apps to keep out. There is no `type`. A session
  with Skip permissions gets no prompt from Claude Code either; one without gets Claude Code's own prompt for an
  MCP tool you haven't allowed (inferred, not checked). Whatever can steer a session can then click as you.
- **It adds little today,** because every pane already has the permissions (above): a session could already use
  `osascript`, `screencapture` or its own code. Screen access gives it a supported way with an arrow and a
  switch, not a boundary.
- **The server only relays.** `Varnick --mcp` sends each call as one line on a socket only your account can open,
  and the running Varnick answers. A paired Mac or a device can't send one: the peer relay refuses it. Any
  process of yours on this Mac can, naming any pane's id; the id is a label, not a credential.
- **Varnick's own window is refused,** and so is a session another Mac or a device is in control of. Turning the
  switch off refuses every call at once.

### Downloads are pinned and checked

The build checks the Metal shaders and zmx against SHA-256 digests in the `Makefile`; the Linux installer does
the same for zmx and Bun; the models download at fixed revisions.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this repository,
then **Report a vulnerability**. Please don't open a public issue or pull request for a vulnerability. No email
address is published for reports.
