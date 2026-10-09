#!/bin/sh
# /work: checks its arguments against the repository's problem files and prints the marker line that Launchy's hook after Bash turns
# into the caller's work record (ADR 0020). It writes no record itself: only the hook input carries a subagent's id. For an option on a
# branch other than main it also ties the branch in git config (docs/agents/issue-tracker.md).

usage() {
  echo "usage: work.sh problem <slug> | option <slug>/<NN> | none | (nothing: show the records)" >&2
  exit 1
}

folder=
[ -n "$LAUNCHY_SESSION_FILE" ] && folder="${LAUNCHY_SESSION_FILE%/*}"

if [ $# -eq 0 ]; then
  [ -d "$folder" ] || { echo "Not in a Launchy pane: no work records here."; exit 0; }
  for f in "$folder"/work "$folder"/work.*; do
    [ -f "$f" ] || continue
    echo "$(basename "$f"): $(tr '\n' ' ' < "$f")"
  done
  [ -f "$folder/work-log" ] && { echo "log (newest last; epoch, agent id, agent type, kind, value, repo, flag):"; tail -n 10 "$folder/work-log"; }
  exit 0
fi

kind=$1
value=$2
case "$kind" in
  none) value= ;;
  problem|option) [ -n "$value" ] || usage ;;
  *) usage ;;
esac

# The repository's main checkout (a worktree's links are its checkout's), and this checkout, where an unmerged problem is.
top=$(git rev-parse --show-toplevel 2>/dev/null)
common=$(git rev-parse --git-common-dir 2>/dev/null)
case "$common" in
  /*) ;;
  ?*) common="$(cd "$common" 2>/dev/null && pwd -P)" ;;
esac
repo=$top
case "$common" in */.git) repo=${common%/.git} ;; esac

if [ "$kind" != none ]; then
  [ -n "$repo" ] || { echo "Not in a git repository." >&2; exit 1; }
  slug=${value%/*}
  [ "$kind" = problem ] && slug=$value
  case "$slug" in ""|.*|*[!A-Za-z0-9._-]*) echo "Not a problem slug: $slug" >&2; exit 1 ;; esac
  problem=
  for root in "$top" "$repo"; do
    [ -f "$root/docs/problems/$slug/problem.md" ] && { problem=$root/docs/problems/$slug; break; }
  done
  [ -n "$problem" ] || { echo "No problem '$slug': docs/problems/$slug/problem.md is not in this checkout or the main one." >&2; exit 1; }
  case "$repo$value" in *'|'*|*'"'*|*'\'*) echo "A path or name with | \" or \\ can't be recorded." >&2; exit 1 ;; esac
fi

if [ "$kind" = option ]; then
  number=${value##*/}
  case "$number" in ""|*[!0-9]*) echo "Not an option number: $number (use <slug>/<NN>)" >&2; exit 1 ;; esac
  number=$(printf '%s' "$number" | sed 's/^0*//')
  [ -n "$number" ] || { echo "Option numbers start at 01." >&2; exit 1; }
  number=$(printf '%02d' "$number")
  value=$slug/$number
  set -- "$problem"/options/"$number"-*.md
  [ -f "$1" ] || { echo "Problem '$slug' has no option $number." >&2; exit 1; }
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null)
  case "$branch" in
    ""|main|master) tied="no branch tie on ${branch:-a detached HEAD}" ;;
    *) git config "branch.$branch.launchy-option" "$value" && tied="branch $branch tied" || tied="branch tie failed" ;;
  esac
fi

if [ ! -d "$folder" ]; then
  echo "Not in a Launchy pane, so no record is written.${tied:+ ($tied)}"
  exit 0
fi

case "$kind" in
  none) echo "Work link cleared." ;;
  problem) echo "Linked to problem $slug." ;;
  option) echo "Linked to option $value ($tied)." ;;
esac
echo "Launchy writes the record after this command; a session started before the hooks existed records nothing until restarted."
# The marker carries the pane id and a one-shot nonce: the hook accepts it once, by deleting the nonce's file, so a marker printed again
# (a transcript read back, a log) links nothing, and another pane's marker is ignored.
find "$folder" -maxdepth 1 -name '.work-mark.*' -mmin +60 -exec rm -f {} + 2>/dev/null
nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
: > "$folder/.work-mark.$nonce" || { echo "Could not write to the pane folder." >&2; exit 1; }
printf 'LAUNCHY-WORK|%s|%s|%s|%s|%s|\n' "${folder##*/}" "$nonce" "$kind" "$value" "${repo:-/}"
