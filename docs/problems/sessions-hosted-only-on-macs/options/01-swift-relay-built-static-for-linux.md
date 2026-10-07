---
problem: sessions-hosted-only-on-macs
title: Launchy's relay, built for Linux on the Ryzen, hosts sessions there with no app
summary: The relay's protocol code moves into a Foundation-only local package that the Mac app and a new Linux relay both build from. Hosts differ at one seam with two adapters. A Mac host hands start, end and the lists to its app, as today. A headless host does all of it itself, from a state folder it owns. An installer shaped like the existing fleet tooling's sends that package to the Ryzen, which builds the Linux relay itself. To the Macs the Ryzen is one more peer; a Mac changes in where its SSH command looks for the relay, and in how a headless peer shows (Decided by the user, 6).
status: accepted
---

## Solution

**A headless host.** The Ryzen runs no Launchy app. Its relay, a Linux build of the relay the Macs run, is the whole of Launchy there. It answers every request itself, from zmx and a state folder of its own. That folder holds:
- an identity (id and name);
- the list of Macs it is paired with;
- a record of each session it started.

Nothing runs in the background: each request is one SSH command, as on a Mac.

**One protocol module.** These move into a module that needs only Foundation:
- the request and reply types;
- the relay's checks and dispatch;
- the zmx commands;
- the frozen screen's preparation;
- the transcript reader;
- project scanning and agent reading.

The Mac app and the Linux relay both build from it, so every request has one definition. Hosts differ at one seam, with two adapters:
- **The Mac adapter** is today's behaviour. It forwards start, resume, end, projects and agents to the running app, and reads `sessions.json`, the search database and UserDefaults.
- **The headless adapter** does all of it itself.

**The Macs.** To a Mac, the Ryzen is a peer like the other Mac. The user adds it by address, `^linux` starts a session on it, and its sessions are in the session list. They open on the card, and the user takes them over, ends them or releases them. A Mac is always the one in control of a session there. A Mac changes in where its SSH command looks for the relay and in how a headless peer shows (Decided by the user, 6).

## Trade-offs

- **One definition of the protocol.** A request's shape, the version check and the rule that only listed Macs get answers live in one place. A bump (the history work and the live view both take the next ones) changes one module, and both relays build from it.
- **The hard-won rules live once:**
  - the session-name check;
  - relabelling before detaching;
  - `/usr/bin/false` as the attach command;
  - the modes the frozen screen strips, and its tail;
  - the transcript markers;
  - the live view's reader and frames, still to be written.
- **A toolchain on the Ryzen.** Swift, installed there with swiftly, builds the Ryzen's own relay. Neither Mac gets a second toolchain (decision 5).
- **A package split.** About 1,200 lines move into a local package. Every declaration the app uses from it needs public access, and structs the app builds field by field need explicit initialisers. The work is mechanical, but it touches the app's build.
- **Each protocol bump means reinstalling on the Ryzen,** as it means rebuilding the other Mac today.
- **Hosting on a Mac is unchanged.** Macs keep their adapter.

## User Stories

1. As a user at either Mac, I want `>^linux fix the tests` to start a session that runs on the Ryzen and opens here in control, so that long work runs on the box that's always on.
2. As a user, I want `#project` and `@agent` after `^linux` to suggest the Ryzen's repos and agents, so that I pick them as I do for the other Mac.
3. As a user, I want the Ryzen's running sessions in the session list under its name, with the Mac in control, so that I can find one from either Mac.
4. As a user at the other Mac, I want Take over on a Ryzen session to move control here, as it does for a session on a Mac.
5. As a user, I want ⌘W on the Mac in control to end a session that Mac started, and to release one it took over, so that the rule is the one I already know.
6. As a user, I want a released session to keep running and show in both Macs' lists as last controlled on the Mac that let it go, so that nothing I didn't end stops.
7. As a user, I want /clear and /resume in a Ryzen session to be followed, so that a later resume opens the right conversation.
8. As a user, I want a session I control to come back after the Ryzen reboots: when my pane reconnects, the session starts again with `--resume` on the same conversation.
9. As a user, I want nothing on the Ryzen to end a session by itself, and a session no Mac has a pane for to show in the lists, so that I can still find it and end it.
10. As a user, I want the Ryzen in Settings › Peers, added by typing `alex@linux-box`, with whether it answered, its build and its zmx.
11. As a user, I want a Mac the Ryzen doesn't list to get nothing from it but a hello, as between Macs.
12. As a user, I want one command, run from the Mac I build on, to install or update the Ryzen's relay, and its row to say when the Ryzen speaks another protocol version.
13. As a user (a later ticket), I want the Ryzen's ended sessions in Recent and its conversations in search, marked with its name, and ↩ to resume one there.
14. As a user (with the live view's tickets), I want the card for a Ryzen session to update while Claude works, like one on a Mac.

## Implementation Decisions

### The headless host

**Install root: `~/.launchy`,** after the existing fleet tooling's one root per capability. It holds:
- the relay;
- the zmx it uses, next to it;
- the package the relay is built from;
- a config file;
- a `state` folder.

A link in `~/.local/bin` lets the user run the relay by hand.

**Config.** The installer writes it, and the user can edit it:
- **The host's name.** By default the hostname with hyphens turned into spaces: `linux-box` becomes "linux box", which answers to `^linuxbox`, `^linux` and `^box`. The installer takes a name of its own.
- **The default folder:** the home folder unless set.
- **The project folders:** `~/Projects` unless set.
- **Skip permissions** when a request doesn't say: off unless set.

**State.** The relay is the only thing that writes it. It holds:
- the identity, a UUID made at the first install that a re-install never changes;
- the peer list;
- the session records;
- a pane folder per session, for the hook file;
- later, the live view's registry of readers.

Every write goes to a temporary file that is renamed into place, under an exclusive lock on the state folder, because two Macs' requests can run at once. None of it lives under `/tmp`, which is cleaned after 30 days there.

**zmx.** The relay uses its own pinned 0.8.1 next to it, installed the existing fleet tooling's way: the release tarball, checked against its published SHA-256. It never uses `~/.local/bin/zmx`, which the existing browser terminal installed and may bump. This mirrors the Mac's rule that Launchy only uses the zmx next to its own binary. `ZMX_DIR` is `/tmp/zmx-<uid>` as on the Macs, apart from the terminal's `/run/user/1000/zmx`.

**Pairing.**
- **A hello** is answered to anyone. It returns:
  - the host's id and name;
  - the build: the commit the installer was run from;
  - the zmx version;
  - `keepSessions` and `running`, both true;
  - `paired`: whether it lists the sender afterwards, worked out the way the app works it out.
- **A hello with `pair` from an unknown Mac** adds it to the list, marked as added by that Mac.
- **The Ryzen never calls back.** It needs no SSH keys for the Macs, and a Mac's Add stands confirmed by the reply.
- **A hello from a listed Mac** updates its name and when it was last seen.
- **Every other request** is answered only to a listed Mac, by the existing check, reading the state folder instead of UserDefaults.
- **Peers by hand.** The relay can list the Macs it is paired with and forget one, run by hand on the Ryzen. Removing the Ryzen on a Mac doesn't remove that Mac on the Ryzen, as between Macs.

### Starting a session

- **`start` is checked as on a Mac.** The asker must be listed, the id must be a UUID, and the folder must exist; a request with no folder gets the default folder.
- **The record is saved first.** It holds the id, folder, prompt, agent, permissions, the origin (the asker), the boot id and the start time. Then the pane folder is made, so the hook has somewhere to write.
- **The relay creates the zmx session through a pseudo-terminal of its own,** at a fixed 120 by 40. One attach creates it with three labels: `launchy=1`, `launchy-control=<asker>` and `launchy-origin=<asker>`. Once `zmx get` sees the session, the relay detaches its own client and replies with the folder. The Mac's pane then attaches with take, as it does today. The order is the same as on a Mac host, where the host's own pane is the starting client. The pseudo-terminal also follows `docs/agents/where-it-breaks.md`, which says to create sessions the way Launchy does, through a pty.
- **The claude command line is the Mac's:**
  - the login shell from the account record, with `-l -i -c 'exec claude "$@"'`;
  - the hook settings;
  - skip permissions when asked;
  - `--agent` when that agent exists in the folder or among the user's agents;
  - `--session-id`, then the prompt as an argument of its own.
- **claude's environment is built fresh:** TERM, COLORTERM, LANG, HOME, USER, LOGNAME, SHELL, the hook file, the pane id, the project root, and zmx's two variables.
- **A claude that exits as it starts** fails the start with that message, as on a Mac.

### Lifecycle with no app

- **Labels** are a Mac host's labels for a session started for a peer. A session on the Ryzen always names a Mac in its control label, since nothing on the Ryzen types.
- **Take over** is the relay's existing `attach` with take, unchanged.
- **`end`** comes from the Mac in control closing its pane. The label must name the asker.
  - **The session came from the asker:** it is killed and its record marked ended.
  - **Otherwise it is released:** every client is detached and the control label is kept, so every Mac shows "Last controlled on <the Mac that closed it>". A Mac reads a missing label as its host being in control, and on the Ryzen that would name a keyboard that doesn't exist. The reply says `released`, as today.
- **Sessions that end by themselves** (claude exits, or `/exit`) aren't watched. Every request that reads the records first reconciles them with `zmx ls`. A record whose session is gone and was created in this boot is marked ended, and goes to the host's Recent if its transcript exists.
- **After a reboot:**
  - **Lost, not ended.** A record whose session is gone, and whose boot id is from an earlier boot, was lost rather than ended.
  - **Starting it again.** A Mac's restored pane asks `start` with resume, as it does today. The relay starts `claude --resume` on the conversation the hook last reported, labelled for that Mac with the record's own origin, and answers `started`.
  - **Ended in this boot:** a record ended in this boot answers `ended`.
  - Nothing else ever starts a session.
- **Orphans** are sessions that run while no Mac has a pane for them: a Mac quit between the start reply and opening its tab, or its saved tabs were lost.
  - Nothing ends them.
  - They show in every Mac's session list under the Ryzen, with the Mac their label names.
  - They end when the user takes them over and closes them on their origin Mac, types `/exit`, or ends them by hand on the Ryzen with the relay.
- **No sweep.** The relay only kills a session the Mac in control asked it to end, or one the user ends by hand.

### The requests a headless host answers

- **hello, attach, screen:** the shared code, unchanged.
- **status:** running, clients and control from zmx. The conversation comes from the hook file, else the record. There is never a title, since a Mac takes one only while the host is in control.
- **sessions:** the running records. The title is the transcript's `ai-title`, else the first line of the prompt.
- **projects:** the shared project scan over the configured folders, with last use read from `~/.claude/projects`.
- **agents:** the shared agent reading, for the folder asked about or the default folder.
- **resume:** as on a Mac. It starts `claude --resume` in a new session under the asker's id, labelled for the asker, and refuses a conversation that a running record holds.
- **recent:** ended records whose transcript exists.
- **rows:** in the later ticket. Until then the answer has no rows and no ids.
- **The pages request** from the accepted history-tied-to-one-mac option goes to every peer at each sync. It is answered with no pages, since there is no Chrome on the Ryzen.

### The Macs

- **Where a Mac's SSH command looks for the relay.** It tries the macOS link, then `$HOME/.launchy/launchy-peer`, so a Mac needs to know nothing about a peer before its first hello. When neither exists, the "no peer link" message still comes out. This was planned with no protocol change; the hello's `headless` field (Decided by the user, 6) bumped it to 11.
- **Adding:** the user adds the Ryzen by address (`alex@linux-box`). Find Macs stays macOS-only (decision 2).
- **`^linux`** works through the host's name.
- **Unchanged:** the session list, the card, Take over, ending, following, restore and Recent.

### Recent and search (the later ticket)

- **`rows`** has no search database to read from on the Ryzen. The relay reads `~/.claude/projects` with the shared transcript reader on every call. One full pass took 0.25 s there with a warm cache (measured by reading every file; parsing only the marked lines adds little, inferred).
- **What it returns:**
  - the sessions the user typed into whose folder exists;
  - the newest copy of each conversation;
  - those changed since the stamp;
  - every id.
- **A cache** of what each transcript gave is a later saving, if a cold pass proves slow.
- **On the Mac,** the rows go into `peer_sessions` and are embedded there, as a Mac's are.
- **The prompts rule** in `docs/agents/where-it-breaks.md` widens from paired Macs to paired peers, the Ryzen included. Nothing goes to a reranker.

### The live view (frozen-screen-not-live, option 04)

- **`watch` comes from the shared module,** since the relay serves it. The reader:
  - connects to the session's socket in `ZMX_DIR`;
  - never sends input, Init or a size;
  - asks zmx for the history;
  - reads the grid from the terminal of the session's program, through `/proc/<pid>/fd/0` on Linux, as option 04 already says.
- **Written once for both hosts.** The reader and its frames go in the shared module, with polling and the window-size call written for both Linux and Darwin.
- **The registry of readers** lives in the state folder, and `sessions` and `status` leave live readers out of the client count.
- **No host's own card.** The Ryzen has none, so it never runs a reader in process.

### Package layout

- **A local package, `Packages/LaunchyPeer`,** with no MLX in its graph, so the Ryzen builds it alone (decision 5). Its targets:
  - a library target for the protocol module, Foundation only, in Swift 5 language mode like the app;
  - a Linux executable target for the headless relay and its adapter.
- **The app target** depends on that library by path, and keeps its own Mac adapter, socket and SSH runner.
- **Public access.** The app reaches the module's declarations through `public`, since `package` access stops at a package's edge. Structs it builds field by field need explicit initialisers.
- **What stays with the app:**
  - the app socket, with Darwin's socket calls and `getpeereid`;
  - the SSH runner and CryptoKit;
  - the identity's UserDefaults and computer name;
  - Settings;
  - `sessions.json` and its records;
  - the search database.

### Install and update

- **Build, on the Ryzen** (decision 5). The installer sends `Packages/LaunchyPeer` as it is at the Mac's commit, leaving out uncommitted edits, so the build the hello reports is what runs. The Ryzen builds it with `swift build -c release`. Swift goes on the Ryzen once, by hand, with swiftly, whose system packages need sudo (inferred); the installer stops and names that fix when Swift is missing. `make build` on the Macs doesn't change.
- **Install.** One script, shaped like the existing fleet tooling's installers: two halves, a far half in `bash -s`, marker lines, and verify means reach it. It:
  - builds the relay as above, copies it beside the running one, and renames it into place;
  - installs zmx 0.8.1 if it is missing;
  - writes the config and the identity only if they are missing;
  - records the commit it was run from as the build;
  - verifies with a hello from the Mac, which must answer with this build's protocol version and the host's id.
- **Re-runs and uninstall.** Running it again converges. Uninstalling removes the relay and keeps the state, zmx and any running sessions.
- **Replacing the relay leaves sessions alone.** An attached pane's relay has already become zmx, and a live view's reader keeps the old file until its channel ends.
- **Keeping in step** is the hello's protocol version, as between Macs.
  - A Mac on a newer protocol shows the mismatch on the Ryzen's row and sends it nothing else.
  - Running the installer from that Mac's checkout fixes it.
  - Two Macs on different protocols can't both use the Ryzen, as two Macs can't use each other today.

### Saved state

- **On the Macs:** nothing new. The Ryzen is a peer in the existing list, and its sessions' records carry its id as their host.
- **On the Ryzen:** the state folder above. No change to `sessions.json` or UserDefaults anywhere.

### Scope and ticket order

1. **The protocol module and the package split,** with no change in behaviour. Done when `make build` passes and pairing, starting, Take over and Recent between the two Macs work by hand as before.
2. **The headless relay:** the install root, the installer, identity, pairing and hello, and the Macs' second relay path. Done when both Macs list the Ryzen as answering.
3. **Sessions on the Ryzen:** start, attach and take over, end and release, status, sessions, projects, agents, resume, recent, reconciling, and resuming after a reboot.
4. **Its conversations in search:** `rows`, later, as the user asked.
5. **The live view** comes with frozen-screen-not-live's own tickets, which then build for both kinds of host.

## Testing Decisions

- **No test target.** The pure seams for the first tests:
  - decoding requests, which is shared;
  - the headless adapter's decisions: end or release; ended or lost, by boot id; refusing a conversation that is already open;
  - reading and writing the state folder under its lock.
- **By hand**, after `make build` on both Macs, the installer run against the Ryzen, and a restart of Launchy the user does:
  - **Pairing.** Add `alex@linux-box` on the Air: its row answers, with its build, zmx 0.8.1 and Keep sessions running on. The relay's peer list on the Ryzen shows the Air. Then the Studio.
  - **The listed rule.** Forget the Studio on the Ryzen: the Studio is told the Ryzen doesn't list it, and stops asking.
  - **Starting.** `>^linux #<repo> @<agent> fix the tests` on the Air opens a pane on the Air, in control. On the Ryzen, the relay's zmx with `ZMX_DIR=/tmp/zmx-1000` lists the session with one client, and claude is signed in.
  - **In the pane:** typing, shift+enter, `~.` at the start of a line, a long prompt with quotes and `$`, and resizing.
  - **The other Mac.** The Studio's session list shows the session under the Ryzen, controlled on the Air. ↩ opens the card, and Take over moves control to the Studio; the Air shows the card.
  - **Releasing and ending.** ⌘W on the Studio, which didn't start it, releases it: both lists show it last controlled on the Studio, and it still runs. Take over on the Air and ⌘W ends it: it is gone from zmx and is in the Air's Recent.
  - **Following.** `/clear` on the Air, then restart Launchy on the Air: the pane comes back on the new conversation.
  - **`/exit`** in a session closes the pane, and the session is in the Ryzen's `recent`.
  - **Reboot** the Ryzen while the Air controls a session. The Air's pane says the connection was lost. Once the Ryzen is back, Reconnect resumes the conversation in a new zmx session.
  - **Reinstalling** while a session is attached: the session and its pane carry on.
  - **An older relay** on the Ryzen: the Air's row shows the protocol mismatch, and nothing else is sent.

## Out of Scope

- A Launchy app or any GUI on Linux.
- Terminal, web, file and app panes on the Ryzen.
- Find Macs finding Linux hosts (decision 2).
- Chrome history on the Ryzen.
- Moving a session between hosts.
- A Mac updating the Ryzen's relay by itself when the protocol changes.

## Further Notes

### Recommendation

Recommended.
- **The protocol is about to grow twice,** with the history pull and the live view, and this keeps it one definition, with the rules that took spikes to learn kept in one place.
- **It meets every wish.** The live view's reader is written once for both kinds of host.
- **The Mac barely changes:** one fallback path and a row that says "relay only" (the protocol bump to 11 came with it).
- **The costs are one-off:** a toolchain on the Ryzen, and a mechanical package split.

Option 02 stays on record as the fallback should Swift fail to build the relay on the Ryzen (spike step 1).

### Risks

- **A session must outlive the SSH call that created it.** The relay creates the session from an SSH command running in a logind session scope under tailscaled.
  - **Why it should survive** (inferred): zmx's daemon double-forks (the existing fleet tooling's verify relies on it), and `KillUserProcesses` is off, so the session should outlive the connection.
  - **Checked by** spike steps 2 and 3.
  - **If it doesn't,** the relay creates it under the user manager instead (`systemd-run --user`), which linger keeps alive.
- **The relay tied to its toolchain.** A plain release build links the Swift runtime from swiftly's toolchain folder, so removing or replacing that toolchain would break the installed relay (inferred). Adding `--static-swift-stdlib` cuts the tie; spike step 1 shows what each build links.
- **Foundation on Linux** differs from Darwin's in small ways: processes, directory enumeration, JSON and dates (inferred). The spike runs a build on the Ryzen.
- **/tmp is cleaned after 30 days.** A session that runs for over a month could lose its socket if tmpfiles doesn't skip sockets in use (inferred that it does). If it doesn't, `ZMX_DIR` moves under the install root.
- **Channels per SSH connection.** Every attached pane and, later, every shown card holds one channel on the shared connection. Tailscale SSH's limit isn't known (spike step 6).
- **One protocol at a time.** The Ryzen speaks one protocol version, so both Macs have to be built from the same commit to use it.

### Considered within this option

- **Installing the relay at the macOS path on Linux** (`~/Library/Application Support/Launchy`), which needs no change on the Mac at all. Not chosen: it puts a macOS folder on Linux to save one line on the Mac.
- **A field in the hello saying the peer is headless,** for its row. Left out at acceptance as cosmetic; the user chose it on 2026-10-05, once the row read "Launchy running" for a host with no Launchy (`headless`, optional, protocol 11).
- **Clearing the control label on release,** as a Mac host does. Not chosen: Macs read a missing label as the host being in control.
- **Creating the session from the Mac's own `ssh -t` attach,** with no client on the Ryzen. Not chosen: `attach` would then create sessions, and the relay's attach refuses to on purpose (`/usr/bin/false`) so that nothing starts behind the user's back.
- **Each Mac ending, at launch, its sessions on the Ryzen that no pane of its own points to.** Not chosen: losing `sessions.json` would then end work that the session list can still give back.
- **A cache for `rows`:** later, if a cold pass is slow.

### Verified and inferred

**Verified in the code at fd3d8be:**
- which requests need the app, and what the relay reads;
- the Darwin-only calls, and what is already portable;
- the fixed relay path;
- how a Mac names the controller of a session with no label;
- Find Macs' macOS filter;
- exact `^name` matching.

**Verified on the Ryzen:** everything in the problem's table.

**Verified in the existing fleet tooling's repo:** that `zmx attach` with no terminal leaves a daemon running.

**Verified on the Air, in a scratch package:** that `package` access doesn't reach the root package through a path dependency.

**Inferred:**
- that swiftly's Swift builds the package on Ubuntu 24.04, and what its relay links;
- a session outliving its SSH call;
- tmpfiles and sockets in use;
- the cost of a cold `rows` pass.

### Records

Accepting this needs an ADR:
- a host with no app, whose relay starts sessions itself from an SSH login. On Linux, claude signs in from its credentials file, so ADR 0007's reason for the app starting claude doesn't apply;
- the shared protocol module and its two adapters;
- the Linux build and its installer.

It amends ADR 0007's "the host's Launchy runs each session".

Docs to update:
- **`CONTEXT.md`.** Peer and Host both say Mac. A term for a headless host goes to `/domain-modeling`.
- **`docs/agents/where-it-breaks.md`, Peers.** "The relay never writes UserDefaults, since the app may be running" holds on Macs only. The headless rules (the lock, reconciling, release keeping the label) join it.
- **`docs/agents/where-it-breaks.md`, Search store.** "Paired Macs" becomes paired peers.

### Spike

These steps cover every option. Run them by hand, from the Air in Terminal.app, not in a Launchy pane. Every step on the Ryzen uses the throwaway `ZMX_DIR=/tmp/zmx-spike` and the existing browser terminal's zmx, never `/tmp/zmx-1000`.

1. **Swift on the Ryzen** (decision 5).
   - Install swiftly and the current Swift release on the Ryzen, from swift.org's install page for Linux.
   - Make a scratch package there whose one executable runs `/bin/true` through `Process`, lists a folder, writes JSON, and then `execve`s `/bin/echo ok`.
   - Build it with `swift build -c release`, then again with `--static-swift-stdlib`. Run each, and note what `ldd` lists for each.
2. **A session made without a terminal outlives the SSH command:**
   ```
   ssh alex@linux-box 'export ZMX_DIR=/tmp/zmx-spike; mkdir -p $ZMX_DIR; ~/.local/bin/zmx attach spike1 sh -c "sleep 2; stty size; exec sleep 900" </dev/null >/dev/null 2>&1 & sleep 4; ~/.local/bin/zmx ls'
   ssh alex@linux-box 'export ZMX_DIR=/tmp/zmx-spike; ~/.local/bin/zmx ls; ~/.local/bin/zmx history spike1'
   ```
   The second command, on a new connection, still lists `spike1`. Its history shows the size the session started at.
3. **A session made through a terminal at a set size,** as option 01's `start` does:
   ```
   ssh -t alex@linux-box 'stty rows 40 cols 120; export ZMX_DIR=/tmp/zmx-spike; ~/.local/bin/zmx attach spike2 sh -c "sleep 2; stty size; exec sleep 900"'
   ```
   In a second window run `ssh alex@linux-box 'ZMX_DIR=/tmp/zmx-spike ZMX_SESSION=spike2 ~/.local/bin/zmx detach'`. The first window returns, `zmx history spike2` shows `40 120`, and `zmx ls` still lists `spike2` a minute later.
4. **claude in a session made over SSH:**
   ```
   ssh -t -e none alex@linux-box 'export ZMX_DIR=/tmp/zmx-spike; cd /tmp && exec ~/.local/bin/zmx attach spike3 /usr/bin/zsh -l -i -c "exec claude \"\$@\"" claude'
   ```
   claude starts signed in and answers a prompt; note what its banner says about the account. Then `/exit`: the window returns, and `zmx ls` no longer lists `spike3`.
5. **The grid on Linux,** for the live view.
   - `zmx ls` gives `spike2`'s `pid=`, and `stty -F /proc/<pid>/fd/0 size` prints `40 120`.
   - Attach from the Air in a window of another size: `ssh -t -e none alex@linux-box 'ZMX_DIR=/tmp/zmx-spike exec ~/.local/bin/zmx attach spike2 /usr/bin/false'`. Ask the size again: it follows the window.
   - Detach from a second window: the Air's ssh returns, and the session lives on.
6. **Channels per connection:** frozen-screen-not-live's spike step 7, run against `alex@linux-box`.
7. **Clean up:**
   ```
   ssh alex@linux-box 'export ZMX_DIR=/tmp/zmx-spike; for s in spike1 spike2 spike3; do ~/.local/bin/zmx kill $s; done; rm -rf /tmp/zmx-spike'
   ```

### Spike results, 2026-10-05

Run over SSH from the Air, all work on the Ryzen (Swift 6.4.0 by swiftly, Ubuntu 24.04, zmx 0.8.1). Foundation on Linux lacked nothing the relay uses.

1. **PASS.** A scratch package, with only `import Foundation` as the Mac sources have, exercised every call the relay makes and built and ran with `swift build -c release`. The calls: `Process`, JSON with `.sortedKeys` and `.withoutEscapingSlashes`, base64, `JSONSerialization`, the ISO 8601 and POSIX date formatters, `NSString` path bridging, `localizedStandardCompare`, the project walk (`enumerator`, `level`, `skipDescendants`), modification dates, atomic writes, `flock` with a rename into place, `NSCondition`, `Thread`, a Dispatch signal source, `poll`, a Unix-socket connect with a zmx history request and reply, `ioctl(TIOCGWINSZ)` on `/proc/<pid>/fd/0`, and `execve`. It also created a session through a pty of its own at 120 by 40, labelled in the same attach, and detached its own client.
   - **The plain build** links 17 `libswift*`/Foundation/ICU `.so` files from swiftly's toolchain folder, so the toolchain risk is real.
   - **`--static-swift-stdlib`** works only with two fixes. Swift Build, now the default build system, leaves out Foundation's static dependencies (`_FoundationICU`, `_FoundationCollections`, `CoreFoundation`, `Synchronization` and others): use `--build-system native` (deprecated) or pass each one with `-Xlinker -l`. And `-lstdc++` isn't found, because clang picks GCC 14 but only `libstdc++-13-dev` is installed: add `-Xlinker -L/usr/lib/gcc/x86_64-linux-gnu/13`, or install `libstdc++-14-dev` (inferred). The result is 71 MB against 356 KB. `ldd` lists only libc, libm, libgcc_s and the system's `libstdc++.so.6`, with no `libswift*`, and every check still passes.
2. **PASS.** `spike1` is still listed on a new connection. Its history says `24 120`, zmx's size with no terminal. The daemon's logind scope is left `closing`; linger is on.
3. **PASS.** The detach returned the first window, history says `40 120`, and `spike2` was still listed minutes later.
4. **PASS.** Started over `ssh -tt` and read through `zmx history`. The banner reads "Sonnet 5.5 · Claude API" at the prompt, with no login prompt. No prompt was sent, so nothing was written to a project. Two things got in the way first:
   - oh-my-zsh's `Would you like to update? [Y/n]` blocks `zsh -l -i`. The relay's fresh environment needs `DISABLE_AUTO_UPDATE=true`.
   - An untrusted folder (`/tmp`) shows Claude's trust dialog first.
5. **PASS.** `stty -F /proc/<pid>/fd/0 size` printed `40 120`, then `30 100` with a 30 by 100 client attached. It stays at `30 100` after that client detaches.
6. **PASS.** 14, 30 and 60 channels at once on one ControlMaster connection to Tailscale SSH: every one answered `ok` in 20 s.
7. **PASS.** Sessions killed, and `/tmp/zmx-spike` and `/tmp/relay-spike` removed.

**Darwin → Linux in the relay:**
- **The terminal of a session's process:** `proc_pidinfo` + `devname_r` become `/proc/<pid>/fd/0`, opened as it is and read with the same `ioctl(fd, UInt(TIOCGWINSZ), &size)`.
- **Writes to a closed socket:** `SO_NOSIGPIPE` becomes `MSG_NOSIGNAL` on `send`, already under `#if` in `ZmxReader`. The watch's stdout still needs `signal(SIGPIPE, SIG_IGN)`.
- **The socket type:** `SOCK_STREAM` becomes `Int32(SOCK_STREAM.rawValue)`, since Glibc imports it as an enum. `SOCK_CLOEXEC` exists and closes the `fcntl` window.
- **The pty a start creates a session through:** SwiftTerm's `forkpty` becomes `openpty`, then `posix_spawn` with `POSIX_SPAWN_SETSID` (written as `0x80`, since it isn't imported), opening the slave by its path as fd 0 and copying it to 1 and 2. `posix_openpt`, `grantpt`, `unlockpt`, `ptsname` and `pipe2` aren't imported either. `pipe` with `fcntl` stays, as today.
- **Imports:** `import Foundation` re-exports Glibc, so no `#if canImport(Darwin)` import is needed.
- **Moved to the headless adapter, as planned:**
  - the host's name: `Host.current().localizedName` is nil on Linux, so the name comes from the config;
  - `UserDefaults` and `CustomApp.supportDirectory` give way to the state folder.
- **Works unchanged:** `Bundle.main.executableURL`, which finds the zmx beside the relay.
- **Not needed:** `getpeereid` (Linux has `SO_PEERCRED`), which stays with the app socket.

**Also found:**
- **Wait for the labels.** `zmx get` succeeds before `attach --labels` has set them, so a start must wait for `launchy=1` in its reply, not just for `get` to succeed.
- **A Dispatch signal source registers asynchronously.** A signal raised just after `resume()`, while the signal is set to `SIG_IGN`, is lost. This doesn't matter for `watch`, whose signals come from sshd later.

## Decided by the user, 2026-10-05

This option is accepted. These settle what it left open, and the fifth changes it:

1. **A Mac that didn't start a session releases it on close,** by the rule between Macs, so only the Mac it came from ends it.
2. **The Ryzen is added by address.** Find Macs stays macOS-only, so no Linux node's host key is accepted on first contact.
3. **The relay has its own pinned zmx 0.8.1,** so the existing browser terminal's installer can't change Launchy's sessions.
4. **Its name is "linux box",** from the hostname, so `^linux` works. The Macs' shortcut skips a name's words that are only digits (a host named `linux-box-2` still answers to `^linux`, not `^2`).
5. **Changed from this option: the relay is built on the Ryzen,** with Swift installed there by swiftly and `swift build -c release`, not cross-built on a Mac. No second toolchain, Swift SDK or swiftly goes on either Mac. Package layout and Install and update say how.
6. **The hello says whether a peer is headless, 2026-10-05 (protocol 11).** An optional `headless`, true from a host with no Launchy app, so its row reads "relay only" instead of "Launchy running". This changes the earlier "no protocol change" and "left out" above. Also on the Macs: the `^` shortcut skips words of a name that are only digits, so a host named `linux-box-2` still answers to `^linux`, not `^2`.
