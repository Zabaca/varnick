#!/bin/sh
# Started detached by `make run`, the status menu's Restart and the upgrade's restart (BuildUpgrade): stops every Varnick of this
# checkout, including one hosting the session that ran it (pkill skips its own ancestors without -a, and with -a would kill make
# before the new instance starts), then starts the fresh build through launchd, never as this script's own child: a child would get
# the macOS permissions of whatever ran the script instead of Varnick's own (docs/agents/where-it-breaks.md, Signing). Every start
# through launchd has the absolute path in its argv; the relative path is what a Varnick started by an older restart, or by the
# direct fallback at the end, has.
# Varnick's output is appended to ~/Library/Logs/Varnick.log, which is where its NSLog lines go (there, not to
# `log show`); when that file can't be opened it goes to /dev/null, so a log that can't be written never stops Varnick
# from starting.
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
# Which launchd job starts Varnick. AGENT_LABEL is the Makefile's LABEL; change them together.
ROOT=$(pwd -P)
BINARY="$ROOT/.build/release/Varnick"
DOMAIN="gui/$(id -u)"
AGENT_LABEL=com.zabaca.varnick
# Beyond launchd's own, a start carries only these two from the caller (a LaunchAgent can carry neither, so a start that has one is
# the transient job's): the database path this script was given, and VARNICK_LOG_RESIZE, which `VARNICK_LOG_RESIZE=1 make run` sets.
DB_ARG=$1
LOG_RESIZE=${VARNICK_LOG_RESIZE-}
# The label names the checkout and the environment above, so a loaded job always has the environment this restart wants and is
# restarted with kickstart, never removed and loaded again: the Varnick the job started may be what ran this script.
JOB_LABEL="$AGENT_LABEL.run.$(printf '%s|%s|%s' "$ROOT" "$DB_ARG" "$LOG_RESIZE" | cksum | cut -d' ' -f1)"
note() { echo "$(date '+%Y-%m-%d %H:%M:%S') restart: $1" >> "$LOG" 2>/dev/null; }
# What still runs after the wait above, normally nothing: a start counts only for a process that wasn't there before it.
BEFORE=$(pgrep -a -f "$VARNICK" | tr '\n' ' ')
started() {
  for pid in $(pgrep -a -f "$VARNICK"); do
    case " $BEFORE " in *" $pid "*) ;; *) return 0 ;; esac
  done
  return 1
}
# What launchd says about a loaded job; the commands fail, or print nothing, for a label that isn't loaded.
program() { launchctl print "$DOMAIN/$1" 2>/dev/null | sed -n 's/^[[:space:]]*program = //p' | head -1; }
runs() {
  out=$(launchctl print "$DOMAIN/$1" 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\)$/\1/p' | head -1
}
# The LaunchAgent counts when the loaded job runs this checkout's binary (the plist file isn't consulted: the job is what runs).
agent_fits() {
  [ -z "$LOG_RESIZE" ] || return 1
  [ -z "$DB_ARG" ] || [ "$DB_ARG" = "$SUPPORT/Varnick/varnick.sqlite" ] || return 1
  [ "$(program "$AGENT_LABEL")" = "$BINARY" ]
}
# Kicks a loaded job (no -k, so a running Varnick is never started beside) and waits for a new process. A kickstart does nothing while
# the job still counts as running, which a Varnick that has just been stopped may for a moment, so it is repeated, whatever it said,
# until a new process shows. 0: started. 1: the job isn't loaded, or nothing started in 15 s. 2: the job ran and its Varnick is gone,
# so launchd's run count went up: a build that dies at launch is not started again by another route.
start_loaded() {
  before=$(runs "$1") || return 1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    launchctl kickstart "$DOMAIN/$1" >/dev/null 2>&1
    sleep 1
    started && return 0
    now=$(runs "$1") || return 1
    if [ "${now:-0}" -gt "${before:-0}" ]; then
      note "launchd ran $1 and Varnick ended within a second; see the log above, and no other way to start it was tried"
      return 2
    fi
  done
  return 1
}
# A transient job: the LaunchAgent's own plist (scripts/varnick-plist.sh) in a temporary folder, read once by bootstrap and then
# removed, so Varnick runs the same way however it was started: launchd's environment, this folder as its working folder, the same
# log. Every step that fails says so before the next start is tried. Returns as start_loaded does.
start_job() {
  start_loaded "$JOB_LABEL"
  rc=$?
  [ "$rc" = 1 ] || return "$rc"
  # Loaded, but a kickstart started nothing: something holds it. Removing it ends that, and it is loaded again below.
  if runs "$JOB_LABEL" >/dev/null; then launchctl bootout "$DOMAIN/$JOB_LABEL" >/dev/null 2>&1; fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/varnick-run.XXXXXX") || { note "couldn't make a temporary folder for the job's plist"; return 1; }
  plist="$dir/$JOB_LABEL.plist"
  scripts/varnick-plist.sh "$JOB_LABEL" "$ROOT" "$LOG" > "$plist" || { note "couldn't write the job's plist"; rm -rf "$dir"; return 1; }
  if [ -n "$DB_ARG$LOG_RESIZE" ]; then
    { plutil -insert EnvironmentVariables -dictionary "$plist" \
      && { [ -z "$DB_ARG" ] || plutil -insert EnvironmentVariables.VARNICK_DB -string "$DB_ARG" "$plist"; } \
      && { [ -z "$LOG_RESIZE" ] || plutil -insert EnvironmentVariables.VARNICK_LOG_RESIZE -string "$LOG_RESIZE" "$plist"; }; } \
      || { note "couldn't put the environment in the job's plist"; rm -rf "$dir"; return 1; }
  fi
  plutil -lint "$plist" >/dev/null || { note "the job's plist isn't valid (a character in the checkout's or the log's path?)"; rm -rf "$dir"; return 1; }
  if ! launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1; then
    sleep 2
    launchctl bootstrap "$DOMAIN" "$plist" >/dev/null 2>&1 || { note "launchctl bootstrap of $JOB_LABEL failed twice"; rm -rf "$dir"; return 1; }
  fi
  rm -rf "$dir"
  for _ in 1 2 3 4 5; do started && return 0; sleep 1; done
  note "the job $JOB_LABEL is loaded, but no Varnick appeared"
  return 2
}
if agent_fits; then
  start_loaded "$AGENT_LABEL"
  rc=$?
  [ "$rc" = 0 ] && exit 0
  [ "$rc" = 2 ] && exit 1
  note "launchctl kickstart of $AGENT_LABEL didn't start Varnick"
fi
start_job
rc=$?
[ "$rc" = 0 ] && exit 0
[ "$rc" = 2 ] && exit 1
# launchd refused (no GUI session, say): Varnick still starts, as a child of whatever ran this, so macOS may take that for the
# process responsible for it and use its grants.
note "launchd wouldn't start Varnick, so it is started directly and gets the macOS permissions of whatever ran this script"
if [ -n "$1" ]; then
  VARNICK_DB="$1" exec .build/release/Varnick >> "$LOG" 2>&1
fi
exec .build/release/Varnick >> "$LOG" 2>&1
