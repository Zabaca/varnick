#!/bin/sh
# Checks the built text helper (.build/release/bun running agent.js) against fake-claude.py: no network, no login, no live call.
# Run `make build` first. Repeat after a bump of Bun, @zabaca/agent or the Agent SDK; the live part of a bump (one spoken
# request, `Varnick --generate`, zbc's e2e:reminders) is by hand.
here=$(cd "$(dirname "$0")" && pwd)
build=$(cd "$here/../.build/release" && pwd) || exit 1
fake=$here/fake-claude.py
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
mkdir "$work/cwd"
failed=0

ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; failed=$((failed + 1)); }
# request <claude> <filter> -> a request line
request() {
  printf '{"prompt":"Say OK","model":"claude-haiku-5-5","claude":"%s","filter":"%s","cwd":"%s"}\n' "$1" "$2" "$work/cwd"
}
# helper <stdin file> <stdout file>: how Varnick runs it
helper() {
  (cd "$work/cwd" && "$build/bun" --no-env-file --no-install "$build/agent.js" < "$1" > "$2" 2> "$work/stderr")
}

# with VAR=value command ...: the variable for that command only (a shell may keep an assignment made before a function)
with() { ( export "$1"; shift; "$@" ); }

request "$fake" "$build/mods/reminders" > "$work/ok.json"
with FAKE_CLAUDE_LOG="$work/fake.log" helper "$work/ok.json" "$work/ok.out"
grep -q '"type":"text","text":"OK"' "$work/ok.out" && grep -q '"type":"result","ok":true,"text":"OK"' "$work/ok.out" && ok "a request is answered in pieces and a result" || bad "a request is answered"
[ -z "$(grep -v '^{' "$work/ok.out")" ] && [ ! -s "$work/stderr" ] && ok "standard output holds JSON lines only, standard error nothing" || bad "standard output or error carries more than JSON lines"
grep -q -- '--no-session-persistence' "$work/fake.log" && grep -q -- '"--tools", ""' "$work/fake.log" && grep -q -- "--plugin-dir\", \"$build/mods/reminders" "$work/fake.log" \
  && ok "claude is started with no transcript, no tools and the filter by its path" || bad "claude's arguments"
grep -q -- '"--effort", "low"' "$work/fake.log" && ok "claude is asked for effort low" || bad "effort low"
[ "$(grep -o -- '--plugin-dir' "$work/fake.log" | wc -l | tr -d ' ')" -eq 1 ] && ok "one reminders filter, ours: the package's own default is replaced, not added to" || bad "plugin directories"

request "$fake" "$work/no-such-filter" > "$work/nofilter.json"
helper "$work/nofilter.json" "$work/nofilter.out"
grep -q '"ok":false,"kind":"filter missing"' "$work/nofilter.out" && ok "a missing filter fails the request" || bad "a missing filter"

echo 'not json' > "$work/garbage.json"
helper "$work/garbage.json" "$work/garbage.out"
grep -q '"kind":"bad request"' "$work/garbage.out" && ok "a bad request line fails the request" || bad "a bad request line"

request "/no/such/claude" "$build/mods/reminders" > "$work/noclaude.json"
helper "$work/noclaude.json" "$work/noclaude.out"
grep -q '"kind":"claude did not start"' "$work/noclaude.out" && ok "a claude that is not there" || bad "a claude that is not there"

with FAKE_CLAUDE_RETRY=1 helper "$work/ok.json" "$work/retry.out"
grep -q '"kind":"retrying: authentication_failed"' "$work/retry.out" && ok "a retrying login fails at once, with its kind" || bad "a retrying login"
pgrep -f fake-claude.py > /dev/null && bad "a claude was left after the retry" || ok "no claude left after the retry"

with FAKE_CLAUDE_TRANSIENT=1 helper "$work/ok.json" "$work/transient.out"
grep -q '"type":"result","ok":true,"text":"OK"' "$work/transient.out" && ok "a retry for an overloaded API goes on and succeeds" || bad "a transient retry"

with FAKE_CLAUDE_HANG=1 helper "$work/ok.json" "$work/hang.out" &
pid=$!
sleep 2
pkill -TERM -f "$build/agent.js"
wait $pid
sleep 0.5
pgrep -f fake-claude.py > /dev/null && bad "a claude was left after SIGTERM" || ok "SIGTERM ends the helper and its claude"

[ "$failed" -eq 0 ] && echo "all passed" || { echo "$failed failed"; exit 1; }
