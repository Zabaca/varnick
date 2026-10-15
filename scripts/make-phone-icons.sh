#!/bin/sh
# Draws the Phone page's icons from scripts/phone-icons/*.svg into PhonePage/page/icons/: the Fold (Sources/Varnick/FoldMark.swift) in
# the accent on the page's light ground, and for the maskable one smaller, inside the 80% safe circle. Needs rsvg-convert
# (`brew install librsvg`). Run it only to change an icon: the PNGs are committed, and `bun test` checks them against
# PhonePage/page/icons/DIGESTS, which this script rewrites.
set -eu
cd "$(dirname "$0")/.."
out=PhonePage/page/icons
mkdir -p "$out"
rsvg-convert -w 180 -h 180 scripts/phone-icons/fold-any.svg -o "$out/apple-touch-icon.png"
rsvg-convert -w 192 -h 192 scripts/phone-icons/fold-any.svg -o "$out/icon-192.png"
rsvg-convert -w 512 -h 512 scripts/phone-icons/fold-any.svg -o "$out/icon-512.png"
rsvg-convert -w 512 -h 512 scripts/phone-icons/fold-maskable.svg -o "$out/icon-maskable-512.png"
{
  echo "# sha256 of the Phone page's icons, made by scripts/make-phone-icons.sh from scripts/phone-icons/*.svg (the Fold mark)."
  echo "# That script rewrites this file; \`bun test\` checks every PNG here against its line, and that no PNG is missing from it."
  (cd "$out" && shasum -a 256 -- *.png)
} > "$out/DIGESTS"
