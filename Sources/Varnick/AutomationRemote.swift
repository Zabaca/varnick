import Foundation
import VarnickPeer

// This Mac's automations on its Phone page (ADR 0040's amendment of 2026-10-29): answers `phoneAutomations` on the main actor, for a listed device. The
// changes are the session tools' (`AutomationAccess.make`, `change` and `turn`, with `AutomationTools.read` checking every field), written only through
// `AutomationStore`, the one writer of the file; run now and delete are the Settings buttons' (`LauncherModel.runNow`, `deleteAutomation`). A change is
// marked "by the phone" with the device's name until the user has seen it. A prompt is never logged: the timing line holds the request's kind and its outcome.

@MainActor
enum AutomationRemote {
    static func answer(_ request: PeerRequest, by: String, model: LauncherModel) -> PeerReply {
        let began = ContinuousClock.now
        var outcome = "ok"
        var kind = "-"
        defer { NSLog("Varnick: automations phone %@ %@ [%.2f s]", kind, outcome, began.duration(to: .now).seconds) }
        guard let ask = request.phoneAutomation else {
            outcome = "unreadable"
            return .failure("That isn't an automations request")
        }
        kind = ask.kind.rawValue
        var reply = PeerPhoneAutomationReply(timeZone: TimeZone.current.identifier, skipPermissions: Settings.shared.skipPermissions)
        // Either file that can't be read blocks every change and every list, as it blocks Settings and the tools.
        if let problem = model.automationFilesProblem {
            outcome = "file problem"
            reply.problem = problem
            return success(reply)
        }
        let device = DeviceList.saved().first { $0.id.lowercased() == by.lowercased() }.map { PeerDevice.cleanName($0.name) } ?? "a device"
        let author = AutomationAccess.Author(name: device, via: PhoneAutomations.phone, folder: HomeFolder.path)
        let access = AutomationAccess.shared
        do {
            switch ask.kind {
            case .list:
                break
            case .switchOnOff:
                let done = try access.turn(["id": ask.id ?? "", "on": ask.on.map { $0 ? "true" : "false" } ?? ""], model, author: author)
                reply.note = done.next == nil ? "\"\(done.current.name)\" is already \(done.on ? "on" : "off")" : "Turned \"\(done.current.name)\" \(done.on ? "on" : "off")"
            case .runNow:
                guard let id = ask.id.flatMap(UUID.init(uuidString:)), let automation = model.automations.automation(id) else { throw AutomationRefusal.unknownID }
                if let refusal = model.runNow(id) {
                    outcome = "refused"
                    reply.refused = [refusal]
                } else {
                    reply.note = "Started a run of \"\(automation.name)\""
                }
            case .save:
                var fields = ask.fields ?? [:]
                let problems = PhoneAutomations.shapeProblems(fields)
                if !problems.isEmpty { throw AutomationRefusal.refused(problems) }
                // The phone's Home is no folder at all: the Mac's Home folder, which an automation with none runs in.
                if fields["folder"]?.trimmingCharacters(in: .whitespaces).isEmpty == true { fields["folder"] = HomeFolder.path }
                if let id = ask.id {
                    fields["id"] = id
                    let done = try access.change(fields, model, author: author)
                    reply.note = done.edited == nil ? "\"\(done.current.name)\" already has those values" : "Saved \"\(done.edited?.automation.name ?? done.current.name)\""
                } else {
                    let made = try access.make(fields, model, author: author)
                    reply.made = made.id.uuidString.lowercased()
                    reply.note = "Made \"\(made.name)\""
                }
            case .delete:
                guard let id = ask.id.flatMap(UUID.init(uuidString:)), let automation = model.automations.automation(id) else { throw AutomationRefusal.unknownID }
                model.deleteAutomation(id)
                reply.note = "Deleted \"\(automation.name)\" and its run list"
            }
        } catch let refusal as AutomationRefusal {
            outcome = refusal.logKind
            reply.refused = [refusal.message]
            if case .refused(let lines) = refusal { reply.refused = lines }
        } catch {
            outcome = "failed"
            reply.refused = ["The change failed inside Varnick"]
        }
        // The list after the ask, whatever it did: the page redraws from it.
        let homeFolder = HomeFolder.path
        reply.automations = model.automations.automations.map { automation in
            let state = AutomationAccess.outcome(of: automation, in: model)
            let next = AutomationSlot.next(automation.cadence, zone: automation.zone, after: Date())
            return PhoneAutomations.row(automation, homeFolder: homeFolder, next: next, going: state.going, last: state.newest)
        }
        return success(reply)
    }

    private static func success(_ reply: PeerPhoneAutomationReply) -> PeerReply {
        var answer = PeerReply.success()
        answer.phoneAutomations = reply
        return answer
    }
}
