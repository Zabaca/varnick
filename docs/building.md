# Building from source

Most people should use the downloaded app (see the [README](../README.md#install)). Build from a checkout to
change the code, to run Varnick on a Mac without the app, or to upgrade Macs from Settings › Peers. To install a
headless Linux host's relay, see [The Linux relay](#the-linux-relay) below.

## Build and run

Build and run through the `Makefile`. It needs a Swift 6.2 toolchain (`swift-tools-version:6.2` in
`Package.swift`):

```
make build      # builds, codesigns, and fetches the files below
make run        # builds, then restarts Varnick from this checkout
make install    # builds, then starts Varnick now and at each login, through a LaunchAgent
make uninstall
```

Plain `swift build` is not enough. `make build` also re-signs the binary so macOS binds its
`Info.plist` (the microphone and system audio usage strings), downloads MLX's prebuilt Metal shaders
(`mlx.metallib`), which `swift build` cannot compile without Xcode, and downloads the pinned zmx release.
Both downloads are checked against SHA-256 digests in the `Makefile`. The first build is slow:
it resolves and compiles the Swift packages.

`make run` and `make install` restart Varnick, which ends every pane that isn't kept running in zmx (see
[the guide](guide.md#restarting-ends-sessions-that-arent-kept-in-zmx)).

## Signing

The binary and zmx are signed ad hoc, unless the Mac's keychain holds a "Developer ID Application"
identity: the build then signs with it, with the hardened runtime and one entitlement (audio input), so macOS
should keep the permissions you give Varnick across rebuilds instead of treating each build as a new app (to be
confirmed by hand; see ADR 0022 and [`SECURITY.md`](../SECURITY.md)). With two or more such identities, or to pick
another, copy `Makefile.local.example` to `Makefile.local` (git-ignored) and name one.

A build never falls back to ad hoc behind your back: if an identity was found and signing with it fails, the build
fails; so does one named in `Makefile.local` that isn't in the keychain, one that has expired or become invalid, a
checkout that has signed before finding none, and a `security find-identity` that itself fails. Set
`SIGN_IDENTITY=-` to sign ad hoc on purpose. A failed build puts the last good binary back. The key must be usable
by `codesign` without a prompt, since an upgrade from Settings › Peers builds unattended.

## What a checkout touches

`make install` also links this checkout's `custom-apps` skill into `~/.claude/skills/` so Claude Code in
any project can find it. It links only when nothing is at that path, or when the link there already
points into this checkout; any other entry is left as it is, and `make uninstall` removes only a link that
points into this checkout. The downloaded app links its own copy by the same rule.

A checkout build reads and writes the same places the app does: `~/Library/Application Support/Varnick` (saved
tabs, models, transcripts and other state), the macOS Keychain (the TypeSafe key, if you save one), and
its own preferences.

`.env` is read from Varnick's working directory when it runs from a checkout, which is that checkout under
`make run` and `make install`. The installed app doesn't read it: it takes the TypeSafe key from the Keychain
or the environment.

The database is a SQLite file, `varnick.sqlite`, in Varnick's folder in Application Support, whichever
way Varnick runs. The first start copies a checkout's `db/` database there, if it has one, and leaves the original
in place. The `VARNICK_DB` environment variable overrides the path; without it, the command-line modes
(`--sync`, `--search`, `--ask`, `--search-eval`) refuse until Varnick has been opened once. `make clean`
removes `.build/` and keeps `db/`, since it holds history Chrome may have already dropped.

## Moving a Mac from a checkout to the app

Run `make uninstall` in the checkout first. The LaunchAgent would otherwise start a second Varnick at every login,
and whichever copy comes second shows an alert and quits. The app and a checkout build share one history database
in Application Support (above); a checkout's older `db/` copy is copied there once, and left in place.

An installed Mac can't upgrade a headless host's relay or be upgraded from another Mac; do those from a Mac that
runs a checkout.

## The Linux relay

A headless host (a Linux machine with no Varnick app) runs Varnick's relay alone. Install it from a Mac, from a
checkout:

```
scripts/install-peer.sh <user>@<host> [--name NAME] [--page | --no-page] [--uninstall]
```

The installer builds `Packages/VarnickPeer` on the host, so the host needs:

- **x86_64 Linux.** Any other architecture is refused.
- **Swift from [swiftly](https://www.swift.org/install/linux/), installed by hand** at
  `~/.local/share/swiftly/bin/swift`. The installer stops and says so when it is missing.
- **A Debian-style system with `apt`, and passwordless `sudo`** for the one package it installs when
  missing, `libstdc++-14-dev`. If the build still fails to link, it retries once with the x86_64 GCC 13
  library folder, `/usr/lib/gcc/x86_64-linux-gnu/13`, added to the link line. That is the folder layout of
  a distribution that ships GCC 13, such as Ubuntu 24.04; this fallback has not been tried here on other
  releases.
- SSH key login from the Mac, and zmx, which the installer downloads and checks.
- For `--page`: `systemd` with user units, Tailscale, and Bun, which the installer downloads from a pinned
  release and checks if the host has none.
