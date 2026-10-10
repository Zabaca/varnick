# Varnick ships as a notarized app beside the checkout build

Varnick is built two ways from one binary. A checkout runs `make build`, `make run` and `make install`, as before (ADR 0022). `make app` wraps the same build in `Varnick.app`, signs it inside out with the hardened runtime, has Apple notarize it, staples the ticket and zips it as `Varnick.zip`, so that a person with an Apple silicon Mac and macOS 14 can download, unzip, move to Applications and open it, with no Swift toolchain and no Gatekeeper warning. Downloads are GitHub Releases on Zabaca/varnick, public since 2026-10-09; the link `https://github.com/Zabaca/varnick/releases/latest/download/Varnick.zip` never changes. `make app` never uploads: the user attaches the zip to a release by hand, and the first release is not published yet. The user accepted this on 2026-10-09. The problem and its options are in `docs/problems/runs-only-from-a-checkout/`; this records [option 02](../problems/runs-only-from-a-checkout/options/02-notarized-app-updated-by-hand.md), and the option has the detail the points below leave out.

A **Published build** (CONTEXT.md) is the app that a release carries. Four decisions make one binary serve both ways, and are hard to see from the code alone:

- **The resource rule.** Varnick finds its helper files (the Metal shaders, the Phone page, the build stamp, the skill) in a resource folder worked out from its own executable's path, links resolved. Inside `<name>.app/Contents/MacOS/` that is the bundle's `Contents/Resources`; anywhere else it is the executable's own folder, where `make build` puts them. Links are resolved because the relay runs through a link outside the bundle and must find the same files. A bundle is never a checkout build, wherever it sits: no launch snapshot, no Upgrade, no `.env`, no restart script.
- **The database lives in Application Support in every mode.** `varnick.sqlite` is beside everything else Varnick keeps, so a checkout build, a worktree's `make run` and the app read one archive, and a deleted or cleaned checkout can no longer take history that Chrome may have dropped. The first start copies an older `db/` database there once and leaves the original in place; `VARNICK_DB` still overrides the path.
- **One copy runs per account.** The app holds a lock on a file in its support folder, so a second copy (a `make run` beside the app, a LaunchAgent beside a login item) says where the first runs from and quits.
- **No in-app updates.** An installed app is updated by downloading the next zip and replacing the app, and Settings › Peers says so where Upgrade would be. Upgrade and Restart keep working on a Mac that runs a checkout.

## Considered Options

- **Updates through the peers' buttons, or with Sparkle (options 03 and 04):** left for later, not rejected. They sign and package the same way and would be built on this. The user isn't worried about updates for now, and a Mac on the app falls behind until someone downloads.
- **Hosting the zip on varnick.com through Cloudflare:** it works while a repository is private, but every build would need a second upload kept in step with the release. GitHub serves the asset under a link that never changes.
- **A DMG, a Homebrew cask, Intel Macs, the Mac App Store and the App Sandbox:** out of scope. A zip of a stapled app installs by itself, and a DMG can be added later with `hdiutil` and no new tool.
- **Publishing from CI:** rejected, since notarizing on a hosted runner would put the notary access there.

## Consequences

- **The app speaks the protocol of the last published build,** while checkouts follow `origin/main`. Whenever `main` bumps the protocol before a new build is published, an app and a checkout can only exchange hellos.
- **A headless host's relay is still installed and upgraded from a Mac that runs a checkout,** never from an installed app.
- **The signing identity and the notary profile stay on the Mac that makes the app,** in git-ignored local settings and the keychain. No tracked file holds them.
- **`make app` refuses anything but a clean `main` that origin has,** unless `CHECK_BUILD=1`, which runs every step but the zip, so every published build matches a public commit and a check never leaves a zip that looks publishable.
- **Replacing the app while it runs would point peers at the new executable before Varnick restarts,** so the README tells people to quit it first.
- **A Mac moving from a checkout runs `make uninstall` first,** since the app leaves an existing LaunchAgent alone. The lock makes a missed step harmless.
- **The first run of the app on a Mac may ask for every permission once more,** if macOS counts the app and the bare executable as different apps (inferred, not checked).
