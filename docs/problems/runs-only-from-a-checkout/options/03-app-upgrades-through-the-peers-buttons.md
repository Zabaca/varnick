---
problem: runs-only-from-a-checkout
title: Installed apps upgrade from published builds through the Upgrade and Restart Launchy buttons
summary: Left for later on 2026-10-09, still proposed: the user chose option 02 and isn't pursuing updates yet. Option 02, plus Launchy's own updater for the app. On an installed Mac, Upgrade downloads the newest published build from the repository's GitHub releases and checks that it is notarized and signed by the same team as the running app. It then stages the build in Application Support. Restart Launchy swaps it into place and opens it, and puts the old app back if the new one doesn't start. The frozen upgrade and restart requests, the separate restart, and Upgrade all and Restart all work as they do for checkouts, so one list in Settings › Peers upgrades a mixed fleet. Macs that run a checkout keep origin/main. There is no new dependency. Rough effort is a week and a half on top of option 02.
status: proposed
---

## Solution

ADR 0013 gives every Mac an Upgrade that makes a build and a separate Restart Launchy that runs it. This option keeps both buttons and both requests, and gives an installed Mac its own way to make a build: download one.

- **The target** for an installed Mac is the newest published build: the latest GitHub release that isn't a pre-release. A Mac that runs a checkout keeps origin/main.
- **Upgrade** downloads the zip, unpacks it and checks it. It must be signed by the same team as the running app, notarized, intact, and newer. It is then kept in Application Support as the waiting build. Nothing runs yet.
- **Restart Launchy** lists the panes it would end, as now. Then a small helper quits Launchy, moves the old app aside, moves the new one into its place and opens it. If the new app doesn't start, the helper puts the old one back.

A Mac with no peers uses the same This Mac row in Settings › Peers.

## Trade-offs

- **One model for both kinds of Mac.** The rows, the states, the refusals and the bulk buttons are ADR 0013's. A row reads the same whether its Mac builds or downloads.
- **Signed by the same team is the gate.** The app installs only what the team's Developer ID key signed and Apple notarized. Under ADR 0013, push access to the repository means code on a checkout Mac; here, holding the signing key means code on every installed Mac.
- **An updater to own.** Download, checks, swap and rollback are security-sensitive code that Launchy maintains itself. Sparkle (option 04) is the tested alternative.
- **Folders the user can't write aren't handled.** An app in a folder only an administrator can change is refused, with "update it by hand". Sparkle would ask for the password instead.
- **No background checks.** A row learns of a new build only when Settings › Peers shows it or another Mac asks for a report, as with checkouts today. A person with one Mac sees an update only in Settings.
- **Published builds and main drift apart.** Option 02's trade-off still stands. Once installed Macs can follow builds quickly, the rule becomes: publish a build after every protocol bump.

## User Stories

1. As a person running the app, I want Upgrade on This Mac to fetch the newest published build, so that I never download it by hand.
2. As the user, I want Upgrade all to bring installed Macs and checkout Macs up to date together, each to its own target.
3. As the user, I want an installed Mac's row to say which build it runs and which one is newest, so that I know what Upgrade will do.
4. As the user, I want a download that isn't signed by my team and notarized to be refused, with the reason, so that a tampered or foreign build never runs.
5. As the user, I want the new build to run only when I press Restart Launchy, after seeing which panes it would end, so that an upgrade never ends my sessions on its own.
6. As the user, I want the old app back if the new one doesn't start, and to be told so, so that a bad build doesn't leave a Mac without Launchy.
7. As a person running the app from a folder I can't change, I want to be told to update by hand before anything downloads.

## Implementation Decisions

**The target and the report**
- `make app` writes a small manifest beside the zip: version, build number, commit, protocol version, the zip's name and its SHA-256. The user attaches both files to the GitHub release.
- An installed Mac reads the manifest from GitHub's fixed "latest release" download address. That address needs no token and isn't subject to the API's rate limit.
- Reading the manifest follows the origin fetch's rules: one at a time, and when the last try is over 10 minutes old, failed tries counted.
- The upgrade report gains optional fields only, as the frozen shape requires: the running version, and the target's version and commit. An older asker ignores them. The row reads "Up to date" or "Newer build available: <version>".
- "Behind" is computed per machine from its own report, so Upgrade all and Restart all need no special case for a mixed fleet.

**Upgrade on an installed Mac**
- Before downloading, it is refused when the app's folder isn't writable by the user, or isn't on the same volume as Application Support.
- The zip is downloaded into the upgrade folder in Application Support, off the main actor, with a deadline, and unpacked with `ditto` into a partial folder. It runs in Launchy's process: nothing downloaded runs until the restart, unlike the checkout build, which ADR 0013 runs in zmx.
- Every check must pass:
  1. The zip's SHA-256 matches the manifest.
  2. The app's signature is valid under a strict check that includes nested code.
  3. The app satisfies a requirement built at run time from the running app's own signature: the bundle id, Apple's Developer ID anchor and the running app's team. No team ID is written anywhere, and a fork signed by another team can't replace this one.
  4. Gatekeeper's assessment accepts it, which means it is notarized.
  5. Its commit is the manifest's, and its build number is higher than the running app's.
- A passing build is renamed to the waiting build, and the state becomes the existing built state, worded "Downloaded · restart Launchy to update". A failing one is deleted, and the state shows which check failed.
- Its state lives in the same upgrade record in Application Support, so a relaunch picks it up.

**Restart Launchy on an installed Mac**
- It keeps today's rules. It is refused while an upgrade runs, and when nothing newer waits. It lists the panes that would end. It starts a second after the reply, from Launchy's own GUI session.
- Launchy starts a helper script from its Resources, detached under `setsid` as `scripts/restart.sh` is. The helper gets Launchy's process id, the app's path and the waiting build's path, and then:
  1. Sends SIGTERM to Launchy, which is what `pkill` does today, so the panes that survive are the ones the list named.
  2. Waits up to 10 s for it to exit.
  3. Renames the running app into the upgrade folder as the previous build, renames the waiting build to the app's path, and opens it.
- If the new app hasn't taken the single-instance lock within 30 s, the helper renames the previous build back and opens it. The next launch shows "The new build didn't start; Launchy is back on <version>".
- The new app deletes the previous build once it holds the lock.

**What stays as in option 02**
- No launch snapshot for the app: its executable changes only at the restart, so peers never reach a build that isn't running.
- Headless hosts are upgraded from a Mac that runs a checkout.
- Checkout Macs: unchanged.

**Docs, once accepted**
- ADR 0013 gets a note that installed Macs download their build. where-it-breaks gains the checks, the helper and the rollback.

## Testing Decisions

There is no test target. These are hand checks with two published builds. The second is a test build attached to a pre-release, which the manifest address doesn't see, so an environment variable points the app at its manifest instead.

- **Upgrade on This Mac:** the download, all five checks and the waiting state. Relaunching Launchy before the restart keeps the state.
- **Each check, failing on purpose:** a changed byte in the zip, an app re-signed ad hoc, an app signed by another identity, an app that isn't notarized, and a lower build number. Each is refused with its reason.
- **Restart Launchy:** the new app opens, the panes listed are the ones that ended, and the previous build is deleted.
- **Rollback:** a waiting build whose executable exits at once. The old app comes back with the message.
- **A folder the user can't write:** refused before anything downloads.
- **A mixed fleet:** a checkout Mac and an installed Mac, with Upgrade all and Restart all. Each reaches its own target, and the bulk lines are right.

## Out of Scope

- Background checks and notifications.
- Delta updates.
- Installing into folders that need an administrator.
- Upgrading a headless host from an installed Mac.
- Choosing a build other than the newest, and going back to an older one.

## Further Notes

- **Left for later (2026-10-09).** The user accepted option 02 and isn't pursuing updates yet, so this option stays proposed for when they are. Before it is picked up it needs reading against what has changed since it was written: the rename (Launchy is Varnick, name-taken-by-another-launcher), and option 02 as built, whose published build is a fixed-name `Varnick.zip` on a GitHub release, with the hosting still open there.
- The App Management protection on recent macOS lets an app update itself when the new bundle comes from the same team. That this holds for a helper script started by Launchy is unverified, and the first test above shows it. If macOS asks, the prompt names Launchy, and the user allows it once.
- A later step could ship the relay's files inside the app, for a headless Upgrade from an installed Mac. It would need an installer mode that takes files instead of a commit, since an installed Mac has no git history to compare against.
