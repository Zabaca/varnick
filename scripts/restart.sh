#!/bin/sh
# Started detached by `make run`: stops every Launchy, including one hosting the session that
# ran make (pkill skips its own ancestors without -a, and with -a would kill make before the
# new instance starts), then starts the fresh build. Matches this repo's build by relative path
# (started by `make run`) or absolute path (started by the LaunchAgent from `make install`).
# Launchy's output is appended to ~/Library/Logs/Launchy.log, which is where its NSLog lines go (there, not to
# `log show`); when that file can't be opened it goes to /dev/null, so a log that can't be written never stops Launchy
# from starting. The peers' Restart runs this too (BuildUpgrade).
# Usage: restart.sh <database path>
cd "$(dirname "$0")/.." || exit 1
LAUNCHY="^($(pwd -P)/)?\.build/release/Launchy$"
pkill -a -f "$LAUNCHY"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -a -f "$LAUNCHY" >/dev/null || break
  sleep 1
done
LOG="$HOME/Library/Logs/Launchy.log"
# A failed redirect on `exec` ends a non-interactive shell, so the log is tried in a subshell first.
if ! ( : >> "$LOG" ) 2>/dev/null; then LOG=/dev/null; fi
LAUNCHY_DB="$1" exec .build/release/Launchy >> "$LOG" 2>&1
