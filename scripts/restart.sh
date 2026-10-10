#!/bin/sh
# Started detached by `make run`: stops every Varnick, including one hosting the session that
# ran make (pkill skips its own ancestors without -a, and with -a would kill make before the
# new instance starts), then starts the fresh build. Matches this repo's build by relative path
# (started by `make run`) or absolute path (started by the LaunchAgent from `make install`).
# Varnick's output is appended to ~/Library/Logs/Varnick.log, which is where its NSLog lines go (there, not to
# `log show`); when that file can't be opened it goes to /dev/null, so a log that can't be written never stops Varnick
# from starting. The peers' Restart runs this too (BuildUpgrade).
# Usage: restart.sh <database path>
cd "$(dirname "$0")/.." || exit 1
VARNICK="^($(pwd -P)/)?\.build/release/Varnick$"
# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): a Launchy binary is stopped too, matched the same anchored way.
LAUNCHY="^($(pwd -P)/)?\.build/release/Launchy$"
LOG="$HOME/Library/Logs/Varnick.log"
# A failed redirect on `exec` ends a non-interactive shell, so the log is tried in a subshell first.
if ! ( : >> "$LOG" ) 2>/dev/null; then LOG=/dev/null; fi
# Short-lived, removed at the rename's Cleanup (docs/problems/name-taken-by-another-launcher/options/01-rename-on-one-branch-and-let-varnick-move-its-own-data.md): with no Varnick to start, stopping would leave nothing running. That is the state of a
# checkout an old Upgrade fast-forwarded and the status menu's or a peer's Restart (which run this with no build) reaches. Nothing is
# stopped, and the log says why.
if [ ! -x .build/release/Varnick ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') restart refused: $(pwd -P) has no .build/release/Varnick (a Mac still on Launchy is cut over by hand, from a terminal: docs/problems/name-taken-by-another-launcher, option 01, \"Cutover: each Mac\"), and nothing was stopped" >> "$LOG" 2>/dev/null
  exit 1
fi
pkill -a -f "$VARNICK"
pkill -a -f "$LAUNCHY"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -a -f "$VARNICK" >/dev/null || pgrep -a -f "$LAUNCHY" >/dev/null || break
  sleep 1
done
VARNICK_DB="$1" exec .build/release/Varnick >> "$LOG" 2>&1
