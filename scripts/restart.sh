#!/bin/sh
# Started detached by `make run`: stops every Launchy, including one hosting the session that
# ran make (pkill skips its own ancestors without -a, and with -a would kill make before the
# new instance starts), then starts the fresh build. Matches this repo's build by relative path
# (started by `make run`) or absolute path (started by the LaunchAgent from `make install`).
# Usage: restart.sh <database path>
cd "$(dirname "$0")/.." || exit 1
LAUNCHY="^($(pwd -P)/)?\.build/release/Launchy$"
pkill -a -f "$LAUNCHY"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -a -f "$LAUNCHY" >/dev/null || break
  sleep 1
done
LAUNCHY_DB="$1" exec .build/release/Launchy >/dev/null 2>&1
