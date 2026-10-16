import AppKit
import Foundation
import VarnickPeer

// Automation tools for sessions (option 01 of `prompts-cant-run-on-a-schedule`, slice 3), the running Varnick's half: the answers to the calls a
// pane's `Varnick --mcp --automations` relays (`AutomationMCP`). They are answered on the main actor and written only through `AutomationStore`, the
// one writer of the file. What a call means (the checks, the change) is `AutomationTools` in the shared package; the rules that break are in
// docs/agents/where-it-breaks.md, Automations.

/// Why a call did nothing. The message is the session's to act on; the log names only the kind.
enum AutomationRefusal: Error {
    case unreadable
    case versionDiffers
    case off
    case starting
    case noPane
    /// The call came from an automation's own run, whose session never has these tools: a request named it by its pane's id anyway.
    case fromRun
    /// The automations file can't be read or is from a newer build, so nothing is saved; the message is the store's own reason.
    case fileProblem(String)
    case unknownTool(String)
    /// An id that no automation has, or none was sent.
    case unknownID
    /// The arguments are not ones the tool takes, one line each.
    case refused([String])
    /// The write did not reach the disk.
    case notSaved(String)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: ScreenRefusal.restartThisSession
        case .off: "Automations is off in Varnick's Settings › Experimental"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .fromRun: "An automation's own run may not make, change or list automations"
        case .fileProblem(let why): why
        case .unknownTool(let name): "Unknown tool \(name)"
        case .unknownID: "No automation has this id. automations_list gives them"
        case .refused(let lines): "Nothing was saved. " + lines.joined(separator: "; ")
        case .notSaved(let why): why
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
        case .unknownID: "unknown id"
        case .refused: "refused"
        case .notSaved: "not saved"
        }
    }
}

@MainActor
final class AutomationAccess {
    static let shared = AutomationAccess()

    /// One automation request line from the socket, answered as one reply line.
    func answer(_ line: String) -> String {
        let arrived = ContinuousClock.now
        var tool = "-"
        var kind = "ok"
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(AutomationRequestHead.self, from: line) else { throw AutomationRefusal.unreadable }
            guard head.automation == AutomationRequest.version else { throw AutomationRefusal.versionDiffers }
            guard let request = PeerJSON.decode(AutomationRequest.self, from: line) else { throw AutomationRefusal.unreadable }
            tool = AutomationMCP.names.contains(request.tool) ? request.tool : "-"
            reply = ScreenReply(text: try run(request), isError: false)
        } catch let refusal as AutomationRefusal {
            kind = refusal.logKind
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the tool, the outcome's kind and the duration: never a name, a prompt, a folder, a title or the request's own words.
        NSLog("Varnick: automations %@ %@ [%.2f s]", tool, kind, arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    /// In order: the switch, Varnick starting, the pane (a Claude pane on this Mac, not a run's), the file being readable, then the tool.
    private func run(_ request: AutomationRequest) throws -> String {
        guard Settings.shared.automationsOn else { throw AutomationRefusal.off }
        guard let model = PeerManager.shared.model else { throw AutomationRefusal.starting }
        let caller = try callingPane(request.pane, in: model)
        guard caller.record.automation == nil else { throw AutomationRefusal.fromRun }
        if let problem = model.automationFilesProblem { throw AutomationRefusal.fileProblem(problem) }
        switch request.tool {
        case AutomationMCP.list: return list(model)
        case AutomationMCP.create: return try create(request.args, model, caller: caller)
        case AutomationMCP.edit: return try edit(request.args, model, caller: caller)
        case AutomationMCP.switch: return try switchOnOff(request.args, model, caller: caller)
        default: throw AutomationRefusal.unknownTool(request.tool)
        }
    }

    // MARK: The tools

    private func create(_ args: PanelArguments, _ model: LauncherModel, caller: ClaudeSession) throws -> String {
        let context = AutomationTools.Context(sessionFolder: caller.record.directory, homeFolder: HomeFolder.path)
        let fields: AutomationTools.Fields
        switch AutomationTools.read(args, creating: true, in: context) {
        case .success(let found): fields = found
        case .failure(let problems): throw AutomationRefusal.refused(problems.lines)
        }
        let now = Date()
        var automation = AutomationTools.make(fields, in: context, now: now)
        automation.mark = AutomationMark(what: AutomationTools.markText(made: automation), by: Self.title(of: caller), at: now)
        guard model.automations.save(automation, rollingBack: true) else { throw notSaved(model) }
        let first = automation.enabled
            ? AutomationSlot.next(automation.cadence, zone: automation.zone, after: now).map { "It first runs \(Self.time($0))." } ?? "It has no next run."
            : "It is off, so it runs when it is turned on."
        return "Made \"\(automation.name)\" with id \(automation.id.uuidString). \(Self.sentence(automation)) \(first) "
            + "Tell the user what you made; Settings › Automations shows it with a mark until they have seen it."
    }

    private func edit(_ args: PanelArguments, _ model: LauncherModel, caller: ClaudeSession) throws -> String {
        let store = model.automations
        // Every wrong part is named at once: the id, a Skip automation, and the fields.
        let found = automation(args, store)
        var problems = found.problem.map { [$0] } ?? []
        if let current = found.automation, let refusal = AutomationTools.editRefusal(for: current) { problems.append(refusal) }
        let context = AutomationTools.Context(sessionFolder: caller.record.directory, homeFolder: HomeFolder.path, current: found.automation)
        var fields = AutomationTools.Fields()
        switch AutomationTools.read(args, creating: false, in: context) {
        case .success(let read): fields = read
        case .failure(let wrong): problems += wrong.lines
        }
        guard problems.isEmpty, let current = found.automation else { throw AutomationRefusal.refused(problems) }
        let now = Date()
        guard var edited = AutomationTools.edit(current, with: fields, now: now) else {
            return "Nothing changed: \"\(current.name)\" already has those values."
        }
        edited.automation.mark = AutomationMark(what: AutomationTools.markText(edited: edited.changed, to: edited.automation), by: Self.title(of: caller), at: now)
        // Onto the store's current copy, which is the one just read: nothing awaits between the two.
        let next = edited.automation
        guard store.update(current.id, rollingBack: true, { $0 = next }) else { throw notSaved(model) }
        let after = next.enabled
            ? AutomationSlot.next(next.cadence, zone: next.zone, after: now).map { "It next runs \(Self.time($0))." } ?? "It has no next run."
            : "It is off."
        return "Changed \(edited.changed.joined(separator: ", ")) of \"\(next.name)\". \(after) Its runs and last slot are as they were. Tell the user what you changed."
    }

    private func switchOnOff(_ args: PanelArguments, _ model: LauncherModel, caller: ClaudeSession) throws -> String {
        let store = model.automations
        var problems = args.keys.sorted().filter { $0 != "id" && $0 != "on" }.map { "\($0) is not an argument: the arguments are id and on" }
        let found = automation(args, store)
        if let problem = found.problem { problems.append(problem) }
        let word = args["on"]?.trimmingCharacters(in: .whitespaces).lowercased()
        if word != "true", word != "false" { problems.append("on is true or false") }
        guard problems.isEmpty, let current = found.automation, let word else { throw AutomationRefusal.refused(problems) }
        let on = word == "true"
        let now = Date()
        guard var next = AutomationTools.switching(current, on: on, now: now) else {
            return "\"\(current.name)\" is already \(on ? "on" : "off"). Nothing changed."
        }
        next.mark = AutomationMark(what: on ? "Turned on" : "Turned off", by: Self.title(of: caller), at: now)
        let marked = next
        guard store.update(current.id, rollingBack: true, { $0 = marked }) else { throw notSaved(model) }
        let after = on
            ? AutomationSlot.next(marked.cadence, zone: marked.zone, after: now).map { "Its slots start from now; it next runs \(Self.time($0))." } ?? "It has no next run."
            : "It runs no more until it is turned on; a run that is going goes on."
        return "Turned \"\(marked.name)\" \(on ? "on" : "off"). \(after) Tell the user."
    }

    /// Every automation as JSON: the fields create takes, as it takes them, and what the list adds. Reads and changes nothing.
    private func list(_ model: LauncherModel) -> String {
        let zone = TimeZone.current
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        let encoder = JSONEncoder()
        func date(_ value: Date?) -> Any { value.map { formatter.string(from: $0) } ?? NSNull() }
        func text(_ value: String?) -> Any { value ?? NSNull() }
        let rows: [[String: Any]] = model.automations.automations.map { automation in
            let cadence = (try? encoder.encode(automation.cadence)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            var last: Any = NSNull()
            let runs = model.taskRuns.runs(of: automation.id)
            if let run = runs.first {
                let now = model.displayed(run)
                last = ["state": now.state.text, "detail": text(now.detail), "slot": date(run.trigger.slot), "count": run.count ?? 1] as [String: Any]
            }
            let going = runs.contains { run in run.pane.flatMap { model.claudePane($0) } != nil && model.displayed(run).state.isGoing }
            var mark: Any = NSNull()
            if let found = automation.mark { mark = ["what": found.what, "by": found.by, "at": date(found.at)] as [String: Any] }
            return [
                "id": automation.id.uuidString,
                "name": automation.name,
                "task": automation.task,
                "prompt": automation.prompt,
                "cadence": cadence,
                "cadence_label": automation.cadence.label,
                "folder": text(automation.folder),
                "agent": text(automation.agent),
                "permissions": AutomationTools.permissionName(automation.permissions),
                "allowed_tools": automation.allowedTools,
                "working_limit_minutes": automation.workingLimitMinutes,
                "enabled": automation.enabled,
                "time_zone": automation.timeZone,
                "next_run": automation.enabled ? date(AutomationSlot.next(automation.cadence, zone: automation.zone, after: Date())) : NSNull(),
                "run_going": going,
                "last_outcome": last,
                "mark": mark,
                "editable_by_sessions": AutomationTools.editRefusal(for: automation) == nil,
            ]
        }
        let document: [String: Any] = ["time_zone": zone.identifier, "home_folder": HomeFolder.path, "automations": rows]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let intro = rows.isEmpty ? "This Mac has no automations." : "This Mac's \(rows.count) automation\(rows.count == 1 ? "" : "s"). A null folder is Home, Varnick's own folder for sessions that belong to no project."
        return intro + "\n" + String(decoding: data, as: UTF8.self)
    }

    // MARK: Helpers

    /// The calling pane: a Claude pane on this Mac. One that another Mac or the phone controls is included (unlike `CallingPane.find`, which Screen
    /// access and Panel access use because they read this Mac's screen): its session runs here, so its automations are this Mac's.
    private func callingPane(_ text: String, in model: LauncherModel) throws -> ClaudeSession {
        guard let id = UUID(uuidString: text),
              let session = model.tabs.lazy.flatMap(\.sessions).first(where: { $0.id == id && $0.isClaude && !$0.isOnPeer }) else { throw AutomationRefusal.noPane }
        return session
    }

    /// The automation an `id` argument names, else the line saying why not.
    private func automation(_ args: PanelArguments, _ store: AutomationStore) -> (automation: Automation?, problem: String?) {
        guard let text = args["id"]?.trimmingCharacters(in: .whitespaces), let id = UUID(uuidString: text), let found = store.automation(id) else {
            return (nil, AutomationRefusal.unknownID.message)
        }
        return (found, nil)
    }

    /// The write failed and was rolled back (`AutomationStore.save`): nothing is in memory or on disk.
    private func notSaved(_ model: LauncherModel) -> AutomationRefusal {
        AutomationRefusal.notSaved((model.automations.writeError ?? "The automation could not be saved") + " Nothing was changed.")
    }

    private static func title(of session: ClaudeSession) -> String { PanelAccess.oneLine(session.label, limit: 60) }

    private static func time(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

    /// "Daily at 9:00, in ~/Projects/x, as @reviewer, permissions: ask."
    private static func sentence(_ automation: Automation) -> String {
        var parts = [automation.cadence.label + " (\(automation.timeZone))", "in " + (automation.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Home")]
        if let agent = automation.agent { parts.append("as @" + agent) }
        parts.append("permissions: " + (automation.permissions.map { AutomationTools.permissionName($0) } ?? "follow Varnick's Skip permissions setting (\(Settings.shared.skipPermissions ? "on" : "off"))"))
        if !automation.allowedTools.isEmpty { parts.append("allowed tools: " + automation.allowedTools.joined(separator: ", ")) }
        return parts.joined(separator: ", ") + "."
    }
}

extension AutomationMark {
    /// "A session: Edited: prompt by "Planning" · Oct 15, 9:07 AM": what the row and the Runs tab show until the user has seen it.
    var line: String {
        "A session: \(what) by \u{201C}\(by)\u{201D} \u{00B7} \(at.formatted(date: .abbreviated, time: .shortened))"
    }
}
