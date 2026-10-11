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
