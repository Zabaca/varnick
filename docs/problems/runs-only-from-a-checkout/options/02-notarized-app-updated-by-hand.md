---
problem: runs-only-from-a-checkout
title: A notarized Varnick.app, made by `make app` and updated by downloading the next one
summary: Accepted on 2026-10-09, with updates left for later (options 03 and 04 stay proposed). Option 01's signing, plus a `make app` target that wraps the same build in Varnick.app with the Fold as its icon. It signs the app inside out with a secure timestamp, notarizes and staples it, and zips it as Varnick.zip for a GitHub release the user publishes. Varnick finds its files in its resource folder, whether it runs from a checkout or as the app. Its database moves to Application Support in every mode. The database step of the rename's first-launch migration copies it there once and leaves the checkout's file in place. One copy runs per account. The app opens at login through Login Items, writes its own log and restarts itself. An installed app is updated by downloading the next zip; Upgrade and Restart keep working on Macs that run a checkout. It is built on the rename's integration branch. Rough effort is a week and a half, about half of it signing round trips and checks by hand.
status: accepted
---

## Solution

Accepted by the user on 2026-10-09, relayed by the coordinator. The user isn't worried about updates for now, so options 03 and 04 stay proposed for later.

**What changed since this option was first written on 2026-10-08:**

- **The rename to Varnick is accepted and being built** (name-taken-by-another-launcher, option 01).
  - The app is Varnick.app, with the bundle id `com.zabaca.varnick`. The support folder is `~/Library/Application Support/Varnick`, the log is `Varnick.log` and the database variable is `VARNICK_DB`.
  - This option is built on the rename's integration branch, `varnick`, once the rename's code, migration, docs and logo tickets have merged into it (they had at 0029dc2). It doesn't wait for main.
- **The database move and the rename's first-launch migration are one migration** (The database, below).
- **The icon is the Fold**, the rename's master mark. The rename gave the app only a runtime icon; the bundle gets a real icon file.
- **The credentials exist** on the Mac that makes the app:
  - the Developer ID Application identity (option 01);
  - a `notarytool` keychain profile, made once on that Mac (validated on 2026-10-09).

  `make app` reads the profile's name from the git-ignored local settings.
- **The first notarization submission is approved** by the user as part of building this. Publishing a release is not: that stays the user's step.
- **Restart in the app.** Since this option was written, a Screen Recording grant (ADR 0021) needs a restart. The app has no checkout and so no restart script, so it relaunches itself (Implementation Decisions › Start at login, the log and restart).
- **Where the zip is hosted is open** (Further Notes).

One binary, two ways to run it.

- **From a checkout** (`make build`, `make run`, `make install`): the bare executable in the build folder, signed as option 01 does (ADR 0022). Upgrade and Restart Varnick work as today (ADR 0013).
- **As the app:** Varnick.app, normally in /Applications. `make app` makes it, from a clean main that origin has, on the Mac that holds the signing identity and the notary profile.

Varnick reads its files from its resource folder. For the bare executable, that is the folder it sits in, which is where `make build` already puts them. For the app, it is Contents/Resources. The lookups change once and serve both.

The database moves to Application Support in both modes, beside everything else Varnick keeps. The first app start after the change copies the old database there and leaves the original in place.

The zip `make app` produces is what a person downloads: unzip, move to Applications, open. Gatekeeper accepts it because it is notarized and stapled. To update, they download the next zip and replace the app.

## Trade-offs

- **Installable without a toolchain.** Anyone with an Apple silicon Mac and macOS 14 can run Varnick.
- **One database for every build.** A checkout build, a worktree's `make run` and the app all read the same archive. Today each checkout has its own `db/`, so a worktree's build starts with an empty one.
- **No in-app updates.** Where Upgrade would be, the installed app says to download the newest build. A Mac on the app falls behind until someone downloads. Options 03 and 04 would add updates on top of this one.
- **A fleet can mix apps and checkouts.** A Mac running the app speaks the protocol of the last published build, while checkouts follow origin/main. Whenever main bumps the protocol before a new build is published, the two kinds can only exchange hellos.
- **Headless hosts still need a checkout.** Installing or upgrading a headless host's relay stays a job for a Mac that runs a checkout.
- **Publishing is by hand.** `make app` signs and notarizes but never uploads. The user creates the GitHub release.
- **Nothing new to depend on.** `codesign`, `notarytool`, `stapler`, `ditto` and `iconutil` come with macOS and the Command Line Tools.

## User Stories

1. As a person new to Varnick, I want to download a zip, move Varnick to Applications and open it without a security warning, so that I can try it without installing Swift.
2. As a person new to Varnick, I want Varnick to ask for the microphone and system audio once, with its own explanation, so that I know why it asks.
3. As the user, I want my existing history archive in Varnick the first time it opens, so that the switch loses nothing.
4. As the user, I want the checkout's database left where it was after the copy, so that I can go back.
5. As the user, I want `make run` and the app to use the same history, sessions and settings, so that switching between them is seamless.
6. As the user, I want only one Varnick running at a time, and a clear message when I start a second one, so that two copies never fight over my sessions and shortcuts.
7. As a person running the app, I want an Open at login switch in Settings, so that Varnick starts with my Mac without a LaunchAgent.
8. As a person running the app, I want its log in the same file `make install` uses, so that the same instructions work for both.
9. As a person who opened the app from the Downloads folder, I want to be told to move it to Applications, so that peers and the Phone page don't end up pointing at a temporary copy.
10. As the user, I want one command that produces a signed, notarized and stapled zip and refuses anything but clean main, so that every published build matches a public commit.
11. As the user, I want the notary credentials and the signing identity to stay out of the repository, so that it stays fit to publish.
12. As a person running the app, I want the custom-apps skill available to Claude Code, as `make install` arranges for a checkout.
13. As the user, I want Settings › Peers to say what an installed Mac can and can't do about upgrades, not "isn't running from a checkout".
14. As a person running the app, I want Restart Varnick to work after I grant Screen Recording, as it does from a checkout.
15. As a person new to Varnick, I want the app to show the Fold in Finder, Login Items and the privacy lists, so that I recognise it.

## Implementation Decisions

**Signing for the checkout build**
- As option 01, shipped: Developer ID with the hardened runtime and the audio input entitlement when the identity is present, ad hoc otherwise.

**The bundle**

| In Varnick.app | What it is |
|---|---|
| Contents/Info.plist | The repository's Info.plist (bundle id, name, the two usage strings), plus the executable's name, the package type, the icon file, the version pair, the minimum macOS (14), `LSUIElement` on, and the commit the build was made from |
| Contents/MacOS/Varnick | The executable `make build` made |
| Contents/MacOS/zmx | The pinned zmx, which Varnick already finds beside its executable (ADR 0004) |
| Contents/Resources/Varnick.icns | The Fold (The icon, below) |
| Contents/Resources/mlx.metallib | MLX's shaders |
| Contents/Resources/PhonePage/ | The page as `make build` copies it, less tests and fixtures |
| Contents/Resources/build-stamp | The stamp `make build` wrote |
| Contents/Resources/skills/custom-apps/ | The skill, with its two links into the docs replaced by the files they point at |
| Contents/Resources/ (notices) | The licence and the third-party notices. The notices already hold the MIT text and the copyright lines that the bundled zmx and metallib need (verified) |

- No Frameworks folder: SwiftPM linked everything into the executable.
- **The executable keeps its linked-in Info.plist.** macOS reads the bundle's Info.plist for the app. The linked-in one still gives a bundle id, and so the settings domain, to the checkout build and to the relay. The relay runs through a link in Application Support, outside the bundle, and the code records that its executable's path is the link (inferred from that comment, not run).
- `LSUIElement` keeps a Dock icon from flashing at launch. The code's accessory policy stays, for the checkout build.

**The icon**
- `make app` draws the Fold's master with the app's own drawing of the mark (the rename's logo ticket), compiled into a small script, at every size the icon format holds. The mark then has one source in code.
- It matches the runtime icon: the master in the page's accent on a clear background. It sits inside the content area of Apple's icon grid (824 of 1024), so it lines up with other apps' icons in Finder.
- No backing plate (Open questions in Further Notes).
- The icon file is a build product and is never committed.

**How Varnick finds its files**
- **The resource rule.** The folder comes from the executable's path, with links resolved. Inside a bundle (`<name>.app/Contents/MacOS/`), it is that bundle's Contents/Resources. Anywhere else, it is the executable's own folder.
  - Links are resolved because the relay runs through a link and must find the same files as the app.
  - This replaces "the bundle's resource folder", which this option first proposed. For the relay, the system's main-bundle lookup would answer with the link's folder.
  - The rule is one small piece with no app dependencies, so a check can compile it alone.
- **A bundle is never a checkout build,** wherever it sits. It gets no launch snapshot, no Upgrade, no `.env` and no restart script. So a bundle assembled inside a checkout's build folder still behaves as the app.
- **The metallib.** Varnick gives MLX the path (`GPU.metallib` in mlx-swift 0.32.3, verified in its source: MLX loads from it when set) at the one check every MLX use passes first. So it is set before the first MLX call. That check reads the same path, and so do the command-line modes that use MLX.
- **The Phone page.** In a checkout with a launch snapshot, the server's files come from the snapshot, as today. Otherwise they come from the resource folder.
- **zmx** is unchanged: beside the executable, which is Contents/MacOS in the app.
- **The build stamp** comes from the resource folder.
  - In a bundle, the "older than the binary" rule is skipped, because signing rewrites the binary after the stamp is written. The signature ties the two together.
  - The app's running build, This Mac's row and the relay's reply all read it.
  - The commit is also in the Info.plist.
- **No launch snapshot for the app.** The peer link points at the app's executable in place, as it does today outside a checkout. If someone replaces the app while it runs, peers reach the new binary before Varnick restarts. That is a known limit, and the README tells people to quit Varnick before replacing it.

**The database**
- **The default** becomes `varnick.sqlite` in Application Support's Varnick folder, in every mode.
  - `VARNICK_DB` still overrides it, for checks and evals.
  - `make run`, `make install` and the LaunchAgent template stop setting it.
  - Restart Varnick keeps passing the open database's path, as it does now. The restart script sets `VARNICK_DB` only when it is given a path, because Varnick takes an empty `VARNICK_DB` as the path itself.
- **One migration.** This copy replaces the database step of the rename's first-launch migration, its step 5, which renamed `launchy.sqlite` in place. It runs where the other steps run: on the app's start only, after the support folder has moved and before anything opens the database.
  1. It runs only when `VARNICK_DB` isn't set and Application Support has no `varnick.sqlite`.
  2. The source is the first of these that exists:
     - the file that `search-db-path` names, in the support folder that the step before has just moved. Launchy rewrote that file at each launch, so on a Mac crossing from Launchy it names the checkout's `launchy.sqlite` (verified on one Mac);
     - `db/varnick.sqlite` under the working folder;
     - `db/launchy.sqlite` under the working folder.
  3. The copy is made with SQLite's online backup into a partial file beside the target, which takes in what the WAL holds. It is checked with a quick check, then renamed into place. That rename never replaces an existing file, so a second Varnick racing the first loses harmlessly.
  4. The source and everything beside it are never changed or deleted. The rename's in-place rename and its checkpoint go, since the copy needs neither.
  5. If the copy fails, the app stops with an `error:` line naming both files and the error, as the rename's steps stop it. It doesn't start with an empty archive, because that would count as done and the history would stay behind.
  6. It logs one line with no values, like the other steps. The relay picks up the new path from `search-db-path`, which the launch rewrites anyway.
- **Either order works.**
  - Recommended: this lands on `varnick` before the rename merges into main. Then each Mac's cutover copies Launchy's database straight to Application Support, and no checkout's `db/` is ever renamed.
  - If a Mac is cut over first, its `db/varnick.sqlite` is the source later, through `search-db-path`. Its LaunchAgent keeps `VARNICK_DB` until the next `make install`, and a Restart keeps passing the open path. So that Mac copies at its next `make install` or `make run`.
- **Removal.** The step goes with the rest of the migration at the rename's cleanup. That is safe once every machine has started a build that has it, which the recommended order makes the cutover itself.
- With no old database anywhere, a new install starts empty, as now.
- The relay and the command-line modes never copy.
  - The relay keeps reading the path the app last wrote.
  - Without `VARNICK_DB`, a command-line mode that opens the database refuses while the default file doesn't exist yet, with "open Varnick once first". Otherwise it would create an empty database that the app would count as already copied.

**Other working-folder defaults**
- `.env` is read only when Varnick runs from a checkout. The app takes the TypeSafe key from the Keychain or the environment.
- When no folder is chosen and `VARNICK_CLAUDE_DIR` isn't set, Claude's default folder is the home folder. From a checkout it stays the working folder.
- **Amendment, 2026-10-15 (relayed by the coordinator):** a session with no project now always starts in `Home` in Varnick's support folder (`~/Library/Application Support/Varnick/Home`), made on first use, for the installed app and a checkout alike. The Default folder setting and `VARNICK_CLAUDE_DIR` are gone. The two sentences above no longer hold.

**One Varnick per account**
- Varnick holds an exclusive lock on a file in its support folder from its start to its exit. The file records its process id and its executable's path. The relay, the MCP server and the command-line modes don't take it, since they run beside the app.
- **Where it is taken.** On the app's start, right after the migration. The migration makes the support folder by moving Launchy's, so a lock taken earlier would create the new folder first and make the folder step skip. Once the rename's cleanup removes the migration, the lock is simply the first thing the start does.
- A second copy waits up to 15 s for the lock, because a restart overlaps the old copy's exit. Then it says "Varnick is already running from <path>" and quits.
- **Refusals are shown.** A refusal on the app's start (this one, the move to Applications below, a failed migration step) is printed and also shown in an alert. An app opened from Finder or by a LaunchAgent has nobody reading its error output.
- This also covers `launchctl kickstart` beside a `make run` build, a known way to get two copies today.

**Start at login, the log and restart**
- **Open at login.** In the app, Settings gains an Open at login row, which registers the app with Login Items. It is off by default.
  - Its state is macOS's, read whenever Settings shows it, not a saved setting, since the user can remove it in System Settings.
  - The checkout build doesn't show it; `make install` keeps its LaunchAgent.
- **The log.** The app appends its output and errors to `~/Library/Logs/Varnick.log`, unless its error output is a terminal. That is the file the LaunchAgent uses.
  - This is the first thing the app's start does, so the migration's lines land there.
  - The relay, the MCP server and the command-line modes are never redirected, because their output is their reply.
- **Restart Varnick in the app** (the status menu item, and Settings' offer after a Screen Recording grant) opens a new instance of the bundle, then quits. The new one waits on the lock.
  - A peer's Restart of an installed Mac stays refused, with the installed-app text below.
- **An existing LaunchAgent** is left alone by the app. Moving a Mac from a checkout to the app means `make uninstall` first, and the README says so. The lock makes a missed step harmless.

**Where the app may run**
- From any folder, unless macOS has translocated it, which it does to an app opened straight from a download. A translocated app, detected by its path, says "Move Varnick to Applications, then open it again" and quits. It does this before the migration, the lock, the peer link or the Phone page.

**The skill link**
- At launch, the app links `~/.claude/skills/custom-apps` to its own copy of the skill. It does so when nothing is at that path, or when the link there points into a Varnick.app (including one that has since moved).
- Anything else is left alone, which is `make skill-link`'s rule; a link into a checkout counts as the user's own.

**Grant in the app**
- When Screen Recording's Grant shows Varnick in Finder for the user to add, the app shows the bundle, not the executable inside it.

**Settings › Peers on an installed Mac**
- The This Mac row, and an installed Mac's row on other Macs, say "Installed app: update it by downloading the newest build", in place of "Varnick isn't running from a checkout of its repository". The frozen report shape is unchanged: this is the refusal text.
- A headless host's Upgrade from an installed Mac says "Upgrade it from a Mac that runs Varnick from a checkout".

**`make app`**
1. **Refusals.** It refuses unless:
   - the checkout has no tracked changes;
   - the signing identity is a Developer ID, never ad hoc;
   - the notary profile is named.

   Off main, or with HEAD not in origin/main as last fetched, it refuses unless asked for a check build. A check build runs every step but the last, so it never writes the published zip.
2. It runs `make build`, then assembles the bundle in the build folder, the icon included.
3. **Signing.** It signs inside out, never with `--deep`: zmx first, then the bundle.
   - Both use the hardened runtime and a secure timestamp.
   - The bundle also gets the entitlements and the identifier.
   - A strict deep verify follows.
4. **Notarizing.** It zips the app with `ditto` and submits it with `notarytool`, waiting for the result. Anything but Accepted fetches the notary log, prints it and stops.
5. **Stapling.** It staples the ticket to the app, validates the staple, and checks the app with a Gatekeeper assessment.
6. **The published build.** It zips the stapled app again as `Varnick.zip` and writes its SHA-256 beside it.
   - The name is fixed, so the link to the latest release's asset never changes.
   - It prints the version pair and the commit, for the release.
7. It never uploads.

**Notary credentials**
- `notarytool` reads them from a keychain profile on the Mac that makes the app. The profile's name is in the same git-ignored local settings as the identity, or on the command line.
- The repository never holds what the profile holds, a team ID, an Apple ID or the profile's name.
- An Apple ID with an app-specific password works with the same profile mechanism, as the fallback.

**The version**
- The Info.plist needs a version pair. Both come from the commit's time in UTC.
  - The short version is the date: year, month and day, without leading zeros.
  - The build number is the date, then the hours and minutes.
- Varnick's UI keeps naming builds by commit, as CONTEXT.md's **Build** says.

**Publishing** (the user's step)
- A GitHub release with `Varnick.zip` and its SHA-256 file attached, named by the version. The link to the latest release's `Varnick.zip` then always reaches the newest published build.
- Where that release lives is open (Further Notes).

**Docs, once built**
- The README gains an Install section: download, move, open, the first prompts, Open at login, how to update, and quitting before replacing. The checkout instructions follow it.
- CONTRIBUTING notes that `make app` is the maintainer's.
- where-it-breaks gains:
  - the resource rule;
  - the database default and its copy;
  - the lock;
  - the app without a snapshot;
  - the relay's output never redirected;
  - a bundle never being a checkout build.
- An ADR, numbered after the rename's 0024, records that Varnick ships as a notarized app beside the checkout build.
- CONTEXT.md gains **Published build**: a build signed, notarized and attached to a GitHub release. The word avoids "release", which already means giving up control of a pane.

## Testing Decisions

There is no test target. `make build` must still pass on a Mac without the identity.

- **Never started on the Mac that builds it.**
  - The built app or binary isn't started bare there. The app's start migrates, and a temporary home doesn't move the settings: it would copy the real settings domain.
  - It isn't run in a mode that writes settings either.
  - The bundle is checked with `codesign --verify --deep --strict`, `codesign -dvv` (the team, the runtime flag and the timestamp, for the app and for zmx), `spctl -a -vv` and `stapler validate`.
  - The resource rule is checked by a harness compiled from the rule alone and run both from a bare folder and from inside a bundle.
  - The bundle's executable is also run in its embedding-reference mode under a temporary `CFFIXED_USER_HOME`. That mode reaches the metallib check and stops at the missing model.
- **The database copy:** a harness compiled from the migration's file, on a temporary folder.
  - A source whose WAL holds a write: the row is in the copy, and the source's modification time is unchanged.
  - A second run does nothing.
  - An unreadable source gives the `error:` line.
  - With a target already in place, nothing is replaced.
- **The lock:** two harness processes on a temporary folder. The second waits, then reports the first's path; after the first exits, the second takes the lock.
- **The skill link:** in a temporary folder.
  - A free path gets linked.
  - A link into a checkout is left alone.
  - A link into a moved app is relinked.
- **The user, on another Mac or a fresh user account,** with the zip moved there so that it is quarantined (a browser download or AirDrop):
  - Opened from Downloads, the move message appears.
  - Moved to Applications and opened, there is no Gatekeeper warning, and Finder shows the Fold.
  - Listening asks for the microphone and system audio once and hears both.
  - Search, semantic search, on-device relevance and text generation work, so the metallib is found in Resources.
  - The Phone page server starts from Resources. Afterwards the app's signature still verifies, so the server wrote nothing into the bundle.
  - A peer's hello reaches this Mac's relay, which is the app's executable.
  - Screen Recording's Grant, then Restart Varnick, comes back granted.
  - Open at login works after a logout.
  - The log file grows.
  - Starting `make run` beside the app shows the lock's message.
- **On a checkout Mac after the change,** at the rename's cutover:
  - `make install` writes a LaunchAgent without `VARNICK_DB`.
  - The first start copies the history to Application Support, and search finds it.
  - Upgrade and Restart Varnick work as before.

## Out of Scope

- Updates from inside the app (options 03 and 04, left for later).
- A DMG. A zip of a stapled app is enough to install, and `hdiutil` can add a DMG later with no new tool.
- A Homebrew cask, Intel Macs, the Mac App Store and the App Sandbox.
- Installing or upgrading a headless host from an installed app.
- Publishing from CI. Notarizing on a hosted runner would put the credentials there.
- Removing the linked-in Info.plist from the executable. The relay needs it.
- A backing plate behind the icon's mark.

## Further Notes

- **Accepted on 2026-10-09** by the user, relayed by the coordinator, with updates left for later.
- **Hosting the download: open, for the user.** varnick.com's Download button (the rename's page) needs a public file.
  - **Recommended: a GitHub release on Zabaca/varnick**, made once the repository is public. The coordinator plans for it, pending the user's word. The page's Download button then links to the latest release's `Varnick.zip`.
    - Waiting costs nothing: the page can't go live before the repository is public anyway, because its other links lead into it (the rename's varnick.com decision).
    - GitHub serves the asset under a link that never changes, with no second upload.
  - **The other choice: host the zip on varnick.com through Cloudflare.** It works while the repository is private, but each published build needs a second upload kept in step with the release. The page still can't go live before the repository is public.
  - **Fallback, if going public slips:** a small public Zabaca/varnick-releases repository holding only releases. That shares the download, but the page's other links still wait.
  - **The page itself** is likely to be served by GitHub Pages from the repository's site folder, with varnick.com as a custom domain in DNS-only mode at Cloudflare. That replaces the Cloudflare Pages project the rename's go-live ticket recommends; that ticket is where it changes.
- **Open questions, each with the recommendation:**
  - A backing plate behind the mark, as many macOS icons have: not now. The icon matches the runtime icon the rename chose.
  - A speech recognition usage string: none, until a check shows Listening needs one. It works today without one (unverified for the app).
- **Verified on 2026-10-09** at 0029dc2 on `varnick`:
  - mlx-swift 0.32.3's metallib override;
  - the relay's link and the code's comment on its executable path;
  - every reader of the build stamp;
  - the restart paths, which pass the open database;
  - the migration's order and its step 5;
  - `search-db-path` naming the checkout's database on one Mac;
  - the skill's two links;
  - the notices' licence text;
  - the tools present on the Mac that will make the app.
- **Inferred, not checked:**
  - that the relay's main bundle is the link's folder;
  - that codesign accepts the linked-in Info.plist inside a bundle;
  - that the Phone page's server writes nothing into its folder (its code removes only its socket, which lives in the support folder);
  - that a bare executable and a bundle with the same id and team count as one app for permissions and the Keychain. If they don't, the switch costs one more round of prompts.
- The App Management protection on recent macOS asks before one app changes another app's bundle. Replacing the app by hand in Finder isn't affected.
- Apple's notary service usually answers within minutes. A first submission can take longer.
- **Tickets,** written on 2026-10-09 as local files in the problem's scratch folder. The AFK ones run unattended on branches off `varnick`; the last two need the user.
  1. The resource rule (AFK).
  2. The database in Application Support, as the migration's step 5 (AFK).
  3. One Varnick per account (AFK).
  4. What only the app does (AFK, after 1 and 3).
  5. `make app`, with the first notarization (AFK, after 1).
  6. Docs and the ADR (AFK, after 1 to 5).
  7. The app checked on another Mac (the user, after 6 and the rename's merge).
  8. The first published build (the user, after 7, the hosting decision and going public).
