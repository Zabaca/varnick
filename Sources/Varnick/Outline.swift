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
    /// The bullets zoomed through, the last being the title; none at Home.
    @Published private(set) var crumbs: [OutlineCrumb] = []
    /// Whether completed bullets show (⌘⇧C); saved with the file.
    @Published private(set) var showsCompleted = false
    /// The row whose note has the caret, or was just opened with ⇧↩: its note shows in full, and shows at all while it is empty.
    @Published private(set) var notePath: OutlinePath?
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
    private var remembered: OutlineCaret?
    private var pending: (path: OutlinePath, field: OutlineField, place: OutlineCaretPlace)?
    /// Keys that arrive while the caret is on its way to another bullet; they are sent again once it has landed.
    private var queuedEvents: [NSEvent] = []
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var typingRun: (path: OutlinePath, field: OutlineField, last: Date)?
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
                NSLog("Varnick: outline.json repaired: \(repairs.missingBullets) missing, \(repairs.insideItself) inside itself, \(repairs.recovered) recovered, \(repairs.duplicatePlacements) repeated ids, \(repairs.unreachable) unreachable, zoom reset: \(repairs.zoomLost)")
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
        let shown = new.crumbs()
        if shown != crumbs { crumbs = shown }
        if new.showsCompleted != showsCompleted { showsCompleted = new.showsCompleted }
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
            if let caret { moveCaret(to: caret.path, field: caret.field, .offset(caret.offset)) }
            return true
        }
    }

    /// A text view's text changed: the user typed. `selectionBefore` is where its selection started before the change (its delegate saw it first).
    func textChanged(_ view: OutlineTextView, selectionBefore: Int?) {
        let field = view.field
        let length = (content(of: view) ?? "").utf16.count
        let before = selectionBefore.map { OutlineCaret(path: view.rowPath, offset: min($0, length), field: field) }
        apply(field == .note ? .setNote(view.rowPath, view.string) : .setText(view.rowPath, view.string), caretBefore: before, typing: true)
    }

    /// The text view with the caret gave up focus: what is typed next is a new step, and a note that no longer has the caret is cut short again
    /// (or gone, if it is empty). A view being removed resigns during a SwiftUI update, so that waits a turn.
    func caretLeft(_ view: OutlineTextView) {
        typingRun = nil
        if activeView === view { activeView = nil }
        guard view.field == .note else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                // Unless the caret has gone into that note again, it is cut short again.
                guard let self, self.notePath == view.rowPath, self.activeView?.field != .note || self.activeView?.rowPath != view.rowPath else { return }
                self.notePath = nil
            }
        }
    }

    func paste(_ view: OutlineTextView, lines: [String]) {
        let selection = view.selectedRange()
        apply(.paste(view.rowPath, range: selection.location..<NSMaxRange(selection), lines: lines))
    }

    /// ⇧↩ in a bullet: its note opens, empty if it has none, with the caret in it.
    private func openNote(_ path: OutlinePath) {
        notePath = path
        moveCaret(to: path, field: .note, .offset(Int.max))
    }

    /// ⇧↩ or esc in a note: back to the bullet's text.
    private func leaveNote(_ view: OutlineTextView, place: OutlineCaretPlace = .offset(Int.max)) {
        moveCaret(to: view.rowPath, field: .text, place)
    }

    /// ⌘⇧C and the header's button. A view setting, so it isn't undone; it is saved with the file.
    func toggleShowsCompleted() {
        guard load == .ready else { return }
        var new = tree
        new.showsCompleted.toggle()
        new = new.ensuringBullet(now: Date())
        let before = rows
        setView(new)
        if let remembered, let moved = new.caretAfterHiding(remembered.path, from: before) {
            moveCaret(to: moved.path, .offset(moved.offset))
        } else {
            restoreCaret()
        }
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
            return OutlineCaret(path: view.rowPath, offset: view.selectedRange().location, field: view.field)
        }
        return remembered
    }

    /// Puts the tree as it is, with the caret, on the undo stack before an edit changes it. A new edit ends the redo line.
    private func record(_ caret: OutlineCaret?, typing: Bool) {
        redoStack = []
        if typing, let run = typingRun, run.path == caret?.path, run.field == caret?.field, Date().timeIntervalSince(run.last) < Self.typingPause {
            typingRun = (run.path, run.field, Date())
            return
        }
        typingRun = typing ? caret.map { ($0.path, $0.field, Date()) } : nil
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
        // Moving about isn't an edit: the zoom stays, unless the caret's row is outside it.
        var restored = step.tree.keepingView(of: tree)
        if let caret = step.caret { restored = restored.zoomShowing(caret.path) }
        // There is always a line to type in: Show completed turned off since may have hidden what the step brings back.
        restored = restored.ensuringBullet(now: Date())
        let before = rows
        use(restored)
        saver.changed(restored)
        if let caret = step.caret, showing(caret.path) {
            moveCaret(to: caret.path, field: usable(caret, in: restored), .offset(caret.offset))
        } else if let caret = step.caret, let moved = restored.caretAfterHiding(caret.path, from: before) {
            moveCaret(to: moved.path, .offset(moved.offset))
        } else {
            restoreCaret()
        }
    }

    /// The field a caret can go back to: a note that is gone or empty (emptied, undone) can't hold it.
    private func usable(_ caret: OutlineCaret, in tree: OutlineTree) -> OutlineField {
        caret.field == .note && !(tree.note(at: caret.path) ?? "").isEmpty ? .note : .text
    }

    /// What a text view shows, from the tree: the bullet's text or its note.
    func content(of view: OutlineTextView) -> String? {
        view.field == .note ? (tree.note(at: view.rowPath) ?? "") : tree.text(at: view.rowPath)
    }

    // MARK: Text views

    func register(_ view: OutlineTextView) { views[view.registryKey] = WeakView(value: view) }

    func unregister(_ view: OutlineTextView) {
        if views[view.registryKey]?.value === view { views[view.registryKey] = nil }
    }

    func caretEntered(_ view: OutlineTextView) {
        if typingRun?.path != view.rowPath || typingRun?.field != view.field { typingRun = nil }
        activeView = view
        let note = view.field == .note ? view.rowPath : nil
        if notePath != note { notePath = note }
        selectionChanged(view)
    }

    func selectionChanged(_ view: OutlineTextView) {
        guard view === activeView else { return }
        remembered = OutlineCaret(path: view.rowPath, offset: view.selectedRange().location, field: view.field)
    }

    // MARK: Caret

    /// The caret goes back to where it was. A row that is hidden now (a collapsed parent) gives it to the nearest row still showing on its path,
    /// at the end of its text; a path that is gone gives it to the first bullet.
    func restoreCaret() {
        guard load == .ready else { return }
        if let remembered, showing(remembered.path) {
            moveCaret(to: remembered.path, field: usable(remembered, in: tree), .offset(remembered.offset))
        } else if let remembered, let near = nearestVisible(remembered.path) {
            moveCaret(to: near, .offset(Int.max))
        } else if let first = rows.first?.path ?? crumbs.last?.path {
            moveCaret(to: first, .offset(Int.max))
        }
    }

    private func nearestVisible(_ path: OutlinePath) -> OutlinePath? {
        var near = path.parent
        while !near.placements.isEmpty {
            if showing(near) { return near }
            near = near.parent
        }
        return nil
    }

    /// Whether a row is on screen: under the zoom, or the title.
    private func showing(_ path: OutlinePath) -> Bool {
        tree.isTitle(path) || rows.contains { $0.path == path }
    }

    // MARK: Zoom

    /// The bullet zoomed into, as a row path: no placements at Home. Its text is the title.
    var zoomPath: OutlinePath { OutlinePath(placements: tree.effectiveZoom) }

    /// ⌘] or a click on a dot: the bullet becomes the top of the view, with the caret in its first nested bullet or, with none, its title.
    func zoomIn(_ path: OutlinePath) {
        guard load == .ready, path != zoomPath, let zoomed = tree.zoomed(into: path) else { return }
        setView(zoomed)
        moveCaret(to: rows.first?.path ?? path, .offset(Int.max))
    }

    /// ⌘[ and the breadcrumbs: back up to `depth` bullets zoomed through (0 is Home), with the caret on the bullet the zoom came from.
    func zoomOut(to depth: Int) {
        let before = zoomPath
        guard load == .ready, depth >= 0, depth < before.placements.count,
              let zoomed = tree.zoomed(into: OutlinePath(placements: Array(before.placements.prefix(depth)))) else { return }
        setView(zoomed)
        moveCaret(to: OutlinePath(placements: Array(before.placements.prefix(depth + 1))), .offset(Int.max))
    }

    /// Where the zoom is, and Show completed, aren't edits, so they aren't undone; they are saved with the file.
    private func setView(_ changed: OutlineTree) {
        typingRun = nil
        use(changed)
        saver.changed(changed)
    }

    /// The last breadcrumb: the caret goes into the title.
    func focusTitle() {
        if let title = crumbs.last { moveCaret(to: title.path, .offset(Int.max)) }
    }

    /// A click below the last bullet.
    func focusLast() {
        if let last = rows.last?.path ?? crumbs.last?.path { moveCaret(to: last, .offset(Int.max)) }
    }

    /// Scrolls to the row, then moves the caret into its text view a tick later: no view update moves the first responder, and a row
    /// off screen has no text view until it is scrolled to.
    private func moveCaret(to path: OutlinePath, field: OutlineField = .text, _ place: OutlineCaretPlace) {
        pending = (path, field, place)
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
        // The title and the row it was zoomed from share a path, so a view counts only if it is the one the path now means.
        let kind: OutlineTextView.Kind = request.field == .note ? .note : tree.isTitle(request.path) ? .title : .row
        let key = OutlineTextView.registryKey(request.path, kind: kind)
        if let view = views[key]?.value, let window = view.window {
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
            // One level back: out of a note first, else the outline closes.
            if let view = activeView, view.field == .note, view.window?.firstResponder === view { leaveNote(view) } else { model?.closeOutline() }
            return true
        }
        // ⌘Z and ⌘⇧Z are taken even when there is nothing to undo, so the Edit menu's never acts on a text view with no undo of its own.
        let command: NSEvent.ModifierFlags = .command, commandShift: NSEvent.ModifierFlags = [.command, .shift]
        if code == kVK_ANSI_Z, flags == command || flags == commandShift {
            if composing { return false }
            undoOrRedo(redo: flags == commandShift)
            return true
        }
        // ⌘[ and ⌘⇧C need no bullet to have the caret.
        if code == kVK_ANSI_LeftBracket, flags == command, load == .ready, !composing {
            zoomOut(to: tree.effectiveZoom.count - 1)
            return true
        }
        if code == kVK_ANSI_C, flags == commandShift, load == .ready, !composing {
            toggleShowsCompleted()
            return true
        }
        guard load == .ready, !composing, let view = activeView, view.window?.firstResponder === view else { return false }
        let selection = view.selectedRange()
        let path = view.rowPath
        let here = OutlineCaret(path: path, offset: selection.location, field: view.field)
        let atStart = selection.location == 0 && selection.length == 0
        // In a note ↩ is a new line, which the text view does itself; the keys that mean the bullet still work.
        if view.field == .note {
            switch (code, flags) {
            case (kVK_Return, .shift), (kVK_ANSI_KeypadEnter, .shift):
                leaveNote(view)
            case (kVK_Return, command), (kVK_ANSI_KeypadEnter, command):
                apply(.complete(here))
            case (kVK_UpArrow, []) where view.caretOnFirstLine:
                leaveNote(view, place: .x(view.caretX(), bottom: true))
            case (kVK_DownArrow, []) where view.caretOnLastLine:
                return cross(from: view, by: 1)
            case (kVK_ANSI_RightBracket, command):
                zoomIn(path)
            default:
                return false
            }
            return true
        }
        // The title of a zoom is the zoomed bullet itself: ↩ adds its first nested bullet, and nothing here moves, joins or deletes it.
        if tree.isTitle(path) {
            switch (code, flags) {
            case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
                apply(.addFirstChild(path, range: selection.location..<NSMaxRange(selection)))
            case (kVK_Delete, []) where atStart, (kVK_Delete, commandShift), (kVK_Tab, []), (kVK_Tab, .shift),
                 (kVK_Return, command), (kVK_ANSI_KeypadEnter, command),
                 (kVK_UpArrow, command), (kVK_DownArrow, command), (kVK_UpArrow, commandShift), (kVK_DownArrow, commandShift),
                 (kVK_ANSI_RightBracket, command):
                break
            case (kVK_Return, .shift), (kVK_ANSI_KeypadEnter, .shift):
                openNote(path)
            case (kVK_DownArrow, []) where view.caretOnLastLine:
                return cross(from: view, by: 1)
            default:
                return false
            }
            return true
        }
        switch (code, flags) {
        case (kVK_ANSI_RightBracket, command):
            zoomIn(path)
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            apply(.split(path, range: selection.location..<NSMaxRange(selection)))
        case (kVK_Return, .shift), (kVK_ANSI_KeypadEnter, .shift):
            openNote(path)
        case (kVK_Return, command), (kVK_ANSI_KeypadEnter, command):
            apply(.complete(here))
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
        func hasNote(_ path: OutlinePath) -> Bool { !(tree.note(at: path) ?? "").isEmpty }
        // Down from a bullet with a note goes into the note first.
        if step > 0, view.field == .text, hasNote(view.rowPath) {
            moveCaret(to: view.rowPath, field: .note, .x(view.caretX(), bottom: false))
            return true
        }
        // The title, when zoomed, comes before the rows.
        let order = (crumbs.last.map { [$0.path] } ?? []) + rows.map(\.path)
        guard let at = order.firstIndex(of: view.rowPath), order.indices.contains(at + step) else { return false }
        let target = order[at + step]
        // Up into a bullet with a note lands in the note's last line.
        moveCaret(to: target, field: step < 0 && hasNote(target) ? .note : .text, .x(view.caretX(), bottom: step < 0))
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
