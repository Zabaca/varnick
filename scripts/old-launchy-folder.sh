#!/bin/sh
# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md).
# Usage: old-launchy-folder.sh <folder>. Exits 0 when the folder is our Launchy's support folder, 1 otherwise. An unrelated launcher is
# also called Launchy, so a folder named Launchy proves nothing; ours holds an entry that only our Launchy wrote. The Makefile and
# restart.sh call this; it is `OldLaunchy.isOurFolder` (Sources/Varnick/OldLaunchy.swift) in shell, and the two lists change together.
for name in sessions.json search-db-path launchy-peer peer.sock; do
  if [ -e "$1/$name" ] || [ -L "$1/$name" ]; then exit 0; fi
done
exit 1
