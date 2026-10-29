import Foundation
import VarnickPeer

// `outline_append`, the one write an automation's run may make to the user's Outline (ADR 0040's amendment of 2026-10-29). The relay half (what
// `Varnick --mcp --outline-append` lists and the one socket line a call becomes) never reads or acts; the running Varnick answers in
// `OutlineAppendAccess`, through the Outline's own `performForSession`, so its undo stack, its saver and the file-never-written-over rules hold.
// What the arguments may be is `OutlineAppendTool` in the shared package. Nothing here logs or returns a bullet's words.

/// One tool call as it travels on the socket. It has no `op`, like a screen, panel or automation request, so the peer relay refuses it and no paired
/// Mac or device can send one; it has an `outlineAppend` key of its own, which is how the app tells it from the others.
struct OutlineAppendRequest: Codable {
    /// The version of this request: a server from an older launch is told to restart.
    var outlineAppend: Int
    var pane: String
    var args: PanelArguments

    static let version = 1
}

/// Just the version of an outline-append request, read before the rest so a server from another launch is told to restart.
struct OutlineAppendRequestHead: Decodable {
    var outlineAppend: Int?
}

enum OutlineAppendMCP {
    static func requestLine(pane: String, arguments: PanelArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let request = OutlineAppendRequest(outlineAppend: OutlineAppendRequest.version, pane: pane, args: arguments)
        return (try? encoder.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// Where an append goes, from the tree alone: Foundation only, so `--outline-check` runs it.
enum OutlineAppending {
    /// The top-level placement whose bullet's text is exactly `heading`: the first, when the user has more than one.
    static func headingPath(_ heading: String, in tree: OutlineTree) -> OutlinePath? {
        tree.bullets[tree.root]?.children.first { tree.bullets[$0.bullet]?.text == heading }.map { OutlinePath(placements: [$0.id]) }
    }

    /// Why the heading can't be filed under, or nil: its bullet is marked done, so the row would be hidden while Show completed is off. Nothing is
    /// made in its place, so there is never a second heading of the same name.
    static func headingProblem(_ heading: String, in tree: OutlineTree) -> String? {
        guard let path = headingPath(heading, in: tree), let id = tree.bulletID(at: path), tree.bullets[id]?.completed != nil else { return nil }
        return "the heading is marked done; open it or pick another heading"
    }

    /// The one edit that files the entry: a new last child of the heading's bullet, or, with no such heading, the heading made at the end of the top
    /// level with the entry already under it. `heading` is the path found, nil when the edit makes it.
    static func plan(_ entry: OutlineAppendTool.Entry, in tree: OutlineTree) -> (edit: OutlineEdit, heading: OutlinePath?) {
        let bullet = OutlineDraft(text: entry.text, note: entry.note)
        if let heading = headingPath(entry.heading, in: tree) { return (.insert([bullet], at: .lastUnder(heading)), heading) }
        let made = OutlineDraft(text: entry.heading, children: [bullet])
        return (.insert([made], at: .lastUnder(OutlinePath(placements: []))), nil)
    }
}

/// Why a call did nothing. The message is the run's to act on; the log names only the kind.
enum OutlineAppendRefusal: Error {
    case unreadable
    case versionDiffers
    case starting
    case noPane
    /// The pane is not an automation's run: other sessions edit the Outline with `outline_act`, and a Task's run and the voice session never do.
    case notAnAutomationRun
    /// The automation's allowed tools don't name the tool; a server that listed it was started from a record that did.
    case notNamed
    /// The arguments break a limit, one sentence each.
    case refused([String])
    /// The Outline switch is off, or its file can't be used; the message is Panel access's own wording for it.
    case outline(PanelRefusal)
    /// The edit was refused or changed nothing; the message says why.
    case notAdded(String)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: ScreenRefusal.restartThisSession
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .notAnAutomationRun: "outline_append is for an automation's own run"
        case .notNamed: "This automation's allowed tools don't name \(OutlineAppendTool.qualifiedName)"
        case .refused(let lines): "Nothing was added. " + lines.joined(separator: "; ")
        case .outline(let refusal): refusal.message
        case .notAdded(let why): "Nothing was added: \(why)"
        }
    }

    var logKind: String {
        switch self {
        case .unreadable: "unreadable"
        case .versionDiffers: "version"
        case .starting: "starting"
        case .noPane: "no pane"
        case .notAnAutomationRun: "not a run"
        case .notNamed: "not named"
        case .refused: "refused"
        case .outline(.outlineOff): "outline off"
        case .outline: "outline unavailable"
        case .notAdded: "not added"
        }
    }
}

@MainActor
final class OutlineAppendAccess {
    static let shared = OutlineAppendAccess()

    /// One outline-append request line from the socket, answered as one reply line.
    func answer(_ line: String) async -> String {
        let arrived = ContinuousClock.now
        var kind = "ok"
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(OutlineAppendRequestHead.self, from: line) else { throw OutlineAppendRefusal.unreadable }
            guard head.outlineAppend == OutlineAppendRequest.version else { throw OutlineAppendRefusal.versionDiffers }
            guard let request = PeerJSON.decode(OutlineAppendRequest.self, from: line) else { throw OutlineAppendRefusal.unreadable }
            reply = ScreenReply(text: try await run(request), isError: false)
        } catch let refusal as OutlineAppendRefusal {
            kind = refusal.logKind
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the outcome's kind and the duration: never a heading, a text, a note or an id.
        NSLog("Varnick: outline_append %@ [%.2f s]", kind, arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    /// In order: Varnick starting, the pane (an automation's run on this Mac), its allowed tools naming the tool, the arguments' limits, the Outline
    /// switch and its file, then the one edit.
    private func run(_ request: OutlineAppendRequest) async throws -> String {
        guard let model = PeerManager.shared.model else { throw OutlineAppendRefusal.starting }
        guard let caller = try? AutomationAccess.shared.callingPane(request.pane, in: model) else { throw OutlineAppendRefusal.noPane }
        guard Self.isAutomationRun(caller) else { throw OutlineAppendRefusal.notAnAutomationRun }
        guard OutlineAppendTool.isNamed(in: caller.record.allowedTools ?? []) else { throw OutlineAppendRefusal.notNamed }
        let checked = OutlineAppendTool.entry(heading: request.args["heading"], text: request.args["text"], note: request.args["note"])
        guard let entry = checked.entry else { throw OutlineAppendRefusal.refused(checked.problems) }
        let outline: Outline
        do { outline = try await OutlinePanelView(model: model).ready() } catch let refusal as PanelRefusal { throw OutlineAppendRefusal.outline(refusal) }
        if let why = OutlineAppending.headingProblem(entry.heading, in: outline.tree) { throw OutlineAppendRefusal.notAdded(why) }
        let plan = OutlineAppending.plan(entry, in: outline.tree)
        let id = caller.id
        // Asked again right before the edit, after its waits: the heading must still be where it was found (or still absent), and the run still be one.
        let done = await outline.performForSession(plan.edit, fresh: { tree in
            OutlineAppending.headingPath(entry.heading, in: tree) == plan.heading && OutlineAppending.headingProblem(entry.heading, in: tree) == nil
                ? nil : "the Outline changed while the call waited: try again"
        }, allowed: { !Task.isCancelled && Settings.shared.outlineOn && model.tabs.lazy.flatMap(\.sessions).contains { $0.id == id && Self.isAutomationRun($0) } })
        if let refusal = done.refusal { throw OutlineAppendRefusal.notAdded(refusal.reason) }
        let tree = outline.tree
        // The insert returns where it put its top-level bullet: the new child, or the new heading, whose only child is the new bullet.
        guard done.changed, let top = done.run.first,
              let added = plan.heading != nil ? tree.bulletID(at: top) : tree.bullets[tree.bulletID(at: top) ?? ""]?.children.first?.bullet
        else { throw OutlineAppendRefusal.notAdded("nothing changed") }
        return "Added bullet \(added) as the last under the heading, which "
            + (plan.heading == nil ? "was made at the end of the top level." : "was already there.")
    }

    /// An automation's run: not a Task's step, not the voice session, not an ordinary pane.
    private static func isAutomationRun(_ session: ClaudeSession) -> Bool {
        session.record.automation != nil && session.record.taskRun == nil && !session.record.isVoice
    }
}
