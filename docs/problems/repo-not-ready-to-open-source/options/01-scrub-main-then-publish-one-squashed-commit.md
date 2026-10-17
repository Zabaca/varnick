---
problem: repo-not-ready-to-open-source
title: Scrub main in ordinary tickets, then publish its tree as one squashed commit
summary: First, ordinary tickets on main, merged and pushed to the still-private origin. They give new installs safe defaults with existing installs unchanged, make Claude panes follow the account's login shell, and leave a user's own skill link alone. They take personal data out of every tracked file, move the proxy's docs out, add a public-repo rule for docs written from now on, and add the licence, notices, README, security note and contributor notes. Last, a full backup of every ref, then an orphan commit holding main's tree, checked as the only thing published. On the user's go, it replaces main on origin by a force-push, the remote prototype branch is deleted, every machine is reset to it, and the repository turns public. Public history starts at that commit.
status: shipped
---

## Solution

Accepted by the user on 2026-10-07, relayed by the coordinator, with the questions open under Further Notes decided as follows:
- **This option:** the scrub, then one squashed orphan commit. Option 02 is rejected.
- **Licence:** Apache-2.0, with Zabaca as the copyright holder (the lead's default, for the user to confirm).
- **The public commit's author:** the repository's current git identity for now. The user may switch it to a GitHub noreply address at the cutover.
- **The proxy's docs** are pushed nowhere. Removed docs are copied to a backup folder outside every repository, and the user moves them to the proxy's private repository later. The backup bundle goes in the same folder.
- **The problems stay published,** under the public-repo rule.
- **The name stays Launchy.**
- **Loopback mode** is documented in the security note now and fixed later.
- **Machines by kind** ("the Studio", "the Air", "the Ryzen") stay in problems and ADRs as dated records. Code and the other docs name roles.
- **The relevance filter** is off for a new install without a TypeSafe key.
- **Where the work lands:** the scrub tickets merge into an integration branch, `open-source-prep`, not into main, and nothing is pushed until the cutover. Main is merged into that branch along the way, so its tip carries main's work. The public commit takes that branch's tree, from a fresh clone of the local repository, since origin doesn't have the branch. The cutover, the user's own ticket, moves it to origin as main. Where this option says main for the scrub, its checks or the public commit's tree, read that branch.
- **Since 2026-10-09:** the name changes after all, to Varnick (name-taken-by-another-launcher option 01). Cutover steps 7 and 8 wait for the rename; the problem's "Where it stands" says until when.

Two phases.

**Phase 1, the scrub, on main.** Each change is an ordinary ticket, built in a worktree, reviewed, merged and pushed to origin while origin is still private. As decided, they merge into the `open-source-prep` branch instead, and nothing is pushed until the cutover (above):

- new installs get safe defaults, and the user's own installs stay as they are;
- Claude panes follow the account's login shell, as the relay already does;
- `make install` leaves a skill link it didn't make alone;
- the README documents the parts that stay author-shaped: the database's place, the Linux installer's platform, and the unpublished relevance checkpoint;
- personal data leaves every tracked file: docs, test fixtures, UI text and comments;
- the proxy's docs move out of the repository;
- a public-repo rule goes into the issue tracker's conventions, so that docs written from now on stay clean;
- the repository gains a licence, third-party notices, a README, a security note, contributor notes and a fuller `.gitignore`.

**Phase 2, the history step, last.**

1. A backup of every ref goes outside the repository.
2. In a fresh clone, an orphan branch takes main's scrubbed tree as one commit.
3. That commit is checked as the only thing that will be published.
4. On the user's go, it replaces main on origin by a force-push, and the remote prototype branch is deleted.
5. Every machine is reset to the new main: each Mac's checkout, and the Ryzen through the installer. Stranded branches are carried over by rebase or deleted.
6. The repository turns public.

## Trade-offs

- **Nothing from history is published.** No old version of a doc is published, no commit message, and no author address other than the one chosen. The audits' line ranges and patterns only have to hold for one tree. Names no pattern catches, such as client names and Chrome profile names, only need removing once, from the tip.
- **No new tool.** It needs only git; git filter-repo isn't installed here.
- **Public history starts at one commit.** Outsiders get no blame, no bisect, and none of the design trail in 295 detailed commit messages. The user keeps the old history locally, in the backup and a local tag, and can graft it under the new root on their own machine (unverified, see Further Notes).
- **The docs' commit references point at nothing publicly:** at least 19 of them. The dates beside them still say when.
- **Work in flight must land first,** or be carried over by rebasing its own commits onto the new main. A merge would bring the old history back.
- **The same aftermath as option 02:**
  - every machine is reset by hand, once;
  - old SHAs stay reachable on GitHub for a while, which the user accepts.

## User Stories

1. As someone who finds Launchy on GitHub, I want a README that says what it is, what it needs, how to build and install it and what it reads and sends, so that I can decide whether to try it.
2. As a potential user, I want a licence, so that I know I may use, change and share the code.
3. As a potential user, I want a security note with the threat model, so that I know what skip permissions, peers, the Phone page and upgrades let others do.
4. As a new user, I want my Claude sessions to start with Claude's permission checks unless I turn them off, so that installing Launchy doesn't quietly lower my guard.
5. As a new user without a TypeSafe key, I want the relevance filter off, so that I'm not shown a paid service as switched on.
6. As a new user whose login shell is bash, I want Claude panes to find claude where my shell's startup files put it, so that sessions start.
7. As a user who keeps their own custom-apps skill link, I want `make install` and `make uninstall` to leave it alone, so that installing Launchy doesn't replace my files.
8. As a Linux user, I want the README to say which hosts the relay installer supports, so that I don't run it on one it refuses.
9. As the author, I want no email address, tailnet name, tailnet IP, Tailscale ID, account name, home path, machine hostname, client name, Chrome profile name or proxy detail in the published repository, so that publishing exposes nothing of mine or my clients'.
10. As the author, I want my own installs to keep skip permissions on and the relevance filter as I set it, so that the new defaults don't change my Macs.
11. As the author, I want a full backup of the old history and branches outside the repository before anything is pushed, so that nothing is lost.
12. As the author, I want to give the go for the force-push and the visibility change myself, so that the irreversible steps happen when I choose.
13. As the author, I want each Mac and the Ryzen back on the new main without losing unpushed commits or work in flight, so that peers, the Phone page and upgrades keep working.
14. As the author, I want a rule in the docs conventions, checked in review, that keeps personal data out of committed docs from now on, so that planners and reviewers don't put it back.
15. As the author, I want peers-upgraded-by-hand's Upgrade to work from the new origin/main, so that the rewrite doesn't break the upgrade path being built.
16. As a contributor, I want to know which Claude Code plugins the repository's agents expect, so that the planning flow works for me or I know why it doesn't.

## Implementation Decisions

### Defaults for a new install

- **Skip permissions** is off when nothing is stored.
  - Existing installs stay on. At launch, when nothing is stored, Launchy stores on if its support folder already holds the sessions file, meaning Launchy has run on this Mac before. Otherwise it stores off. This happens once.
  - It is stored rather than worked out on each read, because the sessions file appears during the first launch, so a value worked out on each read would turn on at the second launch.
  - This Mac has nothing stored (verified), so without this step it would lose the setting.
- **A peer's choice.** A peer's start request keeps carrying its own skip-permissions choice, and the host follows it. A listed peer already reaches the host's account over SSH, so this grants nothing that SSH doesn't. The security note says so.
- **The relevance filter's switch.** With nothing stored about the filter, neither a choice nor the switch, the switch reads as on only when a TypeSafe key is present: in the Keychain, in the environment or in `.env`.
  - Otherwise it reads as off.
  - This is worked out at each read and never stored, like today's reading of the old `off`.
  - An install that has stored either setting is unchanged.
  - "On this Mac" stays a choice, with its import row.
- **The headless relay** already defaults skip permissions to off, and is unchanged.

### Claude panes follow the account's login shell

- **Which shell.** A Mac's Claude panes run the account's login shell from the account record, as the headless relay does, when that shell is zsh, bash or sh.
  - Any other shell falls back to zsh. Fish and nushell can't run the POSIX script that passes the arguments.
  - `-l -i` stays, so the shell's own startup files put claude on PATH.
- **App panes stay on zsh,** since their script uses zsh's `pipestatus`. The README says app panes need bun on zsh's PATH.
- **Docs that say zsh.** The comment on the shared shell arguments, and where-it-breaks' line on the claude command line, change from zsh to "the account's login shell".

### The custom-apps skill link

- `make install` links the skill only when nothing is at the link's path or the link there already points into this checkout. Otherwise it prints that it left the existing entry alone, and carries on.
- `make uninstall` removes the link only when it points into this checkout.

### Left as they are, and documented

- **The database** stays in the checkout's `db/` folder, where `make run` and `make install` put it. The README says so, and that `make clean` keeps it. Moving it to Application Support is out of scope: the relay reads the same file, and the archive holds history Chrome has dropped.
- **The Linux installer** stays x86_64-only, with swiftly. The README lists its requirements.
- **"On this Mac" relevance and the two eval commands.** The README says that the checkpoint isn't published and that the evals need the user's own labelled data. It never names where the author keeps theirs.
- **Claude Code plugins.** `.claude/settings.json` is unchanged. CONTRIBUTING names the plugins the agents expect. That Claude Code skips enabled plugins a user hasn't installed is inferred, not checked.
- **Tool lookups and history.** The fixed lookup paths for bun and tailscale, and Chrome-only history, are unchanged.

### Personal data out of every tracked file

The scrub follows the problem's inventory, then searches by category, since the audits' line ranges proved incomplete.

- **Out everywhere:**
  - email addresses, except a service's public ones;
  - tailnet names and every name under `.ts.net`, and tailnet IPs;
  - Tailscale node and user IDs;
  - the user's account name and home paths;
  - the hostnames of the user's machines, and every `user@host` form of them;
  - Chrome profile names and client names;
  - the credential proxy's name, host, ports, control plane, tokens and secrets setup;
  - the path of the user's private folder, and the names of the files in it.
- **Out of the evergreen text,** which is code, UI text, CONTEXT.md and its skill copy, where-it-breaks and the new files: the user's machines by kind ("the Ryzen", "the Studio", "the Air") give way to roles ("a Linux host", "another Mac").
  - Machines by kind stay in problems and ADRs. They are dated records of what was measured where.
- **Kept:** counts and measurements that support a decision (sessions, transcripts, pages, timings), worded without the identifiers above.
  - The per-profile figures in history-tied-to-one-mac become totals across profiles.
- **Machine-specific recipes keep their steps.** Real accounts and hosts in them become placeholders.
- **Made-up values in examples and fixtures.** One consistent set, chosen by the first ticket that needs it and reused after: an account name, a Mac name, a Linux host name, a tailnet name under `.ts.net`, addresses at the start of 100.64.0.0/10, and IDs in Tailscale's shape that read as examples.
  - In fixtures they keep each field's JSON type.
- **Statements that the repository is private** become dated or go.
- **The scrub list.** Each scrub ticket adds every literal string it removed to a local list in the problem's scratch folder, which is gitignored and never committed. The final checks run that list, and the category patterns, over the tree.

### The proxy's docs

- **The proxy's problem leaves the repository,** with its four options. A copy goes first to wherever the user chooses. The recommendation is the proxy's own private repository, since that is its subject. No other doc links to it (verified).
- **Other mentions of the proxy** are in ADRs 0007, 0009 and 0011, the installer's header, and the problems that cite it as prior art. They keep the design point they make, and lose the proxy's name and everything about how it is deployed.

### Fixtures

- **The values.** The Phone page's tests and the whois fixture get made-up values with the same shapes and JSON types. Expectations that compare against those values change with them, and `bun test` passes.
- **The vendored VERSIONS file.** Its header comments change, and its digest lines don't, since the test reads only lines that aren't comments (verified).

### The public-repo rule, from now on

- **docs/problems/ stays in the repository** and is published. Every ADR links into it, and the planner commits problems on main so that builders' worktrees have them.
- **The rule.** The issue tracker's conventions gain a section, "This repository is public", that states the scrub's rule for anything committed:
  - measurements from the user's own data, recipes with real hosts, and anything else private go in the problem's scratch folder, which is local and gitignored;
  - the committed doc then says "measured on the user's machine; figures kept locally".
- **One place.** That section is the only statement of the rule:
  - the planner's and the reviewer's instructions point to it, and the reviewer checks every diff against it;
  - the prototyper's instructions say a capture branch holds real data and is never pushed.
- **`.gitignore` gains:**
  - `.env.*` and `*.log`;
  - SQLite databases with their `-wal` and `-shm` files, and `*.db`;
  - `*.jsonl`;
  - model weights (`*.safetensors`, `*.gguf`, `*.npz`);
  - `.DS_Store` and `prototypes/`. Another tool's folder in the checkout is kept out by each machine's own `.git/info/exclude`, not by this file, since its name is private.

  No tracked file matches them (verified). The prototyper's capture adds its folder with a forced add.

### New repository files

- **LICENSE.** The user chooses the licence and the copyright holder. The recommendation is Apache-2.0, which matches the Laya translation inside. MIT would work too, with that file's notice kept.
- **THIRD_PARTY_NOTICES.** Each licence is read from its source, not assumed. It covers:
  - the Laya translation (Laya and laya-mlx, Apache-2.0), with their NOTICE files if they have any;
  - the vendored xterm.js and its fit addon (MIT), whose files are already beside them;
  - what the build downloads (zmx, and the metallib from the mlx-metal wheel);
  - what Launchy downloads at runtime (the embedding model and Gemma 4 E2B), each under the terms on its model card at the pinned revision;
  - the Swift package dependencies, by name and licence.
- **README:**
  - What Launchy is.
  - **Requirements:**
    - Apple Silicon and macOS 14 or later;
    - a Swift 6.2 toolchain;
    - Bun;
    - Tailscale, for peers and the Phone page;
    - the Claude Code CLI, on the login shell's PATH.
  - **Build and install** through make. Plain `swift build` lacks the codesigning and the metallib.
  - **Restarting.** A restart ends sessions that aren't kept in zmx.
  - **Optional parts:** peers, the Linux relay and its installer's requirements, the Phone page, Listening, TypeSafe, and the on-device models with their download sizes.
  - **Privacy:** the reads, recordings and sends listed in the problem.
  - A line saying Launchy isn't affiliated with or endorsed by Anthropic.
  - Links to the security note, CONTRIBUTING and docs/.
- **SECURITY.md:**
  - **Skip permissions:** what it allows, that it is off for new installs, and that a peer's request carries the peer's choice.
  - **Peers over SSH:** the peer list and the SSH keys are the boundary, and the relay runs as the user.
  - **The Phone page:**
    - It is off by default, runs behind `tailscale serve`, and identifies the device through Tailscale's whois.
    - In loopback mode, any local process, other accounts on the Mac included, can pose as a listed device and get a shell. The advice is socket mode, or not serving the page on a shared Mac.
  - **The administrator prompt.**
  - **The planned upgrade from origin/main:** anyone who can push to the repository a Mac fetches from can run code there once the user presses Upgrade. A fork fetches its own origin.
  - **How to report:** GitHub's private vulnerability reporting, turned on at publication. This needs no published email address.
- **CONTRIBUTING,** kept short:
  - `make build` and `bun test`, and the fact that there is no Swift test target;
  - the problem, option and ticket flow, and the public-repo rule;
  - the plugins the agents expect;
  - that a restart ends sessions.

### The history step

**Preconditions,** each checked rather than assumed:

- On every Mac, main has been pushed: origin/main equals that Mac's main, or the Mac's extra commits have been pushed first.
- No worktree branch holds unmerged work the user wants. Each is merged, or listed to be carried over.
- Peers-upgraded-by-hand option 03's tickets in flight have merged (see below).
- The scrub's final checks have passed on main.

**Building the public commit,** with nothing pushed:

1. **Backup.**
   - A git bundle of every ref in the main checkout (main, every branch and every worktree branch), written outside every repository to the place the user chose and checked with `git bundle verify`.
   - A local tag on old main, never pushed.
2. **The commit.** A fresh clone of origin/main, outside the main checkout. In it, an orphan branch whose one commit holds main's tree.
   - It is authored and committed as the identity the user chose.
   - Its message says what Launchy is, and that the history before publication isn't public.
3. **Checks on that commit:**
   - its tree is identical to main's, so only the history differs;
   - the category patterns and the scrub list find nothing in it;
   - `make build` and `bun test` pass in the clone;
   - the new files are present.

**Cutover, on the user's go:**

4. **Push.**
   - Force-push the commit as main, with a lease on old main's commit, so that a push made in the meantime makes this push fail instead of being lost.
   - Delete origin's prototype/product-board branch.
   - List origin's refs. Only main should be left.
5. **Each Mac.**
   - Confirm that nothing is unpushed, or that the backup holds it. Then fetch and reset main to origin/main. Never run `git pull`.
   - Stranded worktree branches are either deleted or carried over by rebasing only their own commits onto the new main. They are never merged.
   - Their worktrees are removed.
   - The rebuild and restart happen at the user's moment, since the restart ends sessions not kept in zmx.
6. **The Ryzen.** Rerun the installer from a reset Mac, so that its build file names a commit of the new history.
7. **Visibility.** Make the repository public, then turn on private vulnerability reporting.
8. **Check from outside.** A fresh clone from GitHub has one commit, builds, and passes `bun test`.

### Order with peers-upgraded-by-hand option 03

- Its in-flight tickets 1 to 3 merge before two things:
  - the scrub ticket that edits its option file, which would otherwise conflict with them;
  - the history step, which would otherwise strand them.
- When those tickets have merged, the cutover's reset of each machine doubles as option 03's manual round: reset, build and restart each Mac, and reinstall the Ryzen. From then on, Upgrade works from the new origin/main.
- Option 03 needs no change for the rewrite. A Mac that wasn't reset has commits origin/main lacks, so its Upgrade refuses instead of building (from its spec).

## Testing Decisions

There is no Swift test target. Every code ticket runs `make build`, and every ticket that touches the Phone page runs `bun test` in it.

- **Defaults, by hand after a restart (the user):**
  - On this Mac, Skip permissions still reads as on and is now stored, and the relevance filter is unchanged.
  - A new Claude pane starts, and claude is found.
- **Defaults on a fresh install:**
  - Read the init path.
  - Where possible, launch with a temporary home under both `HOME` and `CFFIXED_USER_HOME` (where-it-breaks' note on HOME). Whether UserDefaults follows that home is unverified. If it doesn't, the check is the code read alone.
- **Shell.**
  - The pane's command line, run by hand under `bash -l -i`, starts claude for a bash setup.
  - On this Mac (zsh), sessions start as before.
- **Skill link.**
  - With a link to somewhere else at the skill's path, `make install` leaves it and says so, and `make uninstall` leaves it too.
  - With nothing there, `make install` links it, and `make uninstall` removes it.
- **The scrub.**
  - After each scrub ticket, its own strings are absent from the tree.
  - After the last one, the category patterns and the whole list find nothing anywhere in the tree, apart from a service's public addresses, which are listed as allowed.
- **The public commit:** the checks in step 3.
- **After the cutover:**
  - Origin's refs are only main.
  - Each Mac's checkout is on the new main, with a clean status.
  - The Ryzen's hello reports a commit of the new history.
  - The phone reaches the page.
  - A peer session starts both ways.
  - An old SHA's URL on GitHub may still answer for a while, which is accepted.

## Out of Scope

- Renaming Launchy. The user decides. If chosen, it needs its own problem, because it changes the bundle id, the LaunchAgent label, the support folder and the UserDefaults domain.
- Hardening loopback mode. That is its own problem; the security note documents the risk now.
- Moving the database to Application Support.
- Supporting more architectures and distributions in the Linux installer.
- Publishing the relevance checkpoint, or a recipe for it.
- A PATH fallback for the bun and tailscale lookups, and history from other browsers.
- Following the account's shell for app panes.
- A new repository, a purge through GitHub Support, CI, releases, and issue templates.
- Rewriting the docs' commit references.
- Pushing any branch but main.

## Further Notes

- **Decided by the user, relayed on 2026-10-07:**
  - a branch, then main replaced by it and force-pushed;
  - old SHAs may stay reachable for a while;
  - no new repository and no purge;
  - only main is pushed.
- **Open for the user** (all decided on 2026-10-07, at the start of Solution):
  - this option or option 02;
  - the licence and copyright holder, and the author identity for the published commit;
  - where the proxy's docs and the backup bundle go;
  - whether docs/problems/ stays public under the rule, or moves to a private companion repository (which breaks every ADR's link);
  - the name;
  - whether loopback mode is fixed before publishing or only documented;
  - whether machines by kind stay in problems and ADRs;
  - whether a fresh install's relevance filter defaults to off (the user may want TypeSafe shown on).
- **Siblings to copy:**
  - for the skip-permissions default, the headless relay's default and the relevance switch's reading of the old `off`;
  - for the login shell, the relay's account lookup;
  - for the stored-once migration, the relevance setting's write of the switch on first change.
- **Grafting locally (unverified).** The user could graft the new root onto old main's tip with `git replace`, for local log and blame across both. Replace refs aren't pushed by default, but whether a push can still send objects through a graft is unverified. Try it against a throwaway bare remote before relying on it.
- **Verified** in code, git or GitHub on 2026-10-07:
  - the defaults and this Mac's stored settings;
  - the shells used per pane kind;
  - the skill link commands;
  - the installer's architecture check and its recorded commit;
  - the loopback banner;
  - that no tracked file matches the new ignores;
  - origin's two branches, and no forks or pull requests;
  - the unmerged worktree branches;
  - the identical CONTEXT.md copy;
  - that the VERSIONS test reads only lines that aren't comments.
- **Inferred, not checked:**
  - that Claude Code skips plugins a user hasn't installed;
  - that the Ryzen has no clone;
  - the licences of the runtime models and zmx;
  - that other local accounts can reach the loopback port.
- **Tickets, a sketch** (`/to-tickets` makes them). The tickets marked AFK run unattended; 12 and 13 need the user:
  1. **Safer defaults (AFK):** skip permissions off for new installs, stored once with existing installs kept on; the relevance switch worked out from a key when nothing is stored.
  2. **Login shell (AFK):** Claude panes follow the account's login shell; the shared comment and where-it-breaks line change.
  3. **Skill link (AFK):** `make install` and `make uninstall` leave a foreign skill link alone.
  4. **UI text and comments (AFK):** made-up examples in UI text and code comments, and machines named by role. This ticket picks the set of made-up values and starts the scrub list.
  5. **Fixtures (AFK):** the Phone page's test fixtures get the made-up values; `bun test` passes.
  6. **The rule (AFK):** `.gitignore`, the public-repo rule in the issue tracker's conventions, and the planner's, reviewer's and prototyper's pointers to it.
  7. **The proxy's docs (AFK once the user has named where the copy goes):** its problem moves out, and other mentions lose its name and details.
  8. **Personal data in problems (AFK):** the five problems with personal and client data; dated private-repo statements.
  9. **Recipes and wording (AFK, after option 03's in-flight tickets merge):** machine-specific recipes in options; wording in ADRs, CONTEXT.md and its copy, where-it-breaks and the MLX comment; a category search over the rest of docs/.
  10. **New files (AFK once the user has chosen the licence):** LICENSE, THIRD_PARTY_NOTICES, README, SECURITY.md and CONTRIBUTING.
  11. **Final scrub check (AFK):** the category patterns and the whole list over the tree; `make build` and `bun test`; a note in the scratch folder of what stays on purpose.
  12. **The public commit (AFK up to the push):** the preconditions checked, the backup bundle and local tag, the fresh clone, the orphan commit and its checks. Nothing is pushed.
  13. **Cutover (the user's go):** the force-push with lease, removing the remote prototype branch, the reset of each Mac and its branches, the Ryzen's reinstall, visibility and vulnerability reporting, and the check from outside.
