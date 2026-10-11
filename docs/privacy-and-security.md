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

### ElevenLabs

Saving an ElevenLabs key under Settings › Models › Keys lets Varnick ask ElevenLabs for your account's voices, when
you save it and whenever Settings › Listening opens; that request carries only the key. Choosing one of those
voices in Settings › Listening › Voice is consent to send every line Varnick speaks to ElevenLabs. To keep the
lines private, leave the voice on one installed on this Mac, which is the default: then no line is sent.

- **What is spoken.** The text of each line, with the voice's id and the key. An answer names pages, sites,
  page descriptions, session titles and folders, and what your prompts said, and can repeat words of your request.
  The fixed lines ("I couldn't answer that.") go too. Never audio from your Mac, or the rows themselves except as
  an answer repeats them.
- **The warm-up.** When "Hey Varnick" is heard, Varnick asks ElevenLabs for the chosen voice, to have the
  connection open when the answer is spoken. It carries the voice's id and the key and nothing of yours.
- **The fallback.** When ElevenLabs fails, is slow or can't be reached, the line is spoken again in the installed
  voice you chose before, on this Mac.
- **The key** is kept in the macOS Keychain and goes only to ElevenLabs, in a request header, and no redirect is
  followed. Varnick never reads it from the environment or a file, and never logs it or what it speaks.

### Anthropic, through Text generation

Text generation writes Hey Varnick's answers, and its decide step whenever TypeSafe's Jev doesn't decide. Choosing
**Claude Code** for it (Settings › Models; the default for an install that never chose) is consent to send what it
needs to Anthropic, under your own Claude account and on your plan. Hey Varnick is off until you turn it on, and its
setting says so; nothing is sent before that. To keep the text on this Mac, choose **On this Mac**. An install that
already answered with it stays there when it upgrades.

- **What you say.** The request after "Hey Varnick", cut to 500 characters. The decide step starts before you have
  quite finished, so words said so far may be sent and then discarded.
- **The results it reads,** for the answer: each one's kind, title, site or folder, how long ago, and description (cut
  to 300 characters), and for a Claude session its prompts, your paired Macs' too. The decide step sends the request
  alone.
- **What Claude Code itself sends** with a call: your account's token, and device and account ids in metadata, as a
  pane's Claude does.

It never sends your Claude settings, hooks, plugins, CLAUDE.md or memory, a `.env`, tools or files, nor the working
folder, the OS or the date that Claude Code would add (a filter drops them). Nothing is saved as a transcript, so a
call is not a session: it is on no board and in no search. Each answer counts toward your plan's usage limits.

The call runs through a copy of Bun inside the app, driving your own `claude` with the environment your login shell
builds, as a pane's does. Varnick reads that environment once per launch, keeps it in memory, never logs or writes it,
and gives it only to Bun and `claude`. It holds whatever your shell exports, other services' tokens included, as a
pane's Claude does; the model has no tools to read it back. An `ANTHROPIC_API_KEY` in it is removed, so your plan is
billed and not a key. When Claude Code can't answer or is slow, this Mac's Gemma writes the text if you have installed
it, and nothing is sent for that.

### Anthropic, through Screen access

With Screen access on (off by default), the Claude sessions started or restarted after you turn it on can read
the window in front, or one they name. What they read goes to Anthropic with the session and stays in its
transcript on this Mac: the window's title, its first 255 controls' label, kind and nearby text and, for a
window that lists nothing or a Chrome page, its short lines read from a picture (the same limits as above), and
which control has the keyboard focus, by its id or its kind ("a text field that isn't listed", "a password
field"), never its label or what it holds. The same caveat holds: typed text of 6 words or fewer in a field
Varnick can't place may be among the lines. Nothing on this path goes to TypeSafe. Varnick's own panel is never
read.

A session can also ask for a **picture** of the window (`look` with `picture`, or one area of it). A picture shows
everything on the window, including what you typed into a field, which the listing leaves out, and it goes to
Anthropic with the session and stays in its transcript on this Mac. Varnick paints black the password fields it
can see before it sends the picture. It can't see one where the app doesn't report it (a Chrome page whose tree
is hidden, a canvas app, a remote desktop, a virtual machine), in a window with more controls than it reads,
where an app shows a password in a plain field ("show password"), or in a field that has no frame, and those
show. The reply says when it reached only part of a window. The picture needs Screen Recording. Varnick's log
holds its kind, pixel size and byte count, never what it shows. If you don't want what is on a window sent to
Anthropic, leave Screen access off, or close the window first.

A session can also ask for a picture of **every display, or of one** (`look` with `screen` or `display`, or one area
of them). **Nothing is hidden in it.** It shows everything on those displays: Varnick's own window, with other
sessions' text, whatever you typed, and every password field, because Varnick reads none of the windows on a
screen and so can't find their fields to paint black. It goes to Anthropic with the session and stays in its
transcript on this Mac. The reply says nothing was blacked out. It needs Screen Recording. The log holds the number
of pictures and each one's kind, pixel size and byte count, never what they show. If you don't want your screen sent
to Anthropic, leave Screen access off, or close what you don't want seen first.

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

### Custom apps and the npm registry

Varnick itself makes no request to list or install the catalog's apps: they ship inside the release, and turning one
on copies files on this Mac. An app's **packages** are fetched by Bun, from the npm registry it is set to use, in
three cases:

- the first time you pick an app that has packages, which for a catalog app is Scratch's Vite and React plugin;
- Scratch's first use in each project, which installs React for the pages;
- any app of your own that has a `package.json`, the same way.

The registry sees the package names and your Mac's address. Offline, the pane shows Bun's error and nothing runs.
What an app does beyond that is its own business, and each catalog app's row says what it fetches or sends.

### Peers and the Phone page

They talk to the hosts and devices you list, over SSH and Tailscale (below).

## What can act as you

### Custom apps

A custom app is code that runs as you, and picking one runs it. It has your rights, and its pane has Varnick's macOS
permissions (see Screen permissions reach every pane, below). Nothing sandboxes it. The apps in Varnick's catalog
are reviewed in its repository before they ship and run only the code of the release you installed; that is a
review, not a restriction. A project's `.varnick/custom-apps/` is read from any repository you open a pane in, so a
cloned repository's apps appear in the picker, and picking one runs its code.

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

### Screen access acts without asking

Screen access (ADR 0023) gives the sessions started or restarted while it is on a `varnick` MCP server with
`look`, `point`, `click`, `type`, `drag` and `window`.

- **A session can click, type, drag and move windows for you, and nothing asks.** The arrow shows on the target
  for a second, then the app comes to the front (not for `window`) and the action happens: no approval prompt, no
  per-pane switch, no list of apps to keep out. A session with Skip permissions gets no prompt from Claude Code
  either; one without gets Claude Code's own prompt for an MCP tool you haven't allowed (inferred, not checked).
  Whatever can steer a session (a page it read, a file, a message) can then act as you. Typing is the strongest:
  it can type a command into a terminal, a message into a chat or a form's fields.
- **Typing is made of key events, and a field's value is never set.** The app sees keystrokes as if you typed
  them, in the app in front. `look` never reads what a field holds, so a session can't check what it typed except
  by selecting the field's contents first and typing over them.
- **Nothing is typed or pressed while a password field has focus,** where Varnick can see one. It can't where the
  app doesn't report it: a Chrome page whose tree is hidden, a canvas app, a remote desktop or a virtual machine.
  A session can type into a password field there, as ADR 0021 accepted for reading. Varnick can't tell a password
  you meant to give from one a session found in a file or a page, and what a session types goes to Anthropic with
  its context, so you type it yourself.
- **Some combos are refused:** Varnick's own shortcuts that work anywhere (show or hide, pin, Listening), and macOS's
  log out, lock screen and Force Quit. Every other combo goes to the app in front as if you pressed it, ⌘Q and ⌘W
  included. A click or drag on the menu bar can still reach Apple menu › Lock Screen or Log Out.
- **Typing stops** when you turn the switch off, bring up Varnick's panel, or another app comes forward.
- **Varnick's log never holds what a session typed.** It holds the tool, the outcome's kind, how many characters
  and keys went, and durations.
- **It adds little today,** because every pane already has the permissions (above): a session could already use
  `osascript`, `screencapture` or its own code. Screen access gives it a supported way with an arrow and a
  switch, not a boundary.
- **The server only relays.** `Varnick --mcp` sends each call as one line on a socket only your account can open,
  and the running Varnick answers. A paired Mac or a device can't send one: the peer relay refuses it. Any
  process of yours on this Mac can, naming any pane's id; the id is a label, not a credential.
- **`look` can return a picture of a window,** which takes nothing from the screen but that window (see above for
  what it shows and what is hidden), **or of the whole screen,** which takes everything on it and hides nothing
  (see above).
- **Varnick's own window is refused for reading controls and for actions,** though not in a picture of the screen
  (above), and so is a session another Mac or a device is in control of. Turning the
  switch off refuses every call at once. `window` moves no pointer and brings no app forward.

### The downloaded app moves itself to Applications

Opened from a download (macOS runs it from a temporary copy) or straight off its disk image, Varnick offers to
move itself to `/Applications`. If you agree, it first checks that the new copy's signature is valid and carries
the same team and identifier as the running copy, and only then removes the "downloaded from the Internet"
quarantine attribute from that copy, so macOS doesn't run it from a temporary copy again at each open. It removes
that attribute from nothing else. It replaces an older Varnick in `/Applications` only once that has quit, and
puts it in the Trash. It never asks for an administrator password: on an account that can't add apps to
`/Applications`, it says so and stops.

### Downloads are pinned and checked

The build checks the Metal shaders, zmx and Bun against SHA-256 digests in the `Makefile`; the Linux installer does
the same for zmx and Bun; the models download at fixed revisions. The text helper's packages (`@zabaca/agent` and the
Agent SDK) are pinned in `TextHelper/package.json` and install from a committed lockfile, frozen. A catalog app's packages are pinned by a
`bun.lock` committed beside it, which holds an integrity hash for every package, and review makes sure it is in step
with the app's `package.json`. The first pick installs with `--frozen-lockfile`, so it fails rather than resolve
versions the lockfile doesn't name.

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this repository,
then **Report a vulnerability**. Please don't open a public issue or pull request for a vulnerability. No email
address is published for reports.
