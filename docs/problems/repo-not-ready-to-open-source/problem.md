---
title: The repository can't be made public as it stands
description: The user wants to open-source Launchy by making its GitHub repository public. Its files and history were written by one person for their own machines. The docs carry personal and client email addresses, the tailnet's name, device IPs, Tailscale IDs and a private credential proxy's setup. Test fixtures use real identifiers, UI text and comments name the user's machines, and some defaults only suit the author. There is no licence, README or security note. Anyone who cloned it would get the author's details, and a setup that partly assumes the author's machines.
impact: Until it is cleaned up the repository stays private, so nobody else can use, read or build on Launchy. Published as it is, it would put the user's and their clients' addresses, the tailnet's layout and the proxy's setup on the web, beyond recall once cloned. A new user's Claude sessions would also start with permission checks off, a paid service's filter would show as on, and the code would carry no licence to use it under.
severity: mid
evidence: Three read-only audits of the tree and its full history, relayed by the coordinator on 2026-10-07; they found no credential in any file or commit. The planner checked on 2026-10-07 at 651cacf, read-only - refs, authors, paths deleted from the tree, patterns over every commit message and every diff on main, and the repository's metadata on GitHub. The code lines below were read at 651cacf, and this Mac's stored settings were read with `defaults read`. Nothing was changed.
status: closed
---

## What the user wants

The user wants the repository at github.com/Zabaca/launchy made public, so that others can use, read and build on Launchy. This is cleanup, not incident response. The user considers nothing exposed seriously sensitive, and no audit found a credential.

**Already decided** (relayed by the coordinator, 2026-10-07):

- The work is done on a branch. Main is then replaced by that branch and force-pushed to origin.
  - A normal branch off main wouldn't remove anything, because every old commit would still be its ancestor.
- Old commit SHAs may stay reachable on GitHub for a while after the force-push. There will be no new repository and no purge through GitHub Support.
- Only main is pushed. Local worktree and prototype branches stay local.

**Still open for the user:**

- Either an orphan branch with one squashed commit, or the history kept and rewritten with git filter-repo. The rewrite would remove paths, replace strings in files and commit messages, and optionally map the author email.
- Once docs/problems/ is published by default, where private and process docs live.

## Where it stands (2026-10-09)

Option 01's scrub is done, and so is its cutover: origin holds only main, whose root is the squashed commit 253012d. Left: making the repository public, and turning on private vulnerability reporting.

Later on 2026-10-09 the user chose to rename Launchy to Varnick before going public (name-taken-by-another-launcher, option 01 accepted). The steps left here, and the check from outside, now wait until the rename has merged, both GitHub renames are done (they were, the same day), every machine runs Varnick, and the public-repo check has run again over the renamed tree. They then run against Zabaca/varnick.

**2026-10-17:** both are done. Zabaca/varnick is public, and private vulnerability reporting is on (read through GitHub's API).

## Today

### The repository

All verified on 2026-10-07.

- **Size.** 220 tracked files. Main has 295 commits, and the local refs hold 305; the first commit is from 2026-09-26.
- **On GitHub.** The repository is private, with no forks, pull requests, releases, workflows, tags or licence, and one collaborator. origin has two branches: main and prototype/product-board. A force-push of main leaves the prototype branch in place, and the old history with it.
- **Local branches.**
  - Two prototype branches and six worktree branches.
  - Three of the worktree branches hold peers-upgraded-by-hand option 03's tickets 1 to 3, unmerged. Ticket 3's branch includes the other two.
  - A fourth worktree branch, from 2026-10-04, holds two commits of an early draft of the relevance-filter problem.
- **Not tracked.** `prototypes/` and another tool's folder, which ignores itself, are in the checkout untracked. `.gitignore` covers only the build folder, `db/`, `.env`, `.scratch/` and Claude Code's worktrees.
- **Docs.**
  - 16 problems with 57 options: 8 accepted, 5 shipped, 25 proposed, 19 rejected.
  - 12 ADRs. Every ADR links into docs/problems/, and so do CONTEXT.md and the planner's own instructions.
  - The planner commits problems on main so that builders' worktrees have them.
- **Commit references.** Docs cite at least 19 commits by short SHA that resolve today.
- **Missing files.** No LICENSE, README, SECURITY.md, notices or CONTRIBUTING.

### Personal data in the tree

From the audits, by file and category. Line numbers are as of 651cacf. The audits' ranges miss a few lines, which the planner found and marks "also".

**Docs about the private credential proxy:**

- `docs/problems/proxy-managed-apart-from-launchy/`, the problem and its four options. They give the proxy's address, its control plane, its sops/age secrets setup and how its tokens are shared. No other doc links to it (verified).
- Shorter mentions by name in ADR 0007 line 13, ADR 0009 line 13 and the installer's header (`scripts/install-peer.sh` line 22). Several problems also cite the proxy as prior art.

**Personal and client data in problems:**

- `history-tied-to-one-mac/problem.md`:
  - personal and client email addresses, Chrome profile names and per-profile visit counts, lines 57 to 86;
  - also: an email address in its impact field and a `user@host` address in its evidence field.
- `history-tied-to-one-mac/options/03-turn-on-chrome-history-sync.md`, lines 10, 14 and 33: the same kinds of data.
- `sessions-hosted-only-on-macs/problem.md`, lines 6, 62 to 67 and 98: host specs, the name of the environment variable that holds the Ryzen's OAuth token (not its value), and a `user@host` address.
- `sessions-out-of-reach-from-the-phone/problem.md`, lines 59 and 81 to 82, and its option 01, line 348: the tailnet's name, the phone's tailnet IP and an email address.
- `sessions-tied-to-one-mac/problem.md`, line 69: the tailnet's device list.
- `relevance-filter-needs-typesafe/problem.md`, lines 54 and 99: the personal data behind the distillation, and the path of the private folder that holds it.

**Machine-specific recipes,** meaning ssh commands with the user's account and hostnames:

- `sessions-hosted-only-on-macs/options/01` (about 77 references);
- `frozen-screen-not-live/options/04`, lines 178 to 180;
- `peers-upgraded-by-hand/options/01` and `03`.

**The process log.** docs/problems/ reads as the author's working log:

- statements that the repository is private (`peers-upgraded-by-hand/problem.md` line 56, `relevance-filter-needs-typesafe/options/02` line 26);
- token counts;
- figures measured from the user's own history, transcripts and usage, for example in `sessions-not-searchable` and ADR 0012.

**Mild wording in docs meant to stay current:**

- CONTEXT.md line 84, and the custom-apps skill's copy of CONTEXT.md, which is byte-identical (verified);
- ADRs 0003, 0009 and 0011;
- `docs/agents/where-it-breaks.md`, lines 50, 80, 100 and 108;
- `Sources/Launchy/MLXRuntime.swift`, line 13: the RAM of the user's Mac.

**Test fixtures** (`PhonePage/`):

- `checks.test.ts`, lines 8 to 14 and 147 to 148: Tailscale user and node IDs, and the phone's tailnet IP.
- `fixtures/whois-own-node.json`: a node ID at line 35, and also an email address at line 46.
- `checks.test.ts`, `hosts.test.ts` and `terminal.test.ts` line 214: the tailnet's name and device hostnames.
- `launch.test.ts`, lines 15, 172 and 231, and `hosts.test.ts`, lines 12 to 45: the user's Linux home folder and account name.
- `home.test.ts` line 21 and `terminal.test.ts` line 27: a device name containing the user's first name.

**UI text and comments:**

- Settings › Peers gives the user's account and the Studio's hostname as its example address, in both the placeholder and its error (`Peers.swift` line 621, `PeersView.swift` line 55).
- Comments naming the user's machines, names or tailnet suffix:
  - `Peers.swift` line 55;
  - `PhonePage/hosts.ts`, lines 19, 41 and 43;
  - `HeadlessConfig.swift`, lines 22 and 37;
  - `HeadlessPeerHost.swift` line 4;
  - `scripts/install-peer.sh`, lines 7 and 225;
  - `scripts/remote/install-peer.sh` line 18;
  - the header comments of `PhonePage/vendor/VERSIONS`.

### Personal data in the history

Verified on main.

- **Author metadata.** Every commit's author and committer address is the user's personal email address, under two author names.
- **Commit messages.**
  - A pattern check covered all 295 messages: email addresses, `.ts.net` names, addresses in Tailscale's range, Tailscale IDs and home paths. It found only Claude's co-author address.
  - About five messages name the credential proxy, and one names the Linux host.
- **Files that are only in history.**
  - Four early warehouse sync scripts, removed in the first days. They describe a private data warehouse on the Linux host, its hostname and how its catalog password is read. The password is read on the host; none is in the files.
  - Older names of two ADRs and one option, and older sources.
- **Identifiers in old versions.** A pattern check of every diff on main found the same identifier categories as the tree, plus one more home-folder path. Names that no pattern catches, such as client names and Chrome profile names, weren't checked in old versions.

### Code that assumes the author

Verified at 651cacf.

- **Skip permissions.**
  - With nothing stored, Settings reads Skip permissions as on, and Claude then starts with `--dangerously-skip-permissions`.
  - A peer's start request carries its own choice, and the host follows it over its own setting (the session record's field).
  - The headless relay defaults to off.
  - This Mac has no stored value, so it runs on the default today.
- **Relevance filter.**
  - With nothing stored, the filter is on with TypeSafe chosen. Without a key, Search shows "Needs a key" with a link to Settings › Models.
  - This Mac has both settings stored.
- **Shells.**
  - Claude panes run `/bin/zsh -l -i`, so that `~/.zshrc` puts claude on PATH. App panes do the same, and their script uses zsh's `pipestatus`.
  - Terminal panes follow `$SHELL`, and the headless relay uses the account's login shell from the account record.
- **The database.**
  - The database is `LAUNCHY_DB`, or else `db/launchy.sqlite` under the working directory. `make run` and `make install` set it to the checkout's `db/`, which is gitignored. `make clean` leaves it, since it holds history Chrome may have dropped.
  - The peer relay reads the same file.
  - `.env`, the TypeSafe key's fallback, is read from the working directory, which under launchd is the checkout.
- **The custom-apps skill link.** `make install` links `~/.claude/skills/custom-apps` to the checkout with `ln -sfn`, which replaces a link the user already has there. `make uninstall` removes whatever link is at that path.
- **The Linux installer.**
  - It supports x86_64 only and says so when it refuses.
  - It expects Swift from swiftly in its default location, installed by hand.
  - Its fallback link step names Ubuntu 24.04's GCC 13 path.
- **On-device relevance and the evals.**
  - The filter's "On this Mac" choice needs a checkpoint distilled for Launchy, which only the author has.
  - `--rerank-eval` and `--search-eval` need labelled data of the user's own.
- **Claude Code plugins.** The committed `.claude/settings.json` enables the TypeSafe plugin and mattpocock-skills from two marketplaces.
- **Smaller assumptions.** Bun and tailscale are looked for in fixed lists of paths, and history comes from Chrome only.

### Security and privacy as they stand

Verified in code and ADRs unless marked.

- **Peers.** Peers reach each other over SSH. A Mac in the peer list sends requests that the relay runs as the user (ADR 0007).
- **The Phone page.**
  - It is off by default.
  - It runs behind `tailscale serve` and identifies the device by asking Tailscale's whois about the first `X-Forwarded-For` address.
  - In loopback mode the server listens on 127.0.0.1. Loopback mode is used with the Tailscale app, and with any Tailscale that can't serve a socket; ADR 0011 records both of the user's Macs as loopback. In this mode any local process can send that header, pose as a listed device and get a shell as the user. Other accounts on the same Mac can do so too (inferred: a loopback port is open to every local user).
  - The page shows a banner saying so, and ADR 0011 records it.
- **The administrator prompt.** When serving a socket is refused to the user, Launchy can run Tailscale's serve as root through macOS's administrator password prompt.
- **Upgrades (planned).** Under peers-upgraded-by-hand option 03 (accepted, being built), each Mac fetches and builds origin/main when the user presses Upgrade. Push access to the repository a Mac fetches from then means code running on that Mac.
- **What Launchy reads, records and sends:**
  - it reads every Chrome profile's History into a local archive;
  - it reads every transcript under `~/.claude/projects`;
  - it records the microphone and system audio while Listening is on;
  - with a TypeSafe key and the filter on, it sends each search, with the titles, sites and descriptions of up to 20 pages, to TypeSafe's API;
  - it downloads its models from Hugging Face.

### Licences

- The dependencies are under MIT or Apache-2.0 (from the audits).
- `LayaModel.swift` is a translation of Apache-2.0 code, and its header says so.
- Two models download at runtime, each under its own terms: Qwen3-Embedding-0.6B for search and Gemma 4 E2B for text generation.
- The vendored xterm.js and its fit addon come with their MIT licence files.
- The build downloads zmx and the mlx-metal wheel's metallib.

### What a rewritten main does to the machines

- **Each Mac's checkout.**
  - Each Mac's main checkout is a clone, so after a rewrite its main holds hundreds of commits the new origin/main lacks.
  - `git pull` refuses to merge unrelated histories by default; this Mac has no `pull.rebase` set (verified). With `pull.rebase` set, a pull would try to replay the old commits on top.
  - Today's upgrade by hand is `git pull` and `make run`.
- **Old branches.** A pre-rewrite branch merged into the new main makes the old commits ancestors again, and the next push publishes them.
  - The orchestrator merges worktree branches with `--no-ff` and pushes (verified in its instructions).
  - Git refuses an unrelated merge unless told otherwise, but only if the rewrite changed the root commit.
- **The Ryzen.** The Ryzen has no checkout. The installer ships the relay package as committed and records the commit in a build file on the host. This is verified in the installer, not checked on the Ryzen. After a rewrite, the recorded commit isn't in the new history.
- **Option 03's Upgrade** (from its spec, accepted and being built). Each of these points at commits the new history lacks until the machine is reset and rebuilt, or for the Ryzen reinstalled:
  - Upgrade fast-forwards main to origin/main, and refuses a main that has commits origin/main lacks;
  - the build stamp names the running commit, and each row counts how far that is behind origin/main;
  - the Ryzen's row compares its recorded commit with origin/main.
- **Unpushed commits.** This Mac's main often runs ahead of origin/main (peers-upgraded-by-hand, Evidence). Commits not pushed before the rewrite exist only on the Mac that has them.
- **Commit references.** The docs' commit references point at nothing in the public repository after any rewrite.

### The name

"Launchy" is also the name of an established cross-platform keystroke launcher that runs on macOS.
