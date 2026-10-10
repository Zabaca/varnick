---
problem: name-taken-by-another-launcher
title: Rename everything on one branch, let Varnick move its own data at first launch, and cut each machine over by hand once
summary: Accepted on 2026-10-09, with the recommendations under Further Notes taken, the Fold as logo and menu-bar icon, and the chosen page for varnick.com. A measurement comes first. It checks how the transcriber hears "Hey Varnick" and whether Jev's measured questions hold with the new name. Then one integration branch renames every name, identifier, file, folder and evergreen doc, and bumps the peer protocol. It also carries a one-time migration, copied from the app's existing settings migration. At its first launch, before anything reads saved state, Varnick ends every zmx session named the old way, then copies the settings domain, moves the support folder, copies the web data and renames the database. Short-lived guards keep a machine still on Launchy from crossing by itself: Varnick's command-line modes refuse to run there, the build refuses while Launchy's binary is in the checkout, stop and restart also stop Launchy, restart refuses with no Varnick to start, install removes the old LaunchAgent, and the Linux installer refuses a host still holding the old root. After the merge come the two GitHub renames. Each machine is then cut over by hand from a terminal outside the app, the Ryzen first, and the user grants permissions and enters keys again. The repository goes public after that, and a last ticket removes the migration and guards. The checkout's folder is renamed after every machine runs Varnick, and varnick.com serves the new page once a downloadable build exists.
status: accepted
---

## Solution

Accepted by the user on 2026-10-09, relayed by the coordinator, with every question open under Further Notes decided as recommended there, and two additions:

- **This option.** Options 02 and 03 are rejected.
- **The checkout's folder** is renamed later, as its own step once every machine runs Varnick.
- **Historical docs.** Problems stay dated records, slugs included. ADRs are renamed where they describe the system as it is now and kept where dated, their file names follow the new titles, and one new ADR maps old names to new (Implementation Decisions › Docs).
  - ADR 0023 has merged since this option was written, so six ADR file names carry the name, and the mapping ADR is 0024.
- **Saved keys** are entered again rather than copied, so no Keychain prompt sits in the launch path.
- **The Ryzen's install root** is moved, not reinstalled fresh. It keeps its id, its pairings and the phone's device listing.
- **The logo is the Fold.** It replaces the menu bar's symbols and becomes the app icon (Implementation Decisions › The logo).
- **varnick.com** gets the chosen landing page. It moves into this repository after the rename and goes live once a downloadable build exists (Implementation Decisions › varnick.com).
- **The in-flight screen-access branch has merged** (89f3b76), so phase 2 can start.
- **GitHub was done early,** on 2026-10-09 at the user's request, before the code rename. Phase 3 no longer waits for the merge.
  - The Deno project is now Zabaca/varnick-deno, archived and still public; its one local clone was repointed first.
  - Zabaca/launchy is now Zabaca/varnick, still private, with a new description. The old URL redirects (checked), and origin on the Mac that did it points at the new name.
  - Left for the user: another tool that pushed the Deno project's work branches still has that clone registered as a project; clones on other machines weren't checked.
- **Added by the planner while writing the tickets** (2026-10-09), each because a Mac still on Launchy could otherwise cross half-way:
  - Varnick refuses every mode but the relay and the MCP server while the old support folder exists and the new one doesn't, and only the app's start migrates (The first-launch migration).
  - The restart script refuses, stopping nothing, while the checkout has no Varnick binary (The guards).

Six phases, in this order.

1. **Measure first** (agent-lab, through the `eval` agent). This runs in parallel with phase 2's other work, but its result goes into the branch before the merge.
   - How the on-device transcriber writes "Hey Varnick", with and without the new contextual strings, and how often it hears the name in speech that doesn't contain it.
   - Whether Jev's decide questions and the screen picker's context still meet their measured thresholds with "Varnick" in place of "Launchy". The panel is also read under the new title.
2. **One integration branch, `varnick`.** It is cut from main after the in-flight screen-access branch has merged, so that branch's names are renamed with everything else. A local tag, never pushed, marks main's last Launchy commit. The tickets merge into this branch:
   - the rename in code;
   - the migration and the guards;
   - the docs and agents;
   - the logo;
   - the final checks.

   It reaches main in one `--no-ff` merge and is pushed to origin, which is still the private Zabaca/launchy.
3. **GitHub** (the user's step). Every clone of the Deno project, and anything that pushes to it, is repointed first. Then Zabaca/varnick becomes Zabaca/varnick-deno and is archived, and Zabaca/launchy becomes Zabaca/varnick, still private.
4. **Cutover, one sitting** (the user's step, with the user at each machine). The Ryzen goes first, then each Mac. A machine left on Launchy can't reach one on Varnick, and the reverse.
5. **Going public** (the user's step). repo-not-ready-to-open-source option 01's last steps run against the renamed repository: visibility, private vulnerability reporting, and the check from outside, after its public-repo check has run again over the renamed tree.
6. **Cleanup.** Once every machine runs Varnick, the migration, the guards and their where-it-breaks entries are removed.

Two pieces follow, each on its own: the checkout's folder is renamed after cleanup (Further Notes), and varnick.com's page moves into the repository after the merge and goes live after a downloadable build (Implementation Decisions › varnick.com).

## Trade-offs

- **Every running session ends once, at each machine's cutover,** as a zmx pin bump does (ADR 0004).
  - Conversations aren't lost: restored panes resume them when first shown (ADR 0001).
  - What ends is work in flight: a turn, background shells and teammates.
  - The user picks a quiet moment. Option 03 keeps sessions alive, at a much higher cost.
- **Each machine needs the user at it anyway,** because macOS asks for every permission again under a new bundle id (ADR 0022). That is why the machine steps are a hand cutover and not the Upgrade button. The app moves its own data, so no step can be done out of order.
- **The settings are copied in the place that already copies them,** so the order is enforced by where the code runs. The copy happens before Settings, the sessions file or the support folder is read. It also happens before the relay's link exists, so the relay never answers from an empty domain and makes a paired Mac drop this one.
- **Short-lived code in a public tree.** The migration and the guards name the old identifiers until the cleanup ticket. They are small and marked, and they hold no personal data.
- **No mixed versions.** Between the first and last machine of the cutover, peers on different names can't see each other. One sitting keeps that short.
- **Moving the support folder is a rename on one volume,** so the 4.3 GB of models don't download again and the relevance checkpoint isn't imported again.
- **Saved keys are entered again** (recommended under Open, below). That costs two pastes and avoids a Keychain prompt at launch.

## User Stories

1. As the user, I want the app, its menus, its Settings, its prompts to macOS and its docs to say Varnick, so that the published project has a name of its own.
2. As the user, I want to say "Hey Varnick" and be heard about as reliably as "Hey Launchy" was, or to know the measured difference before it ships.
3. As the user, I want my settings, peer identity, pairings, devices, tabs, Recent, transcripts, models, web logins and search history to be there after the switch, so that nothing has to be set up again but permissions and keys.
4. As the user, I want every session of the old app ended and its conversation resumable in Varnick, so that no conversation is driven by two Claude processes at once.
5. As the user, I want a Mac still on Launchy to refuse to build or restart into Varnick through Upgrade, Upgrade all or `make run`, and to say why, so that no Mac half-migrates while I'm away from it.
6. As the user, I want the old LaunchAgent gone, so that the next login doesn't start Launchy beside Varnick.
7. As the user, I want my paired Macs and the Ryzen to keep recognising each other after the switch, without pairing again.
8. As the user, I want the Phone page to come back at the same address on every host, so that my phone's bookmark keeps working.
9. As the user, I want a runbook for each kind of machine, with what to grant and what to check, so that I can do the cutover in one sitting.
10. As the user, I want my custom apps in other projects to work after the switch, with a list of what to rename in each.
11. As the user, I want the repository renamed on GitHub without its new name catching pushes meant for the Deno project, and I want to go public only once all of this is done.
12. As a reader of the public repository, I want the docs to describe Varnick as it is, and the dated records to keep the name they were written under, with one place that maps old names to new.
13. As a builder or reviewer, I want the old names left only where they are deliberate (dated records, the checkpoint's keys, the migration and the guards), so that a search for them is a check.

## Implementation Decisions

### The names

| Was | Becomes |
|---|---|
| Launchy, launchy, LAUNCHY | Varnick, varnick, VARNICK |
| `com.zabaca.launchy` (bundle id, signing identifier, LaunchAgent label, settings domain, Keychain service) with `.transcript` and `.screen-text` | `com.zabaca.varnick` with the same suffixes |
| the app's source folder and executable target, the `Launchy` binary and its good copy, the entitlements file, the LaunchAgent template, the `sign-launchy` target | the same with Varnick |
| the package `LaunchyPeer` and its folder, the relay `launchy-peer` | `VarnickPeer`, `varnick-peer` |
| `~/Library/Application Support/Launchy`, `~/Library/Logs/Launchy.log` | `…/Varnick`, `Varnick.log` |
| `~/.launchy` (a Mac's user apps; the headless install root), a project's `.launchy/`, `launchy.json` | `~/.varnick`, `.varnick/`, `varnick.json` |
| zmx: `launchy-<uuid>`, `launchy=1`, `launchy-control`, `launchy-origin`, `launchy-phone-page` and its `launchy-page…` labels, `launchy-upgrade`, `launchy-build-exit=`, `launchy-install-<slug>`, `launchy-app` | the same with varnick |
| the systemd unit `launchy-phone-page.service` | `varnick-phone-page.service` |
| pane files `.launchy-turn` (with `.askers`, `.before`), `.launchy-stop`, `.launchy-session.json`, `.launchy-conversations` | `.varnick-…` |
| every `LAUNCHY_*` variable; the work marker `LAUNCHY-WORK`; the git key `branch.<b>.launchy-option` | `VARNICK_*`, `VARNICK-WORK`, `varnick-option` |
| the setting `heyLaunchy`; "Hey Launchy" | `heyVarnick`; "Hey Varnick" |
| the MCP server `launchy` (from the in-flight branch) | `varnick` |
| `db/launchy.sqlite` | `db/varnick.sqlite` |
| the `launchy-*` agents; transcript lines' answer source `launchy` | `varnick-*`; `varnick` (old transcripts keep theirs) |

**Left as they are, on purpose:**

- the relevance checkpoint's config keys `launchy_format` and `launchy_question`: they are keys in a file this repository doesn't make, and a comment says so;
- problem slugs, such as `panes-share-launchys-permissions`: the Problems board, branch ties, work records and `work_history` key on them;
- the dated records under Docs, below;
- the migration's and guards' own references to the old names, until cleanup.

### The code rename

One ticket, since a half-renamed tree doesn't compile.

- **Mechanical renames,** following the table: files, folders, the package, the targets, symbols that carry the name (`isLaunchy`, `heyLaunchy` and the like), strings, comments and tests.
  - The Phone page's session-name pattern and its fixtures change with the zmx prefix.
  - The installer's archive path and its read of the Mac's SSH command follow the moved files, and the relay comparison's pathspecs change with them ("change both together").
- **Protocol.** `PeerProtocol.version` and the page's `PROTOCOL_VERSION` are bumped together. A machine on either side of the rename then refuses the other with "another version" before reading anything, instead of failing some other way. The `upgrade` and `restart` exception is unchanged.
- **Wake phrase.**
  - The contextual strings become "Varnick" and "Hey Varnick".
  - The matcher accepts the spellings the measurement found. It keeps "hey" and "hay" and the first-three-words rule, and never wakes on a fragment alone, such as "nick".
  - Its comment records the measured miss and false-wake rates.
- **Jev's wording** takes the measurement's result. If a threshold moved, the new value goes in the same ticket. If the measurement isn't done before the merge, the measured wording stays word for word, with a comment, and changes in the cleanup ticket.
- **Kill patterns stay anchored.** The relay's arguments must stay unlike the kill pattern for the new binary, as they are today.

### The first-launch migration

It goes in the app's entry point, after the relay's and the MCP server's early exits (neither writes settings). Each step is skipped when its target already exists, so later launches do nothing.

- **Only the app's start migrates** (decided 2026-10-09). The steps run where the app starts, after every command-line mode has had its turn and before the app's delegate is made, so nothing on the app's path has read settings, the support folder or the database yet.
- **Every other mode refuses on a Mac not yet moved.** Where the current settings migration is, Varnick exits with an `error:` line when `…/Launchy` exists and `…/Varnick` doesn't, unless it is the relay or the MCP server. The line says the Mac still runs Launchy and points to the cutover.
  - A check run from a worktree (`--search-eval`, `--problems`, `--sync` and the rest) would otherwise either do the cutover under the running Launchy, ending every session, or create an empty `…/Varnick` that makes the folder step skip at the real cutover.
  - It lands with the code rename, so no Varnick binary on the branch runs without it. Until the migration lands, the app's start refuses too.

- **The steps run in this order:**
  1. **End the old sessions.** List zmx sessions with the bundled zmx, which is the same release, so it reaches the old daemons. End every session named `launchy-<uuid>` and labelled `launchy=1`, plus `launchy-phone-page`, `launchy-upgrade` and any `launchy-install-…`. Confirm from a listing that came back, as `Zmx.endConfirmed` does.
     - When zmx can't be asked, nothing is ended and the step runs again at the next launch.
     - Panes restore dormant and resume only when shown. That keeps a first launch whose listing failed from driving a conversation twice, provided the user doesn't open such a pane before the step has succeeded. The step logs either way.
  2. **Copy the settings domain.** If the new domain is empty and `com.zabaca.launchy` isn't, copy it whole and rename `heyLaunchy` to `heyVarnick`. The old domain stays until the user removes it.
     - The current step, which copies from the executable-named domain, is removed. On one Mac that older domain is still on disk and would be copied instead.
  3. **Move the support folder.** If `…/Varnick` doesn't exist and `…/Launchy` does, rename it. Then remove the moved `launchy-peer` link, the stale socket, and the `scratch` link left by an earlier migration, since every pane that needed it has just ended.
     - No link is left at the old name. A Launchy relay reached through one would answer from the old domain.
     - If both folders exist, nothing is merged. The step logs it and leaves it to the user. When `…/Varnick` then has no sessions file, the start stops with an `error:` line instead, since it would start empty (added after the first review).
     - The sibling is `PaneFolder.migrateOldScratchFolder(in:)`. Like it, the step takes the folder as a parameter so a check can run it on a temporary one.
  4. **Copy the web data.** Copy WebKit's `com.zabaca.launchy` folder to the new id's, as the current step does for the older name.
  5. **Rename the database.** If the chosen database path doesn't exist and `launchy.sqlite` sits beside it, open it, checkpoint its WAL into the file (truncate), close it, then rename it and drop the `-shm` file.
     - Only the app does this, never the relay.
     - A database that can't be opened is left alone, and the app stops with the error, as it does today, rather than creating an empty one beside it.
- **The order matters.** The sessions end before the folder moves, so no hook writes into a folder that is moving. The domain is copied before `Settings.storeSkipPermissionsIfAbsent`, which decides it's an existing install from the sessions file, so the folder is in place by then too. Everything happens before `PeerLink.refresh` makes the relay's link.
- **Logging.** Each step logs one line: what it did, or why it skipped. It logs no values.
- **Not migrated:**
  - Keychain items (see Open);
  - privacy grants, which can't be;
  - the LaunchAgent, which `make install` handles;
  - custom apps in other projects, the Claude Code folders and the checkout's folder, which are the user's steps.

### The guards

Short-lived; each says in a comment that the cleanup ticket removes it.

- **Build.** The build fails when this checkout's build folder still holds Launchy's binary or its good copy. Its first line starts with `error:`, so the Upgrade card shows it, and says to stop Launchy, remove the old binary (or `make clean`, which keeps `db/`) and follow the cutover.
  - This stops Upgrade, Upgrade all and `make run` on a Mac that hasn't been cut over.
  - A worktree's build folder starts empty, so builders aren't affected.
  - An old Mac's Upgrade will already have fast-forwarded its checkout. Its build then fails, no stamp is written, and its Restart stays refused.
- **Stop and restart.** `make stop` and the restart script also stop a Launchy binary, but only by this checkout's absolute path (the LaunchAgent's form). A Launchy started by `make run` has the relative argv `.build/release/Launchy`, which would match from every checkout, so `make stop` will not stop it: the user quits Launchy from its menu at cutover step 2.
- **Restart with nothing to start** (decided 2026-10-09). The restart script refuses before stopping anything when this checkout has no Varnick binary, and logs why.
  - The status menu's Restart runs the checkout's script with no build, and so does a peer's Restart (verified at 7316d5f). On the Mac the merge lands on, or one whose checkout an old Upgrade fast-forwarded, the new script would otherwise stop Launchy and start nothing.
- **Install.** `make install` and `make uninstall` also boot out the `com.zabaca.launchy` LaunchAgent and remove its plist.
- **Linux installer.** Its far half refuses to install where `~/.launchy` exists, with a line the near half reports. A Mac whose checkout an old Upgrade fast-forwarded therefore can't put a second relay, with a new id, beside the old one.

### Docs

Recommended. The problem leaves this open.

- **docs/problems/** stays as dated records, slugs included. Only a link to a renamed file is fixed. This problem's own files keep the old names they describe.
- **ADRs.** The user decided their evergreen text is renamed. Read that as present-tense statements of how the system is:
  - titles;
  - the decision as it stands;
  - consequences that describe today;
  - identifiers and paths.

  Dated passages keep the name they were written under: measurements, acceptance dates, dated corrections and the considered options' reasoning. The five ADR files with the name in their file name are renamed to match their new titles, and the one link to them is fixed.
- **A new ADR,** "Launchy is renamed Varnick", numbered after the in-flight ADR 0023. It records the decision and holds the table above, so a dated passage can be read through it.
- **Evergreen docs are rewritten:**
  - CONTEXT.md, which notes once that the project was called Launchy until 2026-10;
  - docs/agents, with where-it-breaks;
  - CODING_STANDARDS, CLAUDE.md, README, SECURITY.md, CONTRIBUTING and THIRD_PARTY_NOTICES;
  - the agents, which are renamed;
  - the skills.

  The planner's instructions pass to `varnick-planner`.

### The logo: Fold

Decided by the user on 2026-10-09.

- **The mark.** A V split down the middle, its right half offset. Three drawings in a 64-unit box, each two filled quadrilaterals:

  | Drawing | Used for | Path |
  |---|---|---|
  | master | the app icon, the page's mark and its favicon | `M6 4.5L24 4.5L30.25 27.94L30.25 51.13ZM58 11.5L40 11.5L33.75 34.94L33.75 58.13Z` |
  | cut, idle | the menu bar, not Listening: the halves apart | `M6 5L24 5L29.75 26.56L29.75 50.67ZM58 11L40 11L34.25 32.56L34.25 56.67Z` |
  | cut, Listening | the menu bar while Listening: the halves lined up | `M6 8L24 8L29.75 29.56L29.75 53.67ZM58 8L40 8L34.25 29.56L34.25 53.67Z` |

  The cut widens the gap (3.5 units to 4.5) and shrinks the offset (7 to 6), so the halves stay apart at menu-bar size. Listening lines them up, so the change of state is the change of shape.
- **The menu bar.** The two cuts replace the magnifying glass and the waveform symbols, at the same two places: when the status item is made, and when Listening's state changes. They are template images at 16pt, so the menu bar colours them, and their description is the app's name.
  - They are drawn from the path data in code. A bare executable has no resource bundle to load an image file from.
  - They must read at 16pt, at 1x and 2x, in a light and a dark menu bar and highlighted: two halves, and idle told from Listening at a glance.
- **The app icon.** A bare executable has no bundle icon. At launch the app sets its runtime icon to the master, in the page's accent colour, which AppKit shows wherever it shows the app's icon. A bundle's icon file comes with whichever runs-only-from-a-checkout option makes the app bundle.
- **Risk.** No trademark check has been done on the mark. Noted, not a blocker.

### varnick.com

Decided by the user on 2026-10-09.

- **The page.** A prototype is chosen: variant D, which is A's hero with C's body, with hero copy 2. It is kept in a local Scratch area, outside version control.
- **Into the repository after the rename.** Once the rename has merged, it moves to `site/` as one self-contained page, with no build and no external requests.
  - The prototype's chrome goes: the variant switcher and its bar, the claims drawer and the data behind it, the hero switcher, and the styles of the variants not chosen.
  - It passes the public-repo rule like any committed file.
- **Its claims.** Read against the tree at db973f1, some of what the page says rested on work not yet shipped, among them a notarized download, the public repository and features still proposed. Before it goes live, each claim is backed by shipped work or reworded; the user decides which.
- **Live after a download exists.** Its main button is Download, so it replaces what varnick.com serves only once a downloadable build exists (runs-only-from-a-checkout), and once the repository is public, since its other links lead into it.
  - varnick.com is served through Cloudflare today, from outside this repository (its nameservers and response headers, checked 2026-10-09). Which project deploys it is unverified.
  - The deploy and the DNS change are the user's.

### GitHub (the user's step, after the merge and before the cutover)

Done on 2026-10-09, before the code rename (the start of Solution says what is left).

1. **Repoint first.** Find every clone of the Deno project on every machine, and whatever pushed its work branches. Repoint each clone to the new name and stop that automation. GitHub's redirect covers them only until step 3.
2. **Move the Deno project aside.** Rename Zabaca/varnick to Zabaca/varnick-deno, then archive it.
3. **Rename this repository.** Rename Zabaca/launchy to Zabaca/varnick, still private, and update its description.
4. **Never recreate the old name.** Don't create a repository named launchy in the organisation, which would end the redirect for any clone not yet updated.
5. **Accepted.** Old public links to the Deno project's files now reach this repository: 404 while it is private, the wrong project once it is public.

### Cutover: the Ryzen (the user's step, first)

From a Mac:

1. **End its sessions.** Mark each of its cards Done, or end them on the host with the relay's `end`.
2. **Uninstall with the old installer.** Run the installer with `--uninstall` from a worktree at the tagged last Launchy commit, because only the old installer knows the old unit and root. It unpublishes the page's port and removes the unit, the relay, its link and its source, and keeps `state/`, `config.json` and zmx.
3. **Move the install root on the host,** from `~/.launchy` to `~/.varnick` (recommended; see Open).
4. **Install from Varnick.** Run the installer from a Varnick checkout, with `--page` if the host served the page. It converges: the id, the config and zmx stay, and the far half's guard now passes.
5. **Check.** Once the first Mac is on Varnick, the host's row in Settings › Peers answers, and the phone reaches the host's page.

### Cutover: each Mac (the user's step)

From Terminal.app, not a pane, because this ends every session in the app:

1. **Wait for a quiet moment.** Let background work finish, and mark Done what should close.
2. **Quit Launchy from its menu** (`make stop` will not stop one started by `make run`). Its zmx sessions keep running when Keep sessions running is on, which is expected: Varnick ends them.
3. **Update the checkout.** Point `origin` at the new URL, fetch, then fast-forward main to origin/main. A branch still tied to an option has its git key renamed by hand (none is expected; see Further Notes).
4. **Remove Launchy's binary and its good copy.** This lifts the build guard. If the checkout's folder is renamed now (see Open), do that first and `make clean` instead.
5. **`make install`.** It builds Varnick, removes the old LaunchAgent, installs and starts the new one, and links the skill. Varnick's first launch migrates. Read its lines in the new log.
6. **Grant again.**
   - Turn Listening on, which asks for the microphone and system audio.
   - In Settings, press Grant for Accessibility and for Screen Recording, then restart when Settings offers it.
   - Clear the old rows with `tccutil reset All com.zabaca.launchy`.
   - A pane that needs a protected folder or automation asks again when it next does.
7. **Keys.** Enter the TypeSafe key and the model server's key in Settings, then delete the two old Keychain items.
8. **Check:**
   - the panel and its hotkey;
   - a restored pane resumes;
   - `/work` ties a branch;
   - search finds old history (the database came along);
   - "Hey Varnick" answers;
   - Point at the screen draws;
   - every peer row answers;
   - the phone reaches this Mac's page and its devices are listed;
   - a custom app opens.
9. **Once checked, remove the leftovers:**
   - the old settings domain, and the older executable-named one;
   - WebKit's two old folders;
   - the caches and HTTP storage under the old id;
   - the old log.

### Custom apps elsewhere (the user's step)

- **In each project that has `.launchy/`:** move it to `.varnick/`, rename each `launchy.json`, and change `LAUNCHY_` to `VARNICK_` in the app's code. Commit it in that project.
- **User apps** move from `~/.launchy/custom-apps` to `~/.varnick/custom-apps`.
- **Old Scratch areas** under `.launchy/scratch/` are moved or deleted.
- **Until an app is moved,** the picker doesn't list it, and a restored pane of it closes as its app is gone. Nothing else breaks.

### What it can break (where-it-breaks)

- **Saved state.**
  - The sessions file is moved, never rewritten, so its decoding is untouched.
  - The skip-permissions rule tells an existing install by that file, so the folder must be in place first (the order above).
- **The claude command line and hooks.**
  - Running sessions keep their old hooks. That is why they end at the first launch.
  - The new names change in one place each: the hook settings, the work hooks and the pane folder, all shared by the app and both relays.
  - The work skill's marker and the hook that reads it change together.
- **Peers.**
  - The package must still build on Linux; the Ryzen's install is that check.
  - Both protocol constants are bumped together.
  - The SSH command stays one POSIX literal that the installer reads at the shipped commit.
  - The relay comparison and the installer's archive change together.
  - The relay's arguments stay unlike the kill pattern.
  - No path passes 103 bytes, since the names are the same length.
  - The relay never runs against an un-migrated domain (the order above).
- **Phone page.**
  - The session-name pattern changes on both sides.
  - A server without the new place label is replaced once, as today.
  - On a Mac, the stored target comes along with the settings, so a mount at the old socket counts as the page's own and is replaced.
  - On the Ryzen, the old installer unpublishes first.
- **Listening and spoken requests.** The wake phrase is measured. The self-wake guard is untouched. Jev's wording follows the measurement.
- **Pointing at the screen.** The panel's title and own-app check change their name, and so does `--ask --app`, which finds an accessory app only by its whole name.
- **Signing.** The codesign identifier follows the bundle id. The build guard's `error:` line comes first, and nothing tracked names the identity.
- **Search store.** The database variable changes for the app, the relay, the evals and `--work-history`. The models move with the folder; if the move failed, they would download again and the checkpoint would need importing again.
- **Checking by hand.** The log and the settings domain have new names. A check with a temporary home still writes the real settings, so the domain step takes its domain names as parameters.

## Testing Decisions

There is no Swift test target. Every ticket runs `make build`, and the Phone page's tickets run `bun test`.

- **The measurement** reports per arm, in agent-lab, pinned to the branch's commit:
  - the transcriber's spellings of "Hey Varnick" and its miss rate;
  - wakes in speech without the name;
  - Jev's decide and screen-picker results against their thresholds, with the new name and with the old.
- **The migration's steps** are checked in a temporary folder with made-up domain names, deleted afterwards.
  - Old-named sessions are made in a throwaway absolute `ZMX_DIR`, the way the app makes them (`zmx attach` through a pty, never `zmx run`), with `LAUNCHY_ZMX_DIR` and `VARNICK_ZMX_DIR` both set. The step must end them and leave other names alone.
  - The database step runs on a copy with a WAL holding a write: the row must be there after the rename.
- **The guards.**
  - In a scratch checkout with a dummy old binary, the build fails with the `error:` line first.
  - The kill pattern matches the old binary's relative and absolute forms and not the relay's arguments.
  - Install and uninstall boot out a dummy old LaunchAgent label.
  - The far half refuses with a dummy `~/.launchy` in a throwaway home on the host.
  - The restart script, with no Varnick binary, refuses before it stops anything: run with stand-ins for `pkill` and `pgrep` first on the path, so a mistake can't stop the running Launchy.
  - The refusal: a command-line mode with a temporary home holding a dummy old support folder exits with its `error:` line, and without that folder runs.
- **Search for leftovers.** A search for the old name over the tree finds only the allowed list: dated docs, the checkpoint's keys, and the migration, the refusal and the guards.
- **The public-repo patterns** run over the branch's diff, since it touches nearly every file.
- **By hand at the cutover** (the user): the checks in each runbook.

## Out of Scope

- Running sessions surviving the switch (option 03).
- A Mac left on Launchy: the cutover is all machines in one sitting.
- Renaming problem slugs, or the checkpoint's keys.
- agent-lab's harnesses: the `eval` agent updates them when it next runs against a commit after the rename, and runs pinned to older commits keep working.
- The user's own Claude Code memory and settings outside the repository.
- The Deno project itself, beyond moving it aside.
- A notarized app bundle, moving the database out of the checkout, and a Keychain copy step (see Open).
- Rewriting dated records.

## Further Notes

- **Decided on 2026-10-09, each as recommended** (these were open; the start of Solution records the decision):
  - **The checkout's folder.** Rename it, but as its own small step after every machine runs Varnick. Nothing published depends on it, and moving it also moves Claude Code's own data, which the cutover otherwise leaves alone.
    - Moving it means: `git worktree repair`; `make clean`, since SwiftPM's build folder holds absolute paths; `make install` again for the LaunchAgent and the skill link (removing a link into the old path first, since install leaves a foreign link alone); and moving Claude Code's project folder to the new path's key.
    - A link at the old key to the new folder, and one at the old checkout path, would keep the memory, the transcripts and every saved directory resolving. Whether Claude Code and the project picker treat links that way is unverified: try it on a throwaway project, and drop the checkout link if the picker lists the project twice.
    - Without the links, this project's past sessions can't be opened from Recent or search, and Claude Code starts its memory empty.
    - Keeping the name costs nothing, but the project is then listed as "launchy" in the picker, the board and the Phone page, and a fresh clone elsewhere is named varnick.
  - **Historical docs.** As under Docs: problems verbatim, ADRs renamed where evergreen and kept where dated, file names renamed, and a mapping ADR.
  - **Saved keys.** Enter them again: there are two, and copying would put a Keychain prompt in the launch path, since Settings reads the TypeSafe key while it loads. The alternative is a migration step that reads each old item (macOS asks once) and saves it under the new service.
  - **The Ryzen.** Move its install root. That keeps its id, its pairings with each Mac and its device list. A fresh install means removing and adding it on every Mac, and listing the phone again.
- **Siblings to copy:**
  - the settings and WebKit copy at the top of the app's entry point;
  - `PaneFolder.migrateOldScratchFolder(in:)`, for the folder move and its testable shape;
  - `Zmx.endConfirmed` and the launch sweep, for ending sessions from a listing that came back;
  - the installer's `--uninstall`, for the Ryzen.
- **Preconditions for the cutover,** each checked rather than assumed:
  - the branch has merged and been pushed;
  - both GitHub renames are done;
  - no branch is tied to an option in flight;
  - every Mac's main is pushed;
  - the user is at the machine.
- **Verified** on 2026-10-09 at db973f1: every item marked verified in the problem's Today, and the facts each guard and migration step relies on.
  - The kill patterns.
  - The template's baked-in paths.
  - The install target's skill-link rule.
  - The relay's `unlisted` reply.
  - The Phone page's last published target counting as its own.
  - The installer's uninstall keeping state, config and zmx.
  - The installer reading the SSH command and the package at the shipped commit.
  - The checkpoint's keys.
  - The in-flight branch's MCP server name.
- **Inferred, not checked:**
  - that renaming a database together with its WAL keeps its committed writes (the step checkpoints first, so it doesn't rely on this);
  - that grants a pane triggered are tied to the old bundle id;
  - that the old Keychain items prompt the renamed app;
  - that GitHub's redirect lasts until the old name is reused;
  - that nothing besides the work branches' author pushes to the Deno project.
- **Tickets,** written on 2026-10-09 as local files in the problem's scratch folder. The AFK ones run unattended; the user's need the user:
  1. **Measure** (AFK, the `eval` agent in agent-lab): the wake phrase and Jev's wording.
  2. **The code rename** (AFK, on `varnick`), with the refusal for a Mac not yet moved.
  3. **The first-launch migration and the guards** (AFK, on `varnick`, after 2). Their where-it-breaks entries are marked short-lived.
  4. **Docs and agents** (AFK, on `varnick`, after 2): evergreen docs, ADR text and file names, the mapping ADR, the agents and the skills.
  5. **The Fold** (AFK, on `varnick`, after 2): the menu bar's template images and the runtime app icon.
  6. **Final checks and merge** (AFK up to the push, after 1 to 5): ticket 1's results in the matcher and wording, the leftover search, the public-repo patterns, the build, `bun test`, review, the `--no-ff` merge to main and the push.
  7. **GitHub renames** (the user): done on 2026-10-09, ahead of the rename, with two leftovers for the user.
  8. **Cutover: the Ryzen** (the user, after 6).
  9. **Cutover: each Mac** (the user, after 8).
  10. **Custom apps in other projects** (the user, or AFK per project on the user's go, after 9).
  11. **Going public** (the user, after 9): repo-not-ready-to-open-source option 01's last steps against the renamed repository.
  12. **Cleanup** (AFK, after 8 and 9 on every machine): removes the migration, the refusal, the guards and their where-it-breaks entries.
  13. **The checkout's folder** (the user, after 12).
  14. **The page into `site/`** (AFK, after 6).
  15. **varnick.com goes live** (the user, after 14 and 11, and after a downloadable build exists).
