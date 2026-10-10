---
problem: runs-only-from-a-checkout
title: Installed apps update themselves with Sparkle
summary: Left for later on 2026-10-09, still proposed: the user chose option 02 and isn't pursuing updates yet. Option 02, plus Sparkle 2 in the app. `make app` also signs the zip with an EdDSA key and writes an appcast entry for the user to publish with it. Sparkle checks daily, then downloads, verifies, installs and relaunches, with its standard update window and a Check for Updates item in the menu bar menu. On an installed Mac, Settings › Peers' Upgrade asks Sparkle to download quietly, and Restart Launchy asks it to install and relaunch. Sparkle's installer handles folders that need an administrator, App Management and translocation. The costs are a new dependency, a second signing key, and Sparkle's own install step, which ADR 0013's separate restart has to be fitted around. Rough effort is two weeks on top of option 02.
status: proposed
---

## Solution

Sparkle is the updater most Developer ID apps use. With it, an installed Launchy checks a feed once a day. When a newer build is in the feed, it offers it in a window: Install, Skip or Remind me later. The download is checked against the EdDSA signature in the feed and against the app's own code signature. Sparkle's installer then replaces the app, asking for an administrator's password when the folder needs one, and reopens it.

Settings › Peers keeps ADR 0013's buttons for installed Macs by driving Sparkle instead of showing its window:

- Upgrade asks Sparkle to check and download without a window.
- Restart Launchy, after its usual list of panes, asks Sparkle to install and relaunch.

Macs that run a checkout keep origin/main and `make build`.

## Trade-offs

- **A tested installer.** Sparkle handles cases option 03 refuses or leaves unverified: folders that need an administrator, App Management, translocation, interrupted installs. It also offers delta updates.
- **Updates reach a Mac with no peers.** The daily check and the window work without Settings › Peers, which suits people outside the user's own fleet.
- **A new dependency.** It is a binary framework to embed, re-sign and keep current. CODING_STANDARDS.md allows none without a decision, so it needs an ADR, and its notice goes in the third-party notices.
- **A second key.** The EdDSA private key signs every published build. Losing it strands installed apps on their current build. If it leaks, the Developer ID check is all that still stops a forged update.
- **Two ways to update, fitted together.** Sparkle installs and relaunches in one step and quits Launchy through the normal Quit path. ADR 0013's Restart Launchy kills it with SIGTERM. Under Quit, app servers stop when Keep sessions running is off, so the list of panes that would end must follow Sparkle's path on an installed Mac (where-it-breaks: the list must follow what the next launch does).
- **The feed has to be hosted.** It must be at a fixed address, which is one more file to publish with every build.

## User Stories

1. As a person running the app, I want Launchy to tell me when a newer build is out and install it when I agree, so that I stay current without visiting GitHub.
2. As a person running the app, I want to turn automatic checks off and check by hand from the menu bar menu.
3. As a person whose Launchy is in a folder only an administrator can change, I want the update to ask for the password rather than fail.
4. As the user, I want Upgrade and Restart Launchy in Settings › Peers to work for installed Macs, so that I manage my fleet in one place.
5. As the user, I want an update that isn't signed with both my EdDSA key and my Developer ID to be refused.
6. As the user, I want the same list of panes before a Sparkle relaunch as before any Restart Launchy.

## Implementation Decisions

**The dependency**
- Sparkle 2, pinned exactly, through SwiftPM as its binary framework, with an ADR saying why it is the one updater dependency.
- The app carries the framework in Contents/Frameworks, and the executable looks there.
- `make app` signs inside out with the identity, the hardened runtime and a secure timestamp: Sparkle's helper tools and its updater app inside the framework, then the framework, then zmx, then the app.
- The checkout build doesn't start Sparkle. Whether the bare executable can link the framework and still run from the build folder, or needs the framework copied beside it, is unverified. The first ticket settles it.
- Library validation stays on: the framework is signed by the same team.

**Keys and the feed**
- An EdDSA key pair is made once with Sparkle's tool. The private key is kept in the user's own encrypted secret store and loaded only on the release Mac. The public key goes in the Info.plist; it is public and can be committed.
- The feed is one appcast file at a fixed address: an asset of the latest GitHub release, read through GitHub's "latest release" download address. `make app` writes the entry: version, build number, minimum macOS, length, EdDSA signature, and the zip's address on the same release.
- The user attaches the zip and the appcast together. Sparkle ignores a pre-release, because the address names the latest release only.

**Checks, in the app**
- Sparkle's defaults: it asks whether to check automatically at the second launch, then checks once a day.
- Check for Updates… goes in the menu bar menu, and Settings shows the automatic-check switch.

**Settings › Peers on an installed Mac**
- The upgrade report on an installed Mac uses the frozen shape's optional fields, as option 03 does: the running version, and the newest in the feed.
- **Upgrade** runs Sparkle's background check and download through a user driver of Launchy's own that shows no window. The state becomes "Downloaded · restart Launchy to update" once Sparkle has the update ready to install.
- **Restart Launchy** keeps today's refusals. Its list of panes follows the Quit path, since that is how Sparkle ends Launchy. Then it asks Sparkle to install and relaunch.
- A peer's request never triggers Sparkle's window. If Sparkle needs a password, the row says so and the install waits for someone at that Mac.

**What stays as in option 02**
- The bundle, the resource rule, the database, the lock, Open at login, the log, translocation and the skill link.
- Headless hosts are upgraded from a checkout Mac.

## Testing Decisions

There is no test target. These are hand checks with two published builds and a test feed, which an environment variable points the app at.

- **The window:** the daily check, Install, Skip, and Remind me later. Check for Updates… from the menu.
- **A folder that needs an administrator:** the password prompt, then the update.
- **Tampering:** an update whose EdDSA signature doesn't match, and one re-signed by another identity. Both are refused.
- **From Settings › Peers:** Upgrade downloads without a window. Restart Launchy installs and relaunches, and the panes listed are the ones that ended, with Keep sessions running both on and off.
- **The checkout build** starts no Sparkle and makes no feed request.

## Out of Scope

- Delta updates at first. Sparkle supports them, but they need the previous build at hand when `make app` runs.
- Updating a headless host.
- Beta channels.

## Further Notes

- **Left for later (2026-10-09).** The user accepted option 02 and isn't pursuing updates yet, so this option stays proposed for when they are. Before it is picked up it needs reading against what has changed since it was written: the rename (Launchy is Varnick, name-taken-by-another-launcher), and option 02 as built, whose published build is a fixed-name `Varnick.zip` on a GitHub release, with the hosting still open there.
- Sparkle's licence is MIT. Its helpers are signed as part of the app, so notarization covers them.
- Options 03 and 04 can't both be accepted; they are two answers to the same question.
