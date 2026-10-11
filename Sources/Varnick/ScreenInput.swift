import AppKit
import ApplicationServices
import Foundation

// `type`, `drag` and `window` (ADR 0023), built as `click` is: the Arrow on the target first, one action at a time across all sessions,
// and the switch, the pane, the request's age and the Arrow's generation checked again before acting. Nothing goes into Varnick's own
// windows. What each checks and why is in where-it-breaks.md, Screen access.

extension ScreenAccess {
    /// Each tool's age limit at its last check, before its reads and its action: the relay gives up at 15 s and each ends by 13.75 s,
    /// as `click` does at `staleAfter` (9 s, then about 4.75 s). Another wait or read after the last check shrinks the limit.
    static let dragLimit: Duration = .seconds(7)
    static let windowLimit: Duration = .seconds(9)
    /// Typing's own limit, asked before every character and key: the relay gives up at 15 s, so a character or key is posted only if
    /// the call is younger than this less the typing still to do.
    static let typingDeadline: Duration = .milliseconds(13_500)

    /// A drag's timing, tuned by hand: the button is down this long before it moves, the pointer then travels the line in steps, and
    /// it rests at the end before the button goes up.
    static let dragHold: Duration = .milliseconds(100)
    static let dragTime = 0.3
    static let dragStep: Duration = .milliseconds(16)
    static let dragRest: Duration = .milliseconds(150)

    // MARK: type

    func type(_ args: ScreenArguments, paneText: String, pane: UUID, name: String, arrived: ContinuousClock.Instant) async throws -> Done {
        enum Aim {
            case target(String, ScreenTarget)
            case focused(String?)
        }
        let characters: [Character]
        switch args.text {
        case .flag?: throw ScreenRefusal.bad("text is the words to type, a string")
        case .words(let words)?: characters = Array(words)
        case nil: characters = []
        }
        if let problem = ScreenKeys.problem(withText: String(characters)) { throw ScreenRefusal.bad(problem) }
        let written = args.keys ?? []
        guard written.count <= ScreenKeys.maxKeys else { throw ScreenRefusal.bad("At most \(ScreenKeys.maxKeys) keys in one call") }
        var combos: [KeyCombo] = []
        for text in written {
            guard let combo = ScreenKeys.parse(text) else {
                throw ScreenRefusal.bad("Can't read the key combo \"\(String(text.prefix(30)))\". Write modifiers (cmd, ctrl, opt, shift) and one key joined by +, such as cmd+l, shift+Tab or Return")
            }
            if let why = ScreenKeys.refusal(of: combo) { throw ScreenRefusal.bad(why) }
            combos.append(combo)
        }
        let replace = args.replace == true
        // ⌘A is the key that types "a" on the current layout, never a US key code: that would be ⌘Q on a French one.
        var selectAll: KeyCombo?
        if replace {
            guard let combo = ScreenKeys.parse("cmd+a") else { throw ScreenRefusal.bad("No key of the current keyboard layout types A, so replace can't select all") }
            selectAll = combo
        }
        guard !characters.isEmpty || !combos.isEmpty else { throw ScreenRefusal.bad("Give text, keys or both") }
        let aim: Aim
        if let id = args.id {
            aim = .target(id.lowercased(), try controlTarget(id, pane: pane))
        } else {
            let named = args.app?.trimmingCharacters(in: .whitespaces)
            aim = .focused(named?.isEmpty == false ? named : nil)
        }
        guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }

        // The text and the keys take time after the last check, which the age limit gives back.
        let limit = Self.staleAfter - ScreenKeys.duration(characters: characters.count, keys: combos.count + (replace ? 1 : 0))
        await acquire()
        defer { release() }

        var drawn: Int?
        var typed = 0, pressed = 0, selected = false
        let asked = characters.count
        // What typing is still to do from here, which each check's age limit gives back.
        func remaining() -> Duration {
            ScreenKeys.duration(characters: asked - typed, keys: combos.count - pressed + (selectAll != nil && !selected ? 1 : 0))
        }
        do {
            try stillAllowed(paneText: paneText, arrived: arrived, limit: limit)
            var steps: [String] = []
            if replace { steps.append("select all") }
            if asked > 0 { steps.append("\(asked) character\(asked == 1 ? "" : "s")") }
            if !combos.isEmpty { steps.append(combos.map(\.label).joined(separator: " ")) }
            let what = steps.joined(separator: ", then ")

            let app: NSRunningApplication
            let shown: CGRect
            let sign: String, whereTo: String
            switch aim {
            case .target(let id, let target):
                guard let owner = Self.owner(of: target) else { throw ScreenRefusal.gone }
                guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
                app = owner
                shown = frame
                whereTo = id
                sign = "\(name)\nTyping into \(id): \(String(target.description.prefix(Self.signNote - 40)))\n\(what)"
            case .focused(let named):
                if let named {
                    guard let found = ScreenReader.application(named: named) else { throw ScreenRefusal.noApp(named) }
                    app = found
                } else {
                    guard let found = ScreenReader.focusedApplication() else { throw ScreenRefusal.nothingInFront }
                    app = found
                }
                let focus = await ScreenReader.focus(pid: app.processIdentifier)
                guard let frame = focus.frame ?? focus.windowFrame else { throw ScreenRefusal.noWindow(app.localizedName ?? "That app") }
                shown = frame
                whereTo = "the focused field"
                sign = "\(name)\nTyping into the focused text field\n\(what)"
            }
            guard ArrowOverlay.shared.show(frame: shown, note: sign) else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
            try? await Task.sleep(for: Self.clickLead)
            try stillAllowed(paneText: paneText, arrived: arrived, limit: limit)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            var raising: AXReference?
            if case .target(_, let target) = aim { raising = await ScreenReader.window(of: target) }
            try await Self.bringForward(app, raising: raising)
            try stillAllowed(paneText: paneText, arrived: arrived, limit: limit)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            if case .target(let id, let target) = aim {
                try await putFocus(on: target, id: id, in: app, shown: shown, sign: sign, drawn: &drawn)
            }
            // After the focus is set and before the first character: Varnick never types into a password field it can see.
            let focus = await ScreenReader.focus(pid: app.processIdentifier)
            if focus.isSecure { throw ScreenRefusal.password }
            if replace, !focus.takesSelectAll {
                throw ScreenRefusal.bad("The focus is on something that takes no typing, so select all would select all of it. Click a field first, or leave replace out")
            }
            // Spotlight or a system panel can hold the keyboard while this app is in front: nothing goes to it.
            try await keyboardIsWith(app)

            if let selectAll {
                try await pressChecked(selectAll, app: app, arrow: drawn, paneText: paneText, arrived: arrived, remaining: remaining())
                selected = true
            }
            for character in characters {
                // Nothing awaited between the check and the events.
                try checkedToType(app: app, arrow: drawn, paneText: paneText, arrived: arrived, remaining: remaining())
                ScreenKeys.post(character)
                typed += 1
                try? await Task.sleep(for: ScreenKeys.characterPace)
            }
            for combo in combos {
                try await pressChecked(combo, app: app, arrow: drawn, paneText: paneText, arrived: arrived, remaining: remaining())
                pressed += 1
            }
            ArrowOverlay.shared.hide(after: Self.clickLinger)

            var did: [String] = []
            if replace { did.append("selected everything") }
            if asked > 0 { did.append("typed \(asked) character\(asked == 1 ? "" : "s") into \(whereTo)") }
            if !combos.isEmpty { did.append("pressed \(combos.map(\.label).joined(separator: " "))") }
            var text = did.joined(separator: ", ")
            if let last = did.last, did.count > 1 { text = did.dropLast().joined(separator: ", ") + " and " + last }
            text = text.prefix(1).uppercased() + text.dropFirst() + "."
            if asked > 0 { text += " A field's contents are never read, so look won't show them: type with replace to know what a field holds." }
            return Done(text: text, counts: "characters \(typed) of \(asked), keys \(pressed) of \(combos.count)")
        } catch let refusal as ScreenRefusal {
            if let drawn, ArrowOverlay.shared.generation == drawn { ArrowOverlay.shared.hide() }
            let counts = "characters \(typed) of \(asked), keys \(pressed) of \(combos.count)"
            guard selected || typed > 0 || pressed > 0 else { throw ScreenRefusal.stopped(refusal, "Nothing was typed", counts) }
            var done = asked > 0 ? "Stopped after \(typed) of \(asked) characters" : "Stopped"
            if !combos.isEmpty { done += pressed == 0 ? "; no keys were pressed" : "; pressed \(pressed) of \(combos.count) keys" }
            if selected { done += "; everything was selected first" }
            throw ScreenRefusal.stopped(refusal, done, counts)
        }
    }

    /// Puts the focus on the id's control, with the app in front. Outside a page it is the control's Accessibility focus, which must
    /// then be reported; in a page, or for recognised text, it is a posted click at its centre, which a page may or may not turn into
    /// focus, and which cannot be checked since a page often reports none.
    private func putFocus(on target: ScreenTarget, id: String, in app: NSRunningApplication, shown: CGRect, sign: String,
                          drawn: inout Int?) async throws {
        let content = await ScreenReader.content(of: target, in: app)
        if case .unplaced = content { throw ScreenRefusal.unplaced }
        if let reference = target.reference, case .native = content {
            await ScreenReader.setFocus(of: reference)
            var read = await ScreenReader.focus(pid: app.processIdentifier)
            for _ in 0..<2 where !read.isInside(reference) {
                try? await Task.sleep(for: .milliseconds(80))
                read = await ScreenReader.focus(pid: app.processIdentifier)
            }
            guard read.isInside(reference) else {
                throw ScreenRefusal.bad("Couldn't put the focus in \(id): click it, then type without an id")
            }
            return
        }
        guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if case .page(let page?) = content, !page.contains(centre) { throw ScreenRefusal.gone }
        guard Self.onDisplay(centre) else { throw ScreenRefusal.offDisplay }
        if abs(centre.x - shown.midX) > Self.arrowFollows || abs(centre.y - shown.midY) > Self.arrowFollows {
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }
            guard ArrowOverlay.shared.show(frame: frame, note: sign) else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
        }
        try Self.checkedToPost(at: centre, frontmost: app, arrow: drawn)
        await Self.leftClick(at: centre)
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// Whether the app is the one with the keyboard system-wide.
    private func keyboardIsWith(_ app: NSRunningApplication) async throws {
        guard let owner = await ScreenReader.keyboardOwner() else { throw ScreenRefusal.keyboardUnknown }
        guard owner == app.processIdentifier else { throw ScreenRefusal.keyboardElsewhere }
    }

    /// One key combo. A combo can hand the keyboard to another process (Spotlight, a system panel) or move the focus into a password
    /// field, so both are read first, side by side, off the main actor. The checks then run and the key-down is posted with nothing
    /// awaited between; the key-up always follows.
    private func pressChecked(_ combo: KeyCombo, app: NSRunningApplication, arrow: Int?, paneText: String,
                              arrived: ContinuousClock.Instant, remaining: Duration) async throws {
        async let keyboard: Void = keyboardIsWith(app)
        async let focus = ScreenReader.focus(pid: app.processIdentifier, timeout: 0.1, light: true)
        try await keyboard
        if await focus.isSecure { throw ScreenRefusal.password }
        try checkedToType(app: app, arrow: arrow, paneText: paneText, arrived: arrived, remaining: remaining)
        ScreenKeys.press(combo)
        try? await Task.sleep(for: ScreenKeys.comboHold)
        ScreenKeys.release(combo)
        try? await Task.sleep(for: ScreenKeys.comboPace - ScreenKeys.comboHold)
    }

    /// Run on the main actor right before a character or a key is posted, with nothing awaited between: the switch and the pane, the
    /// call's age, the app still in front, no window of Varnick's with the keyboard (its panel is nonactivating, so it can take the
    /// keyboard while another app stays in front), and the Arrow up still this call's.
    private func checkedToType(app: NSRunningApplication, arrow: Int?, paneText: String, arrived: ContinuousClock.Instant,
                               remaining: Duration) throws {
        try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.typingDeadline - remaining)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw ScreenRefusal.leftFront }
        guard !NSApplication.shared.windows.contains(where: { $0.isVisible && $0.isKeyWindow && !ArrowOverlay.shared.owns($0) }) else {
            throw ScreenRefusal.varnickKey
        }
        guard ArrowOverlay.shared.generation == arrow else { throw ScreenRefusal.replaced }
        guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }
    }

    // MARK: drag

    func drag(_ args: ScreenArguments, paneText: String, pane: UUID, name: String, arrived: ContinuousClock.Instant) async throws -> Done {
        enum End {
            case target(String, ScreenTarget)
            case point(CGPoint)

            var label: String {
                switch self {
                case .target(let id, _): id
                case .point(let at): "\(Int(at.x.rounded())), \(Int(at.y.rounded()))"
                }
            }
        }
        // Early, so a refusal waits for nothing; each is asked again where it can change.
        func end(_ spot: ScreenArguments.Spot?, _ which: String) throws -> End {
            if let id = spot?.id { return .target(id.lowercased(), try controlTarget(id, pane: pane)) }
            guard let at = spot?.point?.point else {
                throw ScreenRefusal.bad("Give \(which) as an id from the last look, or a point {x, y}")
            }
            guard at.x.isFinite, at.y.isFinite, Self.onDisplay(at) else { throw ScreenRefusal.offDisplay }
            guard !Self.varnickCovers(at) else { throw ScreenRefusal.covered }
            return .point(at)
        }
        let from = try end(args.from, "from"), to = try end(args.to, "to")
        switch (from, to) {
        case (.point(let a), .point(let b)) where hypot(a.x - b.x, a.y - b.y) < 2: throw ScreenRefusal.bad("That is a click: use click")
        case (.target(let a, _), .target(let b, _)) where a == b: throw ScreenRefusal.bad("That is a click: use click")
        default: break
        }
        guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }

        await acquire()
        defer { release() }

        var drawn: Int?
        var down = false
        do {
            try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.dragLimit)
            let shown: CGRect
            switch from {
            case .target(_, let target):
                guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
                shown = frame
            case .point(let at):
                shown = CGRect(x: at.x - 14, y: at.y - 14, width: 28, height: 28)
            }
            let sign = "\(name)\nDragging \(from.label) to \(to.label)"
            guard ArrowOverlay.shared.show(frame: shown, note: sign) else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
            try? await Task.sleep(for: Self.clickLead)
            try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.dragLimit)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            // Both ends' apps, found at the same moment and before the start's comes forward: a point's is the ordinary window in
            // front there, an id's is its owner. Only the start's comes forward, since a mouse-down on a window of an app that is not
            // in front often only brings it forward. The end's may be another app (a file dragged from Finder onto a page).
            func app(of end: End) throws -> NSRunningApplication? {
                switch end {
                case .target(_, let target):
                    guard let owner = Self.owner(of: target) else { throw ScreenRefusal.gone }
                    return owner
                case .point(let at): return Self.appUnder(at)
                }
            }
            let startApp = try app(of: from), endApp = try app(of: to)
            switch from {
            case .target(_, let target):
                try await Self.bringForward(startApp!, raising: await ScreenReader.window(of: target))
            case .point(let at):
                if let startApp { try await Self.bringForward(startApp, raising: await ScreenReader.window(at: at, pid: startApp.processIdentifier)) }
            }
            try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.dragLimit)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            // The reads, once the app is in front: never the frames from the look. In a page the centre must be inside what shows.
            func centre(of end: End, in app: NSRunningApplication?) async throws -> (point: CGPoint, frame: CGRect) {
                switch end {
                case .target(_, let target):
                    guard let app else { throw ScreenRefusal.gone }
                    let content = await ScreenReader.content(of: target, in: app)
                    if case .unplaced = content { throw ScreenRefusal.unplaced }
                    guard let frame = await ScreenReader.currentFrame(of: target) else { throw ScreenRefusal.gone }
                    let point = CGPoint(x: frame.midX, y: frame.midY)
                    if case .page(let page?) = content, !page.contains(point) { throw ScreenRefusal.gone }
                    return (point, frame)
                case .point(let at):
                    return (at, CGRect(x: at.x - 14, y: at.y - 14, width: 28, height: 28))
                }
            }
            let begin = try await centre(of: from, in: startApp), finish = try await centre(of: to, in: endApp)
            guard Self.onDisplay(begin.point), Self.onDisplay(finish.point) else { throw ScreenRefusal.offDisplay }
            guard hypot(begin.point.x - finish.point.x, begin.point.y - finish.point.y) >= 2 else { throw ScreenRefusal.bad("That is a click: use click") }
            if abs(begin.point.x - shown.midX) > Self.arrowFollows || abs(begin.point.y - shown.midY) > Self.arrowFollows {
                guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }
                guard ArrowOverlay.shared.show(frame: begin.frame, note: sign) else { throw ScreenRefusal.offDisplay }
                drawn = ArrowOverlay.shared.generation
            }
            try Self.checkedToPost(at: begin.point, frontmost: startApp, arrow: drawn)
            try checkedToRelease(at: finish.point, endApp: endApp, arrow: drawn, paneText: paneText, arrived: arrived)

            Self.postMouse(.mouseMoved, at: begin.point)
            try? await Task.sleep(for: .milliseconds(50))
            try Self.checkedToPost(at: begin.point, frontmost: startApp, arrow: drawn)
            try checkedToRelease(at: finish.point, endApp: endApp, arrow: drawn, paneText: paneText, arrived: arrived)
            Self.postMouse(.leftMouseDown, at: begin.point)
            down = true
            // The button is let go on every path from here, a refusal included: back where it began unless it got to the end.
            var released = false
            defer {
                if !released {
                    Self.postMouse(.leftMouseDragged, at: begin.point)
                    Self.postMouse(.leftMouseUp, at: begin.point)
                }
            }
            try? await Task.sleep(for: Self.dragHold)
            // Drawn again at the end, after a check that it is still this call's.
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }
            guard ArrowOverlay.shared.show(frame: finish.frame, note: sign) else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
            let steps = max(1, Int(Self.dragTime / Self.dragStep.seconds))
            for step in 1...steps {
                try stillAllowed(paneText: paneText, arrived: arrived, limit: nil)
                guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }
                let along = Double(step) / Double(steps)
                Self.postMouse(.leftMouseDragged, at: CGPoint(x: begin.point.x + (finish.point.x - begin.point.x) * along,
                                                              y: begin.point.y + (finish.point.y - begin.point.y) * along))
                try? await Task.sleep(for: Self.dragStep)
            }
            try? await Task.sleep(for: Self.dragRest)
            try checkedToRelease(at: finish.point, endApp: endApp, arrow: drawn, paneText: paneText, arrived: arrived)
            Self.postMouse(.leftMouseUp, at: finish.point)
            released = true
            ArrowOverlay.shared.hide(after: Self.clickLinger)
            let at = "\(Int(finish.point.x.rounded())), \(Int(finish.point.y.rounded()))"
            if case .target = to { return Done(text: "Dragged \(from.label) to \(to.label) (\(at)). Look again to see what happened.") }
            return Done(text: "Dragged \(from.label) to \(at). Look again to see what happened.")
        } catch let refusal as ScreenRefusal {
            if let drawn, ArrowOverlay.shared.generation == drawn { ArrowOverlay.shared.hide() }
            throw ScreenRefusal.stopped(refusal, down ? "Let go where it began" : "Nothing was dragged", "")
        }
    }

    /// Run on the main actor before the button goes down and before it comes up, with nothing awaited between: the switch and the pane,
    /// the Arrow, Varnick's windows, and that the front window at the end is still the end's app's (none, if none was).
    private func checkedToRelease(at end: CGPoint, endApp: NSRunningApplication?, arrow: Int?, paneText: String,
                                  arrived: ContinuousClock.Instant) throws {
        try stillAllowed(paneText: paneText, arrived: arrived, limit: nil)
        guard ArrowOverlay.shared.generation == arrow else { throw ScreenRefusal.replaced }
        guard Self.onDisplay(end) else { throw ScreenRefusal.offDisplay }
        guard !Self.varnickCovers(end) else { throw ScreenRefusal.covered }
        if let endApp {
            guard Self.frontWindow(at: end)?.pid == endApp.processIdentifier else { throw ScreenRefusal.overlapped }
        } else {
            guard Self.appUnder(end) == nil else { throw ScreenRefusal.overlapped }
        }
        guard CGPreflightPostEventAccess() else { throw ScreenRefusal.noPostAccess }
    }

    /// One left-button mouse event at the HID level, as `leftClick`'s.
    nonisolated static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        if type != .mouseMoved { event?.setIntegerValueField(.mouseEventClickState, value: 1) }
        event?.post(tap: .cghidEventTap)
    }

    // MARK: window

    func window(_ args: ScreenArguments, paneText: String, pane: UUID, name: String, arrived: ContinuousClock.Instant) async throws -> Done {
        let position = args.position?.point, size = args.size?.size
        guard position != nil || size != nil else { throw ScreenRefusal.bad("Give a position, a size, or both") }
        if let position, !(position.x.isFinite && position.y.isFinite) { throw ScreenRefusal.bad("The position needs numbers") }
        if let size, !(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0) {
            throw ScreenRefusal.bad("The size needs a positive width and height")
        }
        let reference: AXReference?, named: String?, label: String
        if let id = args.id {
            guard Self.isWindowID(id) else { throw ScreenRefusal.bad("That is a control: window takes a window's id from look (w1), or an app") }
            guard let found = try target(id, pane: pane).reference else { throw ScreenRefusal.gone }
            reference = found
            named = nil
            label = id.trimmingCharacters(in: .whitespaces).lowercased()
        } else if let app = args.app?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            reference = nil
            named = app
            label = "the window"
        } else {
            throw ScreenRefusal.bad("Give a window's id from the last look (w1), or an app")
        }

        await acquire()
        defer { release() }

        var drawn: Int?
        do {
            try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.windowLimit)
            let window: AXReference
            if let reference {
                window = reference
            } else {
                guard let found = ScreenReader.application(named: named ?? "") else { throw ScreenRefusal.noApp(named ?? "") }
                guard let focused = await ScreenReader.window(ofApp: found.processIdentifier) else {
                    throw ScreenRefusal.noWindow(found.localizedName ?? "That app")
                }
                window = focused
            }
            // Never Varnick's: `application(named:)` skips it, and a window id of its own can't come from `look`, but the pid is checked.
            guard let pid = ScreenReader.pid(of: window) else { throw ScreenRefusal.gone }
            guard pid != ProcessInfo.processInfo.processIdentifier else { throw ScreenRefusal.varnickTarget }
            // What stops a window changing, and whether its title bar stays reachable: asked now, for the Arrow, and again after the lead.
            func checked() async throws -> CGRect {
                switch await ScreenReader.refusal(for: window, moving: position != nil, resizing: size != nil) {
                case .fullScreen?: throw ScreenRefusal.bad("That window is in full screen")
                case .minimized?: throw ScreenRefusal.bad("That window is minimized")
                case .cantMove?: throw ScreenRefusal.bad("That window can't be moved")
                case .cantResize?: throw ScreenRefusal.bad("That window can't be resized")
                case nil: break
                }
                guard let now = await ScreenReader.frame(ofWindow: window) else { throw ScreenRefusal.gone }
                // Its title bar is where the user takes hold of it: some of it must be on a display.
                guard Self.titleBarReachable(CGRect(origin: position ?? now.origin, size: size ?? now.size)) else {
                    throw ScreenRefusal.bad("That would put the window's title bar off every display")
                }
                return now
            }
            let now = try await checked()

            let moving = position.map { "to \(Int($0.x.rounded())), \(Int($0.y.rounded()))" }
            let resizing = size.map { "to \(Int($0.width.rounded())) × \(Int($0.height.rounded()))" }
            let sign: String
            switch (moving, resizing) {
            case (let move?, let resize?): sign = "Moving and resizing \(label) \(move), \(resize)"
            case (let move?, nil): sign = "Moving \(label) \(move)"
            case (nil, let resize?): sign = "Resizing \(label) \(resize)"
            case (nil, nil): sign = "Changing \(label)"
            }
            guard ArrowOverlay.shared.show(frame: now, note: "\(name)\n\(sign)") else { throw ScreenRefusal.offDisplay }
            drawn = ArrowOverlay.shared.generation
            try? await Task.sleep(for: Self.clickLead)
            _ = try await checked()
            try stillAllowed(paneText: paneText, arrived: arrived, limit: Self.windowLimit)
            guard ArrowOverlay.shared.generation == drawn else { throw ScreenRefusal.replaced }

            let result = await ScreenReader.set(window, position: position, size: size)
            if result == .invalidUIElement { throw ScreenRefusal.gone }
            guard let back = await ScreenReader.frame(ofWindow: window) else { throw ScreenRefusal.gone }
            if ArrowOverlay.shared.generation == drawn {
                _ = ArrowOverlay.shared.show(frame: back, note: "\(name)\n\(label.prefix(1).uppercased() + label.dropFirst()) is here")
                ArrowOverlay.shared.hide(after: Self.clickLinger)
            }
            var text = "\(label.prefix(1).uppercased() + label.dropFirst()) is now \(Self.describe(back))."
            if result == .cannotComplete { text = "The app did not answer in time. " + text }
            else if result != .success { text = "The app refused part of the change (error \(result.rawValue)). " + text }
            return Done(text: text + " Its controls have moved: look again.")
        } catch let refusal as ScreenRefusal {
            if let drawn, ArrowOverlay.shared.generation == drawn { ArrowOverlay.shared.hide() }
            throw ScreenRefusal.stopped(refusal, "Nothing was moved", "")
        }
    }

    /// Whether enough of the top 30 points of a frame, where the title bar is, is on a display for the user to reach it.
    private static func titleBarReachable(_ frame: CGRect) -> Bool {
        let strip = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(30, frame.height))
        let appKit = ScreenGeometry.appKit(strip, mainDisplayHeight: ScreenGeometry.mainDisplayHeight)
        return NSScreen.screens.contains {
            let shown = $0.frame.intersection(appKit)
            return !shown.isNull && shown.width >= min(20, strip.width) && shown.height >= min(20, strip.height)
        }
    }
}
