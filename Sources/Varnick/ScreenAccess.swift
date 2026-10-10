import AppKit
import ApplicationServices
import Foundation
import VarnickPeer

// Screen access for sessions (ADR 0023), the running Varnick's half: the answers to the `look`, `point` and `click` calls a pane's
// `Varnick --mcp` relays (`ScreenMCP`). They are done here, in this process under its own grants, with the code Hey Varnick points
// with: `ScreenReader`, `ScreenText` and `ArrowOverlay`. What a session may be shown is in where-it-breaks.md, Screen access.

/// Why a call did nothing. The message is the session's to act on; the log names only the kind.
indirect enum ScreenRefusal: Error {
    case unreadable
    case versionDiffers
    case off
    case noAccessibility
    case starting
    case noPane
    case controlled
    case varnickTarget
    case lookFirst
    case gone
    case nothingInFront
    case noApp(String)
    case noWindow(String)
    case offDisplay
    case noPostAccess
    /// A window of Varnick's own is at the point to click.
    case covered
    /// The click waited so long for its turn that the relay has given up on it.
    case late
    /// Another arrow was drawn over this click's.
    case replaced
    case bad(String)
    /// Refused once the click was under way, which says so.
    case stopped(ScreenRefusal)

    @MainActor var message: String {
        switch self {
        case .unreadable: "Varnick couldn't read the request"
        case .versionDiffers: "Restart this session\(Self.restartKeys.map { " (\($0))" } ?? "") to update Varnick's tools"
        case .off: "Screen access is off in Varnick's Settings › Claude"
        case .noAccessibility: "Varnick doesn't have Accessibility. Ask the user to grant it in Varnick's Settings › Claude, under Screen access"
        case .starting: "Varnick is still starting"
        case .noPane: "No Claude session in Varnick's panes on this Mac has this pane id"
        case .controlled: "This session is shown as a card because another Mac or a device is in control of it, so it has no screen of its own to act on"
        case .varnickTarget: "That is in Varnick's own window, which a session may not look at or click"
        case .lookFirst: "No such id. Ids come from the last look and are replaced by the next one: look first"
        case .gone: "gone: look again"
        case .nothingInFront: "No window to look at: nothing but Varnick is in front. Name an app with `app`"
        case .noApp(let name): "No running app named \(name)"
        case .noWindow(let name): "\(name) has no window to look at"
        case .offDisplay: "That is on no display"
        case .noPostAccess: "macOS hasn't let Varnick post clicks. Ask the user to grant Accessibility in Varnick's Settings › Claude, under Screen access"
        case .covered: "A window of Varnick's own is at that point, which a session may not click"
        case .late: "The click waited too long for its turn"
        case .replaced: "Another arrow was drawn over this click's"
        case .bad(let why): why
        case .stopped(let why): why.message + ". Nothing was clicked"
        }
    }

    var logKind: String {
        switch self {
        case .unreadable: "unreadable"
        case .versionDiffers: "version"
        case .off: "off"
        case .noAccessibility: "no Accessibility"
        case .starting: "starting"
        case .noPane: "no pane"
        case .controlled: "controlled"
        case .varnickTarget: "Varnick's own"
        case .lookFirst: "look first"
        case .gone: "gone"
        case .nothingInFront: "nothing in front"
        case .noApp: "no app"
        case .noWindow: "no window"
        case .offDisplay: "off display"
        case .noPostAccess: "no post access"
        case .covered: "covered"
        case .late: "late"
        case .replaced: "replaced"
        case .bad: "bad arguments"
        case .stopped(let why): why.logKind
        }
    }

    /// The restart shortcut as the user has it bound; nil when unbound.
    @MainActor private static var restartKeys: String? { Settings.shared.combo(.restartSession)?.label }
}

/// What a tool did: the text the session reads, and counts for the log.
private struct Done {
    var text: String
    var counts = ""
}

/// Answers the screen tools for the panes' sessions. Reads, presses and posted events run off the main actor, as `ScreenReader.read`
/// does; this type holds the id tables and the one-click-at-a-time queue.
@MainActor
final class ScreenAccess {
    static let shared = ScreenAccess()

    /// How long the Arrow shows on a click's target before the click: long enough to see it fade in and read the sign.
    nonisolated static let clickLead: Duration = .seconds(1)
    static let clickLinger: TimeInterval = 2
    /// A click still waiting or leading this long after its request arrived is dropped: the relay gives up at 15 s, and the frame
    /// read, press check and press after the last check can each take up to a second.
    static let staleAfter: Duration = .seconds(10)
    /// A press that opens a dialog can block, so it waits longer than the walk's reads.
    nonisolated static let pressTimeout: Float = 1
    nonisolated static let signName = 30
    nonisolated static let signNote = 120

    /// Each pane's targets from its last `look`: replaced by the next one, held in memory only, and dropped once the pane has gone.
    private var targets: [UUID: [String: ScreenTarget]] = [:]
    private var clicking = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Turning the switch off: every id and any Arrow of ours goes at once.
    func switchedOff() {
        targets = [:]
        ArrowOverlay.shared.hide()
    }

    // MARK: The call

    /// One screen request line from the socket, answered as one reply line.
    func answer(_ line: String) async -> String {
        let arrived = ContinuousClock.now
        var tool: ScreenTool?
        var kind = "ok"
        var counts = ""
        var reply: ScreenReply
        do {
            guard let head = PeerJSON.decode(ScreenRequestHead.self, from: line) else { throw ScreenRefusal.unreadable }
            guard head.screen == ScreenRequest.version else { throw ScreenRefusal.versionDiffers }
            guard let request = PeerJSON.decode(ScreenRequest.self, from: line) else { throw ScreenRefusal.unreadable }
            tool = ScreenTool(rawValue: request.tool)
            let done = try await run(request, tool: tool, arrived: arrived)
            reply = ScreenReply(text: done.text, isError: false)
            counts = done.counts
        } catch let refusal as ScreenRefusal {
            kind = refusal.logKind
            reply = ScreenReply(text: refusal.message, isError: true)
        } catch {
            kind = "failed"
            reply = ScreenReply(text: "The call failed inside Varnick", isError: true)
        }
        // Only the tool, the outcome's kind, durations and counts: never a label, note, title, app name, session name or the request's own words.
        NSLog("Varnick: screen %@ %@%@ [%.2f s]", tool?.rawValue ?? "-", kind, counts.isEmpty ? "" : " (\(counts))",
              arrived.duration(to: .now).seconds)
        return PeerJSON.line(reply)
    }

    private func run(_ request: ScreenRequest, tool: ScreenTool?, arrived: ContinuousClock.Instant) async throws -> Done {
        guard Settings.shared.screenAccess else { throw ScreenRefusal.off }
        guard ScreenReader.isTrusted else { throw ScreenRefusal.noAccessibility }
        guard let model = PeerManager.shared.model else { throw ScreenRefusal.starting }
        let (id, name) = try pane(request.pane, in: model)
        prune(in: model)
        switch tool {
        case .look: return try await look(request.args, pane: id)
        case .point: return try await point(request.args, pane: id, name: name)
        case .click: return try await click(request.args, paneText: request.pane, pane: id, name: name, arrived: arrived)
        case nil: throw ScreenRefusal.bad("Unknown tool \(request.tool)")
        }
    }

    /// The Claude pane on this Mac with that id, and its name as the session board's card has it.
    private func pane(_ text: String, in model: LauncherModel) throws -> (UUID, String) {
        guard let id = UUID(uuidString: text) else { throw ScreenRefusal.noPane }
        for tab in model.tabs {
            guard let session = tab.sessions.first(where: { $0.id == id && $0.isClaude && !$0.isOnPeer }) else { continue }
            if case .controlled = session.away { throw ScreenRefusal.controlled }
            return (id, String(ScreenElements.cleaned(tab.boardTitle(of: session)).prefix(Self.signName)))
        }
        throw ScreenRefusal.noPane
    }

    /// What can change while a click waits for its turn or leads: the switch, the pane (closed, or another Mac in control now), and
    /// whether the relay is still waiting.
    private func stillAllowed(paneText: String, arrived: ContinuousClock.Instant) throws {
        guard Settings.shared.screenAccess else { throw ScreenRefusal.off }
        guard let model = PeerManager.shared.model else { throw ScreenRefusal.starting }
        _ = try pane(paneText, in: model)
        guard arrived.duration(to: .now) < Self.staleAfter else { throw ScreenRefusal.late }
    }

    private func prune(in model: LauncherModel) {
        guard !targets.isEmpty else { return }
        let open = Set(model.tabs.flatMap { $0.sessions.map(\.id) })
        targets = targets.filter { open.contains($0.key) }
    }

    private func target(_ id: String, pane: UUID) throws -> ScreenTarget {
        guard let target = targets[pane]?[id.trimmingCharacters(in: .whitespaces).lowercased()] else { throw ScreenRefusal.lookFirst }
        guard !ScreenReader.isVarnick(target) else { throw ScreenRefusal.varnickTarget }
        return target
    }

    // MARK: look

    private func look(_ args: ScreenArguments, pane: UUID) async throws -> Done {
        let app: NSRunningApplication
        if let named = args.app?.trimmingCharacters(in: .whitespaces), !named.isEmpty {
            guard let found = ScreenReader.application(named: named) else { throw ScreenRefusal.noApp(named) }
            app = found
        } else {
            guard let found = ScreenReader.focusedApplication() else { throw ScreenRefusal.nothingInFront }
            app = found
        }
        let appName = app.localizedName ?? "That app"
        let pointer = ScreenReader.pointer()
        let reading = await ScreenReader.read(app, pointer: pointer)
        guard reading.window != nil else { throw ScreenRefusal.noWindow(appName) }

        // The picture's text, when the window lists nothing, Chrome hides its page, or the session asked for it.
        var text: ScreenText.WindowText?
        var notes: [String] = []
        if reading.elements.isEmpty || reading.chromeBlind || args.text == true {
            if reading.chromeBlind, reading.emptyWebArea == nil {
                // Without the page's frame its lines can't be told from the tab titles and the toolbar's.
                notes.append("Text was not read from a picture: the page's frame is unknown.")
            } else {
                let found = try await ScreenText.windowText(of: reading, pid: app.processIdentifier,
                                                           within: reading.chromeBlind ? reading.emptyWebArea : nil, pointer: pointer)
                if let skipped = found.look.skipped {
                    notes.append(skipped == "no Screen Recording"
                                 ? "Text was not read from a picture: Varnick doesn't have Screen Recording (the user can grant it in Settings › Claude, under Screen access)."
                                 : "Text was not read from a picture: \(skipped).")
                } else {
                    text = found
                }
            }
        }

        var table: [String: ScreenTarget] = [:]
        var lines = ["\(appName), window \"\(reading.windowTitle)\", frame \(Self.describe(reading.windowFrame ?? .zero))"]
        for (index, element) in reading.elements.enumerated() {
            let id = "e\(index + 1)"
            table[id] = ScreenTarget(reference: element.reference, frame: element.frame, note: ScreenElements.note(for: element),
                                     description: element.description)
            lines.append("\(id)  \(element.description)  \(Self.describe(element.frame))")
        }
        for (index, element) in (text?.lines ?? []).enumerated() {
            let id = "t\(index + 1)"
            // No element to read again: the window is, and the box follows it from where it was captured.
            table[id] = ScreenTarget(reference: nil, frame: element.frame, note: ScreenElements.note(for: element),
                                     description: element.description, window: reading.window, windowFrame: text?.window)
            lines.append("\(id)  \"\(element.label)\" (text on screen)  \(Self.describe(element.frame))")
        }
        if reading.elements.count >= ScreenElements.maxListed {
            notes.append("Only the first \(ScreenElements.maxListed) controls are listed.")
        }
        if reading.elements.isEmpty, text?.lines.isEmpty ?? true {
            notes.append("Nothing is listed in this window.")
        }
        targets[pane] = table
        return Done(text: (lines + notes).joined(separator: "\n"), counts: "elements \(reading.elements.count), text lines \(text?.lines.count ?? 0)")
    }

    // MARK: point

    private func point(_ args: ScreenArguments, pane: UUID, name: String) async throws -> Done {
        let frame: CGRect
        var fallback = "Here."
        let aimed: String
        if let id = args.id {
            let target = try target(id, pane: pane)
            guard let now = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
            frame = now
            fallback = target.note
            aimed = id.lowercased()
        } else if let rect = args.rect?.frame {
            guard rect.width > 0, rect.height > 0, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
                throw ScreenRefusal.bad("The rectangle needs a positive width and height")
            }
            frame = rect
            aimed = "the rectangle"
        } else {
            throw ScreenRefusal.bad("Give an id from the last look, or a rect")
        }
        let note = String(ScreenElements.cleaned(args.note ?? "").prefix(Self.signNote))
        guard ArrowOverlay.shared.show(frame: frame, note: "\(name)\n\(note.isEmpty ? fallback : note)") else { throw ScreenRefusal.offDisplay }
        ArrowOverlay.shared.hide(after: ArrowOverlay.lingers)
        return Done(text: "Pointed at \(aimed). The arrow stays \(Int(ArrowOverlay.lingers)) seconds, or until the next point or click.")
    }

    // MARK: click

    private func click(_ args: ScreenArguments, paneText: String, pane: UUID, name: String, arrived: ContinuousClock.Instant) async throws -> Done {
        enum Aim {
            case target(String, ScreenTarget)
            case point(CGPoint)
        }
        let aim: Aim
        if let id = args.id {
            aim = .target(id.lowercased(), try target(id, pane: pane))
        } else if let at = args.at?.point {
            guard at.x.isFinite, at.y.isFinite, Self.onDisplay(at) else { throw ScreenRefusal.offDisplay }
            // Early, so a refusal waits for nothing; it is asked again right before the click.
            guard !Self.varnickCovers(at) else { throw ScreenRefusal.covered }
            guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }
            aim = .point(at)
        } else {
            throw ScreenRefusal.bad("Give an id from the last look, or a point `at`")
        }

        // One click at a time across all sessions: a second waits for the first to finish.
        await acquire()
        defer { release() }

        // The arrow's generation once it is drawn: when another arrow has replaced it, the user is not looking at this click's target.
        var drawn: Int?
        do {
            try stillAllowed(paneText: paneText, arrived: arrived)
            let sign: String, shown: CGRect
            switch aim {
            case .target(let id, let target):
                guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
                shown = frame
                sign = "\(name)\nClicking \(id): \(String(target.description.prefix(Self.signNote - 10)))"
            case .point(let at):
                shown = CGRect(x: at.x - 14, y: at.y - 14, width: 28, height: 28)
                sign = "\(name)\nClicking at \(Int(at.x.rounded())), \(Int(at.y.rounded()))"
            }
            guard ArrowOverlay.shared.show(frame: shown, note: sign) else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
            try? await Task.sleep(for: Self.clickLead)
            try stillAllowed(paneText: paneText, arrived: arrived)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            let done: String
            switch aim {
            case .target(let id, let target):
                guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
                if let reference = target.reference, await Self.pressable(reference) {
                    done = try await Self.pressed(reference, id: id)
                } else {
                    let centre = CGPoint(x: frame.midX, y: frame.midY)
                    try Self.checkedToPost(at: centre)
                    await Self.leftClick(at: centre)
                    done = "Clicked \(id) at \(Int(centre.x.rounded())), \(Int(centre.y.rounded()))"
                }
            case .point(let at):
                try Self.checkedToPost(at: at)
                await Self.leftClick(at: at)
                done = "Clicked at \(Int(at.x.rounded())), \(Int(at.y.rounded()))"
            }
            ArrowOverlay.shared.hide(after: Self.clickLinger)
            // What was done, never that it worked: the session looks again to see.
            return Done(text: done + ". Look again to see what happened.")
        } catch let refusal as ScreenRefusal {
            if let drawn, ArrowOverlay.shared.generation == drawn { ArrowOverlay.shared.hide() }
            throw ScreenRefusal.stopped(refusal)
        }
    }

    private func acquire() async {
        if clicking {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            clicking = true
        }
    }

    /// Hands the turn to the next click, if one waits, without letting a third in between.
    private func release() {
        if waiting.isEmpty {
            clicking = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: The click itself

    /// Run on the main actor right before a click is posted, with nothing awaited between: Varnick's own windows are then where
    /// they will be when it lands.
    private static func checkedToPost(at point: CGPoint) throws {
        guard !varnickCovers(point) else { throw ScreenRefusal.covered }
        guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }
    }

    /// Whether a visible window of Varnick's own covers the point (Accessibility coordinates), the arrow's panel not counted: it covers
    /// the whole display and ignores the mouse. Any frame counts, whatever is above it: a pinned panel under another window still refuses.
    private static func varnickCovers(_ point: CGPoint) -> Bool {
        let appKit = ScreenGeometry.accessibility(point, mainDisplayHeight: ScreenGeometry.mainDisplayHeight)
        return NSApplication.shared.windows.contains {
            $0.isVisible && $0.alphaValue > 0 && !ArrowOverlay.shared.owns($0) && $0.frame.contains(appKit)
        }
    }

    private nonisolated static func pressable(_ reference: AXReference) async -> Bool {
        await Task.detached { () -> Bool in
            AXUIElementSetMessagingTimeout(reference.element, pressTimeout)
            var names: CFArray?
            guard AXUIElementCopyActionNames(reference.element, &names) == .success, let names = names as? [String] else { return false }
            return names.contains(kAXPressAction as String)
        }.value
    }

    /// The press has its own, longer, messaging timeout, since one that opens a dialog can block.
    private nonisolated static func pressed(_ reference: AXReference, id: String) async throws -> String {
        let result = await Task.detached { () -> AXError in
            AXUIElementSetMessagingTimeout(reference.element, pressTimeout)
            return AXUIElementPerformAction(reference.element, kAXPressAction as CFString)
        }.value
        switch result {
        case .success: return "Pressed \(id)"
        case .cannotComplete: return "Sent the press to \(id); the app did not answer in time"
        case .invalidUIElement: throw ScreenRefusal.gone
        default: throw ScreenRefusal.bad("The app refused the press (error \(result.rawValue)). Try click with a point")
        }
    }

    /// A left mouse-down and mouse-up at the HID level; the pointer moves to the point and stays there.
    private nonisolated static func leftClick(at point: CGPoint) async {
        await Task.detached {
            func post(_ type: CGEventType) {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
                event?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved)
            try? await Task.sleep(for: .milliseconds(50))
            post(.leftMouseDown)
            try? await Task.sleep(for: .milliseconds(40))
            post(.leftMouseUp)
        }.value
    }

    private static func onDisplay(_ point: CGPoint) -> Bool {
        let appKit = ScreenGeometry.accessibility(point, mainDisplayHeight: ScreenGeometry.mainDisplayHeight)
        return NSScreen.screens.contains { $0.frame.contains(appKit) }
    }

    /// A frame as the replies give it: "x,y wxh", in points.
    private static func describe(_ frame: CGRect) -> String {
        "\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())) \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
    }
}

/// Just the version of a screen request, read before the rest so a server from another launch is told to restart.
struct ScreenRequestHead: Decodable {
    var screen: Int?
}
