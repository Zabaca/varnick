---
problem: peers-upgraded-by-hand
title: Each Varnick upgrades itself when a paired Mac asks, through requests answered whatever the protocol
summary: Two new requests, upgrade and restart, are read before the version check, so a Mac on any protocol from 15 on can be asked. Upgrade makes the Mac's own running Launchy fetch origin/main from GitHub, fast-forward its main checkout and build, nothing more. The row then says "Built · restart Launchy to update". Restart Launchy is a separate button, pressed when the user chooses, which first lists the panes it would end. A failed build leaves the old build running and shows the error. While a build waits for its restart, the relay and the Phone page server keep running the old build's files, so each Mac stays on one protocol. The Ryzen is upgraded in one step, with the installer run from this Mac at origin/main. Upgrade all builds everywhere, the other machines first and this Mac last, and skips and reports any machine that refuses. Restart all restarts Launchy on every Mac with a new build waiting, this Mac last, after one confirmation listing each Mac's panes.
status: shipped
---

## Solution

Each Mac's running Launchy upgrades itself when asked, from its own GUI session:

- **Upgrade** fetches origin/main from GitHub, fast-forwards main in its checkout to it and runs `make build`. Nothing restarts. The row then says "Built · restart Launchy to update".
- **Restart Launchy** is a separate button per Mac, pressed when the user chooses. It first lists the panes the restart would end, if any. It restarts Launchy, never the Mac, and says so.
- **A failed build** leaves the old build running, with the error on the row.

The target is origin/main and nothing else. Each Mac fetches GitHub itself, with its own Keychain. Merges a Mac hasn't pushed don't count as newer.

Two new requests carry this between Macs: **upgrade** (report, or begin) and **restart** (say what would end, or restart). The relay reads them before it checks the protocol version, so a Mac on another version can still be asked. They are answered only to a Mac the receiving machine lists, never to a device.

**A build changes nothing until Launchy restarts.** Today a peer's request runs the binary on disk, so a build without a restart puts a Mac's relay on the new protocol while its app is still on the old one. From now on, Launchy takes a snapshot of its build's relay files when it starts, and the relay and the Phone page server run from that snapshot. Each Mac stays on one protocol until Restart Launchy.

**The Ryzen** has no app and no checkout. Its Upgrade runs the installer from this Mac at origin/main, and the new relay is live at once. There is no restart, because the Ryzen's relay starts afresh for each request.

**Upgrade all** builds on every machine: the other machines first, this Mac last. One confirmation lists what will happen on each. A machine that refuses or can't be reached is skipped and reported, and the rest go ahead.

**Restart all** restarts Launchy on every Mac with a new build waiting: the other Macs first, this Mac last. One confirmation lists each Mac's panes that would end. Macs without a new build are skipped.

Each Mac watches origin/main itself: it fetches when Settings › Peers opens, on Check again and about hourly, and shows how far behind it is. It never upgrades by itself.

## Trade-offs

- **Better:**
  - The restart happens inside the upgraded Mac's own GUI session, as `make run` does there today. It needs no LaunchAgent, and no launchd start from an SSH login that lacks the Keychain (ADR 0007).
  - Git fetches with that Mac's own Keychain, as the user's `git pull` does there by hand.
  - One code path serves every Mac, this one included.
- **The restart is the user's call.** A build can finish while sessions are busy, and the restart waits until the user chooses. The cost is a second press per Mac, and a "restart Launchy to update" state that can last.
- **One more round by hand.** Every Mac, and the Ryzen, must be brought by hand to the first build with the two requests (protocol 15). The Air, on its older protocol today, gets nothing from this until then.
- **Launchy must be running on the Mac being upgraded.** The Air is down today, and nothing here can start it. A Launchy started from an SSH login would lack the GUI session's Keychain.
- **A carve-out from "the relay reads a request's version first".** The two requests keep the same shape for good, since every later version must still read them. Any field added later is optional and ignored by older builds.
- **A new power for any listed Mac:** making another Mac fetch, build and restart Launchy. Today's requests start, end and read sessions. It stays bounded: only origin/main, only a clean main checkout, and the restart refuses unless a new build is waiting.
- **Snapshots.** Each launch copies its build's relay binary, zmx and Phone page files into a folder of their own. On APFS the copy is a clone and takes no space until the build changes. The relay and the page then run from a folder that `make build` never writes.
- **The build runs in a zmx session that Launchy starts.** Its process is outside Launchy and every Claude process, but Launchy starts it, which is close to the run in the XProtect report. Restart Launchy spawns the same detached restart `make run` does.

## User Stories

1. As a Launchy user, I want Settings › Peers to show the commit each machine runs, and how far it is behind origin/main, this Mac included.
2. As a Launchy user, I want to see a machine's commit even when it speaks another protocol version.
3. As a Launchy user, I want to upgrade another Mac from this one with one button, without going to it.
4. As a Launchy user, I want Upgrade only to fetch and build, so that nothing restarts while sessions are busy.
5. As a Launchy user, I want a built Mac to say "Built · restart Launchy to update", and to restart Launchy there when I choose.
6. As a Launchy user, before Launchy restarts on any Mac, I want to see which panes would end and to be told the Mac itself isn't restarted.
7. As a Launchy user, I want a failed build to leave the old build running and show me the error.
8. As a Launchy user, I want Upgrade to refuse a checkout that is detached, on another branch or has uncommitted changes, or one where a build is running, and say which. That way a session's hand test isn't clobbered.
9. As a Launchy user, I want a Mac that has built but not restarted to keep working with the others on the protocol it runs.
10. As a Launchy user, I want to upgrade the Ryzen from Settings without remembering the installer's command.
11. As a Launchy user, I want Upgrade all to build on every machine after one confirmation, skipping and reporting the ones that refuse or don't answer.
12. As a Launchy user, I want a Mac whose main holds unpushed merges to show them as ahead of origin/main, not to count as the newest build.
13. As a Launchy user, I want a peer that doesn't answer to show its last known commit.
14. As a Launchy user, I want to restart Launchy on every Mac with a new build waiting with one button and one confirmation that lists each Mac's panes, this Mac last.
15. As a Launchy user, I want each Mac to keep its "behind origin/main" count current by itself, and Check again to refresh it at once, without anything upgrading on its own.

## Implementation Decisions

**The build stamp**

- `make build` writes a one-line stamp beside the binary as its last step, only when every step before it succeeded. The stamp holds the full commit of the checkout's HEAD, and "dirty" when tracked files differed from it. So the stamp names the last successful build.
- A build with no stamp (made before this change, or with plain `swift build`) is reported by its checkout's HEAD, shown with "(checkout)".
- The Ryzen's build file is its stamp already.

**The relay runs the build that is running**

Verified: a peer's request execs the peer link, a process per request (`Launchy --peer`). The link points at the binary in the checkout's build folder, which `make build` rewrites. On 2026-10-06 the Studio's binary was rebuilt at 16:03 while its Launchy had been running since 15:42, so its relay already ran a newer build than its app. The Mac's Phone page server likewise reads its page files from that folder on every request.

- At launch, before it points the peer link anywhere, Launchy copies into a snapshot folder:
  - its binary;
  - the zmx beside it;
  - its stamp;
  - its Phone page folder.
  The copy is a clone on APFS. The snapshot folder sits in the checkout's build folder, named by the stamp, and `make build` never writes it. Launchy also records there the checkout it was started from.
- The peer link points at the snapshot's binary. So the relay, and the zmx it finds beside itself, are the running build's until the next launch. The phone page server is started from the snapshot's page folder, with the snapshot's relay.
- Launchy compares the snapshot's page files with the build folder's (today's digest rule): files changed by a build start the page server again only at the next launch.
- At launch, snapshot folders other than the new one are removed. A relay still running from an old one keeps its open file.
- The relay's arguments stay unlike `make run`'s kill pattern: it runs as the link's path.

**The two requests** (protocol 15)

- **Their shape is frozen**, whatever later versions do, and so is the envelope around them: the reply never gains a required field and keeps `v`, `ok`, `error`, `unlisted`, `upgrade` and `restart` with their types, and the request head stays `v`, `op` and `by`. Otherwise a newer asker couldn't read an older host's reply. Any later field is optional. The relay reads the operation and the asker (the request head: version, operation, asker) and, for these two only, skips the version check. They are answered only to a Mac in the saved peer list. A device, or an unlisted Mac, gets the unlisted refusal.
- **upgrade**, without `begin`, is a report. With `begin` it begins an upgrade, or says why not. (The flag isn't `start`: a request's `start` already holds a session to start.) An optional `fetch` field, set only by Check again, makes the Mac fetch origin before it reports (Watching origin/main); without it the Mac fetches only when its last fetch is over 10 minutes old. Its reply carries:
  - the kind, Mac or headless;
  - the protocol of the running build;
  - the running commit and whether it was dirty;
  - the commit of the last successful build, when that is a different one;
  - the checkout's branch, or detached, and its count of changed tracked files;
  - origin/main's commit, when it was last fetched, and how many commits the running build is behind it and ahead of it;
  - why the last fetch failed, when it did (`fetchError`, optional);
  - the upgrade's state: idle, fetching, building, built, failed or refused. With it come when that state began, a one-line message, and on a failure the build log's last 20 lines.
- **restart**, without confirm, says what a restart would end: the label of each pane that would end, how many panes would reconnect, or why it can't restart. With confirm, it restarts Launchy, or says why not.
- **The relay** answers the report's build fields itself, from the snapshot's stamp and the checkout's stamp, so they work with Launchy not running. Everything else is forwarded to the running Launchy's socket. With Launchy not running, the reply is "Launchy isn't running on <Mac>", plus the build fields.
- **The Ryzen's relay** answers the report with its kind and its build file's commit, and ignores `fetch`. To `begin` or to restart it answers "<host> is upgraded from a Mac, with the installer".
- **Sending them.** On the asking side they go through the same request path as every other request, except that they skip the refusal of a peer known to speak another version. That refusal is how a mismatch is worked around now.
- **The protocol goes to 15**, and the Phone page's protocol constant with it.

**Upgrade on a Mac** (done by its running Launchy, whether a paired Mac asked or the user pressed Upgrade on this Mac)

1. **Check.** Read-only checks, each refusal saying which:
   - the checkout is on main ("On <branch>: left alone"; "Detached on <commit>: left alone");
   - no tracked files changed ("<N> uncommitted changes: left alone");
   - no SwiftPM build runs in the checkout, and no upgrade does ("A build is running there");
   - Launchy runs from that checkout's build.
   Untracked files don't block.
2. **Fetch** origin, off the main actor, as the user in the GUI session, with a 60 s deadline. A failure refuses: "Couldn't fetch origin: <reason>".
3. **Fast-forward** main to origin/main.
   - Main already holding origin/main means nothing to do: "Up to date", or "<N> ahead of origin/main (not pushed)".
   - Main with commits origin/main lacks while also behind it refuses: "Main has commits origin/main lacks: push or merge them by hand".
   - A fast-forward that would overwrite an untracked file fails, and is reported.
4. **Build.** `make build` runs in a zmx session named for the upgrade, never a pane's name: made through Launchy's own pty, waited for, then detached, as the Phone page server's session is. Its log is a file in Application Support. Its last line records whether make succeeded, since a zmx session's exit status says nothing. The session outlives Launchy quitting, and the next launch reads how it ended.
5. **The result.**
   - Success: the stamp on disk is origin/main's commit. The state is built, and the row says "Built <commit> · restart Launchy to update".
   - Failure: the state is failed, with the first error line and the log's last 20 lines. The running build is untouched: the snapshot runs, and the stamp on disk names the last good build, so Restart Launchy isn't offered. Upgrade tries again.

**Restart Launchy on a Mac**

- **Offered only** when the last successful build on disk differs from the running build. It is refused while an upgrade or a SwiftPM build runs in the checkout, so a restart never lands mid-build.
- **What would end** is computed by the Mac's own Launchy: each started Claude, terminal or app pane that isn't running in zmx, by label. Panes in zmx and panes for sessions on a peer reconnect. Sessions on this Mac controlled from another Mac or a device live in zmx and reconnect too. Labels already go to paired Macs as titles.
- **The confirmation**, on whichever Mac the user pressed it, every time, even when nothing ends: "Restart Launchy on <Mac>? Only Launchy restarts, not the Mac." followed by the list of what ends, or "No pane ends: every open pane is kept running." The buttons are "Restart Launchy" and "Cancel".
- **The restart** is the detached one `make run` does after its build, started by that Mac's Launchy from its GUI session after it has replied. The new Launchy takes a new snapshot and points the link at it, so the relay, the page server and the app move to the new build together.
- **The words** are "Restart Launchy" and "restart Launchy to update" everywhere: on the button, in the row, the confirmation and the report. The words "restart the Mac" or "reboot" never appear.

**The Ryzen**

- The installer gains a commit argument. It sends the package and the page as committed at that commit, takes its far half from that commit too, and reads the protocol and the Mac's SSH command from it. Without the argument it uses HEAD, as now.
- Upgrade on the Ryzen's row:
  - fetches origin on this Mac;
  - asks once: "<host> takes the new relay at once; its Phone page restarts if the page changed, which drops a phone's open terminal there for a moment";
  - runs the installer at origin/main in a zmx session of its own on this Mac, logged like a Mac's build.
  The row shows the installer's step, then "<host> at <commit>", or the failure with the installer's last lines. The installer's own checks and verify stand. A failed install leaves the old relay, since it swaps only a binary that runs.
- The near half of the installer is taken from this Mac's working tree. Everything it sends comes from the commit.

**Upgrade all**

- **One button**, under the peer rows: "Upgrade all".
- **First, a report** to every machine and a fetch here. Then one confirmation lists each machine and what will happen there:
  - "fetch and build <commit>; Launchy keeps running until you restart it";
  - for the Ryzen, "take relay <commit> at once";
  - or why it will be skipped: up to date, refused (which check), not answering, or Launchy not running.
  It ends with "Nothing restarts Launchy: each Mac shows Restart Launchy when its build is done."
- **The order:** the other machines' upgrades start first, the Ryzen's and the Mac peers' together. This Mac's starts last.
- **When it ends**, a short report under the button gives each machine's outcome: built, failed (with its first error line), skipped (why) or not answering. A machine that fails doesn't stop the rest.

**Restart all**

- **One button**, beside Upgrade all, shown when at least one Mac has a new build waiting.
- **First, a dry run.** Every Mac is asked for its report and its restart's dry run. Then one confirmation lists each Mac and what will happen there:
  - "Restart Launchy: <commit> → <commit>", followed by the panes that would end, or "no pane ends";
  - or why it will be skipped: no new build, a build running, not answering, or Launchy not running.
  It says "Only Launchy restarts, not the Macs." The buttons are "Restart all" and "Cancel". The Ryzen isn't listed: it has nothing to restart.
- **The order:**
  - Restart is sent with confirm to the other Macs, together, and each Mac checks again before it restarts. A Mac that refuses now (a build started meanwhile, say) is skipped and reported.
  - This Mac restarts last, once every other Mac has answered or 15 s have passed.
- **The report** gives each Mac's outcome: restarted, skipped (why) or not answering. It is kept across this Mac's own restart and shown under the button once, after it. Each restarted Mac's row then shows its new running build at the next report.

**Watching origin/main**

- Each Mac's running Launchy fetches origin itself:
  - when Settings › Peers opens there;
  - on Check again on any Mac: that Mac asks every Mac for its report with fetch, and each fetches at once;
  - when a paired Mac asks for its report without fetch and its last fetch is over 10 minutes old, which is how opening Peers on one Mac reaches the others;
  - about hourly while it runs.
  Each Mac reports how far its running build is behind origin/main, with the fetch's time.
- **A report with fetch** answers once the fetch finishes, or after 8 s with the fetch still running, inside the relay's 10 s wait for the app. A fetch already under way is joined, not started twice. A fetch that outlasts the reply goes on, and the next report shows its result. A failed fetch keeps the last origin/main and its time, and the report's `fetchError` says why.
- A fetch only reads. Upgrading is always a button press, never automatic.
- **The Ryzen** has no checkout. A Mac compares the Ryzen's commit with its own origin/main on the relay package, and on the Phone page when one is installed. If neither changed, the row says "<N> behind, relay unchanged" and offers no Upgrade.

**Settings › Peers**

- **The This Mac row** gains a build line and the buttons Upgrade and Restart Launchy, each shown only when it applies. The build line reads, for example:
  - "Launchy 4a61de4 · protocol 15 · up to date with origin/main, fetched 12 min ago";
  - "Launchy 4a61de4 · 3 behind origin/main";
  - "Built 9c1e2aa · restart Launchy to update".
- **Each peer row's details line** puts the running commit where the build time is today: "Launchy 4a61de4 · protocol 15 · 3 behind · zmx 0.8.1 · Launchy running · Keep sessions running on". A second line says, in order:
  - the upgrade's state while it runs ("Building, 1:40");
  - "Built <commit> · restart Launchy to update";
  - a failure's first error line, with the last 20 lines under a disclosure;
  - a refusal.
  Upgrade and Restart Launchy sit before Remove.
- **A peer on another version** keeps today's mismatch line. Its commit and its buttons come from the report, which works across versions.
- **A peer that doesn't answer** shows its last known commit, saved as an optional field of the peer's saved info.
- **Under the peer rows**, one row holds Check again, Upgrade all and Restart all. Check again fetches here at once, and asks every machine for its report with fetch, so every Mac fetches origin/main right away. Upgrade all shows when some machine is behind, and Restart all when some Mac has a new build waiting.
- **While an upgrade runs** on a machine and Settings shows, the report is asked every 2 s. Otherwise it is asked with the hello every 20 s.
- **Nothing here waits on SSH** or a subprocess on the main actor, as in the rest of Settings.

**Docs, once built**

- ADR 0013 (0012 is text generation): the two requests and their carve-out, the restart split from the build, and the relay and page snapshots. It amends ADR 0007's list of what a listed Mac may ask, and ADR 0009's "reinstall at every protocol bump", now a button.
- where-it-breaks:
  - Peers: the version-first rule and its two exceptions; the request set; "any request but hello goes through send or attachCommand, which refuse another version", with these two as the exception; the snapshot as the relay's binary and zmx.
  - Phone page: the server's files are the snapshot's, not the build folder's.
- CONTEXT.md gains **Build**: "The commit a machine's Launchy or relay was built from, and its protocol. A Mac can have a newer build waiting for Restart Launchy. _Avoid_: version".
- The CLAUDE.md line on restarts, `launchctl kickstart -k` when installed: that starts a second Launchy when the running one came from `make run` (the problem's Evidence). It is the user's file to change.

## Testing Decisions

- `make build`, and `swift build` of the package on the Ryzen, for the shared protocol change. `bun test` in the Phone page for its protocol constant.
- **The snapshot.** Build without restarting, then check:
  - a peer's report shows the old running commit and the new built one;
  - the hello and every other request answer at the running protocol;
  - the Phone page still serves the old page files.
  After Restart Launchy, all three move together.
- **By hand, after the manual round below:**
  - Upgrade the Air from the Studio. Watch the steps on its row, then "Built · restart Launchy to update". Restart Launchy there: the confirmation lists the Air's panes not in zmx, and a new session there afterwards signs in with the subscription.
  - A failed build: in a throwaway clone whose origin is a local bare repository holding a commit that doesn't compile, the upgrade's steps end failed with the error, and the stamp still names the last good build. On a real Mac, the row then shows the error, the old build keeps running and Restart Launchy isn't offered.
  - Each refusal: a detached checkout, another branch, uncommitted changes, a build running, a main ahead of and behind origin/main.
  - Upgrade and Restart Launchy across a protocol mismatch, with a later bump in a throwaway build.
  - A device asking upgrade gets the unlisted refusal.
  - The Ryzen: Upgrade at origin/main from a Studio checkout detached on another branch. It ships origin/main, not the branch.
  - Upgrade all with the Air unreachable: it is skipped and reported, and the rest build.
  - Restart all with a new build waiting on the Air and on this Mac, and none on a third Mac: the confirmation lists both Macs' panes and skips the third. The Air restarts first, and the report shows after this Mac's relaunch.
  - Check again on the Studio makes the Air fetch at once, whenever it last fetched. Opening Peers on the Studio makes it fetch only when its last fetch is over 10 minutes old.
  - This Mac's own Upgrade and Restart Launchy.

## Out of Scope

- Starting Launchy on a Mac where it isn't running.
- Upgrading to anything but origin/main: a branch, an older commit, or a local unpushed main.
- Restarting the Mac itself.
- Pushing to origin.
- The headless relay rebuilding itself.
- Upgrading Tailscale, zmx or Bun. A zmx pin bump still ends running sessions once, at the restart (ADR 0004).
- Freezing the app's own later reads of files beside its binary, such as the metallib.

## Further Notes

- **Decided by the user on 2026-10-07** (relayed by the coordinator):
  - this option accepted; options 01 and 02 stay as written, and their probe and terminal tab aren't built;
  - origin/main as the only target, fetched by each Mac itself;
  - Upgrade split from Restart Launchy, and a failed build leaving the old build running;
  - Upgrade all, and Restart all;
  - watching origin/main: on opening Peers, on Check again and about hourly, never an automatic upgrade;
  - Check again makes every Mac fetch at once, through an optional fetch field on the report; without it the 10-minute rule stands;
  - the Ryzen shows "relay unchanged", with no Upgrade, when only files outside the relay changed;
  - the restart's confirmation lists the exact panes, and this Mac's own restart is always confirmed;
  - the snapshot lives in the checkout's build folder;
  - Build is added to the glossary.
  No question is left open.
- **The manual round.** The first build with protocol 15 and the two requests must reach every machine by hand, once:
  1. `make run` on the Studio, at the user's choice of moment.
  2. `git pull` and `make run` on the Air, at the Air.
  3. The installer for the Ryzen from a Mac.
  From then on every update, protocol bumps included, goes through the buttons.
- **Siblings to copy:**
  - the Phone page server's runner, for the build's zmx session and its log;
  - the Phone page's Use a socket button, for a Settings action and its refusal;
  - `make run`'s detached restart;
  - the installer's markers, for the Ryzen's steps;
  - the peer row's details line.
- **Verified in the code or on this Mac (2026-10-06/07):**
  - a peer's request runs the binary on disk through the link, a process per request;
  - the link resolves into the build folder that `make build` rewrites;
  - the Studio's binary was newer than its running Launchy;
  - the Mac Phone page server reads its page files from disk on every request;
  - a mismatched hello carries only the version;
  - the installer ships HEAD with no branch check;
  - the relay package and page are unchanged between f72de39 and main;
  - Apple's git and Homebrew's both use the Keychain helper;
  - the restart script's kill pattern is anchored to the binary's path;
  - per pane, whether it runs in zmx.
- **Inferred, not checked:**
  - that a zmx session started by the app keeps the GUI session's Keychain for `git fetch` (panes started the same way do for Claude);
  - that an APFS clone of a signed binary runs as the original;
  - that XProtect leaves a snapshot binary run from the build folder alone.

- **Tickets, a sketch** (`/to-tickets` makes them):
  1. The build stamp and the running build's snapshot: the relay and the Phone page server run from it. No protocol change.
  2. Protocol 15 in the shared package: the upgrade and restart requests (`begin`, and the report's optional `fetch` and `fetchError`), their frozen shapes and envelope and version-check exception, listed Macs only, the Ryzen's answers, and the asking side skipping the mismatch refusal for these two. It builds on Linux, and the Phone page's constant moves.
  3. Answering on a Mac: upgrade (checks, fetch, fast-forward, the build in its zmx session and log, its state across a relaunch), restart (the dry run's panes, then the detached restart), and watching origin/main. The manual round above comes after this ticket.
  4. This Mac in Settings › Peers: its build line, Check again, Upgrade, Restart Launchy and its confirmation, and a failure's error.
  5. The peers: their rows from the report, Upgrade and Restart Launchy over the requests, the 2 s poll, and the last known commit.
  6. The Ryzen: the installer's commit argument, Upgrade at origin/main in a zmx session here, and "relay unchanged".
  7. Upgrade all.
  8. Restart all.
  9. Docs: ADR 0013, where-it-breaks, and Build in CONTEXT.md.
  Tickets 1 to 3 must be in the build the manual round installs, since a machine can only be asked once it has them. Tickets 4 to 9 change only the side that asks, so they reach the other Macs through Upgrade.
