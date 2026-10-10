#!/bin/sh
# Started detached by `make run`: stops every Varnick, including one hosting the session that
# ran make (pkill skips its own ancestors without -a, and with -a would kill make before the
# new instance starts), then starts the fresh build. Matches this repo's build by relative path
# (started by `make run`) or absolute path (started by the LaunchAgent from `make install`).
# Varnick's output is appended to ~/Library/Logs/Varnick.log, which is where its NSLog lines go (there, not to
# `log show`); when that file can't be opened it goes to /dev/null, so a log that can't be written never stops Varnick
# from starting. The peers' Restart runs this too (BuildUpgrade).
# Usage: restart.sh [database path]
# The path becomes VARNICK_DB only when it is given and not empty: Varnick takes an empty VARNICK_DB as the path itself, and with none
# it opens its default database (varnick.sqlite in its support folder).
cd "$(dirname "$0")/.." || exit 1
VARNICK="^($(pwd -P)/)?\.build/release/Varnick$"
# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md):
# a Launchy binary is stopped too, but by this checkout's absolute path only. A Launchy started by `make run` has the relative argv
# `.build/release/Launchy`, which would match from any checkout, and a Varnick worktree's restart would end the Mac's Launchy.
LAUNCHY="^$(pwd -P)/\.build/release/Launchy$"
LOG="$HOME/Library/Logs/Varnick.log"
SUPPORT="$HOME/Library/Application Support"
# A Mac still on Launchy reads Launchy.log, so a refusal goes there while Launchy's support folder is the one in use. An
# unrelated launcher is also called Launchy: the folder is ours only by what it holds (old-launchy-folder.sh).
if scripts/old-launchy-folder.sh "$SUPPORT/Launchy" && [ ! -e "$SUPPORT/Varnick" ]; then ON_LAUNCHY=yes; REFUSAL_LOG="$HOME/Library/Logs/Launchy.log"; else ON_LAUNCHY=no; REFUSAL_LOG="$LOG"; fi
# Short-lived, removed at the rename's Cleanup (same option): two refusals, before anything is stopped, each saying why in the log.
#  - With no Varnick to start, stopping would leave nothing running. That is the state of a checkout an old Upgrade fast-forwarded
#    and the status menu's or a peer's Restart (which run this with no build) reaches.
#  - While the Mac still runs Launchy, only the checkout Launchy ran from (it holds db/launchy.sqlite) may restart: Varnick started from
#    any other, say a worktree, would end every Launchy session and move its data.
# The cutover is the user's step, done from Terminal.app; an agent must stop and report this to the user.
refuse() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') restart refused: $1, and nothing was stopped. The cutover from Launchy is the user's step, done from Terminal.app (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md, \"Cutover: each Mac\"); an agent must stop here and report this to the user" >> "$REFUSAL_LOG" 2>/dev/null
  exit 1
}
[ -x .build/release/Varnick ] || refuse "$(pwd -P) has no .build/release/Varnick"
if [ "$ON_LAUNCHY" = yes ] && [ ! -f db/launchy.sqlite ]; then
  refuse "this Mac still runs Launchy and $(pwd -P) has no db/launchy.sqlite, so it isn't the checkout Launchy ran from"
fi
# A failed redirect on `exec` ends a non-interactive shell, so the log is tried in a subshell first.
if ! ( : >> "$LOG" ) 2>/dev/null; then LOG=/dev/null; fi
pkill -a -f "$VARNICK"
pkill -a -f "$LAUNCHY"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -a -f "$VARNICK" >/dev/null || pgrep -a -f "$LAUNCHY" >/dev/null || break
  sleep 1
done
if [ -n "$1" ]; then
  VARNICK_DB="$1" exec .build/release/Varnick >> "$LOG" 2>&1
fi
exec .build/release/Varnick >> "$LOG" 2>&1
