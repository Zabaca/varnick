#!/bin/sh
# make check-mcp: checks what `Varnick --mcp` lists and refuses for each set of tools its arguments name, with standard input from a file
# and no running Varnick: the server only lists, and a call to a tool its sets don't list is refused before anything is sent. One `error:`
# line for each problem, exit 1 if there was any. `make check-mcp BIN=<binary>` checks another build. A call that would reach the app
# needs the app and is checked by hand after a restart (docs/agents/where-it-breaks.md, Panel access). The sets are the server's command line; which of
# them the app names for a pane is ClaudeSession.launchClaude's, checked by hand.
set -u
bin=${1:-.build/release/Varnick}
relay=${2:-Packages/VarnickPeer/.build/debug/varnick-peer}
[ -x "$bin" ] || { echo "error: check-mcp: no binary at $bin (make build first)" >&2; exit 1; }
[ -x "$relay" ] || { echo "error: check-mcp: no headless relay at $relay (make check-mcp builds it)" >&2; exit 1; }

exec python3 -I - "$bin" "$relay" <<'PY'
import json, os, shutil, subprocess, sys, tempfile

binary = sys.argv[1]
relay_binary = sys.argv[2]
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

# The find tools (option 01 of sessions-cant-search-sessions): in Panel access's set, right after panel, show and keys, and in no other set. NEVER call one
# here: with Varnick running, find and session_read would send the user's sessions and history to this process and find_open would open a real tab or page.
# Only a call to a server that does not list them is made (below), and that is refused before anything is sent.
find_tools = ["find", "session_read", "find_open"]
if only_panel[:6] != ["panel", "show", "keys"] + find_tools:
    fail("--panel lists %s first, not panel, show, keys and the find tools" % only_panel[:6])
for arguments in ([], ["--screen"], ["--notify"], ["--automations"], ["--search"], ["--panes"]):
    if set(listed(arguments)) & set(find_tools):
        fail("%s lists a find tool" % arguments)
found = {t["name"]: t for t in listed(["--panel"], full=True)}
if all(name in found for name in find_tools):
    find_schema = found["find"]["inputSchema"]
    find_properties = find_schema.get("properties", {})
    if find_schema.get("required"):
        fail("find requires %s: every argument is optional" % find_schema.get("required"))
    if set(find_properties) != {"query", "kinds", "project", "mac", "agent", "from", "to", "limit", "pages"}:
        fail("find takes %s" % sorted(find_properties))
    if find_properties.get("kinds", {}).get("enum") != ["sessions", "pages", "both"]:
        fail("find's kinds is %s, not sessions, pages or both" % find_properties.get("kinds"))
    for name in ("limit", "pages"):
        if find_properties.get(name, {}).get("type") != "integer":
            fail("find's %s is %s, not an integer" % (name, find_properties.get(name)))
    read_schema = found["session_read"]["inputSchema"]
    if read_schema.get("required") != ["conversation"] or set(read_schema.get("properties", {})) != {"conversation", "around", "after", "last", "exchange", "offset"}:
        fail("session_read is %s: a required conversation, and around, after, last, exchange and offset" % read_schema)
    open_schema = found["find_open"]["inputSchema"]
    if set(open_schema.get("properties", {})) != {"conversation", "address", "place"} or open_schema["properties"]["place"].get("enum") != ["beside", "below"]:
        fail("find_open is %s: conversation, address and place (beside or below)" % open_schema)
else:
    fail("--panel lists %s, not the find tools" % sorted(found))

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

# The automation tools (option 01 of prompts-cant-run-on-a-schedule, slice 3): their own set, named by the app for every pane but an automation's
# run. Named alone it lists the five; with the others it comes after Panel access's and before notify; with none named the
# server still lists the screen tools alone. NEVER call one of these tools here: with Varnick running, the call reaches it and makes a real
# automation. Only a call to a server that does not list them is made (below), and that is refused before anything is sent.
automation_tools = ["automations_list", "automation_create", "automation_edit", "automation_switch", "automation_delete"]
only_automations, with_all = listed(["--automations"]), listed(["--screen", "--panel", "--automations", "--notify"])
if only_automations != automation_tools:
    fail("--automations lists %s, not the five automation tools" % only_automations)
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
    for field in ("name", "prompt", "cadence", "folder", "agent", "permissions", "allowed_tools", "working_limit_minutes", "enabled", "tell_when_done"):
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
    # "Tell me when a run is done" (option 01 of automation-runs-crowd-the-menu): a boolean, off when absent.
    if properties.get("tell_when_done", {}).get("type") != "boolean":
        fail("automation_create's tell_when_done is %s, not a boolean" % properties.get("tell_when_done"))
    limit = properties.get("working_limit_minutes", {})
    if (limit.get("minimum"), limit.get("maximum")) != (5, 1440):
        fail("automation_create's working limit is %s to %s, not 5 to 1440" % (limit.get("minimum"), limit.get("maximum")))
    edit_schema = described["automation_edit"]["inputSchema"]
    if edit_schema.get("required") != ["id"] or set(edit_schema.get("properties", {})) != set(properties) | {"id"}:
        fail("automation_edit takes %s requiring %s: id and create's fields, only id required" % (sorted(edit_schema.get("properties", {})), edit_schema.get("required")))
    switch_schema = described["automation_switch"]["inputSchema"]
    if switch_schema.get("required") != ["id", "on"] or switch_schema.get("properties", {}).get("on", {}).get("type") != "boolean":
        fail("automation_switch is %s: an id and a boolean on, both required" % switch_schema)
    delete_schema = described["automation_delete"]["inputSchema"]
    if delete_schema.get("required") != ["id"] or set(delete_schema.get("properties", {})) != {"id"}:
        fail("automation_delete is %s: an id alone, required" % delete_schema)
    for phrase in ("can't be undone", "Tell the user"):
        if phrase not in described["automation_delete"]["description"]:
            fail("automation_delete's description doesn't say %r" % phrase)
    if described["automations_list"]["inputSchema"].get("required"):
        fail("automations_list requires %s" % described["automations_list"]["inputSchema"].get("required"))

# The task tools and `task_result` are gone (Tasks were removed 2026-11-12). A server an older build started may still name `--tasks` or `--task-result`:
# those are ignored, never an error and never a tool. NEVER call a tool through `--tasks` alone: with no set understood the server lists the screen tools.
removed_tools = ["tasks_list", "task_run", "task_run_status", "task_check", "task_result"]
if listed(["--tasks", "--notify"]) != ["notify"] or listed(["--notify", "--task-result"]) != ["notify"]:
    fail("--tasks or --task-result changes what --notify lists: %s, %s" % (listed(["--tasks", "--notify"]), listed(["--notify", "--task-result"])))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--tasks", "--notify"], ["--notify", "--task-result"],
                  ["--screen", "--panel", "--automations", "--tasks", "--notify", "--task-result"]):
    if set(listed(arguments)) & set(removed_tools):
        fail("%s lists a task tool" % arguments)

# The voice session's own set (option 09 of listening-never-answers, and option 10's end_voice_mode): named by the app for the voice session's pane alone.
# Named alone it lists search and end_voice_mode; with the others they come last. NEVER call either here: with Varnick running and the voice session on,
# a call from the voice session's pane would search the user's history and sessions, or end the Mac's voice mode (a call from any other pane is refused by
# the app). Only a call to a server that does not list it is made (below), and that is refused before anything is sent.
voice_tools = ["search", "end_voice_mode"]
only_search, search_with = listed(["--search"]), listed(["--screen", "--panel", "--automations", "--notify", "--search"])
if only_search != voice_tools:
    fail("--search lists %s, not search and end_voice_mode alone" % only_search)
if search_with != screen + only_panel + automation_tools + ["notify"] + voice_tools:
    fail("every set and --search lists %s, with the voice session's tools last" % search_with)
if listed(["--notify", "--search"]) != ["notify"] + voice_tools:
    fail("--notify --search lists %s" % listed(["--notify", "--search"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--screen", "--panel", "--automations", "--notify"]):
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

# The pane tools (option 01 of panes-open-only-by-hand-at-a-mac, tab_open from option 01, tab_done from option 06 and project_search from option 07 of sessions-cant-start-sessions-in-other-projects): their own set. Named alone it
# lists the five; with the others it comes last; with none named the server still lists the screen tools alone. Their calls travel as Panel access's requests. NEVER call one of these tools here: with Varnick running, the call reaches
# it and opens a real pane. Only a call to a server that does not list them is made (below), and that is refused before anything is sent.
pane_tools = ["pane_open", "pane_close", "tab_open", "tab_done", "project_search"]
only_panes = listed(["--panes"])
if only_panes != pane_tools:
    fail("--panes lists %s, not pane_open, pane_close, tab_open, tab_done and project_search" % only_panes)
if listed(["--screen", "--panel", "--panes"]) != screen + only_panel + pane_tools:
    fail("--screen --panel --panes lists %s, not the screen tools, Panel access's and the pane tools" % listed(["--screen", "--panel", "--panes"]))
if listed(["--notify", "--search", "--panes"]) != ["notify"] + voice_tools + pane_tools:
    fail("--notify --search --panes lists %s, with the pane tools last" % listed(["--notify", "--search", "--panes"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--search"], ["--screen", "--panel", "--automations", "--notify", "--search"]):
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
    tab_schema = pane_described["tab_open"]["inputSchema"]
    tab_properties = tab_schema.get("properties", {})
    if tab_schema.get("required") != ["project"] or set(tab_properties) != {"project", "machine", "agent", "prompt"} or any(tab_properties[name].get("type") != "string" for name in tab_properties):
        fail("tab_open is %s: a required string project and optional string machine, agent and prompt, nothing else (no folder, place or permission argument)" % tab_schema)
    tab_description = pane_described["tab_open"]["description"]
    for phrase in ("not brought up", "Project", "SendMessage", "never skips permission checks when this session does not", "Open only what the user asked for",
                   "machine", "project_search", "controlled from here", "messages both ways", "opener", "14 seconds", "not call again"):
        if phrase not in tab_description:
            fail("tab_open's description doesn't say %r" % phrase)
    if "This Mac's projects only" in tab_description:
        fail("tab_open's description still says it opens on this Mac's projects only")
    search_schema = pane_described["project_search"]["inputSchema"]
    search_properties = search_schema.get("properties", {})
    if search_schema.get("required") is not None or set(search_properties) != {"machine", "search"} or any(search_properties[name].get("type") != "string" for name in search_properties):
        fail("project_search is %s: optional string machine and search, nothing else" % search_schema)
    search_description = pane_described["project_search"]["description"]
    for phrase in ("tab_open", "most recently", "50", "trusted", "not known", "machine", "search", "path"):
        if phrase not in search_description:
            fail("project_search's description doesn't say %r" % phrase)
    if "pane_close does not close it" in tab_description or "tab_done" not in tab_description:
        fail("tab_open's description should send the caller to tab_done, not say pane_close does not close it")
    done_schema = pane_described["tab_done"]["inputSchema"]
    if done_schema.get("required") != ["id"] or set(done_schema.get("properties", {})) != {"id"} or done_schema["properties"]["id"].get("type") != "string":
        fail("tab_done is %s: a required string id, nothing else (no force or reason argument)" % done_schema)
    done_description = pane_described["tab_done"]["description"]
    for phrase in ("Completed", "tab_open", "board_read", "taken the tab over", "working", "waits on the user", "this session's own tab", "another machine"):
        if phrase not in done_description:
            fail("tab_done's description doesn't say %r" % phrase)

# outline_append (ADR 0040's amendment of 2026-10-29): the one write an automation's run may make to the Outline, listed only when the app names
# --outline-append, which it does for a run whose allowed tools name the tool. Named with --notify (a run's set) it lists notify then outline_append;
# a run without it lists notify alone. NEVER call it here: with Varnick running, the call reaches it and files a real bullet in the user's Outline.
# Only a call to a server that does not list it is made (below), and that is refused before anything is sent.
append_tool = ["outline_append"]
if listed(["--notify", "--outline-append"]) != ["notify"] + append_tool:
    fail("--notify --outline-append lists %s, not notify then outline_append" % listed(["--notify", "--outline-append"]))
if listed(["--notify"]) != ["notify"]:
    fail("a run's set without --outline-append lists %s, not notify alone" % listed(["--notify"]))
if listed(["--outline-append"]) != append_tool:
    fail("--outline-append lists %s, not outline_append alone" % listed(["--outline-append"]))
if listed(["--screen", "--panel", "--automations", "--notify", "--search", "--panes", "--outline-append"]) \
        != screen + only_panel + automation_tools + ["notify"] + voice_tools + pane_tools + append_tool:
    fail("every set lists %s, with outline_append last" % listed(["--screen", "--panel", "--automations", "--notify", "--search", "--panes", "--outline-append"]))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--search"], ["--panes"], ["--screen", "--panel", "--automations", "--notify", "--search", "--panes"]):
    if "outline_append" in listed(arguments):
        fail("%s lists outline_append" % arguments)
appended = [t for t in listed(["--outline-append"], full=True) if t["name"] == "outline_append"]
if appended:
    schema = appended[0]["inputSchema"]
    properties = schema.get("properties", {})
    if schema.get("required") != ["heading", "text"] or set(properties) != {"heading", "text", "note"} or any(properties[name].get("type") != "string" for name in properties):
        fail("outline_append is %s: string heading and text (required) and an optional string note, nothing else" % schema)
    description = appended[0]["description"]
    for phrase in ("without reading it", "at most 20000 bytes", "1 to 80", "1 to 300", "One call adds one bullet"):
        if phrase not in description:
            fail("outline_append's description doesn't say %r" % phrase)

# The send tool (option 01 of sessions-cant-reach-each-other-reliably): its own set, named by the app only for a pane started while Messages between sessions is
# on and ready. Named alone it lists send alone; with every other set it comes last; no other set lists it. NEVER call it here: with Varnick running, the
# call reaches it and queues a real message for a real session. Only a call to a server that does not list it is made (below), and that is refused before
# anything is sent.
if listed(["--send"]) != ["send"]:
    fail("--send lists %s, not send alone" % listed(["--send"]))
everything = ["--screen", "--panel", "--automations", "--notify", "--search", "--panes", "--outline-append", "--send"]
if listed(everything)[-1:] != ["send"] or listed(everything)[:-1] != listed(everything[:-1]):
    fail("every set lists %s, with send last" % listed(everything))
for arguments in ([], ["--screen"], ["--panel"], ["--notify"], ["--automations"], ["--search"], ["--panes"], ["--outline-append"],
                  ["--screen", "--panel", "--automations", "--notify", "--search", "--panes", "--outline-append"], ["--notify", "--outline-append"]):
    if "send" in listed(arguments):
        fail("%s lists send" % arguments)
sending = [t for t in listed(["--send"], full=True) if t["name"] == "send"]
if sending:
    schema = sending[0]["inputSchema"]
    properties = schema.get("properties", {})
    if schema.get("required") != ["to", "text"] or set(properties) != {"to", "text"} or any(properties[name].get("type") != "string" for name in properties):
        fail("send is %s: a required string to and a required string text, nothing else" % schema)
    description = sending[0]["description"]
    for phrase in ("opener", "At most 10 messages a minute", "never says the message was acted on", "not the user's approval", "except one that skips permission checks"):
        if phrase not in description:
            fail("send's description doesn't say %r" % phrase)
    if len(description) > 2400:
        fail("send's description is %d characters" % len(description))

# A tool a server doesn't list is unknown to it, and nothing is sent to the app. The removed task tools are listed by no set.
for arguments, name in ((["--screen", "--panel", "--automations", "--notify"], "tasks_list"), ([], "task_run"),
                        (["--notify"], "task_check"), (["--automations"], "task_run_status"), (["--notify"], "task_result"),
                        ([], "panel"), (["--screen"], "panel"), (["--panel"], "look"), (["--panel"], "nothing_of_ours"), ([], "notify"), (["--screen"], "notify"), (["--panel"], "notify"), (["--notify"], "look"),
                        ([], "automations_list"), (["--screen"], "automation_create"), (["--panel"], "automation_edit"), (["--notify"], "automation_switch"), (["--screen", "--panel"], "automation_delete"),
                        (["--screen", "--panel", "--notify"], "automations_list"), (["--automations"], "panel"), (["--automations"], "look"),
                        ([], "search"), (["--notify"], "search"), (["--screen", "--panel", "--automations", "--notify"], "search"),
                        ([], "end_voice_mode"), (["--notify"], "end_voice_mode"), (["--screen", "--panel", "--automations", "--notify"], "end_voice_mode"),
                        (["--search"], "look"), (["--search"], "notify"), (["--search"], "tasks_list"),
                        ([], "pane_open"), ([], "pane_close"), ([], "tab_open"), ([], "tab_done"), ([], "project_search"), (["--panel"], "pane_open"), (["--panel"], "tab_open"), (["--panel"], "tab_done"), (["--panel"], "project_search"), (["--screen", "--panel", "--automations", "--notify"], "pane_close"),
                        (["--search"], "pane_open"), (["--search"], "tab_open"), (["--search"], "tab_done"), (["--search"], "project_search"), (["--send"], "project_search"), (["--panes"], "panel"), (["--panes"], "look"), (["--panes"], "notify"),
                        ([], "outline_append"), (["--notify"], "outline_append"), (["--panel"], "outline_append"), (["--automations"], "outline_append"), (["--outline-append"], "notify"), (["--outline-append"], "outline_act"),
                        ([], "find"), (["--screen"], "find"), (["--notify"], "session_read"), (["--panes"], "find_open"), (["--search"], "find"),
                        ([], "send"), (["--panes"], "send"), (["--panel"], "send"), (["--notify"], "send"), (["--screen", "--panel", "--automations", "--notify", "--search", "--panes", "--outline-append"], "send"),
                        (["--send"], "panel"), (["--send"], "pane_open"), (["--send"], "tab_open"), (["--send"], "notify")):
    replies = talk(arguments, [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": {}}}])
    if replies.get(3, {}).get("error", {}).get("message") != "Unknown tool":
        fail("%s called %s and did not get Unknown tool: %s" % (arguments, name, replies.get(3)))

# The channel server (option 01 of sessions-cant-reach-each-other-reliably): `Varnick --channel --pane <id>`, started with a scratch home folder so its pane's queue
# and mark are in the scratch folder and not the user's. It answers server/discover with "method not found" and initialize with the channel capability, the
# instructions and a protocol revision older than 2026-07-28; lists no tools; pushes nothing before the client says it is initialized, then every queued
# message in the order it was queued, as notifications/claude/channel lines with the text, `from` and `from_project`; keeps a mark while it runs and removes it at
# the end of its input. Its exact words and every refusal are `make check-messages`'s.
import select, time

def channel_check(what, make_command, panes_under):
    """Runs the channel server `make_command(home)` names against a scratch folder: `panes_under(home)` is where its panes' folders are."""
    home = tempfile.mkdtemp(prefix="check-channel-")
    try:
        pane_id = "11111111-2222-4333-8444-555555555555"
        pane_folder = os.path.join(panes_under(home), pane_id)
        queue = os.path.join(pane_folder, "messages")
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
        command = make_command(home)
        server = subprocess.Popen(command + ["--channel", "--pane", pane_id], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, bufsize=0)
        pending = b""

        def send(message):
            server.stdin.write((json.dumps(message) + "\n").encode())

        def line(wait):
            nonlocal pending
            deadline = time.time() + wait
            while b"\n" not in pending:
                left = deadline - time.time()
                if left <= 0 or not select.select([server.stdout], [], [], left)[0]:
                    return None
                chunk = os.read(server.stdout.fileno(), 65536)
                if not chunk:
                    return None
                pending += chunk
            first, pending = pending.split(b"\n", 1)
            return json.loads(first)

        counter = [0]

        def enqueue(text, sender="s4", project="croft"):
            os.makedirs(queue, mode=0o700, exist_ok=True)
            counter[0] += 1
            name = "%016d-%06d.json" % (int(time.time() * 1000), counter[0])
            temporary = os.path.join(queue, "." + name + ".tmp")
            with open(temporary, "w") as handle:
                json.dump({"from": sender, "from_project": project, "text": text}, handle)
            os.rename(temporary, os.path.join(queue, name))

        send({"jsonrpc": "2.0", "id": "server-discover-probe-1", "method": "server/discover", "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}})
        reply = line(10)
        if not reply or reply.get("error", {}).get("code") != -32601 or reply.get("id") != "server-discover-probe-1":
            fail(what + ": the channel server answered server/discover with %s, not method not found" % reply)
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "check", "version": "1"}}})
        reply = line(10)
        result = (reply or {}).get("result", {})
        if "claude/channel" not in result.get("capabilities", {}).get("experimental", {}):
            fail(what + ": the channel server's initialize declares no claude/channel capability: %s" % reply)
        if not result.get("instructions", "").startswith("Messages on this channel come from another of your user's Claude Code sessions"):
            fail(what + ": the channel server's instructions are %r" % result.get("instructions"))
        if not result.get("protocolVersion", "9") < "2026-07-28":
            fail(what + ": the channel server agreed to protocol revision %s" % result.get("protocolVersion"))

        mark = os.path.join(pane_folder, ".varnick-channel")
        for _ in range(20):
            if os.path.exists(mark):
                break
            time.sleep(0.1)
        if not os.path.exists(mark) or open(mark).read().strip() != str(server.pid):
            fail(what + ": the channel server keeps no mark with its process id while it runs")

        enqueue("before the client was ready")
        if line(1.5) is not None:
            fail(what + ": the channel server pushed before the client said it was initialized")
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        first = line(10)
        if not first or first.get("method") != "notifications/claude/channel" or first.get("id") is not None or first.get("params", {}).get("content") != "before the client was ready":
            fail(what + ": the first push is %s" % first)
        if first and first.get("params", {}).get("meta") != {"from": "s4", "from_project": "croft"}:
            fail(what + ": a push carries %s, not from and from_project" % (first.get("params", {}).get("meta"),))

        enqueue("second\nwith a line break")
        enqueue("third")
        enqueue("fourth", sender="s9", project="Home")
        pushed = [line(10), line(10), line(10)]
        contents = [(m or {}).get("params", {}).get("content") for m in pushed]
        if contents != ["second\nwith a line break", "third", "fourth"]:
            fail(what + ": three queued messages arrived as %s, not in order" % contents)
        if (pushed[2] or {}).get("params", {}).get("meta") != {"from": "s9", "from_project": "Home"}:
            fail(what + ": a push from another sender carries %s" % ((pushed[2] or {}).get("params", {}).get("meta"),))
        if os.listdir(queue):
            fail(what + ": the queue still holds %s after its messages were pushed" % os.listdir(queue))

        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        reply = line(10)
        if (reply or {}).get("result", {}).get("tools") != []:
            fail(what + ": the channel server lists tools: %s" % reply)
        server.stdin.close()
        try:
            status = server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            status = None
            fail(what + ": the channel server did not exit when its input ended")
        if status not in (0, None):
            fail(what + ": the channel server exited with %s" % status)
        if os.path.exists(mark):
            fail(what + ": the channel server left its mark behind")
    finally:
        shutil.rmtree(home, ignore_errors=True)

def mac_command(home):
    return [binary]

channel_check("Varnick", mac_command, lambda home: os.path.join(home, "Library", "Application Support", "Varnick", "panes"))

# The headless relay (option 07 of sessions-cant-reach-each-other-reliably): the same binary copied into a scratch install folder, so its `state/` folder, where the
# panes' folders and the outbox are, is the scratch one and not a host's. `--mcp --notify` lists notify alone and with `--send` lists notify then send, whose host
# wording is the answering tool's; send is Unknown tool without `--send`; a send to an id the session was never given is refused before anything is written; and
# its `--channel` is the app's channel server over the host's state folder.
def relay_in(home):
    install = os.path.join(home, "install")
    os.makedirs(install, exist_ok=True)
    copy = os.path.join(install, "varnick-peer")
    # Removed first: macOS kills (SIGKILL) the next exec of a signed binary that was rewritten in place, so each call gets a fresh file.
    if os.path.exists(copy):
        os.remove(copy)
    shutil.copy(relay_binary, copy)
    os.chmod(copy, 0o755)
    return copy

def relay_talk(home, arguments, messages):
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    out = subprocess.run([relay_in(home), "--mcp", "--pane", pane] + arguments, input=lines, capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        fail("the relay %s exited with %d: %s" % (arguments, out.returncode, out.stderr.strip()))
    return {json.loads(line).get("id"): json.loads(line) for line in out.stdout.splitlines()}

relay_home = tempfile.mkdtemp(prefix="check-relay-")
try:
    handshake = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                 {"jsonrpc": "2.0", "method": "notifications/initialized"},
                 {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
    def relay_tools(arguments):
        return relay_talk(relay_home, arguments, handshake).get(2, {}).get("result", {}).get("tools", [])
    if [t["name"] for t in relay_tools(["--notify"])] != ["notify"]:
        fail("the relay's --notify lists %s, not notify alone" % [t["name"] for t in relay_tools(["--notify"])])
    host_tools = relay_tools(["--notify", "--send"])
    if [t["name"] for t in host_tools] != ["notify", "send"]:
        fail("the relay's --notify --send lists %s, not notify then send" % [t["name"] for t in host_tools])
    host_send = [t for t in host_tools if t["name"] == "send"]
    if host_send:
        schema = host_send[0]["inputSchema"]
        if schema.get("required") != ["to", "text"] or set(schema.get("properties", {})) != {"to", "text"}:
            fail("the host's send is %s: a required to and text, nothing else" % schema)
        words = host_send[0]["description"]
        for phrase in ("`from` of a message this session received", "cannot send first", "not the user's approval", "10 messages a minute", "never says the message was acted on"):
            if phrase not in words:
                fail("the host's send description doesn't say %r" % phrase)
        for phrase in ("`opener`", "tab_open", "another machine"):
            if phrase not in words:
                fail("the host's send description doesn't say %r: a host session opened by a Mac reaches its opener" % phrase)
        if "board_read" in words:
            fail("the host's send description names board_read, which a host session has not")
        if "`opener`" not in json.dumps(host_send[0]["inputSchema"]):
            fail("the host's send `to` doesn't take opener")
    mac_send = [t for t in listed(["--send"], full=True) if t["name"] == "send"]
    if mac_send and host_send and mac_send[0]["description"] == host_send[0]["description"]:
        fail("the host's send description is the Mac's")
    unknown = relay_talk(relay_home, ["--notify"], [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send", "arguments": {"to": "s1", "text": "hi"}}}])
    if unknown.get(3, {}).get("error", {}).get("message") != "Unknown tool":
        fail("the relay's --notify server answered a send call with %s, not Unknown tool" % unknown.get(3))
    refused = relay_talk(relay_home, ["--notify", "--send"], [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send", "arguments": {"to": "s1", "text": "hi"}}}])
    result = refused.get(3, {}).get("result", {})
    if result.get("isError") is not True or "No such id" not in result.get("content", [{}])[0].get("text", "") or "Nothing was sent" not in result["content"][0]["text"]:
        fail("a host send to an id it was never given was not refused as no such id: %s" % refused.get(3))
    state_outbox = os.path.join(relay_home, "install", "state", "outbox")
    if os.path.exists(state_outbox):
        fail("a refused host send left an outbox behind")
    empty = relay_talk(relay_home, ["--notify", "--send"], [{"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "send", "arguments": {"to": "s1", "text": "  "}}}])
    if empty.get(3, {}).get("result", {}).get("isError") is not True or "text is needed" not in empty[3]["result"]["content"][0]["text"]:
        fail("a host send with no text was not refused: %s" % empty.get(3))
finally:
    shutil.rmtree(relay_home, ignore_errors=True)

channel_check("the relay", lambda home: [relay_in(home)], lambda home: os.path.join(home, "install", "state", "panes"))

sys.exit(1 if bad else 0)
PY
