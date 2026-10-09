---
problem: runs-only-from-a-checkout
title: Sign every build with Developer ID and the hardened runtime, still run from the checkout
summary: The build signs Launchy and zmx with the user's Developer ID Application identity whenever the keychain has one, with the hardened runtime and an entitlements file that asks only for audio input. Without an identity it signs ad hoc, as today. There is no app bundle, no notarization and no download. Permission grants and Keychain access then follow the team and the bundle id rather than one build's hash, so they should survive rebuilds and ADR 0013 upgrades. Rough effort is a day, most of it checking permissions by hand.
status: proposed
---

## Solution

The build keeps its shape: a bare executable in the checkout's build folder, with zmx, the metallib, the Phone page files and the stamp beside it. Only the signature changes. When the Mac's keychain holds the user's Developer ID Application identity, `make build` signs the binary with it. The signature uses the hardened runtime, the identifier `com.zabaca.launchy` and one entitlement, audio input. zmx is signed with the same identity before it is moved into place.

macOS then identifies Launchy by its bundle id and team, not by the hash of one build. So the microphone, system audio and Keychain grants given once should hold across `make build`, `make run` and the Upgrade button (expected, to be confirmed by the checks below). A Mac without the identity builds exactly as today.

## Trade-offs

- **Small and local.** The Makefile and one entitlements file change; no Swift changes.
- **Doesn't make Launchy installable.** Nobody can download anything; it fixes only the grants that come back after rebuilds.
- **The identity has to be on every Mac that builds.** For an upgrade by the Upgrade button it has to be usable without a prompt, because the build runs unattended in a zmx session. A Mac without it falls back to ad hoc and keeps today's prompts.
- **One more grant at the switch.** The first build signed this way is a new identity to macOS, so it asks once more for the microphone, system audio and each saved key.
- **The hardened runtime could break something that works today.** Candidates: the system audio tap, and MLX's CPU compile path, which loads a library it builds at run time. The checks below look for both, and an entitlement is added only for a failure actually seen.

## User Stories

1. As the user, I want to grant the microphone and system audio once and keep them through every rebuild, so that Listening doesn't stop at a prompt after an upgrade.
2. As the user, I want Launchy to read my saved TypeSafe key after a rebuild without asking, so that the relevance filter keeps working after an upgrade.
3. As the user, I want a Mac without my signing identity to keep building as it does today, so that a contributor's checkout still works.
4. As the user, I want no team ID or certificate name in the repository, so that it stays fit to publish.
5. As the user, I want an upgrade started from another Mac to sign its build without waiting on a prompt, so that it finishes on its own.

## Implementation Decisions

**Which identity**
- The identity is the one named in a git-ignored local settings file in the checkout, which the Makefile reads if present. Without one, it is the only "Developer ID Application" identity in the keychain. With none, the build signs ad hoc, as now.
- With two or more Developer ID identities and none named, the build stops and says to name one, rather than guessing.
- The settings file, its example and the build output are the only places the identity is named. A tracked file never names it, and the build prints its authority only to the terminal.

**How the binary is signed**
- The flags are: force, the identity, the hardened runtime, the entitlements file, and the identifier `com.zabaca.launchy`. A build signed this way leaves out the secure timestamp: only notarization needs it, and it calls Apple's server on every build.
- The re-sign that binds the Info.plist is the same command, so the relink rule for an Info.plist change stays as it is.
- After signing, a strict `codesign --verify` runs, and a failure fails the build.
- When an identity was found but signing with it fails, the build fails. It never falls back to ad hoc silently, which would change the app's identity behind the user's back. A failed build in an upgrade leaves the old one running, as ADR 0013 already guarantees.

**The entitlements file**
- One property list at the repository root, holding audio input (`com.apple.security.device.audio-input`) only. The hardened runtime refuses the microphone without it.
- Nothing for Apple Events, Accessibility, JIT or library validation until a check shows a need. If one does, the entitlement goes in with a comment saying which check needed it.

**zmx**
- zmx is signed with the same identity, with the hardened runtime and no entitlements, in its fetch folder before the rename into place. The running zmx daemons keep their file: signing in place would change pages under a running daemon, which macOS can kill for it.
- The zmx stamp also records which identity signed it. When the identity changes, or one is added after the first fetch, the build copies zmx into the fetch folder, signs the copy and renames it into place. It is the same release, so its protocol is unchanged and running sessions survive, unlike a pin bump (ADR 0004).

**The launch snapshot**
- Unchanged. The snapshot clones the signed binary and zmx, and a clone keeps its signature.

**Setting up a Mac** (the user's steps, kept out of the repository)
- The certificate is created once in the developer account, and its private key is backed up in the user's own secret store.
- On each Mac that should sign, the identity is imported into the login keychain and allowed for `codesign` without a prompt.

## Testing Decisions

There is no test target. After `make build` on a Mac with the identity:

- `codesign -dvv` shows the team, the runtime flag and the identifier. `codesign -d --entitlements -` shows audio input only. The same for zmx.
- After a restart, by hand:
  - Listening on: the microphone and system audio prompts appear once. Then speak, and play a video: both reach the transcript.
  - A search with the TypeSafe key saved: one Keychain prompt, answered Always Allow.
  - On-device relevance, semantic search and text generation each run, so MLX works under the hardened runtime.
  - Keep sessions running on: a new pane survives the restart.
- Then `make build` and restart again: no prompt of any kind, and Listening still hears both sources.
- A peer's hello reaches this Mac's relay, which runs from the snapshot.
- On a second Mac with the identity, an Upgrade from Settings › Peers builds without a prompt.
- On a Mac without the identity: `make build` signs ad hoc and everything works as before.

## Out of Scope

- An app bundle, notarization, a download and updates (options 02 to 04).
- Moving the database.
- Signing the Linux relay. It isn't Mac code.
- Apple Development certificates per Mac. One Developer ID identity gives every Mac the same signer, which is what keeps the grants.

## Further Notes

- This option is the first step of options 02 to 04, which sign the dev build the same way, so it can be built first on its own.
- Grants following the team and bundle id is how macOS treats Developer ID signatures in general. That it holds for each of Launchy's grants is what the checks above confirm.
