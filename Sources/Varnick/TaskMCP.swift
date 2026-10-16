import Foundation
import VarnickPeer

// Task tools for sessions (option 01 of `work-cant-be-saved-or-chained`, slice 2a), the relay half: what `Varnick --mcp --tasks` lists and the one socket
// line each call becomes. It never reads or writes: the running Varnick does, in `TaskAccess`. The request is both halves'. What a call means (the
// check, the engine) is in the shared package; the rules are in docs/agents/where-it-breaks.md (Tasks: the engine).

/// One tool call as it travels on the socket. It has no `op`, like a screen, panel or automation request, so the peer relay refuses it and no paired
/// Mac or device can send one; it has a `tasks` key of its own, which is how the app tells it from the others.
struct TaskToolRequest: Codable {
    /// The version of this request: a server from an older launch is told to restart.
    var tasks: Int
    var pane: String
    var tool: String
    var args: [String: TaskValue]

    static let version = 1
}

/// Just the version of a task request, read before the rest so a server from another launch is told to restart.
struct TaskToolRequestHead: Decodable {
    var tasks: Int?
}

enum TaskMCP {
    static let list = "tasks_list"
    static let run = "task_run"
    static let status = "task_run_status"
    static let check = "task_check"

    /// The four tools, as `tools/list` gives them.
    static let tools: [[String: Any]] = [listTool, runTool, statusTool, checkTool]

    /// The names `tools` lists: the only ones a call may use.
    static let names: Set<String> = [list, run, status, check]

    static func requestLine(pane: String, tool: String, arguments: [String: Any]?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var args: [String: TaskValue] = [:]
        for (key, value) in arguments ?? [:] {
            if let converted = TaskValue(any: value), converted != .null { args[key] = converted }
        }
        let request = TaskToolRequest(tasks: TaskToolRequest.version, pane: pane, tool: tool, args: args)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func tool(_ name: String, summary: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": summary, "inputSchema": schema]
    }

    private static let listTool = tool(list,
        summary: "Lists the Tasks Varnick finds from this session's folder: the project's `.varnick/tasks` and the user's own, a project's hiding the user's of "
            + "the same name. Each has its name, description, the JSON Schema of its input and of its result, the capabilities its steps use, whether it is "
            + "valid (with every problem if not: an invalid Task can't start), and its mark (New or Changed until the user has seen its contents). A Task "
            + "is a saved, named state graph of steps (Claude, Judge, Notify, another Task) with a typed input and result. It reads and changes nothing.",
        properties: [:])

    private static let runTool = tool(run,
        summary: "Starts a Run of a Task and answers its id at once; the Run goes on in Varnick, out of sight. `input` is checked against the Task's input "
            + "schema first, and a refusal names each wrong field. The Run's Claude steps draw on the user's Claude subscription and its Judge steps may "
            + "call TypeSafe; nothing asks the user before it starts, so start only what the user asked for. Call task_run_status with the id until the Run "
            + "has ended: it never blocks, since a Run can wait on the user for a day. The user's notice says how the Run ended, either way.",
        properties: [
            "task": ["type": "string", "description": "The Task's name, as tasks_list gives it."],
            "input": ["type": "object", "description": "The Task's input: an object of the fields its input schema lists."],
        ], required: ["task"])

    private static let statusTool = tool(status,
        summary: "The state of a Run: Running, Waiting on you, Done, Failed or Stopped, its current step, its lines so far and, once it has ended, its result "
            + "(the fields of the Task's result schema) or why it failed. Call it again until the Run has ended. It reads and changes nothing.",
        properties: ["run": ["type": "string", "description": "The Run's id, as task_run answered it."]], required: ["run"])

    private static let checkTool = tool(check,
        summary: "Checks a Task file the way Varnick does before a Task can run: it answers every problem in the file, or that it is valid. The file is "
            + "checked as if it sat in the tasks folder of the project it is in, so its sub-tasks are found there and in the user's own. Use it after "
            + "writing or editing a Task, before telling the user it is ready. It reads the file and changes nothing.",
        properties: ["path": ["type": "string", "description": "The Task file's path, absolute or from ~."]], required: ["path"])
}
