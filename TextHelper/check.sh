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
grep -q '"type":"ready"' "$work/ok.out" && grep -q '"type":"text","text":"OK"' "$work/ok.out" && grep -q '"type":"result","ok":true,"text":"OK"' "$work/ok.out" && ok "a request is answered in pieces and a result" || bad "a request is answered"
[ -z "$(grep -v '^{' "$work/ok.out")" ] && [ ! -s "$work/stderr" ] && ok "standard output holds JSON lines only, standard error nothing" || bad "standard output or error carries more than JSON lines"
grep -q -- '--no-session-persistence' "$work/fake.log" && grep -q -- '"--tools", ""' "$work/fake.log" && grep -q -- "--plugin-dir\", \"$build/mods/reminders" "$work/fake.log" \
  && ok "claude is started with no transcript, no tools and the filter by its path" || bad "claude's arguments"
grep -q -- '"--effort", "low"' "$work/fake.log" && ok "claude is asked for effort low" || bad "effort low"
[ "$(grep -o -- '--plugin-dir' "$work/fake.log" | wc -l | tr -d ' ')" -eq 1 ] && ok "one reminders filter, ours: the package's own default is replaced, not added to" || bad "plugin directories"

# A call with tools (the web answer): the whole tool set, allowed outright, a turn limit, and the turn count in the result.
printf '{"prompt":"Say OK","model":"claude-haiku-5-5","claude":"%s","filter":"%s","cwd":"%s","tools":["WebSearch"],"maxTurns":3}\n' "$fake" "$build/mods/reminders" "$work/cwd" > "$work/web.json"
with FAKE_CLAUDE_LOG="$work/web.log" helper "$work/web.json" "$work/web.out"
grep -q '"type":"result","ok":true,"text":"OK"' "$work/web.out" && grep -q '"turns":1' "$work/web.out" \
  && ok "a call with tools answers with the last turn and its turn count" || bad "a call with tools"
grep -q -- '"--tools", "WebSearch"' "$work/web.log" && grep -q -- '"--allowedTools", "WebSearch"' "$work/web.log" && grep -q -- '"--max-turns", "3"' "$work/web.log" \
  && ok "claude is started with WebSearch as its only tool, allowed, and a turn limit" || bad "claude's arguments for a call with tools"

printf '{"prompt":"Say OK","model":"claude-haiku-5-5","claude":"%s","filter":"%s","cwd":"%s","tools":"WebSearch"}\n' "$fake" "$build/mods/reminders" "$work/cwd" > "$work/badtools.json"
helper "$work/badtools.json" "$work/badtools.out"
grep -q '"kind":"bad request"' "$work/badtools.out" && ok "tools that are not a list of names fail the request" || bad "bad tools"

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

# A conversation (a Task's): one claude kept open, each message answered in order with its own ready and result, the same process for all.
printf '{"prompt":"first question","model":"claude-haiku-5-5","claude":"%s","filter":"%s","cwd":"%s","conversation":true}\n' "$fake" "$build/mods/reminders" "$work/cwd" > "$work/conv-first.json"
(cd "$work/cwd" && export FAKE_CLAUDE_COUNT=1 FAKE_CLAUDE_LOG="$work/conv.log" && { cat "$work/conv-first.json"; sleep 1.5; printf '{"message":"second question"}\n'; sleep 1.5; printf '{"message":"third"}\n'; sleep 1.5; } \
  | "$build/bun" --no-env-file --no-install "$build/agent.js" > "$work/conv.out" 2> "$work/stderr")
[ "$(grep -c '"type":"result","ok":true' "$work/conv.out")" -eq 3 ] && grep -q '"text":"OK 1 after first"' "$work/conv.out" && grep -q '"type":"result","ok":true,"text":"OK 2 after first"' "$work/conv.out" \
  && grep -q '"type":"result","ok":true,"text":"OK 3 after first"' "$work/conv.out" && ok "a conversation answers each message in order, from the same claude" || bad "a conversation's answers"
[ "$(grep -c '"type":"ready"' "$work/conv.out")" -eq 3 ] && [ "$(grep -c '"argv"' "$work/conv.log")" -eq 1 ] && ok "one ready for each message, and one claude for the whole conversation" || bad "a conversation's ready lines or claude processes"
[ -z "$(grep -v '^{' "$work/conv.out")" ] && [ ! -s "$work/stderr" ] && ok "a conversation writes JSON lines only" || bad "a conversation's output"
grep -q -- '--no-session-persistence' "$work/conv.log" && grep -q -- '"--tools", ""' "$work/conv.log" && grep -q -- "--plugin-dir\", \"$build/mods/reminders" "$work/conv.log" \
  && ok "a conversation has no transcript, no tools and the reminders filter, as a one-shot request does" || bad "a conversation's claude arguments"
pgrep -f fake-claude.py > /dev/null && bad "a claude was left after the conversation's input closed" || ok "no claude left once the input closes"

printf '{"prompt":"first question","model":"claude-haiku-5-5","claude":"%s","filter":"%s","cwd":"%s","conversation":true}\n' "$fake" "$work/no-such-filter" "$work/cwd" > "$work/conv-nofilter.json"
helper "$work/conv-nofilter.json" "$work/conv-nofilter.out"
grep -q '"ok":false,"kind":"filter missing"' "$work/conv-nofilter.out" && ok "a conversation with no filter fails its first message" || bad "a conversation with a missing filter"

(cd "$work/cwd" && export FAKE_CLAUDE_HANG=1 && { cat "$work/conv-first.json"; sleep 30; } | "$build/bun" --no-env-file --no-install "$build/agent.js" > "$work/convhang.out" 2> "$work/stderr") &
pid=$!
sleep 2
pkill -TERM -f "$build/agent.js"
wait $pid
sleep 0.5
pgrep -f fake-claude.py > /dev/null && bad "a claude was left after SIGTERM in a conversation" || ok "SIGTERM ends a conversation's helper and its claude"

# The input closing mid-message (Varnick gone) ends the helper and its claude without a signal: nothing outlives Varnick.
(cd "$work/cwd" && export FAKE_CLAUDE_HANG=1 && { cat "$work/conv-first.json"; sleep 2; } | "$build/bun" --no-env-file --no-install "$build/agent.js" > "$work/convclose.out" 2> "$work/stderr") &
pid=$!
sleep 5
if kill -0 $pid 2> /dev/null; then bad "the helper was still running after its input closed during a message"; kill -KILL $pid 2> /dev/null; else ok "the helper ends by itself when its input closes during a message"; fi
wait $pid 2> /dev/null
pgrep -f fake-claude.py > /dev/null && bad "a claude was left after the input closed during a message" || ok "and no claude is left"

[ "$failed" -eq 0 ] && echo "all passed" || { echo "$failed failed"; exit 1; }
