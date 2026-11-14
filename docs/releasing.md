# Releasing

How a **Published build** (CONTEXT.md) is made and put on GitHub Releases, by the maintainer, on the Mac that holds the
signing identity and the notary credential. Why it is shaped this way: ADR [0025](adr/0025-varnick-ships-as-a-notarized-app-beside-the-checkout-build.md)
and [0026](adr/0026-varnick-ships-on-a-disk-image-and-moves-itself-to-applications.md). `make app` never uploads; the steps from 4 on are by hand.

## 1. Before you start

- `main` is clean and pushed: `make app` refuses any other checkout unless `CHECK_BUILD=1`, and a check build is never published.
- `Makefile.local` holds the Developer ID Application identity and one notary credential, a keychain profile or an App Store Connect API
  key file; [`Makefile.local.example`](../Makefile.local.example) shows both. Use the key file when the screen is locked, because the
  keychain profile cannot be read then. Neither goes in a tracked file or a message.
- `uv` is on the PATH: the disk image is built with dmgbuild, which `uvx` runs.
- **Anthropic's legal agreements are read** (https://code.claude.com/docs/en/legal-and-compliance) before the first release that
  ships the Agent SDK, which `agent.js` in the app contains (ADR 0029; its licence is in `THIRD_PARTY_NOTICES.md`). Option 02 of
  `docs/problems/text-generation-ignores-the-claude-subscription/` is the way back if they don't allow it.
- `TextHelper/check.sh` passes against the build.

## 2. Build

```
make app
```

It builds, signs, notarizes and staples `Varnick.app`, zips it, then makes the disk image from that same app and notarizes and staples
that too. Each is assessed by `spctl` before the target succeeds. It leaves, in `.build/app/`:

- `Varnick.app`
- `Varnick.zip` and `Varnick.zip.sha256`
- `Varnick.dmg` and `Varnick.dmg.sha256`

`Varnick.app` carries `Zebkit.framework` (Chromium, ADR [0048](adr/0048-a-chromium-pane-embeds-zebkit-and-serves-cdp-so-a-session-can-drive-the-page-the-user-sees.md)) in `Contents/Frameworks`: about 144 MB on disk, and about 58 MB more to download (the framework zipped alone,
measured with `ditto` on 2026-11-13; the whole app zips to about 134 MB). `make app` signs it inside out with the secure timestamp, its helper with the hardened runtime and
`Zebkit.entitlements`, then the framework, then the app, as it does zmx and Bun. **The first notarization with the framework in the app has not been tried.** Try it before a release, from any checkout with no changes to tracked files, which sends the app (not the disk image) to Apple's notary service and publishes nothing:

```
make app CHECK_BUILD=1
```

If the notary service refuses the app, `notarytool`'s log names the file and the reason, and the target prints it; `Zebkit Helper` and `Zebkit` are the files to look for. Then check it by hand as step 3 says.

It ends by printing the version, build and commit. Both versions come from the commit's time in UTC, so the same commit always
makes the same numbers: `CFBundleShortVersionString` is `2026.10.10` (no leading zeros), `CFBundleVersion` is `20261010.1558`.

## 3. Check it like a download

A file straight off the build was never quarantined, so Gatekeeper judges it more kindly than it will judge a download. Quarantine a copy:

```
d=$(mktemp -d)
cp .build/app/Varnick.dmg "$d/"
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$d/Varnick.dmg"
spctl -a -vv -t open --context context:primary-signature "$d/Varnick.dmg"
mkdir "$d/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$d/mnt" "$d/Varnick.dmg"
spctl -a -vv -t exec "$d/mnt/Varnick.app"
hdiutil detach "$d/mnt"
rm -r "$d"
```

Both `spctl` lines must say `source=Notarized Developer ID`.

Then, with the checkout's Varnick quit (the account lock admits one), run that copy of the app and check Chromium, which no agent has run from a bundle:

- A Browser pane opens a page (a public address) with nothing from Gatekeeper or the keychain, and Resources or Activity Monitor lists a `Zebkit Helper` process whose path is inside `Varnick.app/Contents/Frameworks`.
- The page survives quitting the app and opening it again.
- A blank page, or a `Zebkit Helper` that exits at once, leaves a crash report in `~/Library/Logs/DiagnosticReports`. A signature or library-validation exit means the signing is wrong; an `mmap` or code-memory exit means `Zebkit.entitlements` needs `com.apple.security.cs.allow-unsigned-executable-memory` (add it only for that failure, with a comment); a `dyld` exit means the layout is wrong, which is a zebkit matter (ADR 0048, "Where the framework sits").
- `defaults write com.zabaca.varnick pagesInChromium -bool false` is the way out on a Mac where Chromium can't run: every page is WebKit's at the next launch.

Do not publish a build whose Chromium failed this check: a Browser pane would be blank for everyone, since Chromium is chosen wherever the framework is there.

## 4. Tag and publish

- **Tag:** `v` and the short version, `v2026.10.10`. A later release built from a commit of the same date takes `-2`, `-3`:
  `v2026.10.10-2`. `gh release list` shows what exists.
- **Title:** `Varnick <short version> (build <CFBundleVersion>)`.
- **Target:** the full SHA of the commit the app was built from (the commit the build printed), not `main`, which may have moved.
- **Notes**, in a file: what is new; how to install (open the dmg, drag Varnick to Applications); the requirements; how to update; that
  it is signed and notarized; the commit and build; the SHA-256 of `Varnick.dmg` and of `Varnick.zip`; and that Varnick is not affiliated
  with or endorsed by Anthropic. The latest release is the model: `gh release view <tag>`.

```
gh release create <tag> --repo Zabaca/varnick --target <full commit> --title "<title>" --notes-file <notes> --latest \
  .build/app/Varnick.dmg .build/app/Varnick.dmg.sha256 .build/app/Varnick.zip .build/app/Varnick.zip.sha256
```

## 5. Verify the links

`releases/latest/download/Varnick.dmg` and `releases/latest/download/Varnick.zip` (under `https://github.com/Zabaca/varnick/`) must answer
200, and the SHA-256 of the dmg downloaded from the link must match the one in the notes:

```
curl -sIL -o /dev/null -w '%{http_code}\n' https://github.com/Zabaca/varnick/releases/latest/download/Varnick.zip
curl -sL https://github.com/Zabaca/varnick/releases/latest/download/Varnick.dmg | shasum -a 256
```

## 6. When a downloaded file's name changes

Update the Download buttons on varnick.com (`site/`, deployed as [`site/README.md`](../site/README.md) says), the README and
[`guide.md`](guide.md) only once a release carries the new name: the links point at the latest release, so a button that names a file
it lacks is a 404 (ADR 0026 kept `Varnick.zip` attached for this reason).
