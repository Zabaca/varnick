import AppKit
import ApplicationServices
import Foundation

/// Reads the controls of the window in front through Accessibility, in this process under Launchy's own grant (ADR 0019). It never
/// goes through a helper, a script or a pane: those run under zmx, and a grant to zmx would reach every session it hosts.
/// No image is made. What a candidate may hold is in where-it-breaks.md, Pointing at the screen.
enum ScreenReader {
    // MARK: Limits, tuned by hand

    /// A hung app costs only this.
    static let budget: Duration = .seconds(1)
    static let maxNodes = 3000
    static let maxDepth = 30
    /// For each Accessibility call.
    static let callTimeout: Float = 0.25
    /// How long the first request to an Electron app waits for the tree it was asked to build.
    static let electronSettle: TimeInterval = 0.3

    struct Reading {
        var windowTitle = ""
        var elements: [ScreenElement] = []
        /// A Chrome web area with nothing in it: the page's content is out of reach.
        var chromeBlind = false
        var duration: Duration = .zero
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Which app

    /// The application with keyboard focus; when that is Launchy (its panel is open), the frontmost other app. Launchy's own
    /// windows are never read.
    static func focusedApplication() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused as! AXUIElement, &pid) == .success, pid != ownPID,
               let app = NSRunningApplication(processIdentifier: pid) {
                return app
            }
        }
        // The first window on screen, front to back, that isn't Launchy's. The owner and the layer need no permission.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    /// A running app by its name, for `Launchy --ask --app`.
    static func application(named name: String) -> NSRunningApplication? {
        let wanted = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == wanted } ?? apps.first { $0.localizedName?.lowercased().contains(wanted) == true }
    }

    // MARK: Reading

    /// Where the displays are, in Accessibility coordinates, and the pointer: taken on the main actor before the read.
    struct Surroundings: Sendable {
        var displays: [CGRect]
        var pointer: CGPoint
    }

    @MainActor
    static func surroundings() -> Surroundings {
        let screens = NSScreen.screens
        let height = screens.first?.frame.height ?? 0
        let displays = screens.map { screen in
            CGRect(x: screen.frame.minX, y: height - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        return Surroundings(displays: displays, pointer: ScreenGeometry.accessibility(NSEvent.mouseLocation, mainDisplayHeight: height))
    }

    /// The app's focused window first, then its other windows, then the top of its menu bar, within the limits. Off the main actor.
    static func read(_ app: NSRunningApplication, around: Surroundings) async -> Reading {
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        return await Task.detached(priority: .userInitiated) {
            await readSynchronously(pid: pid, bundle: bundle, around: around)
        }.value
    }

    /// Pids already asked for their web tree: the app keeps it until it quits, so the wait is only for the first request.
    private final class AskedForWebTree: @unchecked Sendable {
        private let lock = NSLock()
        private var pids = Set<pid_t>()

        /// True the first time `pid` is added.
        func first(_ pid: pid_t) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pids.insert(pid).inserted
        }
    }
    private static let askedForWebTree = AskedForWebTree()

    private static func readSynchronously(pid: pid_t, bundle: String, around: Surroundings) async -> Reading {
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = began.advanced(by: budget)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), callTimeout)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, callTimeout)

        // Electron builds its web content's tree only when asked; Chrome refuses, which is harmless.
        if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            if askedForWebTree.first(pid) { try? await Task.sleep(for: .seconds(electronSettle)) }
        }

        var walk = Walk(deadline: deadline, around: around)
        let windows = attribute(app, kAXWindowsAttribute).flatMap { $0 as? [AXUIElement] } ?? []
        var focused = attribute(app, kAXFocusedWindowAttribute).flatMap(asElement)
        if focused == nil { focused = attribute(app, kAXMainWindowAttribute).flatMap(asElement) }
        if focused == nil { focused = windows.first }
        var ordered: [AXUIElement] = focused.map { [$0] } ?? []
        ordered += windows.filter { window in !ordered.contains { CFEqual($0, window) } }
        var title = ""
        for (scope, window) in ordered.enumerated() {
            if scope == 0 { title = ScreenElements.cleaned(string(window, kAXTitleAttribute) ?? "") }
            walk.run(window: window, scope: scope)
        }
        // The top level of the menu bar: its items, not their menus.
        if let bar = attribute(app, kAXMenuBarAttribute).flatMap(asElement) {
            walk.menuBar(bar, scope: ordered.count)
        }
        walk.addElementUnderPointer(app: app, scope: ordered.count + 1)

        var reading = Reading()
        reading.windowTitle = String(title.prefix(ScreenElements.maxLabel))
        reading.elements = ScreenElements.capped(walk.finishedElements())
        reading.chromeBlind = walk.sawEmptyWebArea && bundle.lowercased().contains("chrom")
        reading.duration = began.duration(to: clock.now)
        return reading
    }

    /// The element's frame now, or nil when it is gone. Read again just before the arrow is drawn, since the window may have moved.
    static func currentFrame(of reference: AXReference) -> CGRect? {
        frame(of: reference.element)
    }

    // MARK: The walk

    /// Roles whose labels are the app's own words for a control.
    private static let pointedAt: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXSlider", "AXTextField",
        "AXTextArea", "AXComboBox", "AXColorWell", "AXDisclosureTriangle", "AXImage", "AXMenuBarItem",
    ]
    /// Fields whose value is what the person typed: never read. A secure field is not read at all.
    private static let entryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    private static let dialogSubroles: Set<String> = ["AXDialog", "AXSystemDialog", "AXSheet"]
    /// Containers and scroll machinery: never pointed at, never named.
    private static let notDescended: Set<String> = ["AXScrollBar", "AXSplitter", "AXValueIndicator", "AXMenuBar"]

    private struct Node {
        var element: AXUIElement
        var depth: Int
        var path: [String]
        var inDialog: Bool
        /// The index of the nearest row above it, to name by the first text inside.
        var row: Int?
    }

    private struct Walk {
        let deadline: ContinuousClock.Instant
        let around: Surroundings
        var nodes = 0
        var elements: [ScreenElement] = []
        var texts: [ScreenText] = []
        var sawEmptyWebArea = false
        var scopeFrames: [Int: CGRect] = [:]

        init(deadline: ContinuousClock.Instant, around: Surroundings) {
            self.deadline = deadline
            self.around = around
        }

        var outOfBudget: Bool { nodes >= ScreenReader.maxNodes || ContinuousClock.now >= deadline || Task.isCancelled }

        /// Breadth first from one window.
        mutating func run(window: AXUIElement, scope: Int) {
            scopeFrames[scope] = frame(of: window) ?? around.displays.reduce(CGRect.null) { $0.union($1) }
            var queue = [Node(element: window, depth: 0, path: [], inDialog: false, row: nil)]
            var head = 0
            while head < queue.count, !outOfBudget {
                let node = queue[head]
                head += 1
                queue.append(contentsOf: visit(node, scope: scope))
            }
        }

        /// The items of the menu bar, whose frames are on a display and not in a window.
        mutating func menuBar(_ bar: AXUIElement, scope: Int) {
            scopeFrames[scope] = around.displays.reduce(CGRect.null) { $0.union($1) }
            for item in (attribute(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where !outOfBudget {
                _ = visit(Node(element: item, depth: 1, path: [], inDialog: false, row: nil), scope: scope, descend: false)
            }
        }

        /// The element under the pointer, of any role that has a label, marked and kept first.
        mutating func addElementUnderPointer(app: AXUIElement, scope: Int) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(around.pointer.x), Float(around.pointer.y), &hit) == .success, let hit else { return }
            // The innermost element is often the text inside a button: take the nearest candidate above it, within a few levels.
            var current = hit
            for _ in 0..<5 {
                if let index = elements.firstIndex(where: { $0.reference.map { CFEqual($0.element, current) } ?? false }) {
                    elements[index].underPointer = true
                    return
                }
                guard let parent = attribute(current, kAXParentAttribute).flatMap(asElement) else { break }
                current = parent
            }
            scopeFrames[scope] = around.displays.reduce(CGRect.null) { $0.union($1) }
            if var element = ScreenReader.element(for: hit, path: [], inDialog: false, scope: scope) {
                guard isOnDisplay(element.frame) else { return }
                element.underPointer = true
                elements.insert(element, at: 0)
            }
        }

        func isOnDisplay(_ frame: CGRect) -> Bool {
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            return around.displays.contains { $0.contains(centre) }
        }

        /// Reads one node and returns its children to visit.
        @discardableResult
        mutating func visit(_ node: Node, scope: Int, descend: Bool = true) -> [Node] {
            nodes += 1
            let values = multiple(node.element, [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute])
            let role = values[0] as? String ?? ""
            let subrole = values[1] as? String ?? ""
            if notDescended.contains(role) { return [] }
            let children = values[2] as? [AXUIElement] ?? []
            if role == "AXWebArea", children.isEmpty { sawEmptyWebArea = true }
            let inDialog = node.inDialog || dialogSubroles.contains(subrole) || dialogSubroles.contains(role)
            var row = node.row

            if role == "AXStaticText" || role == "AXHeading" {
                if let text = ScreenReader.text(of: node.element), let frame = ScreenReader.frame(of: node.element), insideScope(frame, scope) {
                    texts.append(ScreenText(label: String(text.prefix(ScreenElements.maxLabel)), frame: frame, path: node.path, scope: scope))
                    if let row, elements[row].label.isEmpty {
                        elements[row].label = ScreenElements.label(from: [text])
                        elements[row].name = String(ScreenElements.cleaned(text).prefix(ScreenElements.maxLabel))
                    }
                }
            } else if role == "AXRow" {
                if let frame = ScreenReader.frame(of: node.element), insideScope(frame, scope) {
                    var element = ScreenElement(role: ScreenReader.roleWords(node.element, role), label: "", name: "", frame: frame, scope: scope)
                    element.path = node.path
                    element.inDialog = inDialog
                    element.isRow = true
                    element.reference = AXReference(node.element)
                    elements.append(element)
                    row = elements.count - 1
                }
            } else if pointedAt.contains(role) || windowButtons.contains(subrole) {
                if let element = ScreenReader.element(for: node.element, path: node.path, inDialog: inDialog, scope: scope),
                   insideScope(element.frame, scope) {
                    elements.append(element)
                }
            }
            guard descend, node.depth < ScreenReader.maxDepth, !children.isEmpty else { return [] }
            // A named ancestor is a group its contents sit in (`in Sidebar`); the window itself is not one.
            var path = node.path
            if node.depth > 0, let group = ScreenReader.groupName(of: node.element) { path.append(group) }
            return children.map { Node(element: $0, depth: node.depth + 1, path: path, inDialog: inDialog, row: row) }
        }

        func insideScope(_ frame: CGRect, _ scope: Int) -> Bool {
            guard frame.width > 1, frame.height > 1 else { return false }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            return (scopeFrames[scope] ?? .null).contains(centre) && isOnDisplay(frame)
        }

        /// Rows without any text inside are dropped, the text beside each control is found, and a control whose name is only a value
        /// is called by the text beside it.
        func finishedElements() -> [ScreenElement] {
            elements.compactMap { element in
                if element.isRow, element.label.isEmpty { return nil }
                var element = element
                if !element.isRow { element.beside = ScreenElements.beside(element, among: texts) }
                if element.name.isEmpty, let beside = element.beside { element.name = beside }
                return element
            }
        }
    }

    // MARK: Attributes

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func asElement(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    /// Several attributes in one call; an attribute the element lacks is nil.
    private static func multiple(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [CFTypeRef], array.count == names.count else { return Array(repeating: nil, count: names.count) }
        return array.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        stringValue(attribute(element, name))
    }

    private static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() { return (value as? NSNumber)?.stringValue }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        let values = multiple(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let position = values[0], let size = values[1],
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              [point.x, point.y, extent.width, extent.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func roleWords(_ element: AXUIElement, _ role: String) -> String {
        string(element, kAXRoleDescriptionAttribute) ?? String(role.dropFirst(2)).lowercased()
    }

    /// A group's name for the path, cut to 40 characters: its title, else its description.
    private static func groupName(of element: AXUIElement) -> String? {
        let values = multiple(element, [kAXTitleAttribute, kAXDescriptionAttribute])
        guard let name = stringValue(values[0]) ?? stringValue(values[1]) else { return nil }
        let words = ScreenElements.cleaned(name)
        return words.isEmpty ? nil : String(words.prefix(40))
    }

    /// The words a text shows: its value, else its title or description.
    private static func text(of element: AXUIElement) -> String? {
        let values = multiple(element, [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute])
        guard let text = stringValue(values[0]) ?? stringValue(values[1]) ?? stringValue(values[2]) else { return nil }
        let words = ScreenElements.cleaned(text)
        return words.isEmpty ? nil : words
    }

    /// A candidate from one element, or nil without a label (a window's own buttons need none) or a frame. A field's value
    /// (what is typed in it) is never asked for, and a secure field is skipped whole.
    fileprivate static func element(for element: AXUIElement, path: [String], inDialog: Bool, scope: Int) -> ScreenElement? {
        let basics = multiple(element, [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute])
        let role = basics[0] as? String ?? ""
        let subrole = basics[1] as? String ?? ""
        guard subrole != "AXSecureTextField", let frame = frame(of: element) else { return nil }
        let isEntry = entryRoles.contains(role) || subrole == "AXSearchField"
        var names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
        if !isEntry { names.append(kAXValueAttribute) }
        let values = multiple(element, names).map(stringValue)
        let title = values[0], description = values[1], help = values[2], placeholder = values[3]
        let value = isEntry ? nil : values[4]
        let label = ScreenElements.label(from: [title, description, value, help, placeholder])
        guard !label.isEmpty || windowButtons.contains(subrole) else { return nil }
        var name = [title, description, placeholder].compactMap { $0 }.map(ScreenElements.cleaned).first { !$0.isEmpty } ?? ""
        // A value is a name only when nothing else is and it is words: "1" names nothing, the text beside the switch does
        // (`finishedElements`).
        if name.isEmpty, let value, Double(value) == nil { name = ScreenElements.cleaned(value) }
        var found = ScreenElement(role: roleWords(element, role), label: label, name: name, frame: frame, scope: scope)
        found.enabled = basics[2] as? Bool ?? true
        found.path = path
        found.inDialog = inDialog
        found.help = help.map(ScreenElements.cleaned)
        found.reference = AXReference(element)
        return found
    }
}
