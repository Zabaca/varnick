import Foundation

// The `task_result` tool of a Claude step (option 01 of `work-cant-be-saved-or-chained`, slice 2a): the step's answer. Its input schema is the step's
// result schema, which the host writes into the pane's folder before the pane starts. The pane's own MCP server (`Varnick --mcp --task-result`) checks
// each call against that file and refuses a wrong one, naming each wrong field, so Claude tries again; an accepted value goes into a result file in the
// same folder, which the host moves onto the step. Like `notify`, it is answered by the server alone, so the headless relay can answer it with no
// running Varnick. Foundation only. The rules are in docs/agents/where-it-breaks.md (Tasks: the engine).

public enum TaskResultTool {
    public static let name = "task_result"
    /// The command-line argument that adds the tool to a server's lists.
    public static let argument = "--task-result"
    public static var qualifiedName: String { "mcp__\(MCPServer.name)__\(name)" }

    static let schemaFileName = ".varnick-task-schema.json"
    static let resultFileName = ".varnick-task-result.json"

    /// Appended to the step's prompt, in Varnick's own words: it is how Claude learns where its answer goes.
    public static let askLine = "When you have the result, call the task_result tool once with it: its arguments are the result's fields. "
        + "Varnick reads nothing you say in reply, only that call."

    public static func schemaFile(in folder: URL) -> URL { folder.appendingPathComponent(schemaFileName) }

    public static func resultFile(in folder: URL) -> URL { folder.appendingPathComponent(resultFileName) }

    // MARK: The host's half

    /// Writes the step's result schema into the pane's folder, and clears any result file an earlier step left there.
    public static func prepare(_ schema: TaskSchema, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: resultFile(in: folder))
        let data = try JSONSerialization.data(withJSONObject: schema.jsonSchema, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: schemaFile(in: folder), options: .atomic)
    }

    /// Whether the folder holds a step's schema: the pane lists `task_result` while it does.
    public static func isPrepared(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: schemaFile(in: folder).path)
    }

    /// The value the pane's server accepted, nil until it has.
    public static func accepted(in folder: URL) -> TaskValue? {
        guard let data = try? Data(contentsOf: resultFile(in: folder)) else { return nil }
        return try? JSONDecoder().decode(TaskValue.self, from: data)
    }

    /// Removes both files when the step ends.
    public static func clear(in folder: URL) {
        try? FileManager.default.removeItem(at: schemaFile(in: folder))
        try? FileManager.default.removeItem(at: resultFile(in: folder))
    }

    // MARK: The server's half

    private static func schema(in folder: URL) -> TaskSchema? {
        guard let data = try? Data(contentsOf: schemaFile(in: folder)),
              let value = try? JSONDecoder().decode(TaskValue.self, from: data) else { return nil }
        return TaskSchema.read(value, at: "result").schema
    }

    /// The tool as `tools/list` gives it for the folder's schema; none while the folder holds no readable one.
    public static func tools(in folder: URL) -> [[String: Any]] {
        guard let schema = schema(in: folder) else { return [] }
        var input = schema.jsonSchema
        input["type"] = "object"
        let fields = schema.formFields.map(\.name)
        return [[
            "name": name,
            "description": "Gives Varnick this step's result. Call it once, when you have it: its arguments are the result's fields"
                + (fields.isEmpty ? "" : " (\(fields.joined(separator: ", ")))")
                + ". A call that doesn't fit is refused with each wrong field named; call it again with those fixed. Nothing you say in reply is read.",
            "inputSchema": input,
        ]]
    }

    /// The answer to a call. A value that doesn't fit is refused naming each field; the first that fits is kept, and a second call is refused.
    public static func call(_ arguments: [String: Any]?, in folder: URL) -> MCPResult {
        guard let schema = schema(in: folder) else {
            return MCPResult(text: "There is no result to give: this step has no result schema.", isError: true)
        }
        if FileManager.default.fileExists(atPath: resultFile(in: folder).path) {
            return MCPResult(text: "The result was already given. Varnick has it; nothing more is needed.", isError: true)
        }
        guard let value = TaskValue(any: arguments ?? [:]) else {
            return MCPResult(text: "The arguments weren't JSON.", isError: true)
        }
        let problems = schema.problems(of: value)
        guard problems.isEmpty else {
            return MCPResult(text: "The result doesn't fit. " + problems.joined(separator: "; ") + ". Call task_result again with these fixed.", isError: true)
        }
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: resultFile(in: folder), options: .atomic)
        } catch {
            return MCPResult(text: "Varnick couldn't keep the result. Call task_result again.", isError: true)
        }
        return MCPResult(text: "Varnick has the result. Nothing more is needed.")
    }

    /// A pane's own folder.
    public static func folder(for pane: UUID) -> URL { PaneFolder.url(for: pane) }
}
