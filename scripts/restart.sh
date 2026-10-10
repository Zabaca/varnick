#!/bin/sh
# Started detached by `make run`: stops every Varnick, including one hosting the session that
# ran make (pkill skips its own ancestors without -a, and with -a would kill make before the
# new instance starts), then starts the fresh build. Matches this repo's build by relative path
# (started by `make run`) or absolute path (started by the LaunchAgent from `make install`).
# Varnick's output is appended to ~/Library/Logs/Varnick.log, which is where its NSLog lines go (there, not to
# `log show`); when that file can't be opened it goes to /dev/null, so a log that can't be written never stops Varnick
# from starting. The peers' Restart runs this too (BuildUpgrade).
# Varnick is started by launchd, never as a child of whatever ran this script: macOS makes a process's TCC "responsible process"
# (whose Accessibility, Screen Recording and microphone grants it uses, and whose name its prompts show) the one that started it, and
# a Varnick started from a terminal such as cmux got cmux's grants and none of its own (measured 2026-10-10; the chain stays rooted
# there through every restart Varnick does of itself). A job launchd spawns is its own responsible process. So: with this checkout's
# LaunchAgent (`make install`) loaded, `launchctl kickstart` of it (no -k: only after this script has stopped every Varnick of the
# checkout, so it can't start a second one); else a transient job bootstrapped from the same plist template under a label of its own;
# only when launchd refuses both, the direct start of old, which says so in the log. Where-it-breaks, Signing, has the rest.
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
# Which launchd job starts Varnick. AGENT_LABEL is the Makefile's LABEL. The transient job is named by this checkout's path, so one
# checkout's restart never removes another's.
ROOT=$(pwd -P)
BINARY="$ROOT/.build/release/Varnick"
DOMAIN="gui/$(id -u)"
AGENT_LABEL=com.zabaca.varnick
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
JOB_LABEL="$AGENT_LABEL.run.$(printf %s "$ROOT" | cksum | cut -d' ' -f1)"
note() { echo "$(date '+%Y-%m-%d %H:%M:%S') restart: $1" >> "$LOG" 2>/dev/null; }
# What still runs after the wait above, normally nothing: a start counts only for a process that wasn't there before it.
BEFORE=$(pgrep -a -f "$VARNICK" | tr '\n' ' ')
started() {
  for pid in $(pgrep -a -f "$VARNICK"); do
    case " $BEFORE " in *" $pid "*) ;; *) return 0 ;; esac
  done
  return 1
}
# The LaunchAgent counts when its plist runs this checkout's binary and the job is loaded. It sets no VARNICK_DB, so it can start
# only a Varnick that opens the default database, which is what the menu's Restart passes when that is the one open.
agent_fits() {
  [ -f "$AGENT_PLIST" ] || return 1
  [ "$(plutil -extract ProgramArguments.0 raw -o - "$AGENT_PLIST" 2>/dev/null)" = "$BINARY" ] || return 1
  [ -z "$1" ] || [ "$1" = "$SUPPORT/Varnick/varnick.sqlite" ] || return 1
  launchctl print "$DOMAIN/$AGENT_LABEL" >/dev/null 2>&1
}
# A kickstart does nothing while the job still counts as running, which a Varnick that has just been stopped may for a moment, so it is
# repeated until a new process shows.
start_agent() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    launchctl kickstart "$DOMAIN/$AGENT_LABEL" >/dev/null 2>&1 || return 1
    sleep 1
    started && return 0
  done
  return 1
}
# The job's plist is the LaunchAgent's own template, so Varnick runs the same way however it was started: launchd's environment (not
# the terminal's), this folder as its working folder, the same log. The plist is read once by bootstrap and then removed. A job left
# from an earlier restart is removed first (it holds nothing: Varnick was stopped above), since bootstrap refuses a label already loaded.
start_job() {
  dir=$(mktemp -d "${TMPDIR:-/tmp}/varnick-run.XXXXXX") || return 1
  plist="$dir/$JOB_LABEL.plist"
  sed -e "s|@LABEL@|$JOB_LABEL|g" -e "s|@ROOT@|$ROOT|g" -e "s|@LOG@|$LOG|g" scripts/varnick.plist.in > "$plist" || { rm -rf "$dir"; return 1; }
  if [ -n "$1" ]; then
    plutil -insert EnvironmentVariables -dictionary "$plist" && plutil -insert EnvironmentVariables.VARNICK_DB -string "$1" "$plist" || { rm -rf "$dir"; return 1; }
  fi
  plutil -lint "$plist" >/dev/null || { rm -rf "$dir"; return 1; }
  launchctl bootout "$DOMAIN/$JOB_LABEL" >/dev/null 2>&1
  launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1
  status=$?
  rm -rf "$dir"
  return $status
}
if agent_fits "$1"; then
  start_agent && exit 0
  note "launchctl kickstart of $AGENT_LABEL didn't start Varnick"
fi
if start_job "$1"; then
  for _ in 1 2 3 4 5; do started && exit 0; sleep 1; done
  note "the job $JOB_LABEL is loaded but no Varnick appeared"
  exit 1
fi
# launchd refused (no GUI session, say): Varnick still starts, as a child of whatever ran this, so macOS may take that for the
# process responsible for it and use its grants.
note "launchd wouldn't start Varnick, so it started directly and may get the grants of whatever ran this script"
if [ -n "$1" ]; then
  VARNICK_DB="$1" exec .build/release/Varnick >> "$LOG" 2>&1
fi
exec .build/release/Varnick >> "$LOG" 2>&1
