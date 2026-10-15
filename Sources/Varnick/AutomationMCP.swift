import Foundation
import VarnickPeer

// Automation tools for sessions (option 01 of `prompts-cant-run-on-a-schedule`, slice 3), the relay half: what `Varnick --mcp --automations` lists
// and the one socket line each call becomes. It never reads or writes: the running Varnick does, in `AutomationAccess`, through the automation
// store. The request is both halves'. The arguments' meaning (what is checked, what a call changes) is `AutomationTools`, in the shared package.

/// One tool call as it travels on the socket. It has no `op`, like a screen or a panel request, so the peer relay refuses it and no paired Mac or
/// device can send one; it has an `automation` key of its own, which is how the app tells it from the other two.
struct AutomationRequest: Codable {
    /// The version of this request: a server from an older launch is told to restart.
    var automation: Int
    var pane: String
    var tool: String
    var args: PanelArguments

    static let version = 1
}

/// Just the version of an automation request, read before the rest so a server from another launch is told to restart.
struct AutomationRequestHead: Decodable {
    var automation: Int?
}

enum AutomationMCP {
    static let list = "automations_list"
    static let create = "automation_create"
    static let edit = "automation_edit"
    static let `switch` = "automation_switch"

    /// The four tools, as `tools/list` gives them.
    static let tools: [[String: Any]] = [listTool, createTool, editTool, switchTool]

    /// The names `tools` lists: the only ones a call may use.
    static let names: Set<String> = [list, create, edit, `switch`]

    static func requestLine(pane: String, tool: String, arguments: PanelArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = AutomationRequest(automation: AutomationRequest.version, pane: pane, tool: tool, args: arguments)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: The tools

    private static func tool(_ name: String, summary: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": summary, "inputSchema": schema]
    }

    private static let unattended = "An automation is a prompt that this Mac's Varnick starts as a Claude session, out of sight, on a cadence in a folder, "
        + "while Varnick runs. Nobody is there to answer, each run draws on the user's Claude subscription, and nothing asks the user before you make or "
        + "change one: tell the user what you did."

    private static let listTool = tool(list,
        summary: "Lists this Mac's automations, each with its id and every field automation_create takes, plus its next run, whether a run is going, "
            + "its last outcome, and its mark (what a session last did to it, until the user has seen it). It reads and changes nothing. The prompts "
            + "go to Anthropic with this session. \(unattended)",
        properties: [:])

    /// The fields create and edit share.
    private static var fields: [String: Any] {
        [
            "name": ["type": "string", "description": "One line shown in the notice, the tab and the Runs tab, cut to \(AutomationTools.nameLimit) characters."],
            "prompt": ["type": "string", "description": "What Claude is asked, given to it as written as the first message. To be told the result, say so in it (\"…and notify me with the count\")."],
            "cadence": [
                "type": "object",
                "description": "How often, as a preset only, in this Mac's time zone. kind minutes: every 15 or 30. kind hours: every 1, 2, 3, 4, 6 or 12. kind daily or weekdays: hour 0 to 23 and minute 0 to 59. kind weekly: weekday 1 to 7 from Sunday, or a day's name, with hour and minute. Nothing shorter than 15 minutes.",
                "properties": [
                    "kind": ["type": "string", "enum": AutomationTools.cadenceKinds],
                    "every": ["type": "integer"],
                    "weekday": ["type": ["integer", "string"]],
                    "hour": ["type": "integer"],
                    "minute": ["type": "integer"],
                ] as [String: Any],
                "required": ["kind"],
            ] as [String: Any],
            "folder": ["type": "string", "description": "An existing folder on this Mac, by absolute path or from ~. On create, absent is this session's own folder; the user's Default folder is a Settings choice a session can't set."],
            "agent": ["type": "string", "description": "A Claude Code agent of that folder, by name. On edit, an empty string clears it."],
            "permissions": ["type": "string", "enum": AutomationTools.permissionNames,
                            "description": "Absent follows Varnick's Skip permissions setting, as a prompt the user types does (with it on, a run runs any command without asking). ask: a command that isn't allowed waits for the user (Needs you). allowed_tools_only: anything not allowed is refused with no dialog. A session may not set Skip permissions; varnick_setting on an edit goes back to following the setting."],
            "allowed_tools": ["type": "array", "items": ["type": "string"], "description": "Claude Code permission rules the run may use without a dialog, one each (Bash(git status), Edit, WebSearch). A run uses them with nobody to ask, so give no more than it needs; the mark the user sees names them."],
            "working_limit_minutes": ["type": "integer", "minimum": AutomationTools.workingLimits.lowerBound, "maximum": AutomationTools.workingLimits.upperBound,
                                      "description": "A run still working after this is ended, its conversation kept. \(Automation.defaultWorkingLimitMinutes) when absent."],
            "enabled": ["type": "boolean", "description": "On when absent. Turning one on starts its slots from now."],
        ]
    }

    private static let createTool = tool(create,
        summary: "Makes an automation on this Mac and answers its id and when it first runs. \(unattended) It is on unless `enabled` is false, and its "
            + "slots start from now. Every field is checked before anything is saved; a refusal names each wrong field. Deleting and Run now stay in "
            + "Varnick's Settings › Automations, the user's.",
        properties: fields, required: ["name", "prompt", "cadence"])

    private static let editTool = tool(edit,
        summary: "Changes the fields given of one automation (by the id automations_list gives) and leaves the rest, its runs and its last slot as "
            + "they are. A changed cadence or time zone (an edit stamps this Mac's), or turning it on, starts its slots from now. It is refused for an automation the user set to Skip "
            + "permissions (switch still works on it), and an edit made while the user has its editor open is overwritten by their Save. "
            + "Tell the user what you changed.",
        properties: ["id": ["type": "string", "description": "The automation's id from automations_list."]].merging(fields) { first, _ in first },
        required: ["id"])

    private static let switchTool = tool(`switch`,
        summary: "Turns one automation on or off. Turning it on starts its slots from now; turning it off releases nothing, and a run that is going goes on. "
            + "It works on an automation set to Skip permissions too. To stop one for good the user deletes it in Settings › Automations. Tell the user.",
        properties: [
            "id": ["type": "string", "description": "The automation's id from automations_list."],
            "on": ["type": "boolean", "description": "true to turn it on, false to turn it off."],
        ], required: ["id", "on"])
}
