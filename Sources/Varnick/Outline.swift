import AppKit
import Carbon
import Combine
import VarnickPeer

/// Where a caret lands in a bullet: a UTF-16 offset (clamped), or the offset nearest `x` on the first line or the last one.
enum OutlineCaretPlace {
    case offset(Int)
    case x(CGFloat, bottom: Bool)
}

/// The Outline (ADR 0030): one tree of bullets in `outline.json`, shown in place of the panel's content like the session board. An object of
/// its own, so typing never publishes the launcher's model, which resizes the panel on every change; the rules are `OutlineTree`'s and `OutlineFile`'s.
@MainActor
final class Outline: ObservableObject {
    enum Load: Equatable {
        case notLoaded, loading, ready
        /// Why, in words that never hold a bullet's text.
        case unreadable(String)
        case newer(Int)
    }

    struct ScrollRequest: Equatable {
        let row: String
        let serial: Int
    }

    weak var model: LauncherModel?
    @Published private(set) var load = Load.notLoaded
    @Published private(set) var rows: [OutlineRow] = []
    /// Asks the view to scroll a row into sight before the caret moves into it.
    @Published private(set) var scrollRequest: ScrollRequest?
    /// A refusal's words, for a moment, in the header.
    @Published private(set) var notice: String?
    /// Not published: the view reads `rows`, and typing must not publish twice.
    private(set) var tree = OutlineTree(root: "", bullets: [:])

    private let saver = OutlineSaver { OutlineFile.url(in: SupportFolder.url) }
    private var scrollSerial = 0

    // The text views on screen, by row id, and the one with the caret.
    private struct WeakView { weak var value: OutlineTextView? }
    private var views: [String: WeakView] = [:]
    private(set) weak var activeView: OutlineTextView?
    private var remembered: (path: OutlinePath, location: Int)?
    private var pending: (path: OutlinePath, place: OutlineCaretPlace)?
    /// Keys that arrive while the caret is on its way to another bullet; they are sent again once it has landed.
    private var queuedEvents: [NSEvent] = []
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var typingRun: (path: OutlinePath, last: Date)?
    private var noticeTask: Task<Void, Never>?

    var fileURL: URL { OutlineFile.url(in: SupportFolder.url) }

    // MARK: Showing

    /// The outline shows. The file is read the first time in a launch, off the main actor.
    func appear() {
        guard load == .notLoaded else { return restoreCaret() }
        load = .loading
        let url = fileURL
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { OutlineFile.read(at: url) }.value
            self?.loaded(result)
        }
    }

    private func loaded(_ result: OutlineFile.ReadResult) {
        let now = Date()
        switch result {
        case .missing:
            use(OutlineTree.empty(now: now))
        case .loaded(let tree, let repairs):
            if !repairs.isEmpty {
                NSLog("Varnick: outline.json repaired: \(repairs.missingBullets) missing, \(repairs.insideItself) inside itself, \(repairs.recovered) recovered, \(repairs.duplicatePlacements) repeated ids, \(repairs.unreachable) unreachable")
            }
            use(tree.ensuringBullet(now: now))
        case .unreadable(let reason):
            NSLog("Varnick: outline.json couldn't be read: \(reason)")
            load = .unreadable(reason)
            return
        case .newer(let version):
            NSLog("Varnick: outline.json is version \(version), newer than this Varnick reads")
            load = .newer(version)
            return
        }
        load = .ready
        if model?.showingOutline == true { restoreCaret() }
    }

    private func use(_ new: OutlineTree) {
        tree = new
        rows = new.visibleRows()
    }

    /// The outline closes: a change not yet written is written at once.
    func close() {
        saver.flush()
        pending = nil
        queuedEvents = []
        typingRun = nil
    }

    /// Quit from the menu bar: a change not yet written is written, after any write under way.
    func saveForQuit() { saver.saveForQuit() }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }

    /// Start a new outline: the file that couldn't be read moves aside, named by the time, and the next change writes a new one.
    func startNew() {
        guard case .unreadable = load else { return }
        do {
            _ = try OutlineFile.moveAside(fileURL)
        } catch {
            return NSLog("Varnick: outline.json couldn't be moved aside: \(error.localizedDescription)")
        }
        use(OutlineTree.empty(now: Date()))
        undoStack = []
        redoStack = []
        load = .ready
        restoreCaret()
    }

    // MARK: Editing

    /// Applies one edit to the tree and puts it on the undo stack. A refusal changes nothing; one that would put a bullet inside itself also
    /// beeps and says so in the header.
    @discardableResult
    private func apply(_ edit: OutlineEdit, caretBefore: OutlineCaret? = nil, typing: Bool = false) -> Bool {
        guard load == .ready else { return false }
        switch tree.applying(edit, now: Date()) {
        case .refused(let reason):
            if reason == .insideItself {
                NSSound.beep()
                say(OutlineRefusal.insideItselfMessage)
            }
            return false
        case .applied(let new, let caret):
            if new != tree {
                record(caretBefore ?? currentCaret(), typing: typing)
                use(new)
                saver.changed(new)
            }
            if let caret { moveCaret(to: caret.path, .offset(caret.offset)) }
            return true
        }
    }

    /// A text view's text changed: the user typed. `selectionBefore` is where its selection started before the change (its delegate saw it first).
    func textChanged(_ path: OutlinePath, _ text: String, selectionBefore: Int?) {
        let length = (tree.text(at: path) ?? "").utf16.count
        let before = selectionBefore.map { OutlineCaret(path: path, offset: min($0, length)) }
        apply(.setText(path, text), caretBefore: before, typing: true)
    }

    /// The text view with the caret gave up focus: what is typed next is a new step.
    func caretLeft() { typingRun = nil }

    func paste(_ view: OutlineTextView, lines: [String]) {
        let selection = view.selectedRange()
        apply(.paste(view.rowPath, range: selection.location..<NSMaxRange(selection), lines: lines))
    }

    /// The disclosure triangle. The caret stays where it was.
    func toggleCollapse(_ path: OutlinePath) {
        guard let row = rows.first(where: { $0.path == path }) else { return }
        apply(.collapse(path, !row.collapsed))
        restoreCaret()
    }

    // MARK: Header message

    /// A short message in the header, such as "A bullet can't go inside itself".
    private func say(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Undo

    private struct Step {
        let tree: OutlineTree
        let caret: OutlineCaret?
    }

    private static let undoLimit = 200
    /// Typing in one bullet is one step until this long a pause, or until the caret leaves the bullet.
    private static let typingPause: TimeInterval = 1

    private func currentCaret() -> OutlineCaret? {
        if let view = activeView, view.window?.firstResponder === view {
            return OutlineCaret(path: view.rowPath, offset: view.selectedRange().location)
        }
        return remembered.map { OutlineCaret(path: $0.path, offset: $0.location) }
    }

    /// Puts the tree as it is, with the caret, on the undo stack before an edit changes it. A new edit ends the redo line.
    private func record(_ caret: OutlineCaret?, typing: Bool) {
        redoStack = []
        if typing, let run = typingRun, run.path == caret?.path, Date().timeIntervalSince(run.last) < Self.typingPause {
            typingRun = (run.path, Date())
            return
        }
        typingRun = typing ? caret.map { ($0.path, Date()) } : nil
        undoStack.append(Step(tree: tree, caret: caret))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    /// ⌘Z and ⌘⇧Z. The text views keep no undo of their own, so typing and structure undo in one order.
    private func undoOrRedo(redo: Bool) {
        guard load == .ready else { return }
        guard let step = redo ? redoStack.popLast() : undoStack.popLast() else { return }
        let here = Step(tree: tree, caret: currentCaret())
        if redo { undoStack.append(here) } else { redoStack.append(here) }
        typingRun = nil
        use(step.tree)
        saver.changed(step.tree)
        if let caret = step.caret, rows.contains(where: { $0.path == caret.path }) {
            moveCaret(to: caret.path, .offset(caret.offset))
        } else {
            if let caret = step.caret { remembered = (caret.path, caret.offset) }
            restoreCaret()
        }
    }

    func text(at path: OutlinePath) -> String? { tree.text(at: path) }

    // MARK: Text views

    func register(_ view: OutlineTextView) { views[view.rowPath.id] = WeakView(value: view) }

    func unregister(_ view: OutlineTextView) {
        if views[view.rowPath.id]?.value === view { views[view.rowPath.id] = nil }
    }

    func caretEntered(_ view: OutlineTextView) {
        if typingRun?.path != view.rowPath { typingRun = nil }
        activeView = view
        selectionChanged(view)
    }

    func selectionChanged(_ view: OutlineTextView) {
        guard view === activeView else { return }
        remembered = (view.rowPath, view.selectedRange().location)
    }

    // MARK: Caret

    /// The caret goes back to where it was. A row that is hidden now (a collapsed parent) gives it to the nearest row still showing on its path,
    /// at the end of its text; a path that is gone gives it to the first bullet.
    func restoreCaret() {
        guard load == .ready else { return }
        if let remembered, rows.contains(where: { $0.path == remembered.path }) {
            moveCaret(to: remembered.path, .offset(remembered.location))
        } else if let remembered, let near = nearestVisible(remembered.path) {
            moveCaret(to: near, .offset(Int.max))
        } else if let first = rows.first {
            moveCaret(to: first.path, .offset(Int.max))
        }
    }

    private func nearestVisible(_ path: OutlinePath) -> OutlinePath? {
        var near = path.parent
        while !near.placements.isEmpty {
            if rows.contains(where: { $0.path == near }) { return near }
            near = near.parent
        }
        return nil
    }

    /// A click below the last bullet.
    func focusLast() {
        if let last = rows.last { moveCaret(to: last.path, .offset(Int.max)) }
    }

    /// Scrolls to the row, then moves the caret into its text view a tick later: no view update moves the first responder, and a row
    /// off screen has no text view until it is scrolled to.
    private func moveCaret(to path: OutlinePath, _ place: OutlineCaretPlace) {
        pending = (path, place)
        scroll(to: path)
        attemptPlace(tries: 0)
    }

    private func scroll(to path: OutlinePath) {
        scrollSerial += 1
        scrollRequest = ScrollRequest(row: path.id, serial: scrollSerial)
    }

    private func attemptPlace(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0 : 0.02)) { [weak self] in
            MainActor.assumeIsolated { self?.tryPlace(tries: tries) }
        }
    }

    private func tryPlace(tries: Int) {
        guard let request = pending else { return }
        if let view = views[request.path.id]?.value, let window = view.window {
            view.syncFromModel()
            window.makeFirstResponder(view)
            view.place(request.place)
            landed()
        } else if tries < 10 {
            // The row may not have been built when the first scroll was asked for (a new row below a full panel).
            scroll(to: request.path)
            attemptPlace(tries: tries + 1)
        } else {
            // Gave up: the old view must not keep text the tree no longer has there, or the next key would write it back.
            activeView?.syncFromModel()
            landed()
        }
    }

    private func landed() {
        pending = nil
        let queued = queuedEvents
        queuedEvents = []
        for event in queued.reversed() { NSApp.postEvent(event, atStart: true) }
    }

    // MARK: Keys

    /// The keys the outline takes, as `SessionBoard.key` does: the switch below lists them. The End session, Mark session done and Restart
    /// session keys are taken and do nothing. The rest goes on; while an input method is composing, so does all but those three.
    func key(_ event: NSEvent) -> Bool {
        if let action = Settings.shared.action(for: event), action == .endPane || action == .doneSession || action == .restartSession {
            return true
        }
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        // The caret is on its way to another bullet: what is typed meanwhile waits for it, ⌘V and ⌥ keys included. A shortcut other than
        // Paste (⌘⇧Y, ⌘,) still acts.
        if pending != nil {
            let shortcut = Settings.shared.action(for: event)
            if shortcut == nil || shortcut == .paste {
                queuedEvents.append(event)
                return true
            }
        }
        let composing = activeView?.hasMarkedText() == true
        let code = Int(event.keyCode)
        if code == kVK_Escape, flags.isEmpty {
            if composing { return false }
            model?.closeOutline()
            return true
        }
        // ⌘Z and ⌘⇧Z are taken even when there is nothing to undo, so the Edit menu's never acts on a text view with no undo of its own.
        let command: NSEvent.ModifierFlags = .command, commandShift: NSEvent.ModifierFlags = [.command, .shift]
        if code == kVK_ANSI_Z, flags == command || flags == commandShift {
            if composing { return false }
            undoOrRedo(redo: flags == commandShift)
            return true
        }
        guard load == .ready, !composing, let view = activeView, view.window?.firstResponder === view else { return false }
        let selection = view.selectedRange()
        let path = view.rowPath
        let here = OutlineCaret(path: path, offset: selection.location)
        let atStart = selection.location == 0 && selection.length == 0
        switch (code, flags) {
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            apply(.split(path, range: selection.location..<NSMaxRange(selection)))
        case (kVK_Delete, []) where atStart:
            apply(.join(path))
        case (kVK_Delete, commandShift):
            apply(.delete(path))
        case (kVK_Tab, []):
            apply(.indent(here))
        case (kVK_Tab, .shift):
            apply(.outdent(here))
        case (kVK_UpArrow, []) where view.caretOnFirstLine:
            return cross(from: view, by: -1)
        case (kVK_DownArrow, []) where view.caretOnLastLine:
            return cross(from: view, by: 1)
        case (kVK_UpArrow, commandShift):
            apply(.move(here, by: -1))
        case (kVK_DownArrow, commandShift):
            apply(.move(here, by: 1))
        case (kVK_UpArrow, command):
            apply(.collapse(path, true))
        case (kVK_DownArrow, command):
            apply(.collapse(path, false))
        default:
            return false
        }
        return true
    }

    /// ↑ or ↓ out of the first or last line of a bullet, into the row above or below.
    private func cross(from view: OutlineTextView, by step: Int) -> Bool {
        guard let at = rows.firstIndex(where: { $0.path == view.rowPath }), rows.indices.contains(at + step) else { return false }
        moveCaret(to: rows[at + step].path, .x(view.caretX(), bottom: step < 0))
        return true
    }
}

/// Writes the tree half a second after the last change, when asked, and at Quit, off the main actor and one write at a time; a newer copy
/// replaces one that hasn't started. It hears of changes only while the file is readable, so it never writes over one that isn't.
@MainActor
final class OutlineSaver {
    /// The queue runs one write at a time, in order, so a Quit that waits on it never lets an older copy land over a newer one.
    private final class Writer: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.zabaca.varnick.outline-write", qos: .utility)
        /// Touched on `queue` only.
        private var keptPrevious = false

        /// Returns why it failed, never any text.
        func write(_ tree: OutlineTree, to url: URL) -> String? {
            if !keptPrevious {
                do {
                    try OutlineFile.keepPrevious(of: url)
                    keptPrevious = true
                } catch {
                    NSLog("Varnick: outline.previous.json couldn't be written: \(error)")
                }
            }
            do {
                try OutlineFile.write(tree, to: url)
                return nil
            } catch {
                return "\(error)"
            }
        }
    }

    private let writer = Writer()
    private let url: () -> URL
    private var pending: OutlineTree?
    private var writing = false
    private var timer: Task<Void, Never>?

    init(url: @escaping () -> URL) { self.url = url }

    func changed(_ tree: OutlineTree) {
        pending = tree
        arm(after: .milliseconds(500))
    }

    private func arm(after delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.flush()
        }
    }

    /// Writes the newest copy now, unless a write is under way: that one's end writes it.
    func flush() {
        timer?.cancel()
        timer = nil
        guard !writing, let tree = pending else { return }
        pending = nil
        writing = true
        let target = url(), writer = writer
        writer.queue.async { [weak self] in
            let failure = writer.write(tree, to: target)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(tree, failure: failure) } }
        }
    }

    private func finished(_ tree: OutlineTree, failure: String?) {
        writing = false
        if let failure {
            NSLog("Varnick: outline.json couldn't be saved: \(failure)")
            pending = pending ?? tree
            // Tried again, but slowly: a disk that stays full shouldn't fill the log.
            arm(after: .seconds(5))
        } else if pending != nil, timer == nil {
            flush()
        }
    }

    func saveForQuit() {
        timer?.cancel()
        timer = nil
        let tree = pending, target = url(), writer = writer
        pending = nil
        writer.queue.sync { if let tree { _ = writer.write(tree, to: target) } }
    }
}
