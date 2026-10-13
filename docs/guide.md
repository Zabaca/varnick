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
- [Bun](https://bun.sh), only for the Phone page and for app panes ([custom apps](#custom-apps)). App panes run in zsh, so
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
- **Keep sessions running** is off (below), and so are Listening, Point at the screen, Screen access, Panel access, the
  Phone page and the Problems board (Experimental, below).
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
would void stay. It starts Varnick through launchd, so Varnick holds its own permissions and not those of the terminal
it was restarted from. If a build has run since Varnick started, the restart starts that build; if it is signed ad hoc,
macOS asks for the permissions again, and the question says so. The item is hidden when the checkout's `scripts/restart.sh` or the
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

A web page each host can serve to your own devices, such as a phone: the host's sessions under their tabs, Recent (its closed tabs), a new
session and a terminal, typed into with the phone's own keyboard plus one row of the keys it lacks (Esc, Tab,
Shift+Tab, the arrows and a sticky Ctrl). It is off by default (Settings › Serve the phone page; on Linux,
`--page`). It needs Bun and Tailscale. It is published with `tailscale serve` on HTTPS port 8444, to your tailnet
only, and each device you list on a host is identified by Tailscale. [Privacy and security](privacy-and-security.md#the-phone-page) explains what
that does and does not protect, including a mode in which any program on the Mac can reach it.

## Listening

Listening transcribes your microphone and what the Mac plays, on this Mac, into a text file for the day
(`Varnick/transcripts/` under Application Support). It is off at each launch and needs macOS 26. macOS asks for
the microphone and system audio permissions the first time.

Settings › Listening › **Save audio** (off by default) also keeps the sound. Each run of Listening, which starts
again when the microphone or output device changes, writes two m4a files, the mic's and the Mac's audio:
`Varnick/recordings/<yyyy-MM-dd>/<HH-mm-ss>-mic.m4a` and `…-system.m4a` under Application Support, named by when
the run started. A run longer than 15 minutes goes on in new files named by their own start time, so a crash
loses at most the last 15 minutes. A source that delivered no audio leaves no file. The setting is read each time
Listening starts or restarts. The files stay on this Mac and Varnick never deletes them.

Hey Varnick speaks in a voice installed on your Mac (Settings › Listening › Voice). To hear a natural one instead,
save an ElevenLabs API key under Settings › Models › Keys (it needs the Text to Speech and Voices Read
permissions) and pick one of your account's voices in the same Voice list. That sends everything Varnick speaks to
ElevenLabs ([privacy and security](privacy-and-security.md#elevenlabs)). The installed voice you had stays as the
Fallback voice and speaks when ElevenLabs fails or takes more than 1.5 seconds to start.

With Text generation on **Claude Code** (Settings › Models; the default for a new install, while installs that already
answered with Gemma stay on On this Mac), your own `claude` writes Hey Varnick's answers on your Claude subscription,
with Claude Haiku: no tools, none of your settings, hooks, plugins, CLAUDE.md or memory, and no transcript saved, so
these calls never show as sessions. Turning Hey Varnick on needs `claude` found and logged in (Settings › Models
shows it, and Check times a call); no model has to download. That sends what you say and the few results it reads
to Anthropic ([privacy and security](privacy-and-security.md#anthropic-through-text-generation)), and each answer
counts toward your plan's usage limits. When Claude Code can't answer, or takes more than a few seconds, Gemma writes the text
if you have installed it (the **Fallback on this Mac** row), and Claude Code rests for a minute.

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
Varnick's panes six tools, from an MCP server named `varnick`: `look` at the controls of a window on your Mac,
`point` at one with the same big arrow Point at the screen draws, signed with the session's name and its
note, `click`, `type` (text and key combos), `drag` between two controls or points, and `window` to move or
resize one. A session that hits a setting it can't see can look, show you where to click, or do it
for you. The server is Varnick's own binary (`Varnick --mcp`) and only passes each call on: the running
Varnick does the reading, drawing and acting, with the code Hey Varnick uses. It needs Accessibility, and
Screen Recording to read the text of a window that lists nothing or of a Chrome page, or to return a picture;
Settings asks for both.

`look` with `picture` also returns an image of the window (or of one area of it). It shows everything on the
window, typed text included, which the listing leaves out, and goes to Anthropic with the session. Password
fields Varnick can see are painted black first; the ones it can't see are listed in
[privacy and security](privacy-and-security.md#anthropic-through-screen-access).

`look` with `screen` returns an image of every display instead, or with `display` and a number, of one; `rect`
crops them. The reply lists the displays with their frames, and says each image's area and pixels per point, so
a session can turn a place in an image into a point to click. It lists no controls unless an app is named too. It
needs Screen Recording. **Nothing in it is hidden:** it shows everything on those displays, Varnick's own window
and other sessions, what you typed and any password field, and goes to Anthropic with the session.

**Nothing asks before an action**: the arrow shows on the target for a second first, then the app comes to the
front (not for `window`) and a click, typing, drag or resize happens. `look` also says which control has focus.
What `type` refuses, when it stops, and what is and isn't logged: see
[privacy and security](privacy-and-security.md#screen-access-acts-without-asking). A session
started with Skip permissions has no prompt before a tool at all; one without gets Claude
Code's own prompt for a tool you haven't allowed, and its per-tool rules can allow `look` and `point` while
still asking for `click`, `type`, `drag` and `window` (not checked). A session gains the tools when it starts, so restart a running one
(⌘⌥R) after turning the switch on; turning it off stops every session's tools at once. It is independent of
Point at the screen and Hey Varnick. See [privacy and security](privacy-and-security.md#anthropic-through-screen-access)
for what a session is shown.

## Resources

⌘⇧M (or `!resources`, also found as `!memory`) shows how much memory Varnick uses and what uses it, in place of the panel's
content as the session board does; the same key again, or esc, goes back. The figures are footprints, the number Activity
Monitor's Memory column shows. At the top are Varnick's total and its process count, and the same processes grouped by
kind (the app, Claude Code, MCP tools, web pages, the Phone page server, app servers, zmx, shells and other). Under it is the
app's own memory: what the on-device models hold (MLX's own count, naming the models loaded now), its graphics memory
beyond that, and everything else. The tabs that run on this Mac follow, biggest first; → opens one into its panes and their
processes (Claude Code, its MCP tool, the commands it runs, a terminal's shell and what runs in it, an app's server, a page's
WebKit process, zmx), and ↩ shows the tab. The Close button on a tab, or your End session key (⌘W) on the selected one, closes
it as its × does, so a tab with a Claude conversation goes to Stopped and Recent, and a session that must ask first brings its
tab up to ask. Below the tabs are what Varnick runs that belongs to no tab (the Phone page server, the text helper, WebKit's
shared processes, links to other machines), the tabs of other machines open here (they show where they run and no figures,
since their memory is on that machine), and, greyed, the Claude Code that runs in other apps and terminals, so the figures
add up to Activity Monitor's. A process is Varnick's only when its ancestry leads to Varnick or to one of its zmx sessions,
never by its name. Rows keep their order while the view is open, and the figures are read every 3 seconds only while it
shows in a visible panel; Varnick runs no other program to read them. WebKit gives no public way to tell which process runs a
web page, so Varnick asks WebKit's private interface and macOS's private "responsible process" call; if a macOS update removes
either, pages show together outside the tabs, or drop out of the total (the view says so in that case).

## Panel access

Settings › Claude › **Panel access** (off by default, and independent of Screen access) gives the Claude sessions
you start or restart in Varnick's panes tools for Varnick itself, from the same `varnick` MCP server. `panel` says
whether the panel is visible, key and pinned, what it shows (the search and its mode, never what is typed in it; a
tab and its panes, with this session marked and the focused pane; the session board and its selected card;
the Outline, with its zoom, filter and caret; Resources, by name only; Settings) and what has the keyboard. `board_read` gives the session
board's cards, one per tab with its sessions listed under it, by column (Running, Stopped, Completed) as the board
shows them, or with `tab: problems` the Problems tab's, while that switch is on. Each pane gets an id such as `s1`
(a card its tab's, a session its pane's), the same every time, in all of them. `pane_read` gives a pane's kind and
title and, for a terminal (a Claude session or a shell, this session's own included), the text its screen shows now,
never its scrollback; for a pane showing a card, the last screen the card holds with its time; for a page, a file or
a custom app, its kind and title only. **A terminal's screen holds whatever is on it, secrets included.** `outline_read` gives
your Outline's bullets: by default the tree from Home, or
from a bullet, three levels down (`depth` 0 for all), with each bullet's id (`o1`, the same every time), text, whether it
is done, collapsed or a mirror, its tags and its note, and which ones your view hides; with `as_shown`, the rows exactly
as you see them, with your zoom, your filter, Show completed, the caret and the selected bullets. It reads whether or not
the Outline is showing, at most 400 rows at a time, and never writes the file; if `outline.json` can't be read it is
refused. **Your bullets and notes go to Anthropic with the session**, though they are otherwise kept on this Mac only.
`outline_act` edits the Outline **without asking**: it adds bullets (indented lines nest), sets a bullet's text or note,
completes, deletes, moves, indents, outdents, collapses or mirrors one, through the Outline's own edits. Each is one step
of your undo, so ⌘Z takes it back, and your caret stays where it was in the text unless the edit moves or removes its
row, when it goes where the same key would put it. A session changes a bullet's text or note only after reading that row, and only if it is
still as it read it (it is told to read again if you typed in it since). In the bullet you are typing in, the change goes in as if typed: your
caret keeps its place in your text, your next key adds to the new text, and ⌘Z takes back the session's change alone; while an input
method is composing there, it waits for the composition to end.

`show` changes what the panel shows, through the same functions its keys and `!` commands use: `view` search,
board, problems (the Problems tab, while that switch is on) or outline, `pane` an id from `panel` or `board_read` (shows
that pane's tab with the pane focused), or `command` the name of a `!` command (`transcript`, `kanban`, `problems`, `outline`, `resources`).
It never shows, hides or pins the panel: with the panel hidden, what it showed is there the next time you open it.
It never runs `!listen`, which turns on the microphone. It never takes the keyboard from the app you are in, never clears what you typed in the search, and is refused while
Settings, the Restart Varnick card or the split picker shows, for two seconds after you press a key in the panel,
and, with the panel hidden, for a pane's tab or while a terminal is on screen. Showing the Outline puts the caret in a
bullet only if the panel already has the keyboard. The tools work through
Varnick's own state, so they need no permission, no Accessibility and no Screen Recording. What a session reads goes to
Anthropic with the session: see [privacy and security](privacy-and-security.md#anthropic-through-panel-access). A
session gains the tools when it starts, so restart a running one (⌘⌥R) after turning the switch on; turning it off
stops every session's tools at once.

## Custom apps

A custom app is a small web server in a folder of its own. It is listed in the split picker (⌃⌘⇧E or ⌃⌘⇧O),
run when you pick it, and shown in a pane. It needs [Bun](https://bun.sh) on zsh's PATH.

- **The catalog.** Settings › **Apps** lists the apps that ship with this release of Varnick, reviewed in its
  repository. Each row says what the app does and what it fetches, and has a switch, off until you turn it on.
  - **On** copies the app into `~/.varnick/custom-apps/<name>/`, with a hidden marker file saying Varnick put it
    there, so it shows in the picker in every project. If the app has a skill, Varnick links it as
    `~/.claude/skills/<name>`, but only when nothing is at that path, so Claude in a session started afterwards
    knows how to use the app. Turning on fetches nothing: an app's packages install with Bun the first time you
    pick it, frozen to the lockfile that shipped with the app. Offline, the pane shows Bun's error, and reload (⌘R) tries again.
  - **Off** moves the copy to the Trash and removes the skill link if it is Varnick's. It is refused while a pane
    runs the app. The app's data is kept, so turning it on again finds it.
  - **A newer release** refreshes an installed app at launch, when no pane runs it. One that is open waits for a
    launch where none is.
- **Your own.** Ask Claude in a session to make a custom app: the `custom-apps` skill, which Varnick links into
  `~/.claude/skills`, tells it how. The last line of Settings › Apps has a button that shows your apps folder.
- **Where apps live.** In `~/.varnick/custom-apps/` for every project, or `<project>/.varnick/custom-apps/` for
  one. A project's app hides a user's of the same name, a catalog app's included, and Settings can't see
  projects, so it doesn't say when that happens.
- **The installed copy is Varnick's.** A refresh replaces it, so an edit made in it is lost at the next update
  that changes the app (the old copy is in the Trash). To change a catalog app, copy its folder under another
  name: that app is yours, and Varnick never touches it. A folder of yours with a catalog app's name keeps its
  switch off, and the row says why.
- **Data.** An app's own files are in `~/Library/Application Support/Varnick/app-data/user/<name>/` for a user
  app, and under a folder named for the repo and a hash of its path for a project's.
- **Rights.** An app runs with your rights, and its panes have Varnick's macOS permissions. The catalog is
  reviewed but not sandboxed: see [privacy and security](privacy-and-security.md#custom-apps).

## Experimental

Settings › **Experimental** holds a switch for each feature that is still being tried, all off until you turn them on.

**Problems board** is for a project that plans its work in `docs/problems/` the way Varnick's own repository
does (problems, options, the `/work` skill and the planner and builder agents, which live in that
repository's `.claude/`). On, the session board has a Problems tab beside Sessions (`!problems`, and Tab switches
between them) and each Claude session Varnick starts on this Mac carries the hooks that link it to the problem
or option it works on. Off, the board shows Sessions only, `!problems` is not listed, and sessions started
after that get none of those hooks; sessions already running keep the hooks they started with. Links already
recorded are kept, so turning it on again shows them. Each Mac decides for the sessions it starts, whoever asks
for them, and a headless host decides with `scripts/install-peer.sh <user@host> --problems` or `--no-problems` (a host
that has neither runs without). `Varnick --problems` prints the board's columns whatever the switch says.

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
| Gemma 4 E2B (4-bit) | Hey Varnick's answers, when Text generation is On this Mac, and its fallback when Claude Code can't answer | about 3.6 GB |

Their licences are in [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

Each of these two can instead run on a model server on your tailnet (Settings › Models › Server);
[privacy and security](privacy-and-security.md#a-model-server-you-name) says what that sends. Text generation can also
run as your own Claude Code, which is its default for a new install and needs no download.

"On this Mac" is also a choice for the relevance filter. It runs a small checkpoint distilled from
TypeSafe's judgments on a person's own history, and that checkpoint is not published: the choice needs
you to import one you have made yourself, and Varnick has no recipe to make it. The two evaluation commands
(`Varnick --rerank-eval` and `Varnick --search-eval`) need labelled data of your own, so they are of use to
someone developing the filter, not to someone using Varnick.
