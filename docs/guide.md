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
- **A session with no `#project` starts in Home,** a folder of Varnick's own, `~/Library/Application Support/Varnick/Home`, made the
  first time it is needed. It is not your home folder, and there is no setting for it. A session started from nowhere in particular
  doesn't land in a repo. Varnick also marks Home trusted in Claude Code, so Claude doesn't stop to ask
  ([privacy and security](privacy-and-security.md#home-is-marked-trusted-in-claude-code)). Resumed sessions keep their own folder.
- **Tabs that don't fit** is Shrink (below).
- **The projects column is hidden** (⌘⇧P shows it; below).
- **Keep sessions running** is off (below), and so are Listening, Point at the screen, Screen access, Panel access, the
  Phone page, the Problems board, the Outline, Tasks and Automations (Experimental, below).
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

## Notices

Varnick tells you when a Claude session needs a look, without a macOS notification, so nothing asks for a permission. When
a session's turn ends, stops on a permission dialog, a question, a plan to approve or an MCP request, or stops on an API
error (a rate limit, say), the menu bar icon gets a dot (orange for a dialog or an error), a system sound plays (softer for
a finished turn) and the menu lists the session at the top, newest first, with its Mac when it runs on another one and what
happened. Choosing it shows the panel on that pane.

- **Not for what you are looking at.** Nothing is raised for the pane on screen when the panel is the key window, nor
  for any pane while the session board shows. A notice is cleared when its pane comes on screen or closes, or when the
  session's turn moves on (you answered a dialog, or sent a prompt). A pane has one notice at most.
- **Done means done.** A turn that leaves background agents, teammates, workflows or shells running stays quiet until they
  have all ended. Stopping Claude yourself with Esc gives no notice.
- **One Mac.** A session raises its notice on the Mac that is in control of it. A pane that shows a card (another Mac or the
  phone is in control, or its host doesn't answer) is silent. A session on a paired Mac is read every 5 seconds, so Done can
  come up to 5 seconds late. Sessions already waiting when Varnick starts, or when a Mac comes back, raise nothing, and
  notices are not kept across a restart.
- **Switches.** Settings › Claude › **Notify me when a session…** has one for each of needs me, is done, stops on an
  error and sends me a message, all on by default.
- **A session can tell you something itself.** Every Claude pane has a `notify` tool (a title and an optional body), and
  Claude Code's own push notification, where you have it on, counts too. Ask a session "notify me when the tests pass" and
  it raises a notice of its own: the orange dot, the louder sound and the menu line showing the message's title. A turn
  that ends right after a message adds no second notice, a session alerts at most once a minute, and the message clears
  at your next prompt or a `/clear`. A pane started before this build has `notify` after its next start. On the phone the
  message comes after 2 seconds, with the message as the notification on the tailnet and only "a session sent you a
  message" off it. While a host has a phone subscribed, Varnick tells Claude Code not to send its own mobile push, so the
  phone is not buzzed twice.
- **A session that stopped on an error** shows "API error" on its board card, in Stopped. A paired Mac on an older build
  shows "Turn not known" for it, and a headless host raises Done for it until its relay is reinstalled.

## Tabs that don't fit

The tabs sit in a strip across the top of a tab. Settings › Claude › **Tabs that don't fit** says what it does when
more tabs are open than fit:

- **Shrink** (the default) narrows the tabs together, widest first, down to 140 points, then puts the ones that still don't fit behind a
  **+N** chip at the end of the strip.
- **Fixed width** makes every tab 180 points, whatever its title, then **+N**.
- **Wrap** lets the tabs flow onto up to three rows, then **+N**. The tab loses the height of the extra rows.

The strip always shows the tab you are in, and ⌘⇧[ and ⌘⇧] bring the tab they switch to into view. **+N** chip opens a list of the
hidden tabs as the search lists them, with a line between those before the shown ones and those after; click or ↩ shows one, ↑ and ↓
move, esc closes. The chip turns orange while a hidden tab has a session waiting on you (a permission, a question, a plan to approve
or an MCP request), and that tab's row carries the same orange mark, as a row in the search does. Dragging reorders the tabs shown.

## The projects column

**⌘⇧P** shows a column left of the panes, as ⌘⇧F shows the file tree on the right. It lists **All**, then each project that has
open tabs, by name, then **Other** for tabs in no project (one started in Home, say). Each row shows how many tabs it has, and an orange
mark with how many of them have a session waiting on you.

- **A tab's project** is its first Claude pane's (a tab with none, its first pane's): the project whose folder is exactly that pane's
  folder when Varnick first saw it. It doesn't change as you move between panes, or when a shell in it changes folder. A pane in a subfolder or a worktree has no project, so its tab is under Other. Another Mac's tabs join the
  same rows by the project's name; hover a row to see how many tabs are on each Mac.
- **Choosing a row** shows only that project's tabs in the strip and brings up the one you last had open there, or its first.
  ⌘⇧[ and ⌘⇧] step through them. **All** brings every tab back and leaves the one on screen as it is.
- **⌃⌘[ and ⌃⌘]** choose the previous or next row, All included, with the column hidden too. Showing a tab of another project, from the
  search, the board or a new session, moves the choice to that project; closing the last tab of the chosen project moves it to All.
- **With the column hidden,** a chip at the strip's left names the chosen project, and clicking it lists the rows.
- **A narrow panel** shows the column only while the panes keep their minimum width beside it and the file tree. Otherwise ⌘⇧P
  lists the rows under the strip, as the chip does.
- **What it doesn't filter:** the search, the session board, Recent and the Phone page always cover every tab.

Whether the column shows is kept across restarts; the chosen project isn't, and the strip starts on All. The three keys can be
rebound in Settings › Shortcuts.

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

On the phone the page installs as an app, one for each host, named for it and opening full screen without the browser's bars. In Chrome
on Android the foot of the home page offers an Install button (or use Chrome's menu); in Safari on an iPhone, use Share › Add to Home
Screen. If the phone can't reach the host (Tailscale is off on it, or the host is asleep), the app says so instead of showing the
browser's error page; Try again loads the page once the host answers. The app keeps nothing of your sessions on the phone.

The page can also notify the phone. At the foot of the home page, Notifications has a switch (Turn on asks the phone's permission, from
that tap; on an iPhone it needs the page added to the Home Screen first). Each host is its own app and its own switch. With it on, the phone
gets a notification when a session of that host needs a permission, a question, a plan or an MCP input, finishes, stops on an API error
(with its kind) or sends a message of its own (Notices, above), each with a switch of its own (Needs me, Done, Errors, Messages), Send a test and Turn off. It comes when you are away from the Mac that
controls the session (CONTEXT.md, Presence, says how Varnick tells), after a short wait to be sure (10 seconds for Done, 2 for a session that needs you, stopped on an error or sent a message); at the Mac you get the Mac's own
notice and the phone stays quiet, nor does it buzz for a notice you have already seen at the Mac, and the phone has none for a session it has open. A session you
drive from the phone, or that runs on a headless host, always notifies it. With the phone on the tailnet the notification names the session;
off it, only the host. Tapping it opens that session. As on the Mac (Notices, above), a turn that leaves background agents or shells running gives
no Done until they have ended, so a shell forgotten in a session keeps its Done from the phone too. Every Mac and a headless host must run the same Varnick commit (protocol 28). Settings › Peers
says which of your devices get notifications from a Mac.

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

Hey Varnick asks TypeSafe's Jev (or, without it, your Text generation model) what each request means, then searches your
History, Bookmarks and Claude sessions together, judges which rows help, and answers from those out loud, saying "Let
me check." first when the answer isn't ready. A project you name or mean ("what did I do in <project>"; Varnick knows
each project's other names and what it does from its remote, `CLAUDE.md` and README) keeps the sessions to that
project's, and a time ("this morning", "yesterday evening", "last week", "on Monday") keeps them to the sessions used
then when only your own things can answer. "What time is it" and "what's the date" are answered from the Mac's clock,
and "set a timer" is told plainly that Varnick can't.

Settings › Listening › **Answer from the web** (off by default) answers from the web what none of that can, such as
when a shop opens: your own Claude Code searches for it, on your plan, and Varnick says "Looking that up." and then
where the answer came from. It needs Hey Varnick, the relevance filter on TypeSafe with a key, and Claude Code found
and logged in. A request that names a project, or that only your own things can answer, never goes to the web: Varnick says it found no
sessions then. What is sent is in [privacy and security](privacy-and-security.md#anthropic-and-a-search-provider-through-answer-from-the-web).

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

Settings › **Resources** shows the same table inside Settings, and measures only while that tab shows. ↑, ↓, →, ←, ↩ and your
End session key work there as in the view, and only while that tab is open; esc closes Settings. ↩ on a tab, or a tab that must
ask before it closes, brings the tab up, which closes Settings. ⌘⇧M while Settings shows closes Settings and opens the view.

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
a custom app, its kind and title only. **A terminal's screen holds whatever is on it, secrets included.** `outline_read` (only while Settings › Experimental › Outline is on; both Outline tools are refused otherwise) gives
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
between them) that reads your projects and Home (a `docs/problems/` in Home shows too, its cards marked Home), and each Claude session Varnick starts on this Mac carries the hooks that link it to the problem
or option it works on. Off, the board shows Sessions only, `!problems` is not listed, and sessions started
after that get none of those hooks; sessions already running keep the hooks they started with. Links already
recorded are kept, so turning it on again shows them. Each Mac decides for the sessions it starts, whoever asks
for them, and a headless host decides with `scripts/install-peer.sh <user@host> --problems` or `--no-problems` (a host
that has neither runs without). `Varnick --problems` prints the board's columns whatever the switch says.

**Outline** is your bullets, kept in a file on this Mac. On, ⌘⇧Y (or `!outline`, also found as `!wf`) shows it in place of
the panel's content. Off, which is how it starts, ⌘⇧Y goes to the pane as any unbound key does, `!outline` is not listed, Settings › Shortcuts
does not list the Outline, and Claude sessions' Outline tools stay listed but refuse. Its shortcut keeps its binding while hidden,
and binding ⌘⇧Y to another action leaves it alone. If it is showing when you turn it off, the panel goes back to
what was under it. Your outline file is never changed or removed by the switch, so turning it on again shows the same Outline.

**Automations** run a Claude prompt for you on a cadence, without opening anything. On, Settings gets an **Automations** page. An
automation is a name, a prompt (sent to Claude as written, as the first message), a folder (a project, or Home), an
optional agent (of that folder: Home has only your own, in `~/.claude/agents`, so to use a repo's agent choose that repo), a time and its permissions. Pick the time from the presets: every 15 or 30 minutes, every 1, 2, 3, 4, 6 or 12
hours, daily, weekdays, or weekly at a time, in this Mac's time zone. **Run now** tries one before you leave it to the clock.
- **A run is a Claude session like one you type,** started in the background. Its tab stays out of the tab strip, the session list,
  Recent and the board's Sessions tab until you open it, from the board's **Runs** tab (⌘⇧B, then Tab) or from its notice in the menu
  bar menu. It tells you as any session does: Done, Needs you, an error, or a message if the prompt asks for one ("…and notify me
  with the count"). Open while it works and you watch it live; open after it ended and its conversation is resumed in a new tab.
  The Runs tab also lists the slots that did not run and why: skipped, missed, couldn't start.
- **Claude sessions can manage them.** With Automations on, every Claude session you start (or restart) lists four Varnick
  tools: list, make, edit and turn on or off an automation, so "run this every weekday morning in this repo" works. There is no
  approval step of Varnick's: with Skip permissions off, Claude Code asks before each call. A session can't set Skip, edit
  an automation you set to Skip (it can switch it), delete one or run one now, and a run's own session never has the tools.
  What a session did shows under the automation in Settings and in the Runs tab, as a mark, until you open its editor, switch it
  or press **Seen**.
- **It runs only while Varnick does on this Mac,** or, for an automation kept on a headless host, on that host's own timer, with every
  Mac asleep. A slot that passed while the Mac slept or Varnick was quit runs once, when
  the Mac wakes or Varnick starts, if it is under 12 hours old; older ones are marked missed. At most one run of an automation goes
  at a time: a slot that falls due while the last run still works or waits on you is skipped. Keep sessions running must be on.
- **Permissions follow Settings › Claude's Skip permissions,** as a prompt you type does, unless the automation says Ask (its allowed
  tools run, anything else waits for you with Needs you), Allowed tools only (anything not allowed is refused with no dialog, and
  Claude goes on or ends) or Skip. A run never gets Screen access or Panel access tools, but like every pane it has Varnick's
  macOS permissions, so a shell command it may run can reach the screen: see [privacy and security](privacy-and-security.md#automations-act-while-you-are-away).
- **A run is ended, with its conversation kept,** when it works past the automation's limit (an hour unless you change it), after 24
  hours waiting on you, or 10 minutes after it finished if you haven't opened it. Each run draws on your Claude subscription.
- **A headless host keeps its own.** Settings › Automations has a section for each paired headless host: make an automation there
  (its projects and agents are the host's, an automation with no project runs in Home, a folder Varnick keeps on the host, and never in the account's own home folder, and "Varnick's setting" for permissions is the host's own Skip permissions), and the host fires it on a
  timer that its installer adds once (`scripts/install-peer.sh <user@host> --automations`; the section says when the timer isn't running). The Mac
  that last saved it holds each run and raises its notices; the Runs tab lists the host's runs beside this Mac's, and the phone lists runs nobody has
  opened under **Runs**. A host runs the Claude prompt only ("On this site" needs a Mac), and a Claude session's tools manage this Mac's automations only.
  Each Mac's Automations switch is its own: a host fires on whatever it says, and turning it off here only shows this Mac's views of those runs as ordinary tabs.
- Turning the switch off stops every run from starting and shows the tabs of runs you haven't opened as ordinary tabs. The
  automations are kept in `automations.json` in Varnick's support folder (each is a cadence and the Task it runs, for now always the
  built-in Claude prompt), and what became of each run in `runs.json` beside it.

**Tasks** hands Varnick something to do on a website: find a fact ("how much is delivery to Canada"), or fill in forms ("create an
account for Robin Vale"). On, `!task` and the split picker's Website tile open a **Website pane**, a browser of Varnick's own. It has none
of your cookies or logins, keeps nothing when you close it, and is not saved, so a restart ends it. Open the site in it, write what
to do in the line under the address bar and press ↩. A column of steps beside the page says what Jev, Claude and the harness do,
one line each, and Varnick can say the milestones aloud (Speak progress, on in the pane). It reads and acts inside the page only, never
on your screen, so it needs no permission and works while you use the Mac.
- **You type** passwords, one-time codes and card numbers in the page yourself (Varnick never reads them, and no model sees them),
  **you tick** the terms box, and **every form submit but a search asks**: Allow lets Varnick press it, I'll do it waits for you to
  press it in the page and then Resume.
- **A click or a key of yours in the page pauses the task** before its next action; Resume hands it back. Stop (the button, or
  ⌘.) ends it at once and leaves the page as it is. Closing the pane, turning the switch off or restarting Varnick ends it too.
- **Jev** chooses each step when the relevance filter is on TypeSafe with a key saved. Without it, or after it fails three times, Claude
  chooses (the pane says "Without Jev"), more slowly. Your own Claude Code, logged in, is needed either way: it writes the values and
  steers. Nothing starts without it.
- One Website pane works at a time. A second piece of work in the same pane keeps the first one's cookies and cart.
- What goes where is in [privacy and security](privacy-and-security.md#anthropic-through-tasks). To try it on a made-up shop,
  run `python3 scripts/task-practice-shop.py` in a terminal and open `http://127.0.0.1:8780/` in a Website pane.

**Saved Tasks** are work Varnick can repeat with values you give it. A Task is a JSON file in a project's `.varnick/tasks` folder or in
your own `~/.varnick/tasks`: a typed input, steps (a Claude session, a judgement by Jev, a notice to you, another Task) and a typed
result. You don't write one by hand; ask a Claude session ("make a Task called Haiku that takes a topic, writes a haiku and has a judge
check it"), and Varnick checks the file as it is read, so a mistake is named before anything runs.
- **`!task`** lists *On this site* first (the Website pane above, opened at once) and then the Tasks found from the focused pane's folder
  and your own. A Task that isn't valid is dimmed and shows its problems. ↩ on a Task shows a form drawn from its input; ↩ in the form
  checks it, naming each wrong field, or starts a **Run**, which opens nothing: the board's **Runs** tab (⌘⇧B, then Tab) shows it, and
  opening it shows its steps one line each, marked with who acted (Jev, Claude, the harness), its result as fields, and **Open tab** for
  the Claude session of a step. **Stop** ends the Run and everything it started.
- **A Run tells you when it ends,** in the menu bar menu: Done with its result, Stopped on an error with the step that failed ("Failed at
  check: no"), or a message from the Task's own notice step. A Claude step's session raises Needs you and messages as any session does.
  These notices stay on this Mac. Each Claude step draws on your Claude subscription, and a Judge step sends its question and state to
  TypeSafe (or to Claude when Jev is unsure or the relevance filter isn't on TypeSafe): see
  [privacy and security](privacy-and-security.md#anthropic-through-task-runs).
- **Settings › Tasks** (shown while Tasks is on) lists each Task file with its problems and the permissions of its Claude steps:
  Varnick's setting, Ask, Allowed tools only or Skip, and the allowed tools. These are yours alone and never in the file. A file that is new
  or changed since you pressed **Seen** is marked.
- **A session can list, check and start Tasks** through four Varnick tools while Tasks is on (`tasks_list`, `task_check`, `task_run`,
  `task_run_status`), with no approval step of Varnick's; a Run's own sessions never have them. It polls `task_run_status` for the result.
- Not in this build: a Task step on a website, and a saved Task as an automation's work.

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
