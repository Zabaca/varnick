# Guide

What each part of Varnick needs, does and starts as. The words it uses (Session, Pane, Peer, Host and the rest)
are defined in [`CONTEXT.md`](../CONTEXT.md). What leaves your Mac, feature by feature, and what each
setting lets others do, is in [privacy and security](privacy-and-security.md).

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

## Install and update

Download `Varnick.dmg` from [the latest release](https://github.com/Zabaca/varnick/releases/latest) (the
link `https://github.com/Zabaca/varnick/releases/latest/download/Varnick.dmg` always reaches the newest
one). The app and the disk image are signed and notarized, so macOS opens them without a security warning.
Each release also carries `Varnick.zip`, the same app zipped.

1. Open the disk image and drag Varnick onto Applications in its window, then open it from Applications.
   Opened straight from the disk image or from Downloads, Varnick offers **Move to Applications**: it moves
   itself there, opens the moved copy and ejects the image, so peers and the Phone page never point at a
   path that is gone at the next launch. If it can't (Applications isn't writable, or a Varnick is running),
   it says why and quits.
2. macOS asks for permissions when a feature first needs one, not at the first launch. Listening asks for
   the microphone and system audio; Point at the screen and Screen access ask for Accessibility and Screen
   Recording (Settings shows each and has a button to grant it). Screen Recording takes effect after a
   restart, which Settings offers.
3. Settings › **Open at login** (off until you turn it on) starts Varnick with your Mac through Login Items.
   Remove it there or in System Settings.
4. The app writes its log to `~/Library/Logs/Varnick.log`, and keeps its state in
   `~/Library/Application Support/Varnick`. One Varnick runs per account: a second one says where the
   first runs from and quits.

**Updating.** The app does not update itself. Quit Varnick (the menu bar menu), then replace the app in
Applications with the one in the newest download. Replacing it while it runs would leave peers reaching the
new executable before Varnick has restarted. Settings › Peers says "Installed app: update it by downloading
the newest build" for a Mac that runs the app.

To build it yourself instead, see [`building.md`](building.md).

## Defaults for a new install

- **Skip permissions is off.** Claude sessions start with Claude's permission checks on. The setting
  (Settings › Skip permissions) starts them with `--dangerously-skip-permissions` instead: Claude then
  runs tools without asking. See [privacy and security](privacy-and-security.md#skip-permissions).
- **The relevance filter is off** unless a TypeSafe key is present, in the Keychain, in the environment
  as `TYPESAFE_API_KEY`, or in `.env`. See [privacy and security](privacy-and-security.md#typesafe) for what turning it on sends.
- **Keep sessions running** is off (below), and so are Listening, Point at the screen, Screen access and the
  Phone page.
- **`make install` leaves a skill link it didn't make alone** (see [`building.md`](building.md)).

A Mac that ran an earlier Varnick keeps what it stored. One that has Varnick's sessions file but never
stored a Skip permissions choice keeps Skip permissions on (it is stored as on at the first launch of this
version); turn it off in Settings.

## Restarting ends sessions that aren't kept in zmx

Varnick runs each Claude and terminal pane as its own child process. Restarting it, quitting it, or a crash ends
every pane's process. Claude conversations resume (`claude --resume`), but work in flight does not.

Settings › **Keep sessions running** avoids that: it runs each pane's process in [zmx](https://github.com/neurosnap/zmx),
which keeps it alive and lets Varnick reconnect after a restart. It is off until you turn it on. It
needs the zmx that ships with Varnick, and Varnick only ever uses the copy next to its binary. A reboot or a
logout ends the sessions either way.

The menu bar menu's **Restart Varnick** (just above Quit) asks first and lists the panes that would end, if any.
In the installed app it opens a new copy of the app and quits this one; the new copy waits for this one to let go.
From a checkout it restarts without building, with `scripts/restart.sh`, so the macOS permission grants a build
would void stay. If a build has run since Varnick started, the restart starts that build and macOS asks for the
permissions again; the question says so. The item is hidden when the checkout's `scripts/restart.sh` or the
database can't be found from where Varnick runs, and a restart waits while a build is running.

## Peers

Varnick on one Mac can pair with Varnick on another Mac, and with a headless host, over SSH with your own
keys. A session runs on one host and stays there; another Mac shows its live screen and can take over.
Add a peer in Settings › Peers (Find Macs searches your tailnet, or add by address as `<user>@<host>`).
The peer list and your SSH keys are the boundary, and pairing copies your history and Claude prompts to the
other Mac: see [privacy and security](privacy-and-security.md#peers-over-ssh).

Settings › Peers also shows each Mac's build and can upgrade it from `origin/main`, which fetches and builds the
checkout (see [privacy and security](privacy-and-security.md#upgrades-from-originmain)). Only a Mac that runs a checkout can be upgraded this way; an
installed app is updated by downloading the newest build. A Mac on the app speaks the protocol of the build it
was made from, so when `main` has moved on, the two kinds of Mac may only be able to exchange hellos until the
app is updated.

A headless Linux host runs Varnick's relay alone, installed from a checkout: see
[`building.md`](building.md#the-linux-relay).

## The Phone page

A web page each host can serve to your own devices, such as a phone: the host's sessions, Recent, a new
session and a terminal, typed into with the phone's own keyboard plus one row of the keys it lacks (Esc, Tab,
Shift+Tab, the arrows and a sticky Ctrl). It is off by default (Settings › Serve the phone page; on Linux,
`--page`). It needs Bun and Tailscale. It is published with `tailscale serve` on HTTPS port 8444, to your tailnet
only, and each device you list on a host is identified by Tailscale. [Privacy and security](privacy-and-security.md#the-phone-page) explains what
that does and does not protect, including a mode in which any program on the Mac can reach it.

## Listening

Listening transcribes your microphone and what the Mac plays, on this Mac, into a text file for the day
(`Varnick/transcripts/` under Application Support). It is off at each launch and needs macOS 26. macOS asks for
the microphone and system audio permissions the first time.

## Point at the screen

With Hey Varnick on, Settings › Listening › **Point at the screen** lets you ask about what is in front of
you ("Hey Varnick, where's the Allow button"). Varnick reads the elements of the window that has focus
through macOS Accessibility, in its own process, asks TypeSafe's Jev which one you mean, draws a big arrow
and a sign on it that never takes focus or clicks, says what it is, and takes the arrow away a few seconds
later. It needs the Accessibility permission, which Settings asks for and shows, and the relevance filter
on TypeSafe with a key (see [privacy and security](privacy-and-security.md#typesafe) for what is sent).

With Varnick's own panel open and in front, it looks in the panel first, as in any window, and reads the app
behind it only when the thing isn't there; a terminal pane's text is not in the panel's elements, so it can't be
pointed into. When the thing isn't among the window's elements, or the window is a Chrome page, whose content the
elements don't hold, and Screen Recording is also granted, Varnick captures that window alone into memory and
reads its text with Apple's text recognition on this Mac, so a Chrome page, a canvas app or a remote desktop can
be pointed into. The picture is never written to disk, logged or sent. Without Screen Recording the elements'
answer stands, and Varnick says it can't see inside Chrome's pages.

A rebuild of Varnick may need either permission given again. The permissions are Varnick's, and every
Claude session and shell in its panes gets them too, kept running in zmx or not: see
[privacy and security](privacy-and-security.md#screen-permissions-reach-every-pane).

## Screen access

Settings › Claude › **Screen access** (off by default) gives the Claude sessions you start or restart in
Varnick's panes three tools, from an MCP server named `varnick`: `look` at the controls of a window on your Mac,
`point` at one with the same big arrow Point at the screen draws, signed with the session's name and its
note, and `click`. A session that hits a setting it can't see can look, show you where to click, or click
for you. The server is Varnick's own binary (`Varnick --mcp`) and only passes each call on: the running
Varnick does the reading, drawing and clicking, with the code Hey Varnick uses. It needs Accessibility, and
Screen Recording to read the text of a window that lists nothing or of a Chrome page; Settings asks for
both.

**A click happens without asking**: the arrow shows on the target for a second first, and there is no
`type`. A session started with Skip permissions has no prompt before a tool at all; one without gets Claude
Code's own prompt for a tool you haven't allowed, and its per-tool rules can allow `look` and `point` while
still asking for `click` (not checked). A session gains the tools when it starts, so restart a running one
(⌘⌥R) after turning the switch on; turning it off stops every session's tools at once. It is independent of
Point at the screen and Hey Varnick. See [privacy and security](privacy-and-security.md#anthropic-through-screen-access)
for what a session is shown.

## TypeSafe

The relevance filter can run on [TypeSafe](https://www.typesafe.ai)'s API, with your own key (Settings
saves it in the Keychain, or it is read from `TYPESAFE_API_KEY` in the environment or from `.env`). Choosing
TypeSafe is consent to send what its features need; with On this Mac, or the filter off, nothing goes to
TypeSafe. What it sends is in [privacy and security](privacy-and-security.md#typesafe).

## On-device models

These download from Hugging Face when you ask (Settings), and run on this Mac with MLX.

| Model | Used for | Download |
|---|---|---|
| Qwen3-Embedding-0.6B (8-bit) | Search by meaning | about 650 MB |
| Gemma 4 E2B (4-bit) | Hey Varnick's answers | about 3.6 GB |

Their licences are in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

Each of these two can instead run on a model server on your tailnet (Settings › Models › Server);
[privacy and security](privacy-and-security.md#a-model-server-you-name) says what that sends.

"On this Mac" is also a choice for the relevance filter. It runs a small checkpoint distilled from
TypeSafe's judgments on a person's own history, and that checkpoint is not published: the choice needs
you to import one you have made yourself, and Varnick has no recipe to make it. The two evaluation commands
(`Varnick --rerank-eval` and `Varnick --search-eval`) need labelled data of your own, so they are of use to
someone developing the filter, not to someone using Varnick.
