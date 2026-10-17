#!/bin/sh
# make check-mcp: checks what `Varnick --mcp` lists and refuses for each set of tools its arguments name, with standard input from a file
# and no running Varnick: the server only lists, and a call to a tool its sets don't list is refused before anything is sent. One `error:`
# line for each problem, exit 1 if there was any. `make check-mcp BIN=<binary>` checks another build. A call that would reach the app
# needs the app and is checked by hand after a restart (docs/agents/where-it-breaks.md, Panel access).
set -u
bin=${1:-.build/release/Varnick}
[ -x "$bin" ] || { echo "error: check-mcp: no binary at $bin (make build first)" >&2; exit 1; }

exec python3 -I - "$bin" <<'PY'
import json, os, shutil, subprocess, sys, tempfile

binary = sys.argv[1]
pane = "00000000-0000-0000-0000-000000000000"
screen = ["look", "point", "click", "type", "drag", "window"]
bad = False


def fail(why):
    global bad
    bad = True
    print("error: check-mcp: " + why, file=sys.stderr)


def talk(arguments, messages, home=None, pane=pane):
    """The replies to the messages, by id, from a server started with the arguments. `home` is a scratch home folder: the server's support folder
    (and so a pane's folder) is under it, so nothing is read or written in the real one."""
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home) if home else None
    out = subprocess.run([binary, "--mcp", "--pane", pane] + arguments, input=lines, capture_output=True, text=True, timeout=30, env=env)
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

# The task tools (option 01 of work-cant-be-saved-or-chained, slice 2a): their own set, named by the app only while Tasks is on and never for a Run's
# session. Named alone it lists the four; with the others it comes after the automation tools and before notify. NEVER call one of these tools here:
# with Varnick running, the call reaches it and starts a real Run, which draws on the user's accounts. Only a call to a server that does not list them
# is made (below), and that is refused before anything is sent.
task_tools = ["tasks_list", "task_run", "task_run_status", "task_check"]
only_tasks, every_set = listed(["--tasks"]), listed(["--screen", "--panel", "--automations", "--tasks", "--notify"])
if only_tasks != task_tools:
    fail("--tasks lists %s, not the four task tools" % only_tasks)
if every_set != screen + only_panel + automation_tools + task_tools + ["notify"]:
    fail("every set lists %s, not the screen tools, Panel access's, the automation tools, the task tools and notify" % every_set)
if listed(["--tasks", "--notify"]) != task_tools + ["notify"]:
    fail("--tasks --notify lists %s" % listed(["--tasks", "--notify"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--screen", "--panel", "--automations", "--notify"]):
    if set(listed(arguments)) & set(task_tools):
        fail("%s lists a task tool" % arguments)
task_described = {t["name"]: t for t in listed(["--tasks"], full=True)}
if all(name in task_described for name in task_tools):
    run_schema = task_described["task_run"]["inputSchema"]
    if run_schema.get("required") != ["task"] or run_schema.get("properties", {}).get("input", {}).get("type") != "object" \
            or run_schema.get("properties", {}).get("task", {}).get("type") != "string":
        fail("task_run is %s: a required string task and an object input" % run_schema)
    status_schema = task_described["task_run_status"]["inputSchema"]
    if status_schema.get("required") != ["run"] or status_schema.get("properties", {}).get("run", {}).get("type") != "string":
        fail("task_run_status is %s: a required string run" % status_schema)
    check_schema = task_described["task_check"]["inputSchema"]
    if check_schema.get("required") != ["path"] or check_schema.get("properties", {}).get("path", {}).get("type") != "string":
        fail("task_check is %s: a required string path" % check_schema)
    if task_described["tasks_list"]["inputSchema"].get("required"):
        fail("tasks_list requires %s" % task_described["tasks_list"]["inputSchema"].get("required"))
    if "task_run_status" not in task_described["task_run"]["description"]:
        fail("task_run's description doesn't send the session to task_run_status for the result")
else:
    fail("--tasks lists %s" % sorted(task_described))

# task_result: a Claude step's answer, listed only while the pane's folder holds the step's schema file, and answered by the server alone. It runs here
# against a scratch home folder, so the schema and the result files are written only there.
scratch = tempfile.mkdtemp(prefix="check-mcp-home-")
try:
    step_pane = "00000000-0000-0000-0000-0000000000aa"
    folder = os.path.join(scratch, "Library", "Application Support", "Varnick", "panes", step_pane)
    os.makedirs(folder)

    def result_server(messages):
        return talk(["--task-result"], messages, home=scratch, pane=step_pane)

    def tool_list():
        replies = result_server([{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        return replies.get(2, {}).get("result", {}).get("tools", [])

    if tool_list():
        fail("--task-result lists %s for a pane whose folder has no schema" % [t["name"] for t in tool_list()])
    with open(os.path.join(folder, ".varnick-task-schema.json"), "w") as schema_file:
        json.dump({"type": "object", "required": ["amount", "currency"], "properties": {
            "amount": {"type": "number"}, "currency": {"type": "string", "enum": ["USD", "EUR"]}, "note": {"type": "string"}}}, schema_file)
    listed_result = tool_list()
    if [t["name"] for t in listed_result] != ["task_result"]:
        fail("--task-result lists %s for a pane whose folder has a schema, not task_result alone" % [t["name"] for t in listed_result])
    elif listed_result[0]["inputSchema"].get("required") != ["amount", "currency"] \
            or set(listed_result[0]["inputSchema"].get("properties", {})) != {"amount", "currency", "note"}:
        fail("task_result's input schema is %s, not the step's result schema" % listed_result[0]["inputSchema"])
    if "task_result" in listed(["--notify"]) or "task_result" in listed(["--screen"]):
        fail("a server started without --task-result lists task_result")

    def task_result(call_id, arguments):
        replies = result_server([{"jsonrpc": "2.0", "id": call_id, "method": "tools/call", "params": {"name": "task_result", "arguments": arguments}}])
        return replies.get(call_id, {}).get("result", {})

    refused_call = task_result(5, {"amount": "five", "extra": 1})
    text = refused_call.get("content", [{}])[0].get("text", "")
    if refused_call.get("isError") is not True or "amount must be" not in text or "currency is missing" not in text or "extra isn't a field" not in text:
        fail("a task_result call that doesn't fit was not refused naming each wrong field: %s" % refused_call)
    if os.path.exists(os.path.join(folder, ".varnick-task-result.json")):
        fail("a refused task_result call left a result behind")
    good = task_result(6, {"amount": 5, "currency": "USD"})
    if good.get("isError") is not False:
        fail("a task_result call that fits was refused: %s" % good)
    try:
        with open(os.path.join(folder, ".varnick-task-result.json")) as result_file:
            kept = json.load(result_file)
    except (OSError, ValueError):
        kept = None
    if kept != {"amount": 5, "currency": "USD"}:
        fail("an accepted task_result call kept %s, not its value" % kept)
    if task_result(7, {"amount": 6, "currency": "EUR"}).get("isError") is not True:
        fail("a second task_result call was not refused")
finally:
    shutil.rmtree(scratch, ignore_errors=True)

# The voice session's own set (option 09 of listening-never-answers, and option 10's end_voice_mode): named by the app for the voice session's pane alone.
# Named alone it lists search and end_voice_mode; with the others they come last. NEVER call either here: with Varnick running and the voice session on,
# a call from the voice session's pane would search the user's history and sessions, or end the Mac's voice mode (a call from any other pane is refused by
# the app). Only a call to a server that does not list it is made (below), and that is refused before anything is sent.
voice_tools = ["search", "end_voice_mode"]
only_search, search_with = listed(["--search"]), listed(["--screen", "--panel", "--automations", "--tasks", "--notify", "--search"])
if only_search != voice_tools:
    fail("--search lists %s, not search and end_voice_mode alone" % only_search)
if search_with != screen + only_panel + automation_tools + task_tools + ["notify"] + voice_tools:
    fail("every set and --search lists %s, with the voice session's tools last" % search_with)
if listed(["--notify", "--search"]) != ["notify"] + voice_tools:
    fail("--notify --search lists %s" % listed(["--notify", "--search"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--tasks"], ["--screen", "--panel", "--automations", "--tasks", "--notify"]):
    for name in voice_tools:
        if name in listed(arguments):
            fail("%s lists %s" % (arguments, name))
ending = [t for t in listed(["--search"], full=True) if t["name"] == "end_voice_mode"]
if ending and (ending[0]["inputSchema"].get("properties") or ending[0]["inputSchema"].get("required")):
    fail("end_voice_mode is %s: it takes no arguments" % ending[0]["inputSchema"])
searching = [t for t in listed(["--search"], full=True) if t["name"] == "search"]
if searching:
    schema = searching[0]["inputSchema"]
    properties = schema.get("properties", {})
    if schema.get("required") != ["query"] or set(properties) != {"query", "project", "from", "to"} or any(properties.get(name, {}).get("type") != "string" for name in properties):
        fail("search is %s: string query (required), project, from and to" % schema)

# The pane tools (option 01 of panes-open-only-by-hand-at-a-mac): their own set, named by the app only while Panel access and Sessions can open panes are
# on, and never for a run's session or the voice session's. Named alone it lists the two; with the others it comes last; with none named the server still
# lists the screen tools alone. Their calls travel as Panel access's requests. NEVER call one of these tools here: with Varnick running, the call reaches
# it and opens a real pane. Only a call to a server that does not list them is made (below), and that is refused before anything is sent.
pane_tools = ["pane_open", "pane_close"]
only_panes = listed(["--panes"])
if only_panes != pane_tools:
    fail("--panes lists %s, not pane_open and pane_close" % only_panes)
if listed(["--screen", "--panel", "--panes"]) != screen + only_panel + pane_tools:
    fail("--screen --panel --panes lists %s, not the screen tools, Panel access's and the pane tools" % listed(["--screen", "--panel", "--panes"]))
if listed(["--notify", "--search", "--panes"]) != ["notify"] + voice_tools + pane_tools:
    fail("--notify --search --panes lists %s, with the pane tools last" % listed(["--notify", "--search", "--panes"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--tasks"], ["--search"], ["--screen", "--panel", "--automations", "--tasks", "--notify", "--search"]):
    if set(listed(arguments)) & set(pane_tools):
        fail("%s lists a pane tool" % arguments)
for name in pane_tools:
    if name in only_panel:
        fail("Panel access's set lists %s: it belongs to --panes" % name)
pane_described = {t["name"]: t for t in listed(["--panes"], full=True)}
if all(name in pane_described for name in pane_tools):
    open_schema = pane_described["pane_open"]["inputSchema"]
    open_properties = open_schema.get("properties", {})
    if open_schema.get("required") != ["kind"] or open_properties.get("kind", {}).get("enum") != ["terminal", "claude", "app", "page", "file"]:
        fail("pane_open is %s: a required kind of terminal, claude, app, page or file" % open_schema)
    for argument in ("folder", "prompt", "agent", "app", "url", "path", "place"):
        if open_properties.get(argument, {}).get("type") != "string":
            fail("pane_open takes no string %s" % argument)
    if open_properties.get("place", {}).get("enum") != ["beside", "below"]:
        fail("pane_open's place is %s, not beside or below" % open_properties.get("place"))
    close_schema = pane_described["pane_close"]["inputSchema"]
    if close_schema.get("required") != ["id"] or close_schema.get("properties", {}).get("id", {}).get("type") != "string":
        fail("pane_close is %s: a required string id" % close_schema)

# A tool a server doesn't list is unknown to it, and nothing is sent to the app.
for arguments, name in ((["--tasks"], "automations_list"), (["--screen", "--panel", "--automations", "--notify"], "tasks_list"), ([], "task_run"),
                        (["--notify"], "task_check"), (["--automations"], "task_run_status"), (["--tasks"], "look"), (["--tasks"], "notify"), (["--notify"], "task_result"),
                        ([], "panel"), (["--screen"], "panel"), (["--panel"], "look"), (["--panel"], "nothing_of_ours"), ([], "notify"), (["--screen"], "notify"), (["--panel"], "notify"), (["--notify"], "look"),
                        ([], "automations_list"), (["--screen"], "automation_create"), (["--panel"], "automation_edit"), (["--notify"], "automation_switch"),
                        (["--screen", "--panel", "--notify"], "automations_list"), (["--automations"], "panel"), (["--automations"], "look"),
                        ([], "search"), (["--notify"], "search"), (["--tasks"], "search"), (["--screen", "--panel", "--automations", "--notify"], "search"),
                        ([], "end_voice_mode"), (["--notify"], "end_voice_mode"), (["--tasks"], "end_voice_mode"), (["--screen", "--panel", "--automations", "--notify"], "end_voice_mode"),
                        (["--search"], "look"), (["--search"], "notify"), (["--search"], "tasks_list"),
                        ([], "pane_open"), ([], "pane_close"), (["--panel"], "pane_open"), (["--screen", "--panel", "--automations", "--tasks", "--notify"], "pane_close"),
                        (["--search"], "pane_open"), (["--panes"], "panel"), (["--panes"], "look"), (["--panes"], "notify")):
    replies = talk(arguments, [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": {}}}])
    if replies.get(3, {}).get("error", {}).get("message") != "Unknown tool":
        fail("%s called %s and did not get Unknown tool: %s" % (arguments, name, replies.get(3)))

sys.exit(1 if bad else 0)
PY
