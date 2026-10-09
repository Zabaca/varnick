# Launchy

Launchy is a macOS launcher: a floating panel that searches your browser history, and runs Claude Code
sessions side by side with terminals, web pages and files. It keeps your Chrome history in a local
archive that outlives Chrome's own retention, searches it by meaning as well as by words, lists your Claude
Code sessions so you can resume any of them, and can pair with Launchy on your other Macs, and with a
headless Linux machine, so that a session on one is reachable from another. A web page it can serve to your own
phone over Tailscale shows the same sessions.

Launchy is not affiliated with or endorsed by Anthropic. Claude and Claude Code are Anthropic's.

The words it uses (Session, Pane, Peer, Host and the rest) are defined in [`CONTEXT.md`](CONTEXT.md).

## Requirements

- An Apple Silicon Mac running macOS 14 or later. Listening (below) needs macOS 26.
- A Swift 6.2 toolchain (`swift-tools-version:6.2` in `Package.swift`).
- [Bun](https://bun.sh), for the Phone page and for app panes (custom apps). App panes run in zsh, so
  `bun` must be on zsh's PATH. The Phone page looks for it at `~/.bun/bin/bun`, `/opt/homebrew/bin/bun`
  and `/usr/local/bin/bun`.
- The [Claude Code](https://claude.com/claude-code) CLI, on the PATH of the account's login shell: Claude
  panes run `claude` through that shell, so the shell's startup files have to find it. That shell is the
  account's own only when it is zsh, bash or sh; for any other, such as fish, panes use `/bin/zsh`, so
  `claude` has to be on zsh's PATH too.
- [Tailscale](https://tailscale.com), for peers and for the Phone page. Launchy looks for its command
  line in the Tailscale app, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`.
- Chrome, if you want its history and bookmarks searched. No other browser is read.

## Build and install

Build and run through the `Makefile`:

```
make build      # builds, codesigns, and fetches the files below
make run        # builds, then restarts Launchy from this checkout
make install    # builds, then starts Launchy now and at each login, through a LaunchAgent
make uninstall
```

Plain `swift build` is not enough. `make build` also re-signs the binary so macOS binds its
`Info.plist` (the microphone and system audio usage strings), downloads MLX's prebuilt Metal shaders
(`mlx.metallib`), which `swift build` cannot compile without Xcode, and downloads the pinned zmx release
(below). Both downloads are checked against SHA-256 digests in the `Makefile`. The first build is slow:
it resolves and compiles the Swift packages.

`make install` also links this checkout's `custom-apps` skill into `~/.claude/skills/` so Claude Code in
any project can find it. It links only when nothing is at that path, or when the link there already
points into this checkout; any other entry is left as it is, and `make uninstall` removes only a link that
points into this checkout.

Launchy reads and writes a few places outside the checkout: `~/Library/Application Support/Launchy` (saved
tabs, models, transcripts and other state), the macOS Keychain (the TypeSafe key, if you save one), and
its own preferences.

### Restarting ends sessions that aren't kept in zmx

Launchy runs each Claude and terminal pane as its own child process. Restarting it, which `make run`
and `make install` do, quitting it, or a crash ends every pane's process. Claude conversations resume
(`claude --resume`), but work in flight does not.

Settings › **Keep sessions running** avoids that: it runs each pane's process in [zmx](https://github.com/neurosnap/zmx),
which keeps it alive and lets Launchy reconnect after a restart. It is off until you turn it on. It
needs the zmx the build fetches, and Launchy only ever uses the copy next to its binary. A reboot or a
logout ends the sessions either way.

## Defaults for a new install

- **Skip permissions is off.** Claude sessions start with Claude's permission checks on. The setting
  (Settings › Skip permissions) starts them with `--dangerously-skip-permissions` instead: Claude then
  runs tools without asking. See [`SECURITY.md`](SECURITY.md).
- **The relevance filter is off** unless a TypeSafe key is present, in the Keychain, in the environment
  as `TYPESAFE_API_KEY`, or in `.env`. See Privacy below for what turning it on sends.
- **Keep sessions running** is off (above), and so are Listening, Point at the screen and the Phone page.
- **`make install` leaves a skill link it didn't make alone** (above).

A Mac that ran an earlier Launchy keeps what it stored. One that has Launchy's sessions file but never
stored a Skip permissions choice keeps Skip permissions on (it is stored as on at the first launch of this
version); turn it off in Settings.

## Optional parts

### Peers

Launchy on one Mac can pair with Launchy on another Mac, and with a headless host, over SSH with your own
keys. A session runs on one host and stays there; another Mac shows its live screen and can take over.
Add a peer in Settings › Peers (Find Macs searches your tailnet, or add by address as `<user>@<host>`).
The peer list and your SSH keys are the boundary: see [`SECURITY.md`](SECURITY.md). Settings › Peers also
shows each Mac's build and can upgrade it from `origin/main`, which fetches and builds the checkout
(again, see [`SECURITY.md`](SECURITY.md)).

### The Linux relay

A headless host (a Linux machine with no Launchy app) runs Launchy's relay alone. Install it from a Mac, from this checkout:

```
scripts/install-peer.sh <user>@<host> [--name NAME] [--page | --no-page] [--uninstall]
```

The installer builds `Packages/LaunchyPeer` on the host, so the host needs:

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
session and a terminal. It is off by default (Settings › Serve the phone page; on Linux, `--page`). It
needs Bun and Tailscale. It is published with `tailscale serve` on HTTPS port 8444, to your tailnet only,
and each device you list on a host is identified by Tailscale. [`SECURITY.md`](SECURITY.md) explains what
that does and does not protect, including a mode in which any program on the Mac can reach it.

### Listening

Listening transcribes your microphone and what the Mac plays, on this Mac, into a text file for the day
(`Launchy/transcripts/` under Application Support). It is off at each launch and needs macOS 26. macOS asks for
the microphone and system audio permissions the first time.

### Point at the screen

With Hey Launchy on, Settings › Listening › **Point at the screen** lets you ask about what is in front of
you ("Hey Launchy, where's the Allow button"). Launchy reads the elements of the window that has focus
through macOS Accessibility, in its own process, asks TypeSafe's Jev which one you mean, draws a big arrow
and a sign on it that never takes focus or clicks, says what it is, and takes the arrow away a few seconds
later. It needs the Accessibility permission, which Settings asks for and shows, and the relevance filter
on TypeSafe with a key (see Privacy below for what is sent). When the thing isn't among the window's
elements, or the window is a Chrome page, whose content the elements don't hold, and Screen Recording is
also granted, Launchy captures that window alone into memory and reads its text with Apple's text
recognition on this Mac, so a Chrome page, a canvas app or a remote desktop can be pointed into. The
picture is never written to disk, logged or sent; only the short lines of text it finds go on, as below.
Without Screen Recording the elements' answer stands, and Launchy says it can't see inside Chrome's pages.
A rebuild of Launchy may need either permission given again. The permissions are Launchy's own. Sessions
kept running in zmx very likely don't get them, but a Claude or terminal pane that Launchy starts itself,
which is every pane while Keep sessions running is off, probably does: see [`SECURITY.md`](SECURITY.md).

### TypeSafe

The relevance filter can run on [TypeSafe](https://www.typesafe.ai)'s API, with your own key (Settings
saves it in the Keychain, or it is read from `TYPESAFE_API_KEY` in the environment or from `.env`). What
it sends is under Privacy.

### On-device models

These download from Hugging Face when you ask (Settings), and run on this Mac with MLX.

| Model | Used for | Download |
|---|---|---|
| Qwen3-Embedding-0.6B (8-bit) | Search by meaning | about 650 MB |
| Gemma 4 E2B (4-bit) | Titles for sessions | about 3.6 GB |

Their licences are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Each of these two can instead run on a model server on your tailnet (Settings › Models › Server); Privacy
says what that sends.

"On this Mac" is also a choice for the relevance filter. It runs a small checkpoint distilled from
TypeSafe's judgments on a person's own history, and that checkpoint is not published: the choice needs
you to import one you have made yourself, and Launchy has no recipe to make it. The two evaluation commands
(`Launchy --rerank-eval` and `Launchy --search-eval`) need labelled data of your own, so they are of use to
someone developing the filter, not to someone using Launchy.

## Things that stay as they are

- **The database** is a SQLite file in this checkout's `db/` folder (`db/launchy.sqlite`), where `make run`
  and `make install` point Launchy. The `LAUNCHY_DB` environment variable overrides the path. `make
  clean` removes `.build/` and keeps `db/`, since it holds history Chrome may have already dropped.
- **`.env` is read from Launchy's working directory**, which is this checkout under `make run` and
  `make install`.
- **Only Chrome's history** is read, and the lookups for `bun` and `tailscale` use the fixed locations above.

## Privacy

Launchy works on your own data, mostly on your Mac. What it reads, records and sends:

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
- **With a TypeSafe key and the relevance filter on TypeSafe,** it sends each search to TypeSafe's API
  with the title, site and page description of up to 20 results. It does not send full addresses or tags.
  The filter is off by default (above). With Hey Launchy on, it also sends TypeSafe's Jev the text you
  say after "Hey Launchy", to choose where to look, with no titles, names or results. Then the request is
  searched and filtered as a typed search is, so its search words and the title, site and page description
  of its first 20 pages go to TypeSafe too. This starts before you have quite finished, so if you go on
  speaking, words said so far may be sent and then discarded. With the filter On this Mac or off, nothing leaves.
- **With Point at the screen on** (Settings › Listening, off by default, and only available with the filter on
  TypeSafe and a key), a request that is about the screen also sends TypeSafe the title of the window in
  front and, for each of its first 255 elements, the label, kind and nearby text. That is the window's
  visible text, not only that near its controls: a message list's subjects and senders, an open mail's body in
  Mail, a page's text in Safari, a file's name in a tab, the account's name in a sidebar. What is typed in a
  field is never read. None of this goes to a model server. If the elements don't have the thing, and Screen
  Recording is granted, a picture of the window alone is also read on this Mac, and its short lines of text
  (at most 6 words and 60 characters each, at most 150) go too, so more of the window's text leaves: every
  short line, such as a message list's subjects and senders or a chat's names. Lines inside a text field
  are dropped, but in a Chrome page the fields can't be seen, so something typed there may go. The
  picture, the lines' positions and longer lines never leave the Mac.
- **It downloads its models from Hugging Face** when you ask.
- **With Server chosen for Search embeddings or Text generation** (Settings › Models, off until you
  choose it), it sends to an OpenAI-compatible server you name, on your tailnet or this Mac and nowhere
  else: the searches you type, the prompts typed in the panel, the text of every page and session it
  embeds, which for a session includes Claude's last reply to each prompt (the paired Macs' sessions included), and each conversation's first prompt for a title. With
  Hey Launchy on, the words you say after "Hey Launchy" and the request's search words go to the
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

## Licence

Launchy is licensed under the Apache License 2.0 (see [`LICENSE`](LICENSE)).

Copyright 2026 Zabaca

Third-party code and models are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
