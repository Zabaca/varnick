# Varnick ships on a disk image too, and moves itself to Applications when opened from the download

A published build becomes two files made from one stapled app. `Varnick.dmg` is the download people are pointed at, at `https://github.com/Zabaca/varnick/releases/latest/download/Varnick.dmg`. `Varnick.zip` stays attached, so links to it keep working. The image opens on a window with Varnick, an arrow and a shortcut to Applications. `make app` builds it with dmgbuild, then signs, notarizes and staples it like the app. In the app, a copy macOS translocated, or one running straight off a disk image, offers Move to Applications instead of refusing to run. Move puts the app in /Applications, removes the download's quarantine from that copy after checking its signature, opens it and quits, ejecting the image. The user accepted this on 2026-10-10. The problem is in `docs/problems/downloaded-app-moved-by-hand/`; this records [option 01](../problems/downloaded-app-moved-by-hand/options/01-disk-image-and-move-to-applications.md), which has the detail.

This changes two things in ADR 0025:

- **Its DMG line** becomes "A DMG: added by ADR 0026, made with dmgbuild, since `hdiutil` alone can't write the window's layout".
- **The download link people are pointed at** is now the dmg's.

## Considered Options

- **`hdiutil` with a committed `.DS_Store`,** the "no new tool" ADR 0025 expected. The window's layout is that file, and only Finder or a tool like dmgbuild can make it, so every change would need one of them anyway. The file is binary, which makes it opaque in review. Its reference to the background may not resolve on a newly made image (inferred).
- **create-dmg, which scripts Finder.** Finder opens the window on screen, and fails while the Mac is locked. A release has already been built with the screen locked, and agents here never drive the screen.
- **appdmg.** It also writes the layout directly, but brings Node and a native module.
- **Only one of the two parts.** The image alone leaves today's refusal for anyone who double-clicks the app inside it, or uses the zip. The move alone keeps an install that isn't what people expect.
- **Leaving the quarantine on the moved copy.** macOS would translocate that copy again at its next open, because only a move by Finder clears that (Apple's documented behaviour, not checked here). The offer would then come back every time.
- **An administrator prompt when /Applications isn't writable:** no. The message says Finder will ask.

## Consequences

- **The Mac that makes the app needs uv.** dmgbuild and its two libraries are pinned to exact versions and run with `uvx`. Nothing of them ships.
- **Each release takes two notarizations,** the app's and then the image's.
- **Varnick removes a quarantine attribute, only from its own moved copy,** and only after checking that the copy's signature carries its own team and bundle id. Gatekeeper has already assessed that build, since it is the copy that is running.
- **The offer runs where the refusal ran:** before the migration, the lock, the peer link and the Phone page. It touches none of them, and never replaces a running copy.
- **Moving the app out of Downloads may make macOS ask for the Downloads folder** (inferred). A grant there would reach every pane session (ADR 0022).
- **The download links switch only after a release carries the image,** because `make app` builds only from main.
