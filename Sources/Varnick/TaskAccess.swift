import AppKit
import Foundation
import VarnickPeer

// Task tools for sessions (option 01 of `work-cant-be-saved-or-chained`, slice 2a), the running Varnick's half: the answers to the calls a pane's
// `Varnick --mcp --tasks` relays (`TaskMCP`). They are answered over the socket in `AutomationAccess`'s order: the switch, Varnick having started, the
// calling pane, the runs file, then the tool. The handler is async so a call reads Task files off the main thread. What a call means is in the shared
// package (`TaskDefinition.check`, `TaskEngine`); the rules that break are in docs/agents/where-it-breaks.md (Tasks: the engine).

/// Why a call did nothing. The message is the session's to act on; the log names only the kind.
enum TaskCallRefusal: Error {
    case unreadable
    case versionDiffers
    case off
    case starting
    case noPane
    /// The call came from a Run's own session, or an automation's, which never has these tools: a request named its pane's id anyway.
    case fromRun
    /// The runs file can't be read or is from a newer build, so nothing starts; the message is the store's own reason.
    case fileProblem(String)
    case unknownTool(String)
    case unknownTask(String)
    case unknownRun
    /// The Task or the arguments are not ones the tool takes, one line each.
    case refused([String])

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: ScreenRefusal.restartThisSession
        case .off: "Tasks is off in Varnick's Settings › Experimental"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .fromRun: "A Run's own session, and an automation's, may not list, start or check Tasks"
        case .fileProblem(let why): why
        case .unknownTool(let name): "Unknown tool \(name)"
        case .unknownTask(let name): "No Task is called \"\(name)\" here. tasks_list gives the Tasks found from this session's folder"
        case .unknownRun: "No Run has this id. task_run answers it"
        case .refused(let lines): "Nothing was started. " + lines.joined(separator: "; ")
        }
    }

    var logKind: String {
        switch self {
        case .unreadable: "unreadable"
        case .versionDiffers: "version"
        case .off: "off"
        case .starting: "starting"
        case .noPane: "no pane"
        case .fromRun: "from a run"
        case .fileProblem: "file problem"
        case .unknownTool: "unknown tool"
        case .unknownTask: "unknown task"
        case .unknownRun: "unknown run"
        case .refused: "refused"
        }
    }
}

@MainActor
final class TaskAccess {
    static let shared = TaskAccess()

    /// One task request line from the socket, answered as one reply line.
    func answer(_ line: String) async -> String {
        let arrived = ContinuousClock.now
        var tool = "-"
        var kind = "ok"
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(TaskToolRequestHead.self, from: line) else { throw TaskCallRefusal.unreadable }
            guard head.tasks == TaskToolRequest.version else { throw TaskCallRefusal.versionDiffers }
            guard let request = PeerJSON.decode(TaskToolRequest.self, from: line) else { throw TaskCallRefusal.unreadable }
            tool = TaskMCP.names.contains(request.tool) ? request.tool : "-"
            reply = ScreenReply(text: try await run(request), isError: false)
        } catch let refusal as TaskCallRefusal {
            kind = refusal.logKind
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the tool, the outcome's kind and the duration: never a Task's name, an input, a path or the request's own words.
        NSLog("Varnick: tasks %@ %@ [%.2f s]", tool, kind, arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    /// In order: the switch, Varnick starting, the pane (a Claude pane on this Mac whose record names no automation and no Run), the runs file being
    /// readable, then the tool.
    private func run(_ request: TaskToolRequest) async throws -> String {
        guard Settings.shared.tasksOn else { throw TaskCallRefusal.off }
        guard let model = PeerManager.shared.model else { throw TaskCallRefusal.starting }
        let caller = try callingPane(request.pane, in: model)
        guard caller.record.automation == nil, caller.record.taskRun == nil else { throw TaskCallRefusal.fromRun }
        if let problem = model.taskRuns.problem { throw TaskCallRefusal.fileProblem(problem) }
        switch request.tool {
        case TaskMCP.list: return await list(model, caller: caller)
        case TaskMCP.run: return try await start(request.args, model, caller: caller)
        case TaskMCP.status: return try status(request.args, model)
        case TaskMCP.check: return try await check(request.args)
        default: throw TaskCallRefusal.unknownTool(request.tool)
        }
    }

    // MARK: The tools

    private func list(_ model: LauncherModel, caller: ClaudeSession) async -> String {
        let files = await TaskCatalog.read(from: caller.record.directory)
        let rows: [[String: Any]] = files.map { file in
            var row: [String: Any] = [
                "name": file.name,
                "file": file.path,
                "valid": file.isValid,
                "problems": file.problems,
                "mark": TaskGrants.shared.mark(of: file)?.text ?? NSNull(),
            ]
            if let definition = file.definition {
                row["description"] = definition.summary
                row["input_schema"] = definition.input.jsonSchema
                row["result_schema"] = definition.result.jsonSchema
                row["capabilities"] = definition.capabilities.map(\.rawValue)
            }
            return row
        }
        let document: [String: Any] = ["folder": caller.record.directory, "tasks": rows]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let intro = rows.isEmpty ? "No Tasks are found from this session's folder (.varnick/tasks here, or in the user's own ~/.varnick/tasks)."
            : "\(rows.count) Task\(rows.count == 1 ? "" : "s") found from this session's folder. A Task that isn't valid can't start; task_check says what is wrong with a file."
        return intro + "\n" + String(decoding: data, as: UTF8.self)
    }

    private func start(_ args: [String: TaskValue], _ model: LauncherModel, caller: ClaudeSession) async throws -> String {
        let extra = args.keys.sorted().filter { $0 != "task" && $0 != "input" }.map { "\($0) is not an argument: the arguments are task and input" }
        guard extra.isEmpty else { throw TaskCallRefusal.refused(extra) }
        guard let name = args["task"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw TaskCallRefusal.refused(["task is required: a Task's name from tasks_list"])
        }
        var input: [String: TaskValue] = [:]
        if let given = args["input"] {
            // A model may send the object as JSON text.
            if let object = given.object {
                input = object
            } else if let text = given.text, let parsed = TaskValue(jsonText: text), let object = parsed.object {
                input = object
            } else {
                throw TaskCallRefusal.refused(["input must be an object, not \(given.kindWord)"])
            }
        }
        let folder = caller.record.directory
        let files = await TaskCatalog.read(from: folder)
        guard let file = TaskFiles.find(name, in: files) else { throw TaskCallRefusal.unknownTask(name) }
        guard file.isValid else { throw TaskCallRefusal.refused(["\(file.name) isn't valid: " + file.problems.joined(separator: "; ")]) }
        let title = PanelAccess.oneLine(caller.label, limit: 60)
        switch model.taskHost.startRun(file, input: input, trigger: .session(titled: title, at: Date()), folder: folder) {
        case .failure(let refusal):
            throw TaskCallRefusal.refused(refusal.problems)
        case .success(let id):
            return "Started \(file.name) as Run \(id.uuidString). It goes on out of sight in Varnick. Call task_run_status with this id until the Run has ended; "
                + "Varnick's own notice tells the user how it ended."
        }
    }

    private func status(_ args: [String: TaskValue], _ model: LauncherModel) throws -> String {
        guard let text = args["run"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), let id = UUID(uuidString: text),
              let run = model.taskRuns.run(id), run.trigger.automation == nil else { throw TaskCallRefusal.unknownRun }
        let formatter = ISO8601DateFormatter()
        var document: [String: Any] = [
            "run": run.id.uuidString,
            "task": run.task,
            "state": run.state.text,
            "ended": !run.state.isGoing,
            "started": run.startedAt.map { formatter.string(from: $0) } ?? NSNull(),
            "started_by": run.trigger.startedBy,
            "lines": run.lines.map { "\($0.actor): \($0.text)" },
        ]
        if let index = run.inFlightIndex { document["current_step"] = run.steps[index].name }
        if run.state == .done { document["result"] = run.result?.any ?? [String: Any]() }
        if run.state.isGoing { document["note"] = run.detail ?? NSNull() } else if run.state != .done { document["failure"] = run.detail ?? run.state.text }
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let head = run.state.isGoing ? "The Run is \(run.state.text.lowercased()). Call this again." : "The Run has ended: \(run.state.text.lowercased())."
        return head + "\n" + String(decoding: data, as: UTF8.self)
    }

    private func check(_ args: [String: TaskValue]) async throws -> String {
        guard let path = args["path"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw TaskCallRefusal.refused(["path is required: a Task file's path"])
        }
        let file = await Task.detached(priority: .userInitiated) { TaskFiles.check(path: path) }.value
        guard file.isValid else {
            return "\(file.name) isn't valid. It can't start until every one of these is fixed:\n" + file.problems.map { "- \($0)" }.joined(separator: "\n")
        }
        return "\(file.name) is valid. Its steps use \(file.definition?.capabilities.map(\.title).joined(separator: ", ") ?? "no capabilities"). "
            + "Settings › Tasks lists it, marked New or Changed until the user presses Seen."
    }

    // MARK: Helpers

    /// The calling pane: a Claude pane on this Mac, as for the automation tools (its session runs here, whoever controls it).
    private func callingPane(_ text: String, in model: LauncherModel) throws -> ClaudeSession {
        guard let id = UUID(uuidString: text),
              let session = model.tabs.lazy.flatMap(\.sessions).first(where: { $0.id == id && $0.isClaude && !$0.isOnPeer }) else { throw TaskCallRefusal.noPane }
        return session
    }
}
