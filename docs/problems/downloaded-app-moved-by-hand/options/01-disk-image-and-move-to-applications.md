---
problem: downloaded-app-moved-by-hand
title: A disk image with an install window, and a Move to Applications offer in the app
summary: Accepted on 2026-10-10 ("do both"). `make app` also makes Varnick.dmg from the same stapled app. Its window shows Varnick, an arrow on a background with the Fold, and a shortcut to Applications. dmgbuild writes the window's layout, pinned and run with uvx on the maintainer's Mac, so no Finder window opens and nothing of it ships. The image is signed, notarized and stapled. A release carries the dmg as the download people are pointed at, and keeps the zip so its links work. In the app, a copy macOS translocated, or one running straight off a disk image, offers Move to Applications and Quit instead of refusing. Move puts it in /Applications, replacing an older copy only once that has quit. It removes the download's quarantine from the moved copy after checking its signature, opens it, quits, and ejects the image. Where it can't move, the app falls back to today's message with the reason. Rough effort is three and a half days, plus an hour of the user's time for the hand test.
status: accepted
---

## Solution

Accepted by the user on 2026-10-10 ("do both"), relayed by the coordinator. ADR 0026 records it.

Two parts, each useful alone:

1. **A disk image with an install window.** `make app` makes `Varnick.dmg` beside `Varnick.zip`, from the same stapled app. Opened, the image shows one window. Varnick sits on the left and a shortcut to Applications on the right, with an arrow between them on a background that carries the Fold. The person drags Varnick across, as with most Mac apps. The image is signed with the Developer ID, notarized and stapled, like the app. A release carries both files. The README, the guide and varnick.com point people at the dmg, and the zip's link keeps working.
2. **Move to Applications in the app.** Today Varnick refuses to run as a copy macOS translocated, which is what opening it from Downloads gives. Instead, it offers to move itself: Move to Applications, or Quit. The same offer now also covers a copy running straight off a disk image, which today runs and points its peer link at a volume that goes away. Move puts Varnick in /Applications, opens the moved copy and quits; from a disk image, it ejects the image too. When it can't move, it falls back to today's message with the reason. That happens when Applications isn't writable for this account, or the call that finds the original location fails.

## Trade-offs

- **A familiar install.** The image's window says what to do, with no text to read.
- **No refusal on the first launch.** Someone who opens the downloaded app (from the zip, or by double-clicking it inside the image's window) gets one button instead of a trip to Finder.
- **One new tool, for the maintainer only.** dmgbuild writes the window's layout, which `hdiutil` can't. It is pinned with its two libraries, run with `uvx` on the Mac that makes the app, and nothing of it ships. That reverses ADR 0025's "no new tool" for a DMG.
- **Two notarizations per release.** First the app's, as today, then the image's. Each usually takes minutes.
- **The app removes the download's quarantine from its moved copy.** Without that, macOS would translocate the moved copy again at its next open, and the offer would come back. Only a move by Finder clears that state. Varnick checks the moved copy's signature first, and does what LetsMove does.
- **Maybe one more prompt.** Moving the app out of Downloads may make macOS ask whether Varnick can access the Downloads folder (inferred). A grant would reach every pane session, since pane processes share Varnick's permissions (ADR 0022). See Open questions in Further Notes.
- **The download links switch after a release.** `make app` builds only from main, so the code merges before the first image exists. The README, the guide and the site point at the dmg only once a release carries one.
- **Publishing stays by hand,** with four files instead of two.

## User Stories

1. As a person new to Varnick, I want the download to open on a window that shows me to drag Varnick to Applications, so that I install it the way I install other Mac apps.
2. As a person new to Varnick, I want the disk image to open without a security warning, so that I trust it.
3. As a person who opened Varnick straight from Downloads, I want it to offer to move itself to Applications, so that my first launch doesn't end in a refusal.
4. As a person who double-clicked Varnick inside the disk image's window, I want the same offer, and the image ejected once Varnick has moved.
5. As a person updating, I want the offer to replace the older Varnick in Applications once I've quit it, and to tell me to quit it while it still runs.
6. As a person on an account that can't add apps to Applications, I want to be told so, and that Finder will ask for an administrator, so that I know what to do.
7. As a person who chooses Quit, I want nothing moved or changed.
8. As a person, I want the moved copy to open later from Finder, Spotlight or Login Items as an ordinary app, with no offer and no temporary copy.
9. As a person with a link to Varnick.zip, I want it to keep working.
10. As the user, I want `make app` to make both files from one stapled app. I want its check build to leave neither file looking publishable.
11. As the user, I want the image built with no Finder window, so that it builds with the screen locked and no agent drives the screen.
12. As the user, I want the image's window to come from one readable, committed layout and the mark's one drawing in code, so that a change to it is a text edit.

## Implementation Decisions

**The disk image: the tool**
- **dmgbuild 1.6.7,** with `ds_store` 1.3.3 and `mac_alias` 2.2.3. All three are pinned to exact versions, current on PyPI on 2026-10-10. `make app` runs them through `uvx`. They are MIT and pure Python; the badge-icon extra, which needs PyObjC, isn't used.
- **Why it.** It writes the `.DS_Store` and the background's reference itself. It runs only `hdiutil`, `SetFile`, `tiffutil` and `ditto`, and attaches its working image with `-nobrowse`. Nothing appears on screen, and it works with the screen locked (all read in 1.6.7's source, not run). Further Notes weighs the alternatives.
- `make app` gains one refusal: no `uvx` on the PATH is an `error:` line naming it, before the build. The Mac that makes the app had uv on 2026-10-10.
- Nothing of dmgbuild goes into the image, so the licence notices don't change.

**The disk image: the layout**
- **One committed settings file,** in the JSON form dmgbuild reads (appdmg's format). It is data, not code, and is read from the checkout root, where `make` runs, so its paths point into the build folder.
- **The volume** is named "Varnick", and its icon is the app's icon file.
- **The window** is 640 by 400 points, with no toolbar, sidebar or status bar.
  - The icons are 128 points.
  - Varnick is centred in the left third and the Applications shortcut in the right third, at one height: about (160, 190) and (480, 190). The builder moves both so the arrow sits between them.
  - Varnick.app's extension is not hidden, which the build found it can't be: dmgbuild hides it by writing Finder information onto the bundle, and a strict signature check (Varnick's own, on the copy it moves) rejects that. See where-it-breaks, Signing, the disk image.
- **The format** is compressed with lzfse (ULFO, readable on macOS 14) on HFS+, dmgbuild's default file system for a JSON layout.

**The disk image: the background**
- **Drawn at build time, as the icon is.** A small script, compiled with the app's own drawing of the mark, writes the background at 640×400 and 1280×800 pixels as `name.png` and `name@2x.png`. dmgbuild combines the two into one Retina background. The mark then still has one source, in code, and the background is never committed.
- **What it shows:** the Fold, small, above the middle, and an arrow from Varnick's place to the shortcut's. No words.
- **The ground is a mid tone,** so the icon labels read whether Finder draws them black or white. Finder appears to pick the label colour from the system appearance, not the background (inferred). The hand test checks both appearances.

**`make app`**
1. Up to the Gatekeeper assessment of the stapled app, it is unchanged.
2. **The zip, as today.** It stays, because links to it are public since the release of 2026-10-10.
3. **The image,** from the same stapled app, by dmgbuild with the layout and the background.
4. **Signing.** The image is signed with the Developer ID identity and a secure timestamp, with no hardened runtime, which is for code. The identity is chosen as the app's is, and the lines that name it stay silent, as the existing ones do.
5. **Notarizing.** The image is submitted to the notary service, and `make app` waits. Anything but Accepted prints the notary log and fails, as for the app.
6. **Stapling.** The ticket is stapled to the image and validated. Gatekeeper then assesses the image as a disk image to open, and must answer that it is notarized.
7. **The published files.** The image's SHA-256 is written beside it. The name is fixed, `Varnick.dmg`, so the latest release's link never changes. Then the version pair and the commit are printed, as today.
- **`CHECK_BUILD=1`** builds the image under a name that isn't the published one, signs it and verifies its signature. It also runs `hdiutil verify` on it. It stops before sending the image to the notary service, and writes neither `Varnick.zip` nor `Varnick.dmg`. The app is still notarized in a check, as today. The first image notarization is therefore the first real `make app`.

**Publishing** (the user's step)
- The release carries `Varnick.dmg` and `Varnick.zip`, each with its SHA-256 file. Its notes point at the dmg.

**Move to Applications: when it's offered**
- **In the app only,** at the place in the start where the translocated copy now stops. That is after the log, and before the migration, the lock, the peer link and the Phone page.
- Like today's refusal, nothing in it reads settings, the support folder or the database, or creates the support folder, and it saves nothing.
- **It is offered when:**
  - macOS translocated the app (today's test, unchanged); or
  - the app runs straight off an attached disk image. This is new: the bundle is under /Volumes, and that volume is in the system's list of attached images (`hdiutil info`, as LetsMove reads it). The list is consulted only for a bundle under /Volumes. It is unknown whether macOS translocates an app opened from a signed, notarized image, so both cases are covered.
- **Anywhere else, the app runs as today,** keeping option 02's "from any folder": ~/Applications, the Desktop, or a copy the person moved into Downloads with Finder. A bundle on an external disk or a network volume is not an image, so it runs too.

**Move to Applications: the offer**
- **An alert,** a sibling of the start's refusal alert, with the app's icon.
  - It is titled "Move Varnick to Applications?".
  - It adds one line on why. Varnick is running from a temporary copy, or from the disk image. Peers and the Phone page need it where it will be at the next launch.
  - Its buttons are **Move to Applications** (the default) and **Quit**.
  - There is no "don't ask again", which would be a saved setting.
- **Quit** writes today's line to the log and exits as the refusal does, with no second alert.

**Move to Applications: the original and the target**
- **The original of a translocated app** comes from the Security framework's translocation call, `SecTranslocateCreateOriginalPathForURL`, as LetsMove finds it. Security exports it, but no public header declares it (both checked in the SDK on 2026-10-10). So Varnick declares it and looks it up at run time. If it is missing, or fails, the offer falls back to today's message.
- **The original of an untranslocated app** is its bundle.
- **The target** is always /Applications/Varnick.app, whatever the original is called. A second download unzips as "Varnick 2.app".

**Move to Applications: checks before the move**

These run in this order. Each stop shows today's message, followed by the reason, unless stated otherwise.
1. **/Applications isn't writable by this account** (a standard account). The message says this account can't add apps to Applications, and that Finder will ask for an administrator. Varnick shows no administrator prompt of its own.
2. **A Varnick runs in this account,** which means the account lock is held.
   - The test makes one non-blocking attempt, released at once. It never creates the lock file or the support folder; a missing lock file means none runs.
   - The offer then shows again, saying "Varnick is already running from <path>. Quit it from its menu bar menu, then choose Move to Applications." Pressing Move checks again.
   - This covers an update, where the copy in Applications is running. It also covers a checkout's Varnick, which would make the lock refuse the moved copy anyway. So a running copy is never replaced.
   - Another account running the copy in /Applications isn't seen, because the lock is per account. That is the same as replacing the app by hand in Finder.
3. **Something other than Varnick is at the target,** with a bundle id other than Varnick's. The stop names it.
4. **The original already is the target.** This happens when a copy was moved with a tool other than Finder, so it is still quarantined and gets translocated. Then there is nothing to move, and the steps run from the quarantine step on.

**Move to Applications: the move**
- **On the same volume as /Applications** (Downloads, the Desktop), the original is moved by rename, so nothing is left behind. The zip it came out of stays where it is.
- **On another volume** (a disk image, an external disk), the original is copied, and left where it is.
- **The order of the steps:**
  1. The new copy lands in /Applications under a hidden temporary name.
  2. Only then does an existing Varnick.app go to the Trash, where it can be recovered.
  3. The new copy is renamed into place.

  A failure before the Trash step leaves what was there untouched. A failure after it says the previous copy is in the Trash.
- **Quarantine.**
  - **Why remove it.** macOS keeps translocating a quarantined app at each open until Finder moves it, and a move by Varnick doesn't count (Apple's documented behaviour; the hand test checks it). So Varnick removes the quarantine attribute from the moved copy and everything in it, as LetsMove does.
  - **Only after a signature check.** The moved copy's signature must be valid, and carry the running copy's own team and bundle id. Both are read from the running copy's own signature, so no team ID is written anywhere.
  - **A failed check** leaves the attribute and stops with today's message.
  - **Gatekeeper has already assessed this build.** The running copy is the notarized, stapled app, and the person chose to open it.
- **Opening the moved copy** works as Restart works in the app. Varnick opens a new instance of the bundle, a new one even though this one runs, then ends this process.
  - The old copy took no lock and made no migration, peer link or Phone page, so the new one has nothing to wait for. The lock would still hold it back if it had.
  - The log gets one line saying Varnick moved itself to Applications.
- **The disk image** is ejected after the old copy has exited, since that copy's executable is on the image.
  - Before quitting, Varnick starts a small detached helper. The helper waits for Varnick's process to end, then detaches the image by the device the system's list names.
  - The detach is never forced. If something else holds the image, it stays mounted and the person ejects it.

**Move to Applications: where the code sits**
- The decision and the file steps are Foundation only, plus Security for its two calls. They take every place as a parameter: the target folder, the Trash, the support folder, the list of attached images. A harness compiles them alone, as it does the installed app's other start pieces.
- The alert sits beside the refusal's alert.
- No saved state changes: no new setting, no UserDefaults key, nothing in the sessions file.

**Docs**

With the code, on the branch:
- **where-it-breaks › The installed app:**
  - the start's order becomes the log, the move offer, the migration, the lock;
  - what the offer may not read or create;
  - the image test;
  - the run-time lookup of the translocation call;
  - the quarantine removal and its signature check;
  - the new instance it opens;
  - the eject helper.
- **where-it-breaks › Signing:**
  - the image's signing, notarization and stapling;
  - what the check build does with it;
  - dmgbuild's pins.
- **CONTRIBUTING's `make app` line:** both files, and that it needs uv.
- **ADR 0025's pointer:**
  - its DMG line becomes "A DMG: added by ADR 0026, made with dmgbuild, since `hdiutil` alone can't write the window's layout";
  - its first paragraph adds that the download people are pointed at is the dmg (ADR 0026), and that the zip's link keeps working.
- **privacy-and-security:** the app removes the download's quarantine from its own moved copy after checking that copy's signature. If the hand test shows the Downloads prompt, the page also says what that grant reaches.

After the first release that carries `Varnick.dmg` (before it, the links would fail), in one docs-only change:
- **The README:**
  - the Download link goes to `releases/latest/download/Varnick.dmg`;
  - Install says to open Varnick.dmg, drag Varnick to Applications and open it, or to open the downloaded app and choose Move to Applications;
  - updating says to quit Varnick, then do the same with the newest download, which replaces the old copy.
- **The guide's Install and update:** the same, with the zip as the alternative, and the offer where the refusal was described.
- **varnick.com:** both Download buttons point at the dmg, then the site's usual deploy.

## Testing Decisions

There is no test target, and `make build` must still pass on a Mac without the identity. Agents never run the app's binary, never open the image in Finder, and never touch the real /Applications, Trash, Downloads or support folder (where-it-breaks › Checking by hand, and the installed app's notes).

- **The image, by `make app CHECK_BUILD=1`.** Afterwards, the builder attaches the check image read-only with `-nobrowse` at a temporary mount point, so nothing shows in Finder. Then it checks:
  - Varnick.app is there, beside a link to /Applications;
  - the background holds two representations (`tiffutil -info`);
  - the layout file and the volume icon are present;
  - the app inside passes `codesign --verify --deep --strict` and `stapler validate`.

  Then it detaches the image. The layout can be read back with the `ds_store` library, to confirm the icon positions and the window's size.
- **The move's pieces,** by a harness compiled alone with `swiftc`, on temporary folders standing in for /Applications, the Trash and the support folder:
  - **The move.**
    - A same-volume original is moved, and nothing is left.
    - An original marked as on another volume is copied, and left.
    - An existing Varnick at the target ends up in the stand-in Trash, with the new one in place.
    - A failure injected before the Trash step leaves the old one untouched.
  - **The checks.**
    - A bundle with another id at the target stops the move.
    - A target folder made unwritable gives the account's message.
  - **The lock.**
    - A harness process holding the lock (as the lock's own check does it) gives "already running from" and its path.
    - With no lock file, the move goes ahead, and afterwards no lock file or folder exists.
  - **Quarantine.**
    - A copy of the signed app from the build folder is put in a temporary folder and given a quarantine attribute with `xattr`. After the step, the attribute is gone.
    - The same with one byte of its executable changed: the signature check fails, and the attribute stays.
  - **The image test.**
    - A small blank image made with `hdiutil` and attached with `-nobrowse` at a temporary mount point is recognised as an image, and then detached.
    - A plain folder isn't.
  - **The translocation lookup** needs a translocated app, so only the hand test covers it.
- **The user's hand test,** with a real download, so the files are quarantined. Get them through a browser from a draft release, whose files the repository's owner can download (inferred), or by AirDrop from the Mac that made them. Use another Mac, or a fresh user account, with no Varnick in Applications:
  1. **The image's window.** Open `Varnick.dmg` from Downloads.
     - There is no security warning.
     - The window shows the background with the Fold and the arrow, and the two icons in place.
     - The window is sized to the background, and it is sharp on a Retina screen.
     - The labels read in both light and dark appearance.
     - The volume shows the Fold.
  2. **Drag to Applications.** Drag Varnick to Applications and open it from there. macOS shows at most its "downloaded from the Internet" confirmation, then Varnick runs. Quit it, then move it to the Trash.
  3. **Quit on the offer.** Double-click Varnick inside the image's window. The offer appears. Press Quit: nothing moved, and the log has today's line.
  4. **Move from the image.** Open it again and press Move to Applications.
     - Varnick is in Applications, running from there, and the log says it moved.
     - The image is ejected.
     - macOS asks nothing more.
  5. **Reopen.** Quit Varnick, then open it from Applications in Finder. It opens with no offer, so it wasn't translocated again.
  6. **Update from the zip.** Download `Varnick.zip` and let Archive Utility unzip it in Downloads.
     - With Varnick running from Applications, open the downloaded app and press Move. It says Varnick is already running from Applications.
     - Quit Varnick from its menu bar, then press Move again. Varnick.app is gone from Downloads, the previous copy is in the Trash, and the new one runs.
     - Note whether macOS asked about access to the Downloads folder.
  7. **Open at login.** If Open at login was on before the replace, Settings still shows it on.
  8. **A standard account.** On a non-administrator account, open the downloaded app and press Move. The message says this account can't add apps to Applications.
  9. **A locked screen.** The next real `make app` runs with the screen locked, as the last one did.

## Out of Scope

- An administrator prompt to move into /Applications, and offering ~/Applications to a standard account.
- Moving an app that runs from any other folder (~/Applications, the Desktop, an external disk). Option 02's "from any folder" stands.
- Deleting the zip or the image file from Downloads.
- Replacing a copy that another account is running from /Applications.
- A licence agreement shown when the image opens, a Homebrew cask, and Intel Macs.
- Updates from inside the app (runs-only-from-a-checkout, options 03 and 04).
- Dropping the zip.

## Further Notes

- **Accepted on 2026-10-10** by the user ("do both"), relayed by the coordinator. ADR 0026 records the image, the tool and the move, and what they change in ADR 0025.
- **The tools weighed for the window's layout:**
  - **dmgbuild (chosen).** It writes the layout itself, with nothing on screen, and builds from a readable settings file. It costs a pinned Python tool on the maintainer's Mac.
  - **`hdiutil` plus a committed `.DS_Store`.** There is no new tool, but:
    - the file is binary, opaque in review, and only Finder (a window on screen, by hand or scripted) or a tool such as dmgbuild can make it, so the first one and every change need one of them anyway;
    - its background reference is an alias to a file on the volume it was made on, which Finder may fail to resolve on a new image (inferred), leaving a plain window.
  - **create-dmg (the shell script).** It scripts Finder, which opens windows on screen and fails while the Mac is locked. The last release was built and notarized with the screen locked, and agents here never drive the screen.
  - **appdmg (Node).** It also writes the layout itself, but brings Node and a native module to build.
- **ADR 0025's line** "a DMG can be added later with `hdiutil` and no new tool" becomes "A DMG: added by ADR 0026, made with dmgbuild, since `hdiutil` alone can't write the window's layout". `hdiutil` still makes the image under dmgbuild.
- **Open questions, each with the recommendation:**
  - **The Downloads prompt.** If the hand test shows macOS asking for access to the Downloads folder, copy from the running copy instead of moving the original, and leave the original in Downloads. A grant would reach every pane session. Moving it was the user's lean ("none left behind"), so this is the user's call after the test.
  - **The zip.** Keep it. Revisit only when nothing links to it.
- **Verified on 2026-10-10 at 887d4a9:**
  - the latest release and its one asset;
  - the translocation stop and its place in the start;
  - Restart's new instance in the app;
  - what the lock's file holds;
  - that working out the support folder's path creates nothing;
  - dmgbuild 1.6.7's calls, attach flags, Retina handling and JSON settings;
  - the translocation calls in the SDK's stubs, with no public header;
  - `uv`, `hdiutil`, `tiffutil` and `SetFile` on the Mac that makes the app.
- **Inferred, not checked:**
  - that a non-Finder move leaves the moved copy translocated;
  - whether an app on a signed image is translocated;
  - the Downloads prompt;
  - Finder's label colour;
  - that the quarantine comes along when the app is copied off the image;
  - that replacing a copy signed by the same team raises no App Management prompt;
  - that a detach right after the old copy exits succeeds while macOS still holds a translocation mount on the image.
- **Rough effort:**
  - the image: about a day (the layout, the background script, the `make app` steps, the first image notarization);
  - the move: about two days (the offer, the lookup, the file steps, the quarantine step and its check, the eject helper, the harness);
  - docs: half a day, in two parts;
  - the user's hand test: about an hour.
- **A likely split for `/to-tickets`:**
  1. The image in `make app` (AFK).
  2. The move offer (AFK).
  3. Docs with the code (AFK, after 1 and 2).
  4. The hand test and the first release with the dmg (the user, after the merge).
  5. The links and the install docs (AFK, after 4).
