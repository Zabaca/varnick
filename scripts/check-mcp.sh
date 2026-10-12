#!/bin/sh
# make check-mcp: checks what `Varnick --mcp` lists and refuses for each set of tools its arguments name, with standard input from a file
# and no running Varnick: the server only lists, and a call to a tool its sets don't list is refused before anything is sent. One `error:`
# line for each problem, exit 1 if there was any. `make check-mcp BIN=<binary>` checks another build. A call that would reach the app
# needs the app and is checked by hand after a restart (docs/agents/where-it-breaks.md, Panel access).
set -u
bin=${1:-.build/release/Varnick}
[ -x "$bin" ] || { echo "error: check-mcp: no binary at $bin (make build first)" >&2; exit 1; }

exec python3 -I - "$bin" <<'PY'
import json, subprocess, sys

binary = sys.argv[1]
pane = "00000000-0000-0000-0000-000000000000"
screen = ["look", "point", "click", "type", "drag", "window"]
bad = False


def fail(why):
    global bad
    bad = True
    print("error: check-mcp: " + why, file=sys.stderr)


def talk(arguments, messages):
    """The replies to the messages, by id, from a server started with the arguments."""
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([binary, "--mcp", "--pane", pane] + arguments, input=lines, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        fail("%s exited with %d" % (arguments, out.returncode))
    replies = {}
    for line in out.stdout.splitlines():
        reply = json.loads(line)
        replies[reply.get("id")] = reply
    return replies


def listed(arguments, full=False):
    replies = talk(arguments, [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ])
    tools = replies.get(2, {}).get("result", {}).get("tools")
    if tools is None:
        fail("%s: no tool list" % arguments)
        return []
    names = [t["name"] for t in tools]
    if len(set(names)) != len(names):
        fail("%s: a tool name is listed twice: %s" % (arguments, names))
    for tool in tools:
        if tool.get("inputSchema", {}).get("type") != "object" or not tool.get("description"):
            fail("%s: %s has no description or object schema" % (arguments, tool["name"]))
    return tools if full else names


none, only_screen, only_panel, both = listed([]), listed(["--screen"]), listed(["--panel"]), listed(["--screen", "--panel"])

if none != screen:
    fail("with no set named the server lists %s, not the screen tools alone" % none)
if only_screen != screen:
    fail("--screen lists %s" % only_screen)
if "panel" not in only_panel:
    fail("--panel lists %s, with no panel" % only_panel)
if set(only_panel) & set(screen):
    fail("--panel lists a screen tool: %s" % sorted(set(only_panel) & set(screen)))
if both != screen + only_panel:
    fail("both sets list %s, not the screen tools then Panel access's" % both)

# The Outline's act tool: one tool with an `action` that names every edit, and the arguments the actions share.
actions = ["add", "set_text", "set_note", "complete", "delete", "move", "indent", "outdent", "collapse", "mirror"]
act = [t for t in listed(["--panel"], full=True) if t["name"] == "outline_act"]
if not act:
    fail("--panel lists no outline_act")
else:
    schema = act[0]["inputSchema"]
    if schema.get("properties", {}).get("action", {}).get("enum") != actions or schema.get("required") != ["action"]:
        fail("outline_act's action is %s, required %s" % (schema.get("properties", {}).get("action"), schema.get("required")))
    for argument in ("id", "text", "note", "under", "after", "first", "done", "by", "collapsed"):
        if argument not in schema.get("properties", {}):
            fail("outline_act takes no %s" % argument)

# The show tool: its `view` names every view a session can bring up, the Outline included (as `command: outline` does).
showing = [t for t in listed(["--panel"], full=True) if t["name"] == "show"]
if not showing:
    fail("--panel lists no show")
else:
    views = showing[0]["inputSchema"].get("properties", {}).get("view", {}).get("enum")
    if views != ["search", "board", "problems", "outline"]:
        fail("show's view is %s, not search, board, problems and outline" % views)

# The keys tool: `text` is a string and `keys` a list of strings, and nothing is required (text, keys or both).
pressing = [t for t in listed(["--panel"], full=True) if t["name"] == "keys"]
if not pressing:
    fail("--panel lists no keys")
else:
    schema = pressing[0]["inputSchema"]
    properties = schema.get("properties", {})
    if properties.get("text", {}).get("type") != "string":
        fail("keys' text is %s, not a string" % properties.get("text"))
    if properties.get("keys", {}).get("type") != "array" or properties["keys"].get("items", {}).get("type") != "string":
        fail("keys' keys is %s, not a list of strings" % properties.get("keys"))
    if schema.get("required"):
        fail("keys requires %s: text, keys or both are enough" % schema.get("required"))

# A tool a server doesn't list is unknown to it, and nothing is sent to the app.
for arguments, name in (([], "panel"), (["--screen"], "panel"), (["--panel"], "look"), (["--panel"], "nothing_of_ours")):
    replies = talk(arguments, [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": {}}}])
    if replies.get(3, {}).get("error", {}).get("message") != "Unknown tool":
        fail("%s called %s and did not get Unknown tool: %s" % (arguments, name, replies.get(3)))

sys.exit(1 if bad else 0)
PY
