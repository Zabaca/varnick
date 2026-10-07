---
problem: peers-upgraded-by-hand
title: Builds and protocols in Settings › Peers, and an Upgrade button that runs in a terminal tab
summary: Settings › Peers shows each machine's build (its commit and protocol, and how far behind it is) against one target, the newest main this Mac holds. A probe sent over SSH outside the relay reads any machine's build, whatever protocol it speaks. A row that is behind gets Upgrade, which opens a terminal tab running that kind of machine's upgrade. For the Ryzen that is the installer. For a Mac peer, the commits are pushed from this Mac, main is fast-forwarded, Launchy is built, and launchd restarts it. For this Mac it is fast-forward, build and the restart `make run` does. Every upgrade refuses a checkout that isn't a clean main, and nothing restarts after a failed build. The protocol doesn't change.
status: proposed
---

## Solution

Settings › Peers compares each machine's **build** with a **target**:

- **Build.** The commit a machine's Launchy or relay was built from, and its protocol version. For a Mac it also includes the checkout's branch and its uncommitted changes. `make build` writes the commit beside the binary, as the Ryzen's installer already does.
- **Target.** The newest commit on main that this Mac holds: its own main or origin/main, whichever contains the other. This Mac fetches origin in its own checkout to find it.
- **Probe.** One fixed command, sent over SSH but not through the relay, that reads a machine's build. So it works across a protocol mismatch, which is when it matters most, and on the builds already deployed. The same read runs locally for this Mac.

Each machine's row says where it stands:

- at target;
- N commits behind;
- on a different protocol;
- built from a branch;
- built with uncommitted changes;
- built but not restarted.

A machine that is behind and safe to upgrade gets **Upgrade**. Upgrade opens a terminal tab on this Mac that runs the upgrade for that kind of machine. So its output, the build's included, is on screen, and ^C stops it. It runs in a shell, never in Launchy's own process or in a Claude process. The three kinds:

- **A Mac peer:** check its checkout, push the target from this Mac to a ref of its own there, fast-forward main and run `make build`. Then restart Launchy there through launchd, and wait for a hello at the target's protocol.
- **The headless host:** the installer, given the target commit instead of HEAD.
- **This Mac:** first a confirmation that names the panes the restart will end. Then check this checkout, fast-forward main, run `make build`, and restart the way `make run` does.

The peer protocol doesn't change.

## Trade-offs

- **It works on what is deployed now.** The probe and the scripts need nothing new on the other machine, so the Air, on an older protocol, gets an Upgrade button the first time. A build made before this change has no commit stamp, so its row shows the commit its checkout is on, marked "(checkout)".
- **A second way in over SSH, beside the relay.** It reads a checkout and runs upgrades. Launchy's own probe goes through the same SSH runner, with fixed text only, and only to listed peers. The scripts in the tab use plain ssh, as the installer does.
- **The terminal tab is the progress display.** It is plain but shows everything. Settings learns the result by probing again when it is next shown; it doesn't follow the upgrade live.
- **A Mac peer can be restarted only if Launchy's LaunchAgent is loaded there** (`make install` run there once). Without it the upgrade stops after the build and says so. A Launchy started from an SSH login would lack the GUI session's Keychain (ADR 0007).
- **The commits reach a Mac peer from this Mac.** So the peer needs neither GitHub nor its Keychain over SSH. This Mac always holds the target, since the target is by definition a commit it has.
- **"Behind" counts commits.** For the headless host, a row that is behind with the relay package unchanged says so and offers no Upgrade: that is the Ryzen at f72de39 today. For a Mac, any commit counts, since any file can change what the app does.
- **Cost.** One more SSH read per machine each time Settings › Peers appears, and a fetch of origin at most every 10 minutes.

## User Stories

1. As a Launchy user, I want Settings › Peers to show the commit and protocol each machine runs, this Mac included, so that I can see at a glance which are behind.
2. As a Launchy user, I want to see the target and where it came from (this Mac's main or origin/main, and when origin was last fetched), so that I know what "behind" is measured against.
3. As a Launchy user, I want a machine on another protocol to show the commit it was built from, not only "protocols differ".
4. As a Launchy user, I want this Mac's row to say when this Mac is the one behind.
5. As a Launchy user, I want to upgrade the other Mac from Settings with one button, without going to it.
6. As a Launchy user, I want to upgrade the Ryzen from Settings without remembering the installer's command.
7. As a Launchy user, I want Upgrade to refuse a checkout that is detached, on another branch or has uncommitted changes, and to say which, so that a session's hand test isn't clobbered.
8. As a Launchy user, I want to watch the build's output, see a failure in full, and be able to stop it.
9. As a Launchy user, I want to see which panes a restart of this Mac will end before I agree to it.
10. As a Launchy user, I want a machine restarted only after its build succeeded, and never while another build of its checkout runs.
11. As a Launchy user, I want a machine that was built but not restarted to say so.
12. As a Launchy user, offline, I want the comparison made against the origin/main last fetched, with the time it was fetched.
13. As a Launchy user, I want a peer that doesn't answer to show its last known build.
14. As a Launchy user, after a protocol bump, I want to bring every machine to the same commit from one Mac.

## Implementation Decisions

**The build stamp**

- Every `make build` writes a one-line stamp beside the binary: the full commit of the checkout's HEAD, plus "dirty" when tracked files differ from it. It is written even when SwiftPM relinks nothing.
- The running app reads its own stamp once at launch: that is the build it runs. The probe reads the stamp on disk: that is the last build. They differ when a build hasn't been restarted.
- Some builds have no stamp: those made before this change, or with plain `swift build`. Such a build is reported by its checkout's HEAD and shown with "(checkout)".
- The Ryzen's build file is already its stamp, holding the short commit.

**The probe**

- **Its form.** One fixed POSIX command, kept as one literal like the relay's SSH command.
  - It goes through Launchy's SSH runner, as a request with a 15 s deadline, and only to a listed peer.
  - For this Mac, the same script runs locally without SSH.
  - It prints `KEY=value` lines. They are read whatever the exit status, as the installer's are, because Tailscale SSH reports every command as exit 0.
- **On a Mac**, it finds the checkout from the peer link's target: the binary inside the checkout's build folder. Launchy points the link at whichever binary it last launched from, so the probe follows Launchy into another checkout or worktree. It reports:
  - the kind and the checkout's path;
  - the stamp and whether it is dirty, or none;
  - the checkout's HEAD; its branch, or detached; and how many tracked files have changed (untracked files don't count);
  - the binary's modification time, and the start time of the Launchy running from that checkout, or none;
  - whether a SwiftPM build runs in the checkout, and whether an upgrade holds its lock;
  - whether Launchy's LaunchAgent is loaded in the user's GUI domain;
  - how many panes a restart would end there. These are the running Launchy's direct child processes other than zmx and ssh clients. A pane in zmx is a zmx client, and a pane for a session on a peer is an ssh client. Any other child is a pane's own process, which dies with Launchy. The spike checks this count.
- **On the headless host**, it reports the kind, the build file's commit, and whether the Phone page is installed.
- **No peer link**, on a Mac where Launchy has never run, reads "Launchy hasn't run there yet", as a failed hello does today.
- **When it runs:**
  - when Settings › Peers appears, or the panel comes back to it;
  - on Check again;
  - when a peer's hello changes its build time or protocol;
  - for a machine, just before its Upgrade opens.
  It doesn't run on the 20 s hello loop.
- **The protocol** comes from the hello, or from the version in its mismatch reply, as today.
- **Saved.** The peer's saved info gains an optional commit, so a peer that doesn't answer shows "last known: <commit>".

**The target**

- **Where it is computed.** In this Mac's checkout: the one its binary was built in.
- **The fetch.** `git fetch origin`, off the main actor, with a 30 s deadline, as this Mac's user in its GUI session, so git's Keychain helper works. It runs:
  - when Settings › Peers appears, if the last fetch (the fetch file's date) is over 10 minutes old;
  - on Check again.
- **Which commit is the target:**
  - local main, if it contains origin/main;
  - else origin/main, if it contains local main;
  - else there is no target. The row says "main here and origin/main have diverged", and no machine gets Upgrade.
- **Its protocol** is read from the target's own source, as the installer reads its version.
- **Its row**, the Target row, reads one of:
  - "Target <commit> · protocol 14 · main here, 4 ahead of origin";
  - "Target <commit> · origin/main, fetched 3 min ago";
  - "Couldn't reach origin (<reason>): origin/main as of 14:05".

**Where each build stands.** This is computed on this Mac with its own git, off the main actor.

- **Its commit, as this Mac's repository knows it:**
  - the target itself: "at target";
  - an ancestor of the target: "N behind";
  - known here but not an ancestor: "built from <branch> (not main)", or "from a branch" when the probe gave no name. Left alone.
  - unknown here: "built from a commit this Mac doesn't have". It may be newer, so it can't be compared. The row adds: "Push it from <machine>, then Check again".
- **A dirty stamp** adds "with uncommitted changes".
- **A protocol other than the target's** comes first, in orange: "protocol 12 (target 14)".
- **A binary newer than the running Launchy** reads "built, not restarted".
- **A headless host that is behind** has its relay package compared between its commit and the target, and its Phone page too where one is installed. Unchanged: "N behind, relay unchanged", with no Upgrade.
- **This Mac** compares the build it runs with the target, in the same words. A peer whose commit is ahead of this Mac's build shows this Mac as behind, because both are compared with the target, which the fetch keeps current.

**Settings › Peers**

- **The This Mac row** gains a line with its build and where it stands, and Upgrade.
- **A Target row** under it holds the target's line and Check again. It reads "Checking…" while the fetch and the probes run.
- **Each peer row's details line** puts the commit in place of the build time:
  - a Mac peer: "Launchy <commit> · protocol 14 · 3 behind · zmx 0.8.1 · Launchy running · Keep sessions running on";
  - the headless host: "Relay <commit> · protocol 14 · relay only".
  A build with no commit keeps today's build time.
- **A second line**, in orange, says what blocks an upgrade.
- **Upgrade** sits before Remove:
  - shown when the machine is behind or speaks another protocol;
  - disabled when something blocks it, with the reason as its help text;
  - hidden at target.
- **Today's mismatch line** stays as it is.

**What blocks an Upgrade.** The probe checks these before the tab opens, and the script checks them again before it changes anything. A refusal changes nothing.

- The checkout isn't on main (another branch, or detached): "On <branch>: left alone".
- Tracked files have changed: "N uncommitted changes: left alone".
- Main there isn't an ancestor of the target: "Main there has commits the target lacks".
- A build runs in the checkout, or another upgrade of it does: "A build is running there".
- There is no target, or the machine is at target.
- The machine doesn't answer.

Untracked files don't block. A fast-forward that would overwrite one fails by itself, and the script reports that.

**Upgrading a Mac peer.** A new script shaped like the installer: a near half on this Mac, a far half piped to the peer that prints `KEY=value` markers, and the near half judging them.

1. **Check.** The far half runs the checks above, which only read. Once they pass, and before anything changes, it takes the lock. The lock is a folder in the checkout's build folder holding the script's process id; a lock whose process is gone is stale. It is removed at the end, whatever happened.
2. **Send.** The near half pushes the target to a ref of its own in the peer's checkout, never to a branch. It uses ssh in batch mode, as the installer does.
3. **Fast-forward.** The far half fast-forwards main to the pushed commit.
4. **Build.** The far half runs `make build` and streams its output. On a failure the near half ends with "Build failed: <peer> still runs <commit>; its checkout is at <target>", and nothing restarts.
5. **Restart**, only after a successful build:
   - The far half checks again that no other build runs in the checkout.
   - If the LaunchAgent isn't loaded, it stops before stopping anything, and says: "Built. Restart Launchy on <peer> yourself (`make run` there), or run `make install` there once so Upgrade can."
   - Otherwise it stops the Launchy running from that checkout by the same anchored pattern `make run` uses, and waits up to 10 s for it to exit.
   - Then it starts Launchy through launchd in the user's GUI session (`launchctl kickstart gui/<uid>/<label>`).
   - It never runs `make run` or the binary itself from the SSH login.
6. **Verify.** The near half sends a hello the way a Mac does, every 2 s for up to 60 s. It passes when the hello answers at the target's protocol with Launchy running, and the probe's stamp equals the target. Then it prints "VERIFY=ok".

What else the restart touches:

- Sessions this Mac controls on the peer live in the peer's zmx, and reconnect as after any restart there.
- The peer's Phone page server starts again at its next launch when the page's files changed (ADR 0011's rule), so a phone's terminal there drops for a moment.

**Upgrading the headless host**

- The installer gains a commit argument. It archives the package and the page at that commit, and reads the protocol and the Mac's SSH command from it, instead of HEAD. Without the argument it uses HEAD, as now.
- Upgrade runs it with the target, so a checkout here that is detached on a test branch ships main's relay, not the branch's. The installer's own checks, build, swap, build file and hello stay as they are.

**Upgrading this Mac**

1. **Confirm.** Before the tab opens, a confirmation in Settings lists what the restart will end: each started Claude, terminal or app pane not running in zmx, by label. It says that panes in zmx and panes on peers reconnect. It asks even when nothing would end, since the restart closes and reopens the panel.
2. **Run.** The tab runs the self-upgrade script on this checkout, with the same checks and lock: fast-forward main to the target, `make build`, then, only after a successful build, the detached restart `make run` does.
3. **After.** The tab is a terminal pane. With Keep sessions running on it is in zmx, so it comes back after the restart with its log. With the setting off it ends with Launchy, after the restart has been handed off.

**The tab**

- The button opens a new terminal tab in this Mac's checkout. Its shell runs the script once, with the machine's address and the target, then stays open as an interactive shell.
- The command isn't saved: a restored tab is a plain shell and never runs the upgrade again.
- Its title is "Upgrade <machine>".
- A second upgrade of the same machine is refused by the lock.

**Docs, once accepted**

- An ADR from the draft in Further Notes.
- `docs/agents/where-it-breaks.md`, Peers:
  - the probe is one fixed literal, read by its markers, never by its exit status;
  - an upgrade never starts Launchy from an SSH login;
  - the upgrade lock;
  - the installer's commit argument.
- The CLAUDE.md line on restarts says `launchctl kickstart -k` when installed. That starts a second Launchy when the running one came from `make run` (see the problem's Evidence). It is the user's file to change.

## Testing Decisions

- There is no test target. Verification is `make build`, `bash -n` on the scripts, and checks by hand.
- **A spike comes first, on the Air**, since the restart step rests on it:
  - From an SSH login, stop Launchy, then start it with `launchctl kickstart gui/<uid>/com.zabaca.launchy`. Check that the panel shows, that a new Claude session started there signs in with the subscription and not "Claude API", and that the peer socket opens.
  - `git push` from the Studio to a ref of the Air's checkout.
  - The probe's count of panes a restart would end, against the Air's real panes, with Keep sessions running off and then on.
  - If a launchd start from SSH lacks the GUI session, this option's peer restart doesn't work as written. Option 03's restart from inside the peer's own Launchy is the alternative.
- **The far half on a throwaway clone here.** It takes the checkout's path, and a check can tell it to leave out the restart. It must:
  - refuse a detached checkout, another branch, tracked changes, a main that diverged, a running SwiftPM build and a held lock;
  - fast-forward and build a clean one;
  - treat a lock whose process is gone as free.
- **The installer's commit argument:** run it against the Ryzen with a commit other than HEAD, and check that the hello carries that commit.
- **By hand, after the user restarts Launchy:**
  - The rows for the Studio, the Air and the Ryzen: commits, protocols, the Target row, and "relay unchanged" on the Ryzen while only Mac files changed.
  - A peer on another protocol shows its commit.
  - Upgrade the Air: the tab's log, the restart, the verify, and the row at target afterwards.
  - Upgrade the Ryzen.
  - Each refusal: a checkout on a branch, uncommitted changes, a build running.
  - A failed build on a peer: nothing restarts, and the row says built-but-not-restarted or still on the old commit.
  - This Mac's confirmation lists the panes not in zmx.
  - With the network off: the Target row says when origin was last fetched.

## Out of Scope

- One button that upgrades every machine.
- Upgrading a machine to anything but the target: a branch, or an older commit.
- Installing the LaunchAgent on a peer over SSH.
- Pushing this Mac's main to origin.
- Upgrading Tailscale, zmx or Bun.
- Putting the commit in the hello: that is a protocol change, and option 03's.

## Further Notes

- **Siblings to copy:**
  - the installer's two halves and their markers, for the probe and the Mac script;
  - the peer row's details line, for the build line;
  - the Phone page's Use a socket button, for a Settings action with a refusal shown beside it;
  - `make run`'s detached restart, for this Mac.

- **Verified in the code or on this Mac:**
  - what the hello carries;
  - that a mismatch reply carries only the version;
  - that a Mac's build is the binary's modification time, read by the relay from the binary on disk;
  - that the Ryzen's is the installer's commit;
  - that the SSH runner's only caller sends relay requests;
  - that the installer ships HEAD with no branch check and verifies the commit with a hello;
  - which panes restart in zmx (Launchy tracks this per pane);
  - that the restart script's kill pattern is anchored to the binary's path, so relay requests, which run through the link, survive it;
  - the Studio's LaunchAgent being loaded while its Launchy came from `make run`;
  - that the relay package and the Phone page are unchanged between f72de39 and main;
  - that `git-receive-pack` is in `/usr/bin` on this Mac.
- **Inferred, and settled by the spike:**
  - that `launchctl kickstart` from SSH starts Launchy in the GUI session;
  - that git over SSH on the Air can't use the Keychain, which is why the commits are pushed rather than fetched there (ADR 0007's Claude login suggests it can't);
  - the count of panes a restart would end, from child processes;
  - that a terminal pane is far enough from XProtect's heuristic (not reproducible on purpose).

- **Draft ADR** (take the next free number when accepted):

  > # Launchy reads and upgrades a paired machine's checkout over SSH, beside the relay
  >
  > Settings › Peers compares each machine's build (the commit `make build` or the installer stamped, and the protocol) with a target, the newest main this Mac holds. It reads the build with a probe: a fixed command over SSH that doesn't go through the relay, so it works whatever protocol the other machine speaks. Upgrade runs scripts in a terminal tab on this Mac. A Mac peer gets the target pushed from this Mac, fast-forwards main, builds, and is restarted through launchd in its GUI session. The headless host gets the installer at the target. This Mac fast-forwards, builds and restarts as `make run` does. Every upgrade refuses a checkout that isn't a clean main, and nothing restarts after a failed build. We chose this over a relay request (option 03) because it works on builds already deployed and changes no protocol. The problem and its options are in `docs/problems/peers-upgraded-by-hand/`.
  >
  > ## Consequences
  >
  > - A second way in over SSH beside the relay, for reading a checkout and upgrading it. It amends ADR 0007's "a peer's SSH command runs Launchy's own binary in a relay mode".
  > - Launchy is never started from an SSH login, which lacks the GUI session's Keychain. A Mac peer whose LaunchAgent isn't loaded is built but not restarted.
  > - ADR 0009's "reinstall the headless host at every protocol bump" becomes a button.

- **Open questions, each with a recommendation:**
  - *The target:* the newer of this Mac's main and origin/main, not origin/main alone. This Mac's main is often ahead of GitHub, and the installer already ships this Mac's commits.
  - *How the commits reach a Mac peer:* pushed from this Mac to a ref of its own. The alternative is for the peer to fetch from GitHub, which needs the peer's Keychain from an SSH login. Recommended: push, and the spike confirms the fetch would fail.
  - *Restarting a Mac peer:* through launchd only, which means `make install` once on each Mac; without it, build and say so. Recommended, once the spike holds.
  - *A headless host behind only in commits:* no Upgrade while its relay package and Phone page are unchanged. Recommended.
  - *When the probe runs:* on showing Settings › Peers, on Check again, and when a hello's build or protocol changes, not every 20 s. Recommended.
  - *Panes that a peer's restart ends:* show the probe's count, and confirm when it is above zero, if the spike shows the count is right. Otherwise, word it from Keep sessions running ("Keep sessions running is off on the Air: restarting ends its open sessions").
  - *A confirmation for this Mac when no pane ends:* yes, one confirmation every time, since the panel closes and comes back.
  - *Upgrade all, in order* (the headless host, the Mac peers, then this Mac last): not now. The rows show what is behind, and each button is one click.
  - *Glossary:* add **Build** ("The commit a machine's Launchy or relay was built from, and its protocol. _Avoid_: version") and **Target** ("The commit Settings › Peers measures builds against: the newest main this Mac holds"). Recommended; it's for the user to accept.
