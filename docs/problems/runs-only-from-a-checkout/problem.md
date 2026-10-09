---
title: Launchy runs only from a source checkout
description: Launchy exists only as a bare executable that `make build` leaves in a checkout of its repository. Since 2026-10-09 it is signed with the user's Developer ID and the hardened runtime when the building Mac has the identity, and ad hoc otherwise (option 01, ADR 0022). To use it, a person clones the repository, installs a Swift toolchain and runs `make`. There is nothing to download and open. The binary's helper files, its database, its restart, its start at login and its upgrades all assume they live in that checkout. The user has an Apple Developer account and wants a signed, notarized Launchy.app that installs like any other Mac app.
impact: Once the repository is public (repo-not-ready-to-open-source), only people willing to build from source can try Launchy. Anyone building without a Developer ID identity gets an ad-hoc signature, the hash of one build, so macOS treats each of their builds as a new app, and a rebuild can bring back the Keychain prompt and the privacy prompts. On a signed build, Accessibility and Screen Recording grants survive a rebuild (measured 2026-10-09), and the microphone's is expected to (unverified). The user's history archive, which holds history Chrome may already have dropped, lives inside a working tree, where a `git clean -x` or a deleted checkout would take it.
severity: mid
evidence: Code and Makefile as of 9595244, read on 2026-10-08. The same day, read-only on this Mac - the running build's signature (`codesign -dv`), the signing identities in the keychain (`security find-identity`), the installed developer tools, the build folder and Launchy's Application Support folder. MLX's metallib lookup and CPU compile path read in the pinned mlx-swift 0.32.3 checkout. Nothing was signed, built or changed.
status: open
---

## What the user wants

A Launchy.app that a person downloads, opens and keeps up to date, signed with the user's Apple Developer account and notarized by Apple: Developer ID distribution, outside the Mac App Store.

Related decisions:

- **repo-not-ready-to-open-source**, option 01, is accepted: the repository goes public. After that, other people need a way in that isn't a Swift toolchain.
- **peers-upgraded-by-hand**, option 03, is accepted and built (ADR 0013). Each Mac upgrades by fetching origin/main into its checkout and running `make build` there, and Restart Launchy is a separate press. That model needs a checkout on every Mac.

## Today

### How Launchy is built and started

All verified at 9595244.

- **`make build`** (Makefile:45-53) runs `swift build -c release`, then re-signs the binary ad hoc with the identifier `com.zabaca.launchy`. It fetches MLX's prebuilt `mlx.metallib` from a pinned PyPI wheel and the pinned zmx release from GitHub, each checked by SHA-256. It copies `PhonePage/`, less its tests and fixtures, and writes the build stamp last. All of these land in `.build/release/` beside the binary.
- **The Info.plist** (bundle id, name, and the microphone and system audio usage strings) is linked into the binary as a section (Package.swift:5-8 and 40). The re-sign binds it. There is no `.app`, no entitlements file, no hardened runtime and no version number.
- **`make run`** (Makefile:88-89) starts `scripts/restart.sh` detached under `setsid`. The script kills every Launchy whose path matches this checkout's binary, waits up to 10 s, and starts the new build with `LAUNCHY_DB` set to the checkout's database (restart.sh:7-14).
- **`make install`** (Makefile:98-107) fills `scripts/launchy.plist.in` into a LaunchAgent. The agent runs the checkout's binary, with the checkout as its working folder, `LAUNCHY_DB` set to the checkout's `db/`, and its output going to `~/Library/Logs/Launchy.log`. It also links the custom-apps skill.
- **Apple silicon only.** The zmx download is aarch64 and the metallib wheel is arm64.
- **Nothing to embed but zmx.** The binary links only system frameworks and libraries (`otool -L`). SwiftPM produced no resource bundles, dylibs or frameworks. In a bundle, the nested code would be the main executable and zmx.

### What assumes the checkout or `make`

Line numbers are as of 9595244.

| What | Where | What it assumes | Inside an app bundle |
|---|---|---|---|
| The search database | main.swift:70-72, 81; Makefile:1, 89, 100-102; restart.sh:14; launchy.plist.in:13-18 | `LAUNCHY_DB`, else `db/launchy.sqlite` under the working folder. `make run` and `make install` pass the checkout's. | Opened from Finder, the working folder is `/`, so Launchy would stop at launch with "Check LAUNCHY_DB" (inferred from the code). |
| The relay's copy of that path | MacPeerHost.swift:211-226; Peers.swift:526 | Each launch writes the database's absolute path to `search-db-path` in Application Support, for the relay. | Works anywhere. It also tells a migration where the old database is (on this Mac it names the checkout's `db/launchy.sqlite`, verified). |
| `.env`, the TypeSafe key's fallback | Reranker.swift:110-120; Settings.swift:377 | Read from the working folder. | Never found. The Keychain and the environment still work. |
| Claude's default folder | LauncherModel.swift:2024-2029 | The setting, else `LAUNCHY_CLAUDE_DIR`, else the working folder. | Would be `/`. |
| `mlx.metallib` | MLXRuntime.swift:6-11; EmbedCommands.swift:10-11; MLX's own lookup | Beside the binary. MLX looks beside its binary, then in `Resources/` under the binary's folder. | Contents/MacOS should hold only code, and MLX's second guess would be Contents/MacOS/Resources, not Contents/Resources. mlx-swift 0.32.3 has `GPU.metallib` to name the file instead (verified in its source). |
| zmx | Zmx.swift:16-28; ADR 0004 | The copy beside the binary, links resolved, and never one from PATH. | Contents/MacOS/zmx works unchanged. |
| Phone page files | PhonePage.swift:90-95; LaunchSnapshot.swift:66-69 | `PhonePage/` beside the binary, or in the launch snapshot. | Belong in Contents/Resources. |
| The build stamp | LaunchSnapshot.swift:4-42; Makefile:57-69 | A `build-stamp` line beside the binary, written from git. It's ignored when it is older than the binary. Outside a git checkout there is none. | Signing a bundle rewrites the binary after the stamp is written, so the age rule would discard it. |
| The launch snapshot | LaunchSnapshot.swift:56-110 | Taken only when the binary is inside a checkout's `.build`. Otherwise the peer link points at the binary in place. | No snapshot: peers run the app's executable in place. |
| The peer link and the SSH command | PeerSocket.swift:154-180; main.swift:479-481 | A fixed link in Application Support, pointing at whatever binary runs, which answers `--peer` before AppKit starts. | Works unchanged: the relay is the app's own executable. |
| A hello's build | PeerIdentity.swift:37-46 | The binary's modification time. | Works. |
| Upgrade and Restart Launchy (ADR 0013) | BuildUpgrade.swift:59, 205, 354, 376-397; UpgradeRunner.swift:28; CheckoutGit.swift:171; LaunchSnapshot.swift:156-168 | A checkout to fetch into, `make build` in it, and `scripts/restart.sh` from it. | Each is refused: "Launchy isn't running from a checkout of its repository". |
| Headless host install and Upgrade (ADR 0009, ADR 0013) | install-peer.sh:31, 117-121, 126, 147; HeadlessUpgrade.swift:209-211; RelayComparison.swift:7-11, 62 | `git archive` from the checkout, the protocol version and remote command read from git, and "relay unchanged" from `git diff`. | Need a checkout and its history. |
| The custom-apps skill link | Makefile:27-28, 115-130 | Links `~/.claude/skills/custom-apps` to the checkout's skill folder, which itself holds two links into the repository's docs. | No `make`. A copy would need those links resolved. |
| Preferences and web data | main.swift:486-497 | Keyed by the bundle id `com.zabaca.launchy`. | Same id, so unchanged, provided the app isn't sandboxed. |
| Everything else Launchy keeps | SessionStore.swift:165; SupportFolder.swift | `~/Library/Application Support/Launchy`: saved tabs, models, transcripts, peers, devices, panes, upgrade state. | Unchanged. |
| Tools it looks for | PhonePage.swift:150 (Bun); Peers.swift:133-134 (Tailscale); ZmxRun.swift:83 | Fixed lists of paths. | Unchanged. |

### Signing and permissions

**Since 2026-10-09** (option 01, ADR 0022), builds are signed with Developer ID and the hardened runtime on a Mac that has the identity, which the user created that day. Launchy now also uses Accessibility (ADR 0019) and Screen Recording (ADR 0021) for Point at the screen, and both grants survived a signed rebuild and restart (measured 2026-10-09). The list below is as read on 2026-10-08.

Verified unless marked.

- **The running build** is signed ad hoc, with identifier `com.zabaca.launchy`, no team, the Info.plist bound and no sealed resources. zmx carries its linker's ad-hoc signature.
- **What Launchy asks macOS for:**
  - the microphone (Listening.swift:75);
  - system audio, through a Core Audio process tap (Listening.swift:354-359);
  - on-device speech through the Speech framework. The Info.plist has no speech recognition usage string;
  - Keychain items for API keys (Keychain.swift).
- **What it doesn't use:**
  - Accessibility. The global shortcuts are Carbon's `RegisterEventHotKey` (HotKey.swift:31), and the event monitors are local (main.swift:149, 161). Neither needs Accessibility.
  - Apple Events from its own process. The Phone page's administrator prompt runs `osascript` as a child process (PhonePage.swift:341, PhonePageServer.swift:162).
  - The camera and screen recording.
- **The processes Launchy starts** (shells, claude, Bun, ssh, zmx) inherit it as the app responsible for their privacy prompts, for example a Claude pane reading Documents (inferred; not checked for panes kept in zmx across a restart).
- **An ad-hoc signature names one build.** Keychain.swift:4-5 records that macOS asks again before a rebuilt Launchy reads a saved key. Microphone and system audio grants are expected to behave the same way (unverified on this Mac).
- **No App Sandbox, and Launchy can't have one.** It reads Chrome's profile folders and `~/.claude`, and runs ssh, zmx, shells and claude. Developer ID distribution doesn't require the sandbox.

### This Mac's tools, 2026-10-08

- The Command Line Tools are selected, with no Xcode. They include `notarytool` and `stapler`. `codesign`, `ditto` and `hdiutil` are present.
- The keychain holds no valid code signing identity. (The user created a Developer ID Application identity on 2026-10-09, ADR 0022.)

### Data in the checkout

`db/` holds the live `launchy.sqlite`, with its WAL and shared-memory files, and older exports beside it. Only `launchy.sqlite` is live. `make clean` leaves `db/` alone on purpose (Makefile:131-133).

### Constraints from other decisions

- **ADR 0004:** Launchy uses only the zmx beside its binary.
- **ADR 0013:**
  - Upgrade fetches origin/main and builds in a zmx session, and Restart Launchy is a separate press that starts from the Mac's own GUI session.
  - The launch snapshot keeps a Mac's relay and app on one protocol until that restart.
  - The `upgrade` and `restart` requests are frozen: new fields only, optional.
- **ADR 0009:** a headless host's relay is built on the host from a Mac's checkout.
- **CODING_STANDARDS.md:** no new dependencies without a decision. Sparkle would be one.
- **CONTEXT.md:** **Build** says to avoid "version", and **Release** already means giving up control of a pane. A downloadable app needs a word of its own; the options say "published build".
- **This repository is public** (`docs/agents/issue-tracker.md`). No team ID, certificate name or notary credential goes in a tracked file, so the Makefile has to find them on the machine.
- **The name.** "Launchy" is also an established launcher that runs on macOS (repo-not-ready-to-open-source, The name). Two apps called Launchy.app would collide in /Applications.

## Unverified

- That microphone and system audio grants are lost at each ad-hoc rebuild, and kept across rebuilds once signed with Developer ID. Accessibility and Screen Recording were measured kept across a signed rebuild on 2026-10-09.
- Which hardened-runtime entitlements the system audio tap needs beyond audio input, and whether the Speech framework needs any.
- MLX on the GPU needs no entitlement (inferred). On macOS, mlx-swift 0.32.3 compiles in MLX's CPU compile path, which builds a library at run time and loads it (verified in its source). Library validation would refuse that library. Whether Launchy ever reaches that path is unverified.
- That `Bundle.main`'s resource folder, for a bare executable, is the executable's own folder.
- Whether only the account holder can create a Developer ID Application certificate, or an admin can too.
