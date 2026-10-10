#!/bin/bash
# Copies the catalog (apps/) to the folder given, replacing what is there: next to the binary for `make build`, and into the bundle's
# Resources for `make app`. In a checkout only tracked files go, so a release carries committed files and nothing a working tree
# happens to hold (an untracked file, a scratch copy); a tracked file deleted but not yet committed is skipped. Never node_modules
# (Scratch's hold unsigned native binaries that notarization would reject) or .DS_Store. A folder that isn't a checkout copies all
# of apps/.
#
# The folder must be an absolute path to a folder named `apps`, since this script removes it before it copies and changes to the
# checkout's root first: a relative path would mean something else after that.
set -eu
dest=${1:?usage: copy-catalog.sh <absolute path to a folder named apps>}
case $dest in
  /*/apps) ;;
  *) echo "error: copy-catalog: $dest is not an absolute path to a folder named apps" >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."
rm -rf "$dest"
mkdir -p "$dest"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C apps ls-files -z | while IFS= read -r -d '' file; do
    if [ -e "apps/$file" ] || [ -L "apps/$file" ]; then printf '%s\0' "$file"; fi
  done | rsync -a --from0 --files-from=- --exclude 'node_modules' --exclude '.DS_Store' apps/ "$dest/"
else
  rsync -a --exclude 'node_modules' --exclude '.DS_Store' apps/ "$dest/"
fi
