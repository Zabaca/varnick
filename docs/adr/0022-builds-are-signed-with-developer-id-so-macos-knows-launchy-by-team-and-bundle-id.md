# Builds are signed with Developer ID and the hardened runtime, so macOS knows Launchy by its team and bundle id

`make build` signs Launchy and zmx with the user's Developer ID Application identity, the hardened runtime and an entitlements file holding audio input alone. It does so whenever the building Mac's keychain has that identity. Without the identity it signs ad hoc, as before, and a found identity that fails to sign fails the build rather than falling back. There is still no app bundle, no notarization and no download.

macOS stops knowing Launchy by the hash of one build and knows it by its team and bundle id (`com.zabaca.launchy`). So permissions and Keychain access granted once should hold across `make build`, `make run` and the Upgrade button (ADR 0013). That covers the microphone and system audio (Listening), Accessibility (ADR 0019), Screen Recording (ADR 0021) and saved keys. Until now, each rebuild could bring back the prompts or silently stop a grant applying.

The user accepted this on 2026-10-09, after creating the identity. The problem and its options are in `docs/problems/runs-only-from-a-checkout/`; this records option 01.

## Considered Options

- **Keep signing ad hoc:** every build is a new app to macOS, so grants and Keychain access come and go with rebuilds.
- **An Apple Development certificate per Mac:** each Mac would sign as a different developer, so a grant on one build machine's output wouldn't carry to another's. One Developer ID identity gives every Mac the same signer.
- **A notarized Launchy.app (options 02 to 04):** later. They sign the same way and build on this.

## Consequences

- **The identity is the user's, and no tracked file names it.**
  - The building Mac picks it from a git-ignored local settings file, or as the keychain's only Developer ID Application identity.
  - The team ID and certificate name appear only in that file and in build output.
  - Each Mac that builds needs the identity in its login keychain, usable by `codesign` without a prompt, or an unattended upgrade stops. A Mac without it keeps building ad hoc.
- **The first signed build is a new identity to macOS,** so every permission and each saved key is asked for once more. After that, rebuilds ask nothing.
- **Grants no longer lapse at a rebuild, and that cuts both ways.** Every process in Launchy's panes is attributed to Launchy (the correction of 2026-10-09 in ADR 0019, `panes-share-launchys-permissions`). With ad-hoc builds, a rebuild at least stopped Launchy's Accessibility and Screen Recording from applying. Now, once granted, they reach every pane session until the user removes them or that problem is fixed.
- **The hardened runtime refuses the microphone without its entitlement,** so audio input is the one entitlement.
  - Accessibility and Screen Recording need none.
  - Anything else (JIT, library validation, Apple Events) is added only for a failure a check actually showed, with a comment naming it.
  - MLX's CPU compile path and the system audio tap are the parts most at risk.
- **Library validation and the hardened runtime stop other code from being loaded into Launchy's process,** which an ad-hoc build without the runtime allowed.
- **zmx is signed with the same identity** before it is moved into place. Running daemons keep their file, and the zmx stamp records the identity, so a change of identity re-signs a copy without a pin bump (ADR 0004).
- **A strict `codesign --verify` runs after signing,** and its failure fails the build.
