---
title: The downloaded app has to be moved to Applications by hand
description: A published build is `Varnick.zip` (ADR 0025). A person unzips it and drags Varnick.app to Applications themselves, with nothing on screen showing them to. Most Mac apps arrive as a disk image whose window shows the app, an arrow and a shortcut to Applications. Opened straight from Downloads, Varnick runs from a temporary copy macOS makes of it (translocation), says "Move Varnick to Applications, then open it again" and quits. The person then has to find the app in Finder, move it and open it again. This meets every new user of the published build, and every update, since an update is the next download.
impact: A first launch that ends in a refusal, right after macOS's own "downloaded from the Internet" confirmation. Some people give up there. The rest spend three more steps in Finder before Varnick does anything.
severity: mid
evidence: Code as of 887d4a9, read on 2026-10-10. The latest release's assets, read with `gh` the same day. dmgbuild 1.6.7's source, read from its published wheel. The translocation calls in the Command Line Tools SDK's Security stubs. The tools present on the Mac that makes the app. Nothing was built, run or mounted.
status: closed
---

## What the user wants

An install that works the way other Mac apps do: a disk image whose window shows where to drag Varnick, and, for anyone who opens Varnick from the download anyway, an app that offers to move itself to Applications instead of refusing.

## Today

Verified at 887d4a9 unless marked.

- **What a release carries.** The latest release, v2026.10.10, published on 2026-10-10, has one asset: `Varnick.zip`. The README's Download link, the guide's Install section and both Download buttons on varnick.com point at `releases/latest/download/Varnick.zip`. So links to the zip are public from that release on.
- **What `make app` makes.** It builds and signs Varnick.app, notarizes and staples it, assesses it with Gatekeeper, and zips it as `Varnick.zip` with its SHA-256 beside it. With `CHECK_BUILD=1` it runs every step but the zip. There is no disk image.
- **What the app does when opened from the download.**
  - Archive Utility unzips into Downloads. Opening that copy, macOS asks for the usual "downloaded from the Internet" confirmation, then runs it from a translocated, read-only copy.
  - Varnick's start, in the app only, goes: the log, then the translocation test, then the rename's migration, then the account lock. The test is the executable's path containing `/AppTranslocation/`.
  - A translocated copy stops with an alert titled "Varnick can't start", saying "Move Varnick to Applications, then open it again", with one OK. It stops before the migration, the lock, the peer link and the Phone page, so none of them points at a path that is gone at the next launch.
- **A copy running straight off a disk image** isn't caught by that test unless macOS translocated it. Whether macOS translocates an app opened from a signed, notarized disk image is not known here (unverified). If it doesn't, such a copy would run, and its peer link would point at a volume that goes away when the image is ejected (inferred from the code).
- **Restart in the app** opens a new instance of the bundle (a new one even while this one runs) and ends the process at once. The new copy waits up to 15 s for the account lock. The lock's file records the holder's process id and executable path.
- **Nothing on the start's early path creates the support folder.** Working out its path creates nothing; the lock creates it, after the migration.
- **ADR 0025** lists a DMG as out of scope, and says one "can be added later with `hdiutil` and no new tool".

## Tools

Checked on the Mac that makes the app, on 2026-10-10.

- `hdiutil`, `tiffutil` and `SetFile` are present, and so are `uv` and `uvx`.
- **A disk image's window** (its background, icon positions, size and view) is a `.DS_Store` file on the image's volume. `hdiutil` makes, mounts and converts images, but writes no `.DS_Store`.
- **create-dmg**, the common shell script, sets the layout by scripting Finder: it opens the image's window on screen (inferred from its documented method, not run here). That fails while the Mac is locked, and the last release was built and notarized with the screen locked. Agents here never drive the screen.
- **dmgbuild 1.6.7** (MIT, current on PyPI on 2026-10-10) writes the `.DS_Store` and the background's reference itself, with two pure-Python libraries, `ds_store` 1.3.3 and `mac_alias` 2.2.3 (both MIT). Read in its source:
  - it runs only `hdiutil`, `SetFile`, `tiffutil` and `ditto`, and no Finder scripting;
  - it attaches the image it builds with `-nobrowse`, so Finder doesn't show it;
  - given `name.png` beside `name@2x.png`, it combines them into one Retina background with `tiffutil -cathidpicheck`;
  - besides Python settings files, it reads a JSON settings file in appdmg's format;
  - it doesn't sign the image.
- **Finding a translocated app's original location.** The Security framework exports `SecTranslocateIsTranslocatedURL` and `SecTranslocateCreateOriginalPathForURL` (listed in the SDK's Security stubs), but no public header in the SDK declares them. LetsMove, the well-known move-to-Applications library, looks them up at run time.

## Unverified

- That an app moved by anything other than Finder (a rename by the app itself, `mv`) is translocated again at its next open while it keeps its quarantine attribute. This is Apple's documented behaviour for translocation, and it is why LetsMove removes the attribute from the copy it moves.
- Whether an app opened from a signed and notarized disk image is translocated.
- Whether moving an app out of Downloads makes macOS ask whether the moving app may access the Downloads folder.
- Whether Finder draws a disk image window's icon labels in the system appearance's text colour whatever the background, which would make a light background unreadable in dark mode.
