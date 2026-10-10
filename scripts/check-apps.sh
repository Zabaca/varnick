#!/bin/sh
# make check-apps: checks every entry of the catalog (apps/ by default, or the folder given) offline, one `error:` line for each
# problem, and exits 1 if there was any. The rules are the ones CONTRIBUTING lists for an app to be accepted that a script can
# check; that bun.lock is in step with package.json needs the network (`bun install --frozen-lockfile`) and is part of review.
set -u
root=${1:-apps}
bad=0
count=0
keys=""

fail() {
  echo "error: check-apps: $1" >&2
  bad=1
}

# The manifest's string field, empty when it is missing or not a string.
field() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

[ -d "$root" ] || { echo "error: check-apps: no folder $root" >&2; exit 1; }

for dir in "$root"/*/; do
  [ -d "$dir" ] || continue
  dir=${dir%/}
  name=$(basename "$dir")
  count=$((count + 1))

  case $name in
    -* | *[!a-z0-9-]*) fail "$name: the folder's name must be lowercase letters, digits and dashes, and not start with a dash" ;;
  esac

  manifest="$dir/varnick.json"
  if [ ! -f "$manifest" ] || ! plutil -convert json -o /dev/null "$manifest" >/dev/null 2>&1; then
    fail "$name: no readable varnick.json"
    continue
  fi
  entry=$(field entry "$manifest")
  case $entry in
    "") fail "$name: varnick.json names no entry" ;;
    /* | ../* | */../* | */..) fail "$name: the entry $entry leaves the app's folder" ;;
    *) [ -f "$dir/$entry" ] || fail "$name: the entry $entry does not exist" ;;
  esac
  [ -n "$(field description "$manifest")" ] || fail "$name: varnick.json has no description"
  [ -n "$(field network "$manifest")" ] || fail "$name: varnick.json has no network line (an app whose only fetch is its packages says so)"

  key=$(field key "$manifest" | tr 'A-Z' 'a-z')
  if [ -n "$key" ]; then
    case $key in
      c | t | b) fail "$name: the key $key is a built-in's" ;;
    esac
    keys="$keys $key:$name"
  fi

  if [ -f "$dir/package.json" ]; then
    [ -f "$dir/bun.lock" ] || fail "$name: package.json without a bun.lock beside it"
    if plutil -extract trustedDependencies raw -o - "$dir/package.json" >/dev/null 2>&1; then
      fail "$name: package.json has trustedDependencies; packages' install scripts stay off"
    fi
  fi

  # Tracked, not merely present: a checkout that ran the app has one, which the copy leaves out.
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$root" ls-files -- "$name" 2>/dev/null | grep -Eq '(^|/)node_modules/'; then
      fail "$name: node_modules is tracked"
    fi
  elif [ -n "$(find "$dir" -name node_modules -prune -print 2>/dev/null)" ]; then
    fail "$name: has a node_modules folder"
  fi

  # A link would point out of the installed copy, which is made by copying the entry alone.
  if [ -n "$(find "$dir" -name node_modules -prune -o -type l -print 2>/dev/null)" ]; then
    fail "$name: has a symbolic link"
  fi

  if [ -d "$dir/skill" ]; then
    if [ ! -f "$dir/skill/SKILL.md" ]; then
      fail "$name: the skill folder has no SKILL.md"
    else
      skill=$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } /^name:/ { sub(/^name:[ ]*/, ""); print; exit }' "$dir/skill/SKILL.md")
      [ "$skill" = "$name" ] || fail "$name: the skill is named '$skill', not '$name'"
    fi
  fi
done

# Each key once, across the entries.
for pair in $keys; do
  key=${pair%%:*}
  others=""
  for other in $keys; do
    [ "$other" != "$pair" ] && [ "${other%%:*}" = "$key" ] && others="$others ${other#*:}"
  done
  [ -n "$others" ] && fail "${pair#*:}: the key $key is also used by ${others# }"
done

[ $bad = 0 ] && echo "check-apps: $count app(s) ok"
exit $bad
