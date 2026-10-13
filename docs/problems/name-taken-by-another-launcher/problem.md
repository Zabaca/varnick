---
title: Launchy shares its name with an established launcher, and is about to be published under it
description: "Launchy" is also the name of a long-established cross-platform keystroke launcher that runs on macOS. This repository is about to go public under that name; repo-not-ready-to-open-source has only the visibility switch and vulnerability reporting left. The user has chosen a new name, Varnick, and wants the rebrand done before the repository goes public. The name is more than text. It is the bundle id that macOS ties privacy grants and Keychain items to. It is also the name of the settings domain, the support folder, the LaunchAgent and the database file. Every zmx session's name and labels carry it, as do every Claude pane's hook files and variables. So do the peers' SSH command and relay, the headless host's install root and unit, the Phone page's server, and custom apps' manifests in other projects. The agents and skills use it, and the tree outside docs/problems mentions it about 1,500 times.
impact: Published as Launchy, it would compete for a name another project has held for years. Searches would lead to the other launcher, and a later rename would break every clone, link and install made in between. A rename after going public would also have to keep strangers' installs working. Renamed now, only the user's own Macs and the Ryzen need migrating. Even so, a careless migration can do real harm. The old and new apps can both run and drive the same conversations. History built over months can be left behind or replaced by an empty database. Paired Macs can drop each other, and Claude sessions, privacy grants and saved keys end with no plan for them.
severity: mid
evidence: The user's decisions of 2026-10-09, relayed by the coordinator. Read-only inspection by the planner on 2026-10-09 at db973f1. It covered git grep over the tree, the build, install, restart and installer scripts, and the code named under Today. It also covered the one in-flight branch, plus, on one Mac, the running processes, zmx's session list, the stored settings' key names and the Library folders named after the app. Both GitHub repositories' metadata was read through the API. Nothing was changed. What was inferred rather than checked is marked.
status: closed
---

## What the user wants (2026-10-09)

Rename Launchy to **Varnick** before the repository goes public, in full, with a one-time migration on the user's own machines.

**Decided by the user** (relayed on 2026-10-09; no option here reopens these):

1. **GitHub.** The existing public Zabaca/varnick, an unrelated Deno project, is renamed aside, for example to Zabaca/varnick-deno, and archived. Its history stays public as it is. Then Zabaca/launchy is renamed to Zabaca/varnick.
   - GitHub redirects the old launchy URL only until a repository named launchy is created in the organisation again.
   - Each Mac's `origin` remote is updated.
2. **The full rebrand, with migration.** That covers:
   - the name;
   - the bundle id, `com.zabaca.launchy` becoming `com.zabaca.varnick`, with its `.screen-text` and `.transcript` sub-ids;
   - the LaunchAgent label;
   - the support folder;
   - the settings domain;
   - `launchy.json` for custom apps;
   - the peer and relay names: `launchy-peer`, `launchy-upgrade`, `launchy-install`, the Phone page's names and the socket names;
   - the `launchy-*` agents and the skills;
   - CONTEXT.md;
   - the ADRs' and docs' evergreen text;
   - the Makefile's targets;
   - the source folder.

   Nothing outside the user's own machines depends on the old names, so there is nothing to stay compatible with. The only exception is a one-time migration on the user's Macs and the Ryzen.
3. **The wake phrase becomes "Hey Varnick".** How reliably the transcriber hears it is a risk to measure. It is not a reason to keep the old phrase.

## Order against going public

repo-not-ready-to-open-source option 01 has done its scrub and its cutover. Two of its steps are left: making the repository public and turning on private vulnerability reporting. Those steps, and its check from outside, wait until four things are done: the rename has merged, both GitHub renames are done, every machine runs Varnick, and the tree has been checked again under that problem's public-repo rule (the rename touches nearly every file).

What changes in that problem:

- **Its option 01** decided "The name stays Launchy". Its Out of Scope says a rename needs its own problem, because it changes the bundle id, the LaunchAgent label, the support folder and the settings domain. This is that problem. The option is in progress and belongs to the user, so this problem doesn't edit it. A dated line there pointing here would keep the record straight.
- **Its problem.md** ends with "The name": "Launchy" is also an established keystroke launcher's name. That observation is this problem's reason, and this problem answers it.
- **README, SECURITY.md, CONTRIBUTING and THIRD_PARTY_NOTICES**, which that option added, carry the name. They also carry the support folder and log paths, the database's file, the relay's name, the custom-apps folder and the wake phrase. All of that is renamed with the rest.
  - SECURITY.md's way to report a vulnerability names no repository and stays as it is.
  - The README's line saying it isn't affiliated with Anthropic stays, with the new name.
- **Its check from outside** clones from GitHub. After the rename, that clone comes from the new URL.

## Today

Verified at db973f1 unless marked. The tree has 334 tracked files. Outside docs/problems the name appears 1,503 times in 148 files, and inside docs/problems 2,127 times.

### What macOS knows Launchy by

- **The bundle id `com.zabaca.launchy`.** It is in the Info.plist the linker embeds and in the identifier the Makefile signs with. ADR 0022 says macOS knows a signed Launchy by its team and bundle id, so a new bundle id makes it a new app. For the first signed build, its words were that "every permission and each saved key is asked for once more".
- **The grants Launchy asks for:** the microphone and system audio (Listening), Accessibility (Point at the screen) and Screen Recording (the text fallback). The Info.plist's usage strings name the app.
  - Every pane process is attributed to Launchy (ADR 0019's correction). So any grant a pane's process triggered, such as a protected folder or automation, is also Launchy's and stays with the old id (inferred).
- **Saved keys.** The Keychain holds two items, the TypeSafe key and the model server's key, under the service `com.zabaca.launchy` and labelled "Launchy" and the account. Their access list names the app that saved them, so a renamed app is asked before it can read them. This is inferred from ADR 0022 and the Keychain module's own comment. The TypeSafe key is read while Settings loads at launch.
- **Dispatch queue labels** `com.zabaca.launchy.transcript` and `com.zabaca.launchy.screen-text`. They are only labels, with no state.

### Saved state on a Mac

- **The settings domain** is the bundle id's. It holds:
  - this Mac's peer identity (id, name, address);
  - the peer list;
  - every setting, among them Keep sessions running and Skip permissions;
  - the Phone page's last published target;
  - one key named after the app, `heyLaunchy`.
- **An earlier migration** runs at the top of the app's entry point, before anything reads settings. When the bundle id's domain is empty, it copies the domain named after the executable ("Launchy") and the WebKit folder of that name. On one Mac that older domain and folder are still on disk (verified). After a rename, that code would copy those stale settings into the new, empty domain.
- **The support folder,** `~/Library/Application Support/Launchy`.
  - It is defined once for the app and the relay (`SupportFolder`, "on a Mac the path never moves"). The session store, the two model loaders, the reranker and the transcripts also name it.
  - It holds:
    - `sessions.json` and its backups;
    - `panes/`, each Claude pane's hook files, plus a `scratch` link left by an earlier migration;
    - `models/`, about 4.3 GB on one Mac: the embedding model, Gemma, and the relevance checkpoint imported from a private folder;
    - `transcripts/`;
    - the custom apps' data and logs;
    - `devices.json`;
    - `phone/`, which holds the page's socket;
    - `ssh/`, the control sockets;
    - `readers/` and `upgrade/`;
    - `peer.sock`, the `launchy-peer` link and the file that tells the relay where the database is.
- **Web pane data** (cookies and logins) is under `~/Library/WebKit/com.zabaca.launchy`, with caches and HTTP storage under the same id.
- **The history database** is `db/launchy.sqlite` in the checkout, with its WAL.
  - `LAUNCHY_DB` chooses it, set by `make run`, `make install` and the LaunchAgent; otherwise it is that default under the working folder.
  - It holds history Chrome has since dropped, so it can't be rebuilt. An app that doesn't find it creates an empty one.
- **The log** is `~/Library/Logs/Launchy.log`.

### Starting and stopping

- **The LaunchAgent `com.zabaca.launchy`** comes from a template that bakes in the checkout's path and the database's path. On one Mac it is installed and not running, since Launchy was started by `make run` (verified).
- **`make stop` and the restart script** find Launchy by the binary `.build/release/Launchy`, run from this checkout or by that relative path.
  - A build whose binary has a new name would leave a running Launchy alive beside the new app, with both holding the same hotkeys and the same zmx sessions.
  - The peers' Restart and the status menu's Restart Launchy run the same script.
- **The build** keeps a copy of the last good binary while it runs. The launch snapshot names its binary after the running one.

### Panes, zmx and the hooks

These live mostly in the shared package that the Linux relay builds too.

- **Pane sessions.** Every pane's zmx session is `launchy-<uuid>`, labelled `launchy=1`, and a peer's session also carries `launchy-control` and `launchy-origin`.
  - The prefix is read by the launch sweep, the relay's session list and the Phone page's session-name pattern, and appears in its links (`#s=launchy-…`).
  - A build with new names neither sees nor sweeps sessions named the old way.
- **Other zmx sessions:**
  - `launchy-phone-page`, labelled `launchy-page`, `launchy-page-mode` and `launchy-page-place`. It outlives a restart by design.
  - `launchy-upgrade`. Its log ends with a `launchy-build-exit=` line.
  - `launchy-install-<slug>`.
  - App panes carry `launchy-app` in their command line.
- **Hooks are fixed when claude starts.** A running Claude pane's hooks are in the `--settings` it started with. In the pane's folder under the support folder they write:
  - `.launchy-turn`, with `.askers` and `.before`;
  - `.launchy-stop`;
  - `.launchy-session.json`;
  - `.launchy-conversations`.

  They find that folder through `LAUNCHY_SESSION_FILE`. The work hooks read the work skill's `LAUNCHY-WORK|…` markers, and branch ties live in git config as `branch.<branch>.launchy-option`. On one Mac, the running claude processes carry those names in their command lines (verified). A running session can't follow a rename: it writes the old names until it restarts.
- **Variables.**
  - Panes and apps are given `LAUNCHY_SESSION_FILE`, `LAUNCHY_PANE_ID`, `LAUNCHY_PROJECT`, `LAUNCHY_SPLIT_FROM` and `LAUNCHY_APP_DATA`.
  - The app, the relay, the page and the evals read `LAUNCHY_DB`, `LAUNCHY_ZMX_DIR`, `LAUNCHY_CLAUDE_DIR`, `LAUNCHY_BOOT_ID`, `LAUNCHY_EMBEDDINGS`, `LAUNCHY_TEXT_GENERATION`, `LAUNCHY_EVAL_FILTER`, `LAUNCHY_LOG_RESIZE`, `LAUNCHY_PAGE_SOCKET`, `LAUNCHY_PAGE_LOOPBACK`, `LAUNCHY_PAGE_PORT`, `LAUNCHY_RELAY`, `LAUNCHY_DEVICES` and `LAUNCHY_TAILSCALE`.
  - On one Mac, none is set in launchd's environment, the shell profiles or Claude Code's user settings (verified).
- **Ending sessions has precedents.** ADR 0004 accepts that bumping zmx's pin "ends running sessions once", and a restored pane whose session is gone resumes its conversation when first shown (ADR 0001).
- **One name is a key in someone else's file.** The relevance checkpoint's own config file uses the keys `launchy_format` and `launchy_question`, which the reranker decodes. The private checkpoint was made with those keys, so renaming them would stop it loading.

### Peers and the headless host

- **The SSH command.** A Mac's SSH command runs `$HOME/Library/Application Support/Launchy/launchy-peer`, else `$HOME/.launchy/launchy-peer`.
  - The installer reads that command from the app's source at the commit it ships, and ships the package by its folder's name.
  - On a Mac the relay is the app's own binary through that link. It reads the same settings domain, and it runs before the app's migration code.
  - A relay whose domain lists no peers answers `unlisted`. A Mac that gets that answer drops the other Mac's sessions and Recent entries until a hello brings it back (where-it-breaks › Peers).
- **No path grows.** Socket and control paths are limited to 103 bytes, and the old and new names are the same length: "Launchy" and "Varnick", `launchy-peer` and `varnick-peer`, the zmx prefixes, and the bundle ids.
- **The headless host's install root** is `~/.launchy`. It holds:
  - the relay and a link to it;
  - zmx;
  - the package's source;
  - `config.json`;
  - the build record;
  - `state/`: its id, `peers.json`, `devices.json` and session records;
  - the install lock;
  - with the page: the page's files, its socket and the systemd user unit `launchy-phone-page.service`.

  The installer's `--uninstall` removes the relay, its link, its source and the page. It keeps `state/`, `config.json`, zmx and running sessions.
- **The upgrade path can't carry a machine across** (ADR 0013).
  - After the rename, neither side's SSH command finds the other side's relay.
  - A Launchy Mac pressing Upgrade would fast-forward to the renamed tree and build it. Its Restart would then run the new restart script, which doesn't stop the old app.
  - An installer run from a renamed checkout would put a fresh relay, with a new id, beside the old root.
- **The relay comparison** names the package's folder, and so does the installer's archive step.

### The Phone page

- **On a Mac, the published mount.** `tailscale serve` points the port either at the page's socket under the support folder or at a loopback port.
  - One Mac's stored target is the socket (verified on 2026-10-09; ADR 0011 recorded loopback for both Macs).
  - The publisher counts a mount at the last published target as its own and replaces it, and leaves any other mount alone (`PhonePage.serveState`). So after the support folder moves, the page republishes only if the stored target comes along with the settings.
- **On the Ryzen,** the installer counts the mount as its own only when it points at the socket in its own install root. A moved root leaves the old mount looking like someone else's.
- **The address doesn't change.** The page's address (host and port) and its title don't contain the name. Its session links do.

### Custom apps, the agents and the skills

- **Where apps live.** Apps are found in `.launchy/custom-apps/<app>/launchy.json` in a project and in `~/.launchy/custom-apps/`. They keep their data in the support folder and read the `LAUNCHY_*` variables above. Scratch writes into `.launchy/scratch/<pane id>/` in the project.
  - This repository holds the Scratch app. Other projects on one Mac hold apps of their own; they were counted locally.
  - On a Mac `~/.launchy` holds user apps; on the headless host it is the install root.
- **The skill link.** `make install` links the custom-apps skill into the user's Claude skills only when nothing is there or the link is already its own. A link into a moved checkout is left alone. On one Mac the link isn't there today (verified).
- **The agents and docs.** The agents are `launchy-blogger`, `launchy-builder`, `launchy-orchestrator`, `launchy-planner`, `launchy-prototyper` and `launchy-reviewer`. The skills are custom-apps, scratch and work. CLAUDE.md, CONTEXT.md (which the skill links to), CODING_STANDARDS.md and docs/agents all name the app.

### Spoken requests

- **The wake-phrase matcher** accepts "hey" or "hay" followed by a word starting "launch", "lunch" or "lanch", within the first three words; "launch you" also counts as the name. The microphone's transcriber is given "Launchy" and "Hey Launchy" as contextual strings.
- **Measured wording.** Jev's decide questions and the screen picker's context say the person spoke "to Launchy, a launcher on their Mac", and Launchy's own panel is read under the title "Launchy". where-it-breaks says those questions are used word for word as measured, and that changing them means measuring again.

### The checkout's folder

- **Claude Code's keys.** The checkout is a folder named `launchy`. Claude Code keys each project's transcripts and memory on its path, with non-alphanumerics turned into dashes. On one Mac there is one such folder for the checkout and one per worktree (verified).
- **Launchy's own keys.** Launchy computes whether a session can be resumed from its directory the same way (where-it-breaks). Saved panes, Recent, ended cards and search rows all hold directories.
- **Other holders of the path:**
  - the LaunchAgent and the skill link;
  - git's worktree records;
  - SwiftPM's build folder, which holds absolute paths.
- **agent-lab** (counted, not read through). Its harnesses call the binary, its variables and its paths by the old names, in about 20 files.

### In flight

- One worktree branch is tied to sessions-cant-see-or-act-on-the-screen option 01.
  - It adds an MCP server named `launchy`, whose tools Claude Code names after it, and ADR 0023.
  - It touches where-it-breaks, the README and SECURITY.md, which the rename also touches.

### GitHub

Read through the API on 2026-10-09.

- **Zabaca/launchy** is private, with main as its default branch and no Pages.
- **Zabaca/varnick** is public and not archived, with main as its default branch.
  - Its last push was on 2026-09-18, and it has no stars or forks.
  - It has no webhooks, workflows, releases or deploy keys.
  - Besides main and `archive` it has 12 work branches (14 heads in all, counted with `git ls-remote`).
- **Clones of Zabaca/varnick.** One Mac has a clone with it as `origin` (verified); other machines, and whatever pushed those work branches, weren't checked. Once Zabaca/launchy takes the name, a push to the varnick URL from such a clone lands in this repository.

## Left to decide

- How each machine is migrated, and whether running sessions must survive the switch.
- Whether the checkout's folder is renamed, and when.
- Whether docs/problems/ and the ADRs keep "Launchy" as a dated record or are rewritten.
- Whether the two saved keys are copied (macOS asks once for each) or entered again.
- Whether the Ryzen's install root is moved, which keeps its id, its pairings and its device list, or installed fresh and paired again.
