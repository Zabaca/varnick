# Varnick

Varnick is a macOS launcher: a floating panel that searches your browser history, and runs Claude Code
sessions side by side with terminals, web pages and files. It keeps your Chrome history in a local
archive that outlives Chrome's own retention, searches it by meaning as well as by words, lists your Claude
Code sessions so you can resume any of them, and can pair with Varnick on your other Macs, and with a
headless Linux machine, so that a session on one is reachable from another. A web page it can serve to your own
phone over Tailscale shows the same sessions.

Varnick is not affiliated with or endorsed by Anthropic. Claude and Claude Code are Anthropic's.

The words it uses (Session, Pane, Peer, Host and the rest) are defined in [`CONTEXT.md`](CONTEXT.md).

## Requirements

- An Apple Silicon Mac running macOS 14 or later. Listening (below) needs macOS 26.
- The [Claude Code](https://claude.com/claude-code) CLI, on the PATH of the account's login shell: Claude
  panes run `claude` through that shell, so the shell's startup files have to find it. That shell is the
  account's own only when it is zsh, bash or sh; for any other, such as fish, panes use `/bin/zsh`, so
  `claude` has to be on zsh's PATH too.
- Chrome, if you want its history and bookmarks searched. No other browser is read.
- [Bun](https://bun.sh), only for the Phone page and for app panes (custom apps). App panes run in zsh, so
  `bun` must be on zsh's PATH. The Phone page looks for it at `~/.bun/bin/bun`, `/opt/homebrew/bin/bun`
  and `/usr/local/bin/bun`.
- [Tailscale](https://tailscale.com), for peers and for the Phone page. Varnick looks for its command
  line in the Tailscale app, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`.
- A Swift 6.2 toolchain (`swift-tools-version:6.2` in `Package.swift`), only to build from a checkout. The
  downloaded app needs none.

## Install

Download `Varnick.zip` from [the latest release](https://github.com/Zabaca/varnick/releases/latest) (the
link `https://github.com/Zabaca/varnick/releases/latest/download/Varnick.zip` always reaches the newest
zip). A published build is signed and notarized, so macOS opens it without a security warning.

1. Unzip it and move `Varnick.app` to Applications, then open it. Opened straight from Downloads, macOS runs
   it from a temporary copy; Varnick says so, asks you to move it to Applications and quits, so peers and
   the Phone page never point at a path that is gone at the next launch.
2. macOS asks for permissions when a feature first needs one, not at the first launch. Listening asks for
   the microphone and system audio; Point at the screen and Screen access ask for Accessibility and Screen
   Recording (Settings shows each and has a button to grant it). Screen Recording takes effect after a
   restart, which Settings offers.
3. Settings › **Open at login** (shown only in the app, off until you turn it on) starts Varnick with your
   Mac through Login Items. Remove it there or in System Settings.
4. The app writes its log to `~/Library/Logs/Varnick.log`, and keeps its state where a checkout does, in
   `~/Library/Application Support/Varnick`. One Varnick runs per account: a second one says where the
   first runs from and quits.

**Updating.** The app does not update itself. Quit Varnick (the menu bar menu), then replace the app in
Applications with the one in the newest download. Replacing it while it runs would leave peers reaching the
new executable before Varnick has restarted. Settings › Peers says "Installed app: update it by downloading
the newest build" for a Mac that runs the app.

**Moving a Mac from a checkout to the app.** Run `make uninstall` in the checkout first. The LaunchAgent would
otherwise start a second Varnick at every login, and whichever copy comes second shows an alert and quits. The app and a checkout build share one history database in
Application Support (see "Things that stay as they are"); a checkout's older `db/` copy is copied there
once, and left in place.

The app links its copy of the `custom-apps` skill into `~/.claude/skills/` when nothing is there, by the
rule `make install` uses (below). An installed Mac can't upgrade a headless host's relay or be upgraded
from another Mac; do those from a Mac that runs a checkout.

## Build from a checkout

Build and run through the `Makefile`. This is how the code is changed and how a Mac without the app runs
Varnick; it needs the Swift toolchain above:

```
make build      # builds, codesigns, and fetches the files below
make run        # builds, then restarts Varnick from this checkout
make install    # builds, then starts Varnick now and at each login, through a LaunchAgent
make uninstall
```

Plain `swift build` is not enough. `make build` also re-signs the binary so macOS binds its
`Info.plist` (the microphone and system audio usage strings), downloads MLX's prebuilt Metal shaders
(`mlx.metallib`), which `swift build` cannot compile without Xcode, and downloads the pinned zmx release
(below). Both downloads are checked against SHA-256 digests in the `Makefile`. The first build is slow:
it resolves and compiles the Swift packages.

**Signing.** The binary and zmx are signed ad hoc, unless the Mac's keychain holds a "Developer ID Application"
identity: the build then signs with it, with the hardened runtime and one entitlement (audio input), so macOS
should keep the permissions you give Varnick across rebuilds instead of treating each build as a new app (to be
confirmed by hand; see ADR 0022 and SECURITY.md). With two or more such identities, or to pick another, copy
`Makefile.local.example` to `Makefile.local` (git-ignored) and name one. A build never falls back to ad hoc
behind your back: if an identity was found and signing with it fails, the build fails; so does one named in
`Makefile.local` that isn't in the keychain, one that has expired or become invalid, a checkout that has signed
before finding none, and a `security find-identity` that itself fails. Set `SIGN_IDENTITY=-` to sign ad hoc on
purpose. A failed build puts the last good binary back. The key must be usable by `codesign` without a prompt,
since an upgrade from Settings › Peers builds unattended.

`make install` also links this checkout's `custom-apps` skill into `~/.claude/skills/` so Claude Code in
any project can find it. It links only when nothing is at that path, or when the link there already
points into this checkout; any other entry is left as it is, and `make uninstall` removes only a link that
points into this checkout.

The app reads and writes the same places a checkout build does. Both read and write a few places outside the checkout: `~/Library/Application Support/Varnick` (saved
tabs, models, transcripts and other state), the macOS Keychain (the TypeSafe key, if you save one), and
its own preferences.

### Restarting ends sessions that aren't kept in zmx

Varnick runs each Claude and terminal pane as its own child process. Restarting it, which `make run`
and `make install` do, quitting it, or a crash ends every pane's process. Claude conversations resume
(`claude --resume`), but work in flight does not.

Settings › **Keep sessions running** avoids that: it runs each pane's process in [zmx](https://github.com/neurosnap/zmx),
which keeps it alive and lets Varnick reconnect after a restart. It is off until you turn it on. It
needs the zmx the build fetches, and Varnick only ever uses the copy next to its binary. A reboot or a
logout ends the sessions either way.

The menu bar menu's **Restart Varnick** (just above Quit) restarts it without building, with `scripts/restart.sh`, so
the macOS permission grants a build would void stay. It asks first and lists the panes that would end, if any. If a
build has run since Varnick started, the restart starts that build and macOS asks for the permissions again; the
question says so. The item is hidden when the checkout's `scripts/restart.sh` or the database can't be found from
where Varnick runs, and a restart waits while a build is running. In the installed app the item opens a new copy of the
app and quits this one; the new copy waits for this one to let go, and there is no build to start.

## Defaults for a new install

- **Skip permissions is off.** Claude sessions start with Claude's permission checks on. The setting
  (Settings › Skip permissions) starts them with `--dangerously-skip-permissions` instead: Claude then
  runs tools without asking. See [`SECURITY.md`](SECURITY.md).
- **The relevance filter is off** unless a TypeSafe key is present, in the Keychain, in the environment
  as `TYPESAFE_API_KEY`, or in `.env`. See Privacy below for what turning it on sends.
- **Keep sessions running** is off (above), and so are Listening, Point at the screen, Screen access and the Phone page.
- **`make install` leaves a skill link it didn't make alone** (above).

A Mac that ran an earlier Varnick keeps what it stored. One that has Varnick's sessions file but never
stored a Skip permissions choice keeps Skip permissions on (it is stored as on at the first launch of this
version); turn it off in Settings.

## Optional parts

### Peers

Varnick on one Mac can pair with Varnick on another Mac, and with a headless host, over SSH with your own
keys. A session runs on one host and stays there; another Mac shows its live screen and can take over.
Add a peer in Settings › Peers (Find Macs searches your tailnet, or add by address as `<user>@<host>`).
The peer list and your SSH keys are the boundary: see [`SECURITY.md`](SECURITY.md). Settings › Peers also
shows each Mac's build and can upgrade it from `origin/main`, which fetches and builds the checkout
(again, see [`SECURITY.md`](SECURITY.md)). Only a Mac that runs a checkout can be upgraded this way; an
installed app is updated by downloading the newest build. A Mac on the app speaks the protocol of the build it
was made from, so when `main` has moved on, the two kinds of Mac may only be able to exchange hellos until the
app is updated.

### The Linux relay

A headless host (a Linux machine with no Varnick app) runs Varnick's relay alone. Install it from a Mac, from this checkout:

```
scripts/install-peer.sh <user>@<host> [--name NAME] [--page | --no-page] [--uninstall]
```

The installer builds `Packages/VarnickPeer` on the host, so the host needs:

- **x86_64 Linux.** Any other architecture is refused.
- **Swift from [swiftly](https://www.swift.org/install/linux/), installed by hand** at
  `~/.local/share/swiftly/bin/swift`. The installer stops and says so when it is missing.
- **A Debian-style system with `apt`, and passwordless `sudo`** for the one package it installs when
  missing, `libstdc++-14-dev`. If the build still fails to link, it retries once with the x86_64 GCC 13
  library folder, `/usr/lib/gcc/x86_64-linux-gnu/13`, added to the link line. That is the folder layout of
  a distribution that ships GCC 13, such as Ubuntu 24.04; this fallback has not been tried here on other
  releases.
- SSH key login from the Mac, and zmx, which the installer downloads and checks.
- For `--page`: `systemd` with user units, Tailscale, and Bun, which the installer downloads from a pinned
  release and checks if the host has none.

### The Phone page

A web page each host can serve to your own devices, such as a phone: the host's sessions, Recent, a new
session and a terminal, typed into with the phone's own keyboard plus one row of the keys it lacks (Esc, Tab,
Shift+Tab, the arrows and a sticky Ctrl). It is off by default (Settings › Serve the phone page; on Linux, `--page`). It
needs Bun and Tailscale. It is published with `tailscale serve` on HTTPS port 8444, to your tailnet only,
and each device you list on a host is identified by Tailscale. [`SECURITY.md`](SECURITY.md) explains what
that does and does not protect, including a mode in which any program on the Mac can reach it.

### Listening

Listening transcribes your microphone and what the Mac plays, on this Mac, into a text file for the day
(`Varnick/transcripts/` under Application Support). It is off at each launch and needs macOS 26. macOS asks for
the microphone and system audio permissions the first time.

### Point at the screen

With Hey Varnick on, Settings › Listening › **Point at the screen** lets you ask about what is in front of
you ("Hey Varnick, where's the Allow button"). Varnick reads the elements of the window that has focus
through macOS Accessibility, in its own process, asks TypeSafe's Jev which one you mean, draws a big arrow
and a sign on it that never takes focus or clicks, says what it is, and takes the arrow away a few seconds
later. It needs the Accessibility permission, which Settings asks for and shows, and the relevance filter
on TypeSafe with a key (see Privacy below for what is sent). With Varnick's own panel open and in front,
it looks in the panel first, as in any window, and reads the app behind it only when the thing isn't there;
a terminal pane's text is not in the panel's elements, so it can't be pointed into. When the thing isn't among the window's
elements, or the window is a Chrome page, whose content the elements don't hold, and Screen Recording is
also granted, Varnick captures that window alone into memory and reads its text with Apple's text
recognition on this Mac, so a Chrome page, a canvas app or a remote desktop can be pointed into. The
picture is never written to disk, logged or sent; only the short lines of text it finds go on, as below.
Without Screen Recording the elements' answer stands, and Varnick says it can't see inside Chrome's pages.
A rebuild of Varnick may need either permission given again. The permissions are Varnick's, and every
Claude session and shell in its panes gets them too, kept running in zmx or not: see [`SECURITY.md`](SECURITY.md).

### Screen access

Settings › Claude › **Screen access** (off by default) gives the Claude sessions you start or restart in
Varnick's panes three tools, from an MCP server named `varnick`: `look` at the controls of a window on your Mac,
`point` at one with the same big arrow Point at the screen draws, signed with the session's name and its
note, and `click`. A session that hits a setting it can't see can look, show you where to click, or click
for you. The server is Varnick's own binary (`Varnick --mcp`) and only passes each call on: the running
Varnick does the reading, drawing and clicking, with the code Hey Varnick uses. It needs Accessibility, and
Screen Recording to read the text of a window that lists nothing or of a Chrome page; Settings asks for
both. **A click happens without asking**: the arrow shows on the target for a second first, and there is no
`type`. A session started with Skip permissions has no prompt before a tool at all; one without gets Claude
Code's own prompt for a tool you haven't allowed, and its per-tool rules can allow `look` and `point` while still asking
for `click` (not checked). A session gains the tools when it starts, so restart a running one (⌘⌥R) after turning the
switch on; turning it off stops every session's tools at once. It is independent of Point at the screen
and Hey Varnick. See Privacy below for what a session is shown, and [`SECURITY.md`](SECURITY.md).

### TypeSafe

The relevance filter can run on [TypeSafe](https://www.typesafe.ai)'s API, with your own key (Settings
saves it in the Keychain, or it is read from `TYPESAFE_API_KEY` in the environment or from `.env`). Choosing
TypeSafe is consent to send what its features need; with On this Mac, or the filter off, nothing goes to TypeSafe.
What it sends is under Privacy.

### On-device models

These download from Hugging Face when you ask (Settings), and run on this Mac with MLX.

| Model | Used for | Download |
|---|---|---|
| Qwen3-Embedding-0.6B (8-bit) | Search by meaning | about 650 MB |
| Gemma 4 E2B (4-bit) | Hey Varnick's answers | about 3.6 GB |

Their licences are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Each of these two can instead run on a model server on your tailnet (Settings › Models › Server); Privacy
says what that sends.

"On this Mac" is also a choice for the relevance filter. It runs a small checkpoint distilled from
TypeSafe's judgments on a person's own history, and that checkpoint is not published: the choice needs
you to import one you have made yourself, and Varnick has no recipe to make it. The two evaluation commands
(`Varnick --rerank-eval` and `Varnick --search-eval`) need labelled data of your own, so they are of use to
someone developing the filter, not to someone using Varnick.

## Things that stay as they are

- **The database** is a SQLite file, `varnick.sqlite`, in Varnick's folder in Application Support, whichever
  way Varnick runs. The first start copies a checkout's `db/` database there, if it has one, and leaves the original
  in place. The `VARNICK_DB` environment variable overrides the path; without it, the command-line modes
  (`--sync`, `--search`, `--ask`, `--search-eval`) refuse until Varnick has been opened once. `make clean`
  removes `.build/` and keeps `db/`, since it holds history Chrome may have already dropped.
- **`.env` is read from Varnick's working directory** when it runs from a checkout, which is that checkout under
  `make run` and `make install`. The installed app doesn't read it: it takes the TypeSafe key from the Keychain
  or the environment.
- **Only Chrome's history** is read, and the lookups for `bun` and `tailscale` use the fixed locations above.

## Privacy

Varnick works on your own data, mostly on your Mac. What it reads, records and sends:

- **It reads the History of every Chrome profile** and copies it into a local archive that only grows,
  and mirrors every profile's bookmarks beside it.
- **It reads every Claude Code transcript under `~/.claude/projects`**, to list your sessions and make your
  prompts searchable, and keeps the last thing Claude wrote after each prompt (cut at 1,000 characters),
  which only the search by meaning reads.
- **Between Macs you have paired, it copies both your Claude prompts and your browsing history to the other
  Mac**, so that Recent and search find them there. The prompts come with each session's folder, title and
  agent, and with the last thing Claude wrote after each. The history is that Mac's whole archive: full page addresses, titles, the names of its Chrome
  profiles, visit counts and last visits, the terms you searched, and each page's description. The other
  Mac keeps what it copied until you remove the Mac from the peer list (or that Mac removes this one).
  Only pair a Mac you would show that history to.
- **It fetches the pages in your history**, one request each and without cookies, to read each page's own
  description, and stores the description. Those requests go to the sites you visited.
- **It records the microphone and the Mac's system audio while Listening is on,** and writes what it
  transcribes, on this Mac, to the day's transcript file.
- **Choosing TypeSafe is consent to send what a feature backed by it needs,** Varnick's own panel and the names
  of your sessions and projects included, and each new kind of data is listed here and in SECURITY.md. Keeping
  things private is the relevance filter's **On this Mac** setting: with it, or with the filter off, none of
  the TypeSafe sending below happens.
- **With a TypeSafe key and the relevance filter on TypeSafe,** it sends each search to TypeSafe's API
  with the title, site and page description of up to 20 results. It does not send full addresses or tags.
  The filter is off by default (above). With Hey Varnick on, it also sends TypeSafe's Jev the text you
  say after "Hey Varnick", to choose where to look, with no titles, names or results. Then the request is
  searched and filtered as a typed search is, so its search words and the title, site and page description
  of its first 20 pages go to TypeSafe too. This starts before you have quite finished, so if you go on
  speaking, words said so far may be sent and then discarded. With the filter On this Mac or off, nothing leaves.
- **With Point at the screen on** (Settings › Listening, off by default, and only available with the filter on
  TypeSafe and a key), a request that is about the screen also sends TypeSafe the title of the window in
  front and, for each of its first 255 elements, the label, kind and nearby text. That is the window's
  visible text, not only that near its controls: a message list's subjects and senders, an open mail's body in
  Mail, a page's text in Safari, a file's name in a tab, the account's name in a sidebar. The elements never
  hold what is typed in a field. None of this goes to a model server. With Varnick's panel open and in front,
  the panel is such a window too, and is read first: its session titles, folders, projects, Macs' names, page
  titles and problem titles go the same way. A terminal pane's text is not among them. If the elements don't have the thing,
  and Screen Recording is granted, a picture of the window alone is also read on this Mac, and its short
  lines of text (at most 6 words and 60 characters each, at most 150) go too, so more of the window's text
  leaves: every short line, such as a message list's subjects and senders or a chat's names. Lines inside a
  text field the elements find (a native one, or a web page's in Safari or an Electron app), and inside the field with focus, are dropped. But a field Varnick
  can't place is not: a Chrome page's, a canvas app's, a remote desktop's or a virtual machine's, one past
  the limits of the read, or one that moved before the picture was taken. So typed text of 6 words or
  fewer there may reach TypeSafe. The picture, the lines' positions and longer lines never leave the Mac.
- **With Screen access on** (Settings › Claude, off by default), the Claude sessions started or restarted
  after you turn it on can read the window in front, or one they name, and what they read goes to Anthropic
  with the session, and stays in its transcript on this Mac: the window's title, each of its first 255
  controls' label, kind and nearby text, which is the window's visible text, such as a message list's
  subjects and senders or a page's text in Safari, and, for a window that lists nothing or a Chrome page,
  its short lines of text read from a picture of the window on this Mac (at most 6 words and 60 characters
  each, at most 150). The controls never hold what is typed in a field, and a password field is not read. But
  a line in a field Varnick can't place is not dropped (see Point at the screen above), so typed text of 6 words or
  fewer there may be shown to the session, and so reach Anthropic. The picture is never written, logged or
  sent. None of this goes to TypeSafe, and the TypeSafe filter has no part in it. Clicks happen without
  asking. Varnick's own panel is never read or clicked by it.
- **It downloads its models from Hugging Face** when you ask.
- **With Server chosen for Search embeddings or Text generation** (Settings › Models, off until you
  choose it), it sends to an OpenAI-compatible server you name, on your tailnet or this Mac and nowhere
  else: the searches you type, the prompts typed in the panel, the text of every page and session it
  embeds, which for a session includes Claude's last reply to each prompt (the paired Macs' sessions included). With
  Hey Varnick on, the words you say after "Hey Varnick" and the request's search words go to the
  embedding server, and the request and the titles, sites, folders and descriptions of the results it reads out
  go to the Text generation server; words said before you finished may be sent and then discarded. A key
  for that server is kept in the Keychain. Nothing goes to a third party.
- **Peers and the Phone page** talk to the hosts you list, and the Phone page to the devices you list, over
  SSH and Tailscale.

## Security

See [`SECURITY.md`](SECURITY.md) for what Skip permissions, peers, the Phone page and upgrades let others
do, and how to report a vulnerability.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). The design is written down in [`docs/`](docs/): decisions in
`docs/adr/`, the problems and options behind them in `docs/problems/`, and what a change can break in
`docs/agents/where-it-breaks.md`.

The varnick.com page is in [`site/`](site/), which also says how it is deployed.

## Licence

Varnick is licensed under the Apache License 2.0 (see [`LICENSE`](LICENSE)).

Copyright 2026 Zabaca

Third-party code and models are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
