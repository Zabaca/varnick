#!/bin/sh
# Copies the catalog (apps/) to the folder given, replacing what is there: next to the binary for `make build`, and into the bundle's
# Resources for `make app`. In a checkout only tracked files go, so a release carries committed files and nothing a working tree
# happens to hold (an untracked file, a scratch copy). Never node_modules (Scratch's hold unsigned native binaries that notarization
# would reject) or .DS_Store. A folder that isn't a checkout copies all of apps/.
set -eu
cd "$(dirname "$0")/.."
dest=${1:?usage: copy-catalog.sh <folder>}
rm -rf "$dest"
mkdir -p "$dest"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C apps ls-files -z | rsync -a --from0 --files-from=- --exclude 'node_modules' --exclude '.DS_Store' apps/ "$dest/"
else
  rsync -a --exclude 'node_modules' --exclude '.DS_Store' apps/ "$dest/"
fi
