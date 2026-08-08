#!/usr/bin/env bash
#
# What a stranger's first run does, as far as one machine can honestly show it.
#
# This clones the repository into a fresh temporary directory and runs it with
# an environment scrubbed of everything varnick-specific, everything Claude
# Code-specific, and a HOME that has never held either. It is the closest thing
# to a clean-machine run that can be performed on a machine that is not clean.
#
# It is not a clean-machine run, and it must never be reported as one. What it
# establishes and what it only approximates is printed at the end, and the same
# list is in README.md. Read it before quoting this script's output.
#
#   scripts/clean-clone.sh
#
# Exits non-zero if any step a stranger would hit fails.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/varnick-clean-clone.XXXXXX")"
clone="$work/varnick"
fresh_home="$work/home"
mkdir -p "$fresh_home"

failures=0
step() {
  printf '\n=== %s ===\n' "$1"
}
record() {
  if [ "$1" -eq 0 ]; then
    printf '    ok\n'
  else
    printf '    FAILED (exit %s)\n' "$1"
    failures=$((failures + 1))
  fi
}

# The interpreter, found on the *current* PATH and then passed by absolute path,
# because the scrubbed environment below has no idea where a developer keeps it.
bun_bin="$(command -v bun || true)"
if [ -z "$bun_bin" ]; then
  echo "bun is not on PATH; a stranger would install it first. Stopping." >&2
  exit 2
fi
git_bin="$(command -v git)"

# The scrubbed environment. `env -i` starts from nothing, so anything below is
# there because this script put it there:
#
#   HOME       a directory created a moment ago. No ~/.claude, no ~/.claude.json,
#              no shell profile, no bun install cache.
#   PATH       the system directories plus wherever bun lives, and nothing else.
#   TMPDIR     preserved, because macOS puts a per-user one there and dropping it
#              sends everything to /tmp.
#
# Deliberately absent: every CLAUDE*, every ANTHROPIC_*, every VARNICK_*, the
# developer's PATH additions, and their shell configuration.
scrubbed() {
  env -i \
    HOME="$fresh_home" \
    PATH="$(dirname "$bun_bin"):/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LANG=C \
    "$@"
}

printf 'clone     %s\n' "$clone"
printf 'HOME      %s\n' "$fresh_home"
printf 'source    %s @ %s\n' "$repo_root" "$(git -C "$repo_root" rev-parse --short HEAD)"

step "git clone"
"$git_bin" clone --quiet "$repo_root" "$clone"
record $?

# What a stranger would find if the author's machine had leaked into the
# repository. Paths, home directories and the author's own project location.
# `git grep` so it only ever reads tracked files.
step "no author-specific paths in the tracked source"
leaks="$(
  "$git_bin" -C "$clone" grep -nIE '/Users/(uptown|[a-z]+)/(Projects|Documents|Desktop)|zabaca/varnick' \
    -- ':!docs/adr' ':!scripts/clean-clone.sh' || true
)"
if [ -n "$leaks" ]; then
  printf '%s\n' "$leaks"
  record 1
else
  record 0
fi

step "bun install"
(cd "$clone" && scrubbed "$bun_bin" install) >"$work/install.log" 2>&1
record $?
tail -3 "$work/install.log"

for task in typecheck test build drive; do
  step "bun run $task"
  case "$task" in
    test) (cd "$clone" && scrubbed "$bun_bin" test packages) >"$work/$task.log" 2>&1 ;;
    *) (cd "$clone" && scrubbed "$bun_bin" run "$task") >"$work/$task.log" 2>&1 ;;
  esac
  record $?
  tail -4 "$work/$task.log"
done

# The dev server, which is what `bun run dev` gives a stranger before they have
# a desktop app. Started, asked for the page, stopped. Nothing here proves the
# chat works — that needs the Tauri host, a credential, and a window.
step "bun run dev serves the page"
(cd "$clone" && scrubbed "$bun_bin" run dev) >"$work/dev.log" 2>&1 &
dev_pid=$!
served=1
for _ in $(seq 1 40); do
  if /usr/bin/curl -fsS -o /dev/null http://localhost:1420/; then
    served=0
    break
  fi
  sleep 0.5
done
record $served
kill "$dev_pid" 2>/dev/null
wait "$dev_pid" 2>/dev/null
tail -4 "$work/dev.log"

# Not run here, and the honest reason for each.
step "not attempted"
cat <<'NOTE'
    cargo test        needs a Rust toolchain, which a stranger installs for
                      themselves; the clean environment deliberately has no
                      ~/.cargo on PATH.
    bun tauri dev     needs a Rust toolchain, a window server and a running
                      desktop session. A script cannot honestly assert what a
                      first launch looks like on screen.
    the credential    reading it would touch the developer's real keychain,
                      which no part of this repository may do.
NOTE

step "what this establishes"
cat <<'NOTE'
    Established:
      * the repository clones and builds from nothing but its own contents
      * install, typecheck, tests, the state-machine driver and the production
        build all pass with no varnick-, Claude Code- or shell-specific
        variable in the environment, and a HOME that has never held any of them
      * the tracked source names no author path
      * the dev server starts and serves on a clone that has never been run

    Approximated, not established:
      * this is one machine that HAS run varnick. The kernel, the installed
        toolchains, the login keychain and the OS itself are the author's.
        A scrubbed HOME is not a new user account and is not a new computer.
      * the first launch of the desktop app, the credential path, and the
        chat itself are outside what this can run at all.
      * nothing here is evidence about any machine other than this one.
        varnick has no users besides its author and no deployments.
NOTE

printf '\nartifacts %s\n' "$work"
if [ "$failures" -eq 0 ]; then
  printf 'result    every step a stranger would reach passed\n'
else
  printf 'result    %s step(s) failed\n' "$failures"
fi
exit $((failures > 0))
