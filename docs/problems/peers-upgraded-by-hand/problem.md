---
title: Paired machines are brought up to date by hand
description: When a change reaches main, each paired machine has to be rebuilt from it by hand. For the other Mac that means `git pull` and `make run` on it; for the Ryzen it means rerunning the installer from a Mac. Launchy doesn't say which machines are behind. A Mac reports only when its binary was built, and a machine on another protocol version reports nothing but its version number. The user keeps track of who needs what, and runs the steps on each machine himself.
impact: After a protocol bump (11 to 14 across 5 and 6 October), a machine that hasn't been rebuilt can only answer a hello. Sessions, Take over, the live screen, Recent and search rows don't work across it until someone rebuilds it. A change without a bump is less visible still, because a Mac runs the old behaviour and nothing says so. Upgrading by hand can land on a checkout another session is testing on a branch, and the restart ends every pane that isn't kept in zmx.
severity: mid
evidence: Code as of 2f86bf5. This Mac's saved peer list, process table and LaunchAgent on 2026-10-06. Git history of the protocol version. ADR 0007 (a session started from an SSH login). The user's report of XProtect killing a Claude process.
status: closed
---

## Today

Checked in the code at 2f86bf5 and on the Studio on 2026-10-06.

**What a machine says about itself.** A hello answers with its id, name, address, build, zmx version, Keep sessions running, whether Launchy itself answered, and `headless` for a host with no app. Every request and reply also carries the protocol version.

- A Mac's build is its binary's modification time in UTC, such as "2026-10-06 22:05 UTC". The relay reads it, and the relay is the binary on disk, reached through the peer link. After a `make build` without a restart, that is newer than the Launchy that is running.
- The Ryzen's build is the short commit the installer ran from, written to a file in its install root, such as "f72de39".
- No machine reports a commit it runs, a branch, or uncommitted changes. The Ryzen's commit is the one exception.
- While Settings › Peers shows, each peer is asked for a hello every 20 s. A Mac peer's row reads "Launchy built 2026-10-06 22:05 UTC · zmx 0.8.1 · Launchy running · Keep sessions running on". The Ryzen's row reads "Relay built f72de39 · zmx 0.8.1 · relay only". The This Mac row shows only the name and address.

**A protocol mismatch.** The relay reads a request's version before anything else, a hello included. To another version it answers only with an error and its own version number. So this Mac learns which protocol the other side speaks, but not its name, build or commit. The row's dot turns orange and the row says "Launchy protocols differ (12 and 14): build both Macs from the same commit · last answered …". From then on this Mac sends that peer nothing but a hello: requests, attaches and live screens are refused here before they leave.

**Upgrading by hand.**

- **The other Mac:** on that Mac, `git pull` and `make run` in its checkout. `make run` builds first. Only if the build succeeds does it stop every Launchy started from that checkout and start the new one, detached so it outlives the shell that ran it.
- **The Ryzen:** on a Mac, the installer with the Ryzen's address.
  - It sends the relay package as committed at the Mac's HEAD, whatever branch that is. Uncommitted changes in the package are left out with a warning.
  - It builds the package on the Ryzen and swaps the binary in only if it is static and answers.
  - It writes the commit to the build file and updates the Phone page where one is installed.
  - It ends with a hello sent the way a Mac sends it, which must carry the protocol and that commit. It prints "build: <commit> (protocol N)".
- **Launchy itself** runs nothing on another Mac except the relay. Its SSH runner can carry any fixed command, but its only caller sends relay requests, and no request pulls, builds or restarts.

**What a restart ends.** These panes come back after a restart:

- a pane whose process runs in zmx: Claude and terminal panes started while Keep sessions running was on, and app servers always;
- a pane for a session on a peer: it is an ssh client, and its session lives on the host.

A Claude or terminal pane started while Keep sessions running was off is a child process of Launchy, and ends with it.

**Checkouts are shared.** Each Mac builds Launchy from its main checkout, and sessions work in that same checkout. Earlier on 2026-10-06, both the Air's and the Studio's main checkouts were detached on unmerged branches that another session was testing by hand. A `git pull` there would have failed, or moved that test. A build would have replaced the binary under test.

## Evidence

- **Protocol bumps** (git history):
  - 11 at be2fdb7 on 10-05;
  - 12 at 67b98f1 and 46288c1 on 10-06, on two branches;
  - 13 at the merge of those two branches;
  - 14 at 40cb150 on 10-06.
- **This Mac's saved peer list** on 2026-10-06:
  - The Air's last hello said its build was "2026-10-06 22:05 UTC". The Air is now down and on an older protocol.
  - The Ryzen's said "f72de39", headless. The Studio and the Ryzen speak 14.
- **Behind on commits, current in what runs.** f72de39 is 5 commits behind main (2f86bf5), but the relay package and the Phone page are identical at the two commits. Comparing commits alone would call the Ryzen out of date.
- **This Mac's main is often ahead of GitHub.** When this planning started, main was 4 commits ahead of origin/main; they were pushed while it ran. Merges on this Mac often sit unpushed for a while, so an upgrade that only fetches from GitHub would miss them.
- **How Launchy runs on this Mac.** The Launchy running here was started by `make run`: launchd is its parent after the detach, and it runs from the relative path the restart script uses. Launchy's LaunchAgent is loaded, with no instance running. `launchctl kickstart -k` on that label would start a second Launchy beside this one.
- **An SSH login lacks the GUI session's Keychain** (ADR 0007). A session started from an SSH login showed "Claude API" instead of the subscription login. A Launchy started over SSH would start its sessions the same way.
- **GitHub access needs the Keychain.** The repository was private on GitHub on 2026-10-07, fetched over HTTPS, with the macOS Keychain as git's credential helper.
- **XProtect.** macOS killed a Claude process after it had run LaunchAgent installs, launchctl, detached daemons and a downloaded binary. This is the user's report; it hasn't been reproduced.
