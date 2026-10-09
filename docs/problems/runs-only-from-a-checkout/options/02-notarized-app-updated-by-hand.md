---
problem: runs-only-from-a-checkout
title: A notarized Launchy.app, made by `make app` and updated by downloading the next one
summary: Option 01's signing, plus a `make app` target that wraps the same build in Launchy.app, signs it inside out with a secure timestamp, notarizes and staples it, and zips it for a GitHub release the user publishes. Launchy finds its files through its bundle whether it runs from a checkout or as the app. It keeps its database in Application Support, copied once from the checkout, and runs one copy per account. The app opens at login through Login Items and writes its own log. An installed app is updated by downloading the next zip; Upgrade and Restart Launchy keep working on Macs that run a checkout. Rough effort is a week and a half, about half of it signing round trips and checks by hand.
status: proposed
---

## Solution

One binary, two ways to run it.

- **From a checkout** (`make build`, `make run`, `make install`): the bare executable in the build folder, signed as in option 01. Upgrade and Restart Launchy work as today (ADR 0013).
- **As the app:** Launchy.app, anywhere but a checkout's build folder, normally /Applications. It is made by `make app` on the Mac that holds the signing identity and the notary credentials, from a clean main that origin has.

Launchy reads its files from its bundle's resource folder. For the bare executable, that is the folder it sits in, which is where `make build` already puts them. For the app, it is Contents/Resources. So the lookups change once and serve both.

The database moves to Application Support in both modes, where everything else Launchy keeps already is. The first launch after the change copies the checkout's database there and leaves the original in place.

The zip `make app` produces is what a person downloads: unzip, move to Applications, open. Gatekeeper accepts it because it is notarized and stapled. To update, they download the next zip and replace the app.

## Trade-offs

- **Installable without a toolchain.** Anyone with an Apple silicon Mac and macOS 14 can run Launchy.
- **One database for every build.** A checkout build, a worktree's `make run` and the app all read the same archive. Today each checkout has its own `db/`, so a worktree's build starts with an empty one.
- **No in-app updates.** The installed app says "update it by downloading the newest build" where Upgrade would be. A Mac on the app falls behind until someone downloads. Options 03 and 04 add updates on top of this one.
- **A fleet can mix apps and checkouts.** A Mac running the app speaks the protocol of the last published build, while checkouts follow origin/main. Whenever main bumps the protocol before a new build is published, the two kinds can only exchange hellos.
- **Headless hosts still need a checkout.** Installing or upgrading the relay on a headless host stays a job for a Mac that runs a checkout.
- **Publishing is by hand.** `make app` signs and notarizes but never uploads. The user creates the GitHub release.
- **Nothing new to depend on.** `codesign`, `notarytool`, `stapler` and `ditto` come with the Command Line Tools.

## User Stories

1. As a person new to Launchy, I want to download a zip, move Launchy to Applications and open it without a security warning, so that I can try it without installing Swift.
2. As a person new to Launchy, I want Launchy to ask for the microphone and system audio once, with its own explanation, so that I know why it asks.
3. As the user, I want my existing history archive in the app the first time it opens, so that switching a Mac to the app loses nothing.
4. As the user, I want the checkout's database left where it was after the copy, so that I can go back.
5. As the user, I want `make run` and the app to use the same history, sessions and settings, so that switching between them is seamless.
6. As the user, I want only one Launchy running at a time, and a clear message when I start a second one, so that two copies never fight over my sessions and shortcuts.
7. As a person running the app, I want an Open at login switch in Settings, so that Launchy starts with my Mac without a LaunchAgent.
8. As a person running the app, I want its log in the same file `make install` uses, so that the same instructions work for both.
9. As a person who opened the app from the Downloads folder, I want to be told to move it to Applications, so that peers and the Phone page don't end up pointing at a temporary copy.
10. As the user, I want one command that produces a signed, notarized and stapled zip and refuses anything but clean main, so that every published build matches a public commit.
11. As the user, I want the notary credentials and the signing identity to stay out of the repository, so that it stays fit to publish.
12. As a person running the app, I want the custom-apps skill available to Claude Code, as `make install` arranges for a checkout.
13. As the user, I want Settings › Peers to say what an installed Mac can and can't do about upgrades, not "isn't running from a checkout".

## Implementation Decisions

**Signing for the checkout build**
- As option 01: Developer ID with the hardened runtime and the audio input entitlement when the identity is present, ad hoc otherwise.

**The bundle**

| In Launchy.app | What it is |
|---|---|
| Contents/Info.plist | The repository's Info.plist (bundle id, name, the two usage strings), plus the executable's name, the package type, the version pair, the minimum macOS (14), `LSUIElement` on, and the commit the build was made from |
| Contents/MacOS/Launchy | The executable `make build` made, unchanged |
| Contents/MacOS/zmx | The pinned zmx. Launchy already finds it beside its executable (ADR 0004) |
| Contents/Resources/mlx.metallib | MLX's shaders |
| Contents/Resources/PhonePage/ | The page as `make build` copies it, less tests and fixtures |
| Contents/Resources/build-stamp | The stamp `make build` wrote |
| Contents/Resources/skills/custom-apps/ | The skill, with its two links into the docs replaced by the files they point at |
| Contents/Resources/ (notices) | The licence, the third-party notices, and the licence texts that the bundled zmx and metallib require |

- No Frameworks folder: SwiftPM linked everything into the executable.
- The executable keeps its linked-in Info.plist section. The bundle's Info.plist is the one macOS reads for the app, and the checkout build keeps working as it does.
- `LSUIElement` keeps a Dock icon from flashing at launch. The code's accessory policy stays for the checkout build.

**How Launchy finds its files**
- One rule: the bundle's resource folder. The first ticket confirms that a bare executable's resource folder is its own folder. If it isn't, the rule becomes "the executable's folder outside a bundle".
- **The metallib:** Launchy hands MLX the path explicitly (mlx-swift's `GPU.metallib`) before the first MLX call. The "no metallib" check reads that same path, so the lookup no longer relies on MLX's guesses next to the binary. The command-line modes that use MLX do the same.
- **The Phone page:** without a launch snapshot, the server's files come from the resource folder. With one, in a checkout, they come from the snapshot, as today.
- **zmx:** unchanged.
- **The build stamp:** inside the app it comes from the resource folder, and the "older than the binary" rule is skipped, because signing rewrites the binary after the stamp. The signature already ties the two together. The commit is also in the Info.plist, for anything that only needs the commit.
- **No launch snapshot for the app.** The peer link points at the app's executable in place, as it does today outside a checkout. If someone replaces the app while it runs, peers reach the new binary before Launchy restarts. That is a known limit, and the README tells people to quit Launchy before replacing it.

**The database**
- In every mode, the default becomes `launchy.sqlite` in Application Support's Launchy folder. `LAUNCHY_DB` still overrides it, for checks and evals. `make run`, `make install` and the LaunchAgent template stop setting it. Restart Launchy keeps passing the running database's path, as it does now.
- The restart script sets `LAUNCHY_DB` only when it is given a path. Launchy takes an empty `LAUNCHY_DB` as the path itself, so an empty one must never be set.
- **The one-time copy** runs at launch, after the skip-permissions step and before the model is made. It runs only when `LAUNCHY_DB` isn't set and Application Support has no database:
  1. The old database is the file that `search-db-path` names, else `db/launchy.sqlite` under the working folder.
  2. It is copied with SQLite's online backup into a partial file, which takes in what the WAL holds. The copy is checked with a quick check, then renamed into place.
  3. The old file and everything beside it are never changed or deleted.
  4. If the copy fails, Launchy shows both paths and the error, and quits. It doesn't start with an empty archive, because that would count as done and the history would stay behind.
  5. The copy is logged once. The relay picks up the new path from `search-db-path`, which the launch rewrites anyway.
- With no old database anywhere, a new install starts empty, as now.
- The relay and the command-line modes never copy. The relay keeps reading the path the app last wrote, and the command-line modes read `LAUNCHY_DB` or the default path. Without `LAUNCHY_DB`, a command-line mode that writes refuses while the default database doesn't exist yet, with "open Launchy once first". Otherwise it would create an empty database that the app would then count as already copied.

**Other working-folder defaults**
- `.env` is read only when Launchy runs from a checkout. The app takes the TypeSafe key from the Keychain or the environment.
- When no folder is chosen and `LAUNCHY_CLAUDE_DIR` isn't set, Claude's default folder is the home folder, unless Launchy runs from a checkout, which keeps the working folder.

**One Launchy per account**
- Launchy holds an exclusive lock on a file in Application Support from launch to exit. The file records its process id and the path of its executable. The relay and the command-line modes don't take it, since they run beside the app.
- A second copy waits up to 15 s for the lock, because a restart overlaps the old copy's exit. Then it shows "Launchy is already running from <path>", and quits.
- This also covers `launchctl kickstart` beside a `make run` build, a known way to get two copies today.

**Start at login, and the log**
- In the app, Settings gains Open at login, which registers the app with Login Items. It is off by default. The checkout build doesn't show it; `make install` keeps its LaunchAgent.
- The app sends its output and errors to `~/Library/Logs/Launchy.log`, appending, unless its error output is a terminal. That is the file the LaunchAgent uses.
- The app leaves an existing LaunchAgent alone. Moving a Mac from a checkout to the app means `make uninstall` first, and the README says so. The lock makes a missed step harmless.

**Where the app may run**
- From any folder, unless macOS has translocated it, which it does to an app opened straight from a download. A translocated app, detected by its path, says "Move Launchy to Applications, then open it again" and quits before it points the peer link anywhere or starts the Phone page.

**The skill link**
- At launch, the app links `~/.claude/skills/custom-apps` to its own copy of the skill. It does so when nothing is at that path, or when the link there points into a Launchy.app (including one that has since moved). Anything else is left alone, which is `make skill-link`'s rule; a link into a checkout counts as the user's own.

**Settings › Peers on an installed Mac**
- The This Mac row, and an installed Mac's row on other Macs, say "Installed app: update it by downloading the newest build", in place of "Launchy isn't running from a checkout of its repository". The frozen report shape is unchanged: this is the refusal text.
- A headless host's Upgrade from an installed Mac says "Upgrade it from a Mac that runs Launchy from a checkout".

**`make app`**
1. It refuses unless the checkout has no tracked changes, is on main, and HEAD is in origin/main as last fetched. It also refuses unless the signing identity and the notary profile are found.
2. It runs `make build`, then assembles the bundle in the build folder.
3. It signs inside out, never with `--deep`: zmx first, then the bundle. Both use the hardened runtime and a secure timestamp; the bundle also gets the entitlements and the identifier. A strict verify follows.
4. It zips the app with `ditto` and submits it with `notarytool`, waiting for the result. Anything but Accepted fetches the notary log, prints it and stops.
5. It staples the ticket to the app, validates the staple, and checks the app with a Gatekeeper assessment.
6. It zips the stapled app again as the published build, named with its version, and writes its SHA-256 beside it.
7. It never uploads. The user creates the GitHub release and attaches the zip.

**Notary credentials**
- `notarytool` reads them from a keychain profile on the release Mac, named in the same git-ignored local settings as the identity. The profile holds an App Store Connect API key. It isn't tied to a person's Apple ID password, and it can be revoked on its own.
- The key file itself lives in the user's own encrypted secret store and is loaded into the profile once. The repository never holds the key, the key's id, the issuer, a team ID or an Apple ID.
- An Apple ID with an app-specific password works with the same profile mechanism, as the fallback.

**The version**
- The Info.plist needs a version pair. Both numbers come from the commit's time in UTC: the short version is the date (year, month, day), and the build number is the date and time. Launchy's UI keeps naming builds by commit, as CONTEXT.md's **Build** says.

**Docs, once accepted**
- The README gains an Install section: download, move, open, the first prompts, Open at login, and how to update. The checkout instructions follow it.
- CONTRIBUTING notes that `make app` is the maintainer's.
- where-it-breaks gains the resource-folder rule, the database default, the lock and the app without a snapshot.
- An ADR records that Launchy ships as a notarized app beside the checkout build.
- CONTEXT.md gains **Published build**: a build signed, notarized and attached to a GitHub release. It avoids "release", which already means giving up control of a pane.

## Testing Decisions

There is no test target. `make build` must pass on a Mac without the identity too.

- **On the release Mac:** `make app` passes. On the result, `codesign -dvv` shows the team, the runtime flag and the timestamp, for both the app and zmx. `stapler validate` and the Gatekeeper assessment pass.
- **On another Mac,** downloading the zip through a browser so that it is quarantined:
  - Open it from Downloads: the move message appears.
  - Move it to Applications and open it: no Gatekeeper warning.
  - Listening asks for the microphone and system audio once and hears both.
  - Search, semantic search, on-device relevance and text generation work, so the metallib is found in Resources.
  - The Phone page server starts from Resources.
  - A peer's hello reaches this Mac's relay, which is the app's executable.
  - Open at login works after a logout.
  - The log file grows.
- **The database copy,** on a copy of the data: a throwaway home for Application Support (where-it-breaks › Checking by hand), and a working folder holding a copy of a database.
  - First launch: the copy is complete, with the same counts in the main tables, and the original's modification time is unchanged.
  - Second launch: no copy.
  - An unreadable source: the error and quit.
- **The lock:** with the app running, `make run` waits and then shows the message. With the checkout build running, opening the app does the same. A Restart Launchy on a checkout Mac still comes back.
- **On a checkout Mac after the change:** `make run` comes back with the copied history. `make install` writes a LaunchAgent without `LAUNCHY_DB`. Upgrade and Restart Launchy work as before.
- **The skill link:** free path, then linked; a link into the checkout, left alone; a link into a moved app, relinked.

## Out of Scope

- Updates from inside the app (options 03 and 04).
- A DMG. A zip of a stapled app is enough to install, and `hdiutil` can add a DMG later with no new tool.
- A Homebrew cask, Intel Macs, the Mac App Store and the App Sandbox.
- Installing or upgrading a headless host from an installed app.
- Renaming the app, and an icon.
- Publishing from CI. Notarizing on a hosted runner would put the credentials there.
- Removing the linked-in Info.plist from the executable.

## Further Notes

- The first ticket should confirm the resource-folder rule, and that `GPU.metallib` set before the first MLX call is honoured. The bundle's layout rests on both.
- The app and the checkout build share a bundle id and a team, so macOS is expected to treat them as one app for permissions and the Keychain (unverified). If a bare executable and a bundle count as separate clients, the switch costs one more round of prompts.
- The App Management protection on recent macOS asks before one app changes another app's bundle. Replacing the app by hand in Finder isn't affected.
- Apple's notary service usually answers within minutes. A first submission can take longer.
