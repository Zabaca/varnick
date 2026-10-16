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

# The notify tool (option 04 of phone-page-is-only-a-browser-tab): its own set, in every Claude pane. Named alone it lists notify alone; named
# with the others it comes last; with none named the server still lists the screen tools alone.
only_notify, screen_notify, all_three = listed(["--notify"]), listed(["--screen", "--notify"]), listed(["--screen", "--panel", "--notify"])
if only_notify != ["notify"]:
    fail("--notify lists %s, not notify alone" % only_notify)
if screen_notify != screen + ["notify"]:
    fail("--screen --notify lists %s, not the screen tools then notify" % screen_notify)
if all_three != screen + only_panel + ["notify"]:
    fail("all three sets list %s, not the screen tools, Panel access's and notify" % all_three)
if "notify" in none or "notify" in only_screen or "notify" in only_panel or "notify" in both:
    fail("a server started without --notify lists notify")
notify = [t for t in listed(["--notify"], full=True) if t["name"] == "notify"]
if not notify:
    fail("--notify lists no notify")
else:
    schema = notify[0]["inputSchema"]
    properties = schema.get("properties", {})
    if schema.get("required") != ["title"] or properties.get("title", {}).get("type") != "string" or properties.get("body", {}).get("type") != "string":
        fail("notify's schema is %s: a required string title and an optional string body" % schema)

# A notify call is answered by the server alone: it checks the arguments and acts on nothing. Only an empty title is refused, and longer text is cut.
def called(arguments):
    replies = talk(["--notify"], [{"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "notify", "arguments": arguments}}])
    return replies.get(4, {}).get("result", {})

ok = called({"title": "Tests passed: 214", "body": "all green"})
if ok.get("isError") is not False or "phone" not in ok.get("content", [{}])[0].get("text", ""):
    fail("a notify call with a title was not answered with what Varnick will do: %s" % ok)
for empty in ({}, {"title": ""}, {"title": "  \n "}, {"body": "no title"}, {"title": 7}):
    refused = called(empty)
    if refused.get("isError") is not True:
        fail("a notify call with %s was not refused" % empty)
long_title = called({"title": "x" * 200, "body": "y" * 500})
if long_title.get("isError") is not False or "title was cut to 80" not in long_title["content"][0]["text"] or "body was cut to 300" not in long_title["content"][0]["text"]:
    fail("a notify call with long text did not say what it cut: %s" % long_title)

# The automation tools (option 01 of prompts-cant-run-on-a-schedule, slice 3): their own set, named by the app only while Automations is on and never
# for an automation's run. Named alone it lists the four; with the others it comes after Panel access's and before notify; with none named the
# server still lists the screen tools alone. NEVER call one of these tools here: with Varnick running, the call reaches it and makes a real
# automation. Only a call to a server that does not list them is made (below), and that is refused before anything is sent.
automation_tools = ["automations_list", "automation_create", "automation_edit", "automation_switch"]
only_automations, with_all = listed(["--automations"]), listed(["--screen", "--panel", "--automations", "--notify"])
if only_automations != automation_tools:
    fail("--automations lists %s, not the four automation tools" % only_automations)
if with_all != screen + only_panel + automation_tools + ["notify"]:
    fail("all four sets list %s, not the screen tools, Panel access's, the automation tools and notify" % with_all)
if listed(["--automations", "--notify"]) != automation_tools + ["notify"]:
    fail("--automations --notify lists %s" % listed(["--automations", "--notify"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--screen", "--panel", "--notify"]):
    if set(listed(arguments)) & set(automation_tools):
        fail("%s lists an automation tool" % arguments)
described = {t["name"]: t for t in listed(["--automations"], full=True)}
for name in automation_tools:
    if name not in described:
        fail("--automations lists no %s" % name)
if all(name in described for name in automation_tools):
    create_schema = described["automation_create"]["inputSchema"]
    properties = create_schema.get("properties", {})
    if create_schema.get("required") != ["name", "prompt", "cadence"]:
        fail("automation_create requires %s, not name, prompt and cadence" % create_schema.get("required"))
    for field in ("name", "prompt", "cadence", "folder", "agent", "permissions", "allowed_tools", "working_limit_minutes", "enabled"):
        if field not in properties:
            fail("automation_create takes no %s" % field)
    if properties.get("cadence", {}).get("properties", {}).get("kind", {}).get("enum") != ["minutes", "hours", "daily", "weekdays", "weekly"]:
        fail("automation_create's cadence kinds are %s" % properties.get("cadence", {}).get("properties", {}).get("kind"))
    if properties.get("cadence", {}).get("required") != ["kind"]:
        fail("automation_create's cadence requires %s, not kind" % properties.get("cadence", {}).get("required"))
    # A session may not set Skip: the values are following Varnick's setting, Ask, and Allowed tools only.
    for name in ("automation_create", "automation_edit"):
        permissions = described[name]["inputSchema"].get("properties", {}).get("permissions", {}).get("enum")
        if permissions != ["varnick_setting", "ask", "allowed_tools_only"]:
            fail("%s's permissions are %s: no skip, and nothing else" % (name, permissions))
    # An automation is a trigger of the Claude prompt Task (option 01 of work-cant-be-saved-or-chained, slice 1): the list says which Task each names,
    # and create and edit say theirs is the Claude prompt. Their arguments are the same four fields, with no `task` or `input` until slice 2.
    if "task" not in described["automations_list"]["description"] or "Claude prompt" not in described["automations_list"]["description"]:
        fail("automations_list's description doesn't say each automation names a Task, the Claude prompt")
    for name in ("automation_create", "automation_edit"):
        if "Claude prompt" not in described[name]["description"]:
            fail("%s's description doesn't say an automation runs the Claude prompt Task" % name)
        if {"task", "input"} & set(described[name]["inputSchema"].get("properties", {})):
            fail("%s takes task or input, which arrive in slice 2" % name)
    limit = properties.get("working_limit_minutes", {})
    if (limit.get("minimum"), limit.get("maximum")) != (5, 1440):
        fail("automation_create's working limit is %s to %s, not 5 to 1440" % (limit.get("minimum"), limit.get("maximum")))
    edit_schema = described["automation_edit"]["inputSchema"]
    if edit_schema.get("required") != ["id"] or set(edit_schema.get("properties", {})) != set(properties) | {"id"}:
        fail("automation_edit takes %s requiring %s: id and create's fields, only id required" % (sorted(edit_schema.get("properties", {})), edit_schema.get("required")))
    switch_schema = described["automation_switch"]["inputSchema"]
    if switch_schema.get("required") != ["id", "on"] or switch_schema.get("properties", {}).get("on", {}).get("type") != "boolean":
        fail("automation_switch is %s: an id and a boolean on, both required" % switch_schema)
    if described["automations_list"]["inputSchema"].get("required"):
        fail("automations_list requires %s" % described["automations_list"]["inputSchema"].get("required"))

# A tool a server doesn't list is unknown to it, and nothing is sent to the app.
for arguments, name in (([], "panel"), (["--screen"], "panel"), (["--panel"], "look"), (["--panel"], "nothing_of_ours"), ([], "notify"), (["--screen"], "notify"), (["--panel"], "notify"), (["--notify"], "look"),
                        ([], "automations_list"), (["--screen"], "automation_create"), (["--panel"], "automation_edit"), (["--notify"], "automation_switch"),
                        (["--screen", "--panel", "--notify"], "automations_list"), (["--automations"], "panel"), (["--automations"], "look")):
    replies = talk(arguments, [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": {}}}])
    if replies.get(3, {}).get("error", {}).get("message") != "Unknown tool":
        fail("%s called %s and did not get Unknown tool: %s" % (arguments, name, replies.get(3)))

sys.exit(1 if bad else 0)
PY
