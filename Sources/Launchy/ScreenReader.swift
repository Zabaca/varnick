import AppKit
import ApplicationServices
import Foundation

/// Reads the elements of the focused window through Accessibility, in this process under Launchy's own grant (ADR 0019). It never
/// goes through a helper, a script or a pane: those run under zmx, and a grant to zmx would reach every session it hosts.
/// No image is made. What an element may hold is in where-it-breaks.md, Pointing at the screen.
enum ScreenReader {
    // Limits, tuned by hand. A hung app costs only the budget.
    static let budget: Duration = .seconds(1)
    static let maxNodes = 3000
    static let maxDepth = 30
    static let callTimeout: Float = 0.25
    /// How long the first request to an Electron app waits for the web tree it was asked to build.
    static let electronSettle: TimeInterval = 0.3

    struct Reading {
        var windowTitle = ""
        var elements: [ScreenElement] = []
        /// A Chrome web area with nothing in it: the page's content is out of reach.
        var chromeBlind = false
        var duration: Duration = .zero
        /// The window and its frame, which text recognition (ADR 0021) finds its picture by and its boxes follow.
        var window: AXReference?
        var windowFrame: CGRect?
        /// The frames of the text fields, text areas, combo boxes, search fields and secure fields the walk met, and of the field
        /// that has focus: recognised lines inside them are what a person typed and are dropped. Never sent.
        var entryFrames: [CGRect] = []
        /// The biggest web area with nothing in it, which is where a Chrome page's text is.
        var emptyWebArea: CGRect?
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

    /// The pointer in Accessibility coordinates.
    @MainActor
    static func pointer() -> CGPoint {
        ScreenGeometry.accessibility(NSEvent.mouseLocation, mainDisplayHeight: ScreenGeometry.mainDisplayHeight)
    }

    /// The app's focused window, within the limits, off the main actor.
    static func read(_ app: NSRunningApplication, pointer: CGPoint) async -> Reading {
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        let electron = isElectron(app)
        return await Task.detached(priority: .userInitiated) {
            await readWindow(pid: pid, bundle: bundle, electron: electron, pointer: pointer)
        }.value
    }

    /// Electron apps carry their framework; Chrome does not, and is not asked.
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    /// Pids already asked for their web tree: the app keeps it until it quits, so only the first request waits.
    private final class AskedForWebTree: @unchecked Sendable {
        private let lock = NSLock()
        private var pids = Set<pid_t>()

        func first(_ pid: pid_t) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return pids.insert(pid).inserted
        }
    }
    private static let askedForWebTree = AskedForWebTree()

    private static func readWindow(pid: pid_t, bundle: String, electron: Bool, pointer: CGPoint) async -> Reading {
        let clock = ContinuousClock()
        let began = clock.now
        let deadline = began.advanced(by: budget)
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), callTimeout)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, callTimeout)

        if electron, AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success,
           askedForWebTree.first(pid) {
            try? await Task.sleep(for: .seconds(electronSettle))
        }

        var reading = Reading()
        guard let window = attribute(app, kAXFocusedWindowAttribute).flatMap(asElement)
                ?? attribute(app, kAXMainWindowAttribute).flatMap(asElement) else {
            reading.duration = began.duration(to: clock.now)
            return reading
        }
        reading.windowTitle = String(ScreenElements.cleaned(string(window, kAXTitleAttribute) ?? "").prefix(ScreenElements.maxLabel))
        reading.window = AXReference(window)
        reading.windowFrame = frame(of: window)
        // The field with focus may be outside what the walk reaches, and is where a person is typing.
        if let focus = attribute(app, kAXFocusedUIElementAttribute).flatMap(asElement),
           case let values = multiple(focus, [kAXRoleAttribute, kAXSubroleAttribute]),
           isEntry(role: values[0] as? String ?? "", subrole: values[1] as? String ?? ""), let focusFrame = frame(of: focus) {
            reading.entryFrames.append(focusFrame)
        }
        var walk = Walk(deadline: deadline)
        walk.run(window: window)
        if clock.now < deadline { walk.markUnderPointer(app: app, pointer: pointer) }

        let texts = walk.elements.filter(\.isText)
        reading.elements = walk.elements.prefix(ScreenElements.maxListed).map { element in
            var element = element
            element.beside = ScreenElements.beside(element, among: texts)
            return element
        }
        reading.entryFrames += walk.entryFrames
        reading.chromeBlind = walk.emptyWebArea != nil && bundle.lowercased().contains("chrom")
        reading.emptyWebArea = walk.emptyWebArea
        reading.duration = began.duration(to: clock.now)
        return reading
    }

    /// The element's frame now, or nil when it is gone. Read again just before the arrow is drawn.
    /// Where `target` is now, off the main actor: its element's frame, or for recognised text its box carried along with a window
    /// that moved. Nil when the element is gone or the window changed size.
    static func currentFrame(of target: ScreenTarget) async -> CGRect? {
        await Task.detached { () -> CGRect? in
            if let reference = target.reference { return frame(of: reference.element) }
            guard let window = target.window, let was = target.windowFrame else { return target.frame }
            return frame(of: window.element).flatMap { ScreenGeometry.moved(target.frame, from: was, to: $0) }
        }.value
    }

    // MARK: The walk

    // Left out of the list, as the eval left them out: containers and scroll machinery.
    private static let skippedRoles: Set<String> = ["AXSplitter", "AXScrollBar", "AXValueIndicator", "AXColumn", "AXLayoutArea", "AXUnknown", "AXMenuBar"]
    private static let skippedSubroles: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
    private static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    private static let textRoles: Set<String> = ["AXStaticText", "AXHeading"]
    /// The roles whose value is their state or choice, the only controls whose value is read (a switch's "1", a pop-up's "Bottom").
    /// A cell's or any other role's value may be what a person entered.
    private static let stateRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXIncrementor", "AXStepper"]

    /// Where the person types: neither its value nor anything inside it is read (a draft's text runs are its children).
    private static func isEntry(role: String, subrole: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || ["AXSearchField", "AXSecureTextField"].contains(subrole)
    }

    private struct Node {
        var element: AXUIElement
        var depth: Int
        var path: [String]
    }

    private struct Walk {
        let deadline: ContinuousClock.Instant
        var nodes = 0
        /// In tree order: depth first, a parent before its children.
        var elements: [ScreenElement] = []
        var emptyWebArea: CGRect?
        var entryFrames: [CGRect] = []
        var window = CGRect.infinite

        var outOfBudget: Bool { nodes >= ScreenReader.maxNodes || ContinuousClock.now >= deadline }

        mutating func run(window root: AXUIElement) {
            var stack = [Node(element: root, depth: 0, path: [])]
            while let node = stack.popLast(), !outOfBudget {
                stack.append(contentsOf: visit(node).reversed())
            }
        }

        /// Lists the node if it qualifies and returns its children.
        mutating func visit(_ node: Node) -> [Node] {
            nodes += 1
            let basics = ScreenReader.multiple(node.element, [kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
                                                              kAXChildrenAttribute, kAXEnabledAttribute])
            let role = basics[0] as? String ?? ""
            let subrole = basics[1] as? String ?? ""
            let children = basics[3] as? [AXUIElement] ?? []
            let entry = ScreenReader.isEntry(role: role, subrole: subrole)
            let frame = ScreenReader.frame(of: node.element)
            if role == "AXWebArea", children.isEmpty {
                let area = frame ?? .zero
                if emptyWebArea == nil || area.width * area.height > emptyWebArea!.width * emptyWebArea!.height { emptyWebArea = area }
            }
            if entry, let frame { entryFrames.append(frame) }
            // Nothing of a secure field is read but where it is (text recognition drops what lies in it, ADR 0021).
            guard subrole != "AXSecureTextField" else { return [] }
            if node.depth == 0 { window = frame ?? .infinite }

            let parts = ScreenReader.labelParts(node.element, readsValue: !entry && (stateRoles.contains(role) || textRoles.contains(role)))
            let label = ScreenElements.label(from: parts)
            if node.depth > 0, !skippedRoles.contains(role), !skippedSubroles.contains(subrole), let frame, frame.width > 1, frame.height > 1,
               window.contains(CGPoint(x: frame.midX, y: frame.midY)), !label.isEmpty || windowButtons.contains(subrole) {
                var element = ScreenElement(role: ScreenReader.stringValue(basics[2]) ?? String(role.dropFirst(2)).lowercased(), label: label,
                                            name: ScreenReader.name(parts, isText: textRoles.contains(role)), frame: frame)
                element.enabled = basics[4] as? Bool ?? true
                element.path = node.path
                element.help = parts[3].map(ScreenElements.cleaned)
                element.isText = textRoles.contains(role)
                element.reference = AXReference(node.element)
                elements.append(element)
            }
            // The walk goes through layout areas and the like, as the eval's did; only a scroll bar's machinery is left alone.
            guard !entry, role != "AXScrollBar", node.depth < ScreenReader.maxDepth, !children.isEmpty else { return [] }
            // A named ancestor is a group its contents sit in (`in Sidebar`); the window itself is not one.
            var path = node.path
            if node.depth > 0, let group = parts.lazy.compactMap({ $0 }).map(ScreenElements.cleaned).first(where: { !$0.isEmpty }) {
                path.append(String(group.prefix(40)))
            }
            return children.map { Node(element: $0, depth: node.depth + 1, path: path) }
        }

        /// Marks the listed element under the pointer: the first listed one within four levels of the hit, or its listed ancestor
        /// when that one is text. Where the pointer is inside a field, the field is what is under it: its text is never read.
        /// Gives up when the time is spent.
        mutating func markUnderPointer(app: AXUIElement, pointer: CGPoint) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(pointer.x), Float(pointer.y), &hit) == .success, let hit else { return }
            var chain = [hit]
            while chain.count < 6, ContinuousClock.now < deadline,
                  let parent = ScreenReader.attribute(chain.last!, kAXParentAttribute).flatMap(ScreenReader.asElement) {
                chain.append(parent)
            }
            var outer: Int?
            for (index, element) in chain.enumerated() {
                guard ContinuousClock.now < deadline else { return }
                let values = ScreenReader.multiple(element, [kAXRoleAttribute, kAXSubroleAttribute])
                if ScreenReader.isEntry(role: values[0] as? String ?? "", subrole: values[1] as? String ?? "") { outer = index }
            }
            if let outer { chain = Array(chain[outer...]) }
            let listed = chain.prefix(4).compactMap { candidate in
                elements.firstIndex { $0.reference.map { CFEqual($0.element, candidate) } ?? false }
            }
            guard let first = listed.first else { return }
            var marked = first
            if elements[first].isText, let ancestor = listed.first(where: { !elements[$0].isText }) { marked = ancestor }
            elements[marked].underPointer = true
        }
    }

    // MARK: Attributes

    fileprivate static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    fileprivate static func asElement(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    /// Several attributes in one call; one the element lacks is nil.
    fileprivate static func multiple(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
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

    fileprivate static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID() { return (value as? NSNumber)?.stringValue }
        return nil
    }

    fileprivate static func frame(of element: AXUIElement) -> CGRect? {
        let values = multiple(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let position = values[0], let size = values[1],
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              [point.x, point.y, extent.width, extent.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Title, description, value, help and placeholder, in that order. The value is asked for only when `readsValue`.
    fileprivate static func labelParts(_ element: AXUIElement, readsValue: Bool) -> [String?] {
        let values = multiple(element, readsValue ? [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXValueAttribute]
                                                  : [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute])
            .map(stringValue)
        return [values[0], values[1], readsValue ? values[4] : nil, values[2], values[3]]
    }

    /// Title, else description, else placeholder; a text's own words for text. Empty when there is none, as for a switch whose label
    /// is only its state.
    fileprivate static func name(_ parts: [String?], isText: Bool) -> String {
        let order = isText ? [parts[0], parts[1], parts[2], parts[4]] : [parts[0], parts[1], parts[4]]
        return order.compactMap { $0 }.map(ScreenElements.cleaned).first { !$0.isEmpty } ?? ""
    }
}
