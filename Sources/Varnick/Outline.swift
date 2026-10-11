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

        /// Why a session can't read the outline now (nil when it can), in words that never hold a bullet's text.
        var problem: String? {
            switch self {
            case .ready: nil
            case .notLoaded, .loading: "outline.json is still loading"
            case .unreadable(let reason): "outline.json couldn't be read (\(reason))"
            case .newer(let version): "outline.json is from a newer Varnick (file version \(version))"
            }
        }
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
    /// What is typed in the header's filter. It belongs to this launch: nothing about it is saved.
    @Published private(set) var filterText = ""
    /// Bumped by ⌘F to move the caret into the filter field.
    @Published private(set) var filterFocusRequest = 0
    /// The words the filter looks for (`OutlineTree.filterWords`).
    private(set) var filterWords: [String] = []
    /// The bullets the caret has been in, kept in view under a filter even when they stop matching, until the filter changes: rows never
    /// vanish under the caret, or from under a click.
    private var filterKept: Set<OutlinePath> = []
    private let foldCache = OutlineFoldCache()
    /// The bullets ⌥⌘C copied, in order, to be placed again by ⌥⌘V: held here for the launch, never on the system clipboard.
    private var mirrorToPlace: [String] = []
    /// The bullets selected whole (⇧↑ and ⇧↓ at the edge of a bullet), as sibling paths. Never saved. While it is set no text view has the
    /// keyboard, and `key` takes every key but Varnick's shortcuts.
    @Published private(set) var selection: OutlineSelection?
    /// The caret the selection started from, which esc puts back while that bullet is still the fixed end.
    private var selectionOrigin: OutlineCaret?
    /// The other places of the mirrors on screen, worked out once per tree: the dot's tooltip asks on every redraw.
    private var placesCache: [OutlinePath: OutlinePlaces] = [:]

    /// What the rows depend on besides the tree.
    private var scope: OutlineScope { OutlineScope(filter: filterWords, keeping: filterKept, cache: foldCache) }
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
    private struct CaretTarget {
        let path: OutlinePath
        let field: OutlineField
        let place: OutlineCaretPlace
    }
    private var pending: CaretTarget?
    /// Keys that arrive while the caret is on its way to another bullet; they are sent again once it has landed.
    private var queuedEvents: [NSEvent] = []
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var typingRun: (path: OutlinePath, field: OutlineField, last: Date)?
    private var noticeTask: Task<Void, Never>?

    var fileURL: URL { OutlineFile.url(in: SupportFolder.url) }

    // MARK: Showing

    /// The outline shows. The file is read the first time in a launch, off the main actor. With `focusing` false (a session's `show` while the
    /// panel doesn't have the keyboard) the caret is neither moved nor placed, now or when the file arrives.
    func appear(focusing: Bool = true) {
        if focusing { focusesOnLoad = true }
        guard load == .notLoaded else {
            if focusing { restoreCaret() }
            return
        }
        startLoading()
    }

    /// Whether the file's arrival puts the caret in a bullet: not when a session loaded it or showed the outline while the panel lacked the keyboard.
    private var focusesOnLoad = false
    private var loadTask: Task<Void, Never>?

    private func startLoading() {
        load = .loading
        let url = fileURL
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { OutlineFile.read(at: url) }.value
            self?.loaded(result)
        }
    }

    /// A session's read (Panel access) needs the file read, as showing the outline would: the first call in a launch reads it, off the main
    /// actor, without showing the outline or moving the caret; a call that arrives while it is being read waits for it. Reading never writes.
    func loadForSession() async {
        if load == .notLoaded { startLoading() }
        await loadTask?.value
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
        if model?.showingOutline == true, focusesOnLoad { restoreCaret() }
    }

    private func use(_ new: OutlineTree) {
        tree = new
        foldCache.prune(toBulletsIn: new.bullets)
        placesCache = [:]
        refreshRows()
        let shown = new.crumbs()
        if shown != crumbs { crumbs = shown }
        if new.showsCompleted != showsCompleted { showsCompleted = new.showsCompleted }
    }

    /// The rows for the tree, the filter and the bullet the caret is in; published only when they differ.
    private func refreshRows() {
        let shown = tree.visibleRows(scope)
        if shown != rows { rows = shown }
        // A selected bullet that stops showing ends the selection, and the caret comes back where esc would have put it.
        if let selection, !selection.run.allSatisfy({ path in shown.contains { $0.path == path } }) {
            endSelection()
            restoreCaret()
        }
    }

    /// The outline closes: a change not yet written is written at once.
    func close() {
        endSelection()
        saver.flush()
        pending = nil
        queuedEvents = []
        typingRun = nil
        focusesOnLoad = false
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
    private func apply(_ edit: OutlineEdit, caretBefore: OutlineCaret? = nil, typing: Bool = false) -> OutlineRefusal? {
        applyEdit(edit, caretBefore: caretBefore, typing: typing).refusal
    }

    /// What an edit did: its refusal, or the caret and the new rows it returned (which the keys follow; a session's edit may not).
    private struct Applied {
        var refusal: OutlineRefusal?
        var caret: OutlineCaret?
        var run: [OutlinePath] = []
    }

    /// `apply`, with the edit's own caret handed back. With `forSession` (Panel access) the edit is the same, on the same undo stack, but it
    /// doesn't follow the edit's caret, scroll, beep, say anything in the header, keep its rows in view under a filter, or end the user's
    /// selection itself: `performForSession` decides where the user's caret goes. `scope` is what the edit works with, the user's own when
    /// left out.
    private func applyEdit(_ edit: OutlineEdit, caretBefore: OutlineCaret? = nil, typing: Bool = false, forSession: Bool = false,
                           scope: OutlineScope? = nil) -> Applied {
        guard load == .ready else { return Applied(refusal: "not ready") }
        switch tree.applying(edit, now: Date(), scope: scope ?? self.scope) {
        case .refused(let reason):
            if !forSession, let message = reason.message {
                NSSound.beep()
                say(message)
            }
            return Applied(refusal: reason)
        case .applied(let new, let caret, let run):
            // A new bullet doesn't match the filter, and the caret is on its way into it.
            if !forSession, let caret { keep(caret.path) }
            let held = selection
            if new != tree {
                record(caretBefore ?? currentCaret(), typing: typing)
                if !forSession, !filterWords.isEmpty { filterKept.formUnion(run) }
                // The selection follows the run to its new rows before they show, or ends when the caret is to go somewhere.
                if !forSession, let held {
                    if let caret {
                        remembered = caret
                        dropSelection()
                    } else if edit.keepsSelection, let followed = held.following(run) {
                        selection = followed
                        selectionOrigin = selectionOrigin.map { $0.path == held.fixed ? OutlineCaret(path: followed.fixed, offset: $0.offset) : $0 }
                    } else {
                        endSelection()
                    }
                }
                use(new)
                saver.changed(new)
                // Nothing to put the caret in: an insert whose bullets are all hidden may have taken the place of the bullet that had it.
                var inserted = false
                if case .insert = edit { inserted = true }
                if !forSession, held != nil || inserted, selection == nil, caret == nil { restoreCaret() }
                if !forSession, let moving = selection?.moving { scroll(to: moving) }
            }
            if !forSession, let caret { moveCaret(to: caret.path, field: caret.field, .offset(caret.offset)) }
            return Applied(refusal: nil, caret: caret, run: run)
        }
    }

    /// A text view's text changed: the user typed. `selectionBefore` is where its selection started before the change (its delegate saw it first).
    func textChanged(_ view: OutlineTextView, selectionBefore: Int?) {
        let field = view.field
        let length = (content(of: view) ?? "").utf16.count
        let before = selectionBefore.map { OutlineCaret(path: view.rowPath, offset: min($0, length), field: field) }
        apply(field == .note ? .setNote(view.rowPath, view.string) : .setText(view.rowPath, view.string), caretBefore: before, typing: true)
    }

    // MARK: A session's edits (Panel access)

    /// What a session's edit did. `refusal` is a sentence for the session; with none, `changed` says whether the tree differs, and `run` and
    /// `caret` are the tree edit's own (the new rows of an insert, the placement of a mirror).
    struct SessionOutcome {
        var refusal: String?
        var changed = false
        var run: [OutlinePath] = []
        var caret: OutlineCaret?
    }

    /// The text view the user is typing in: the one with the caret, while no bullets are selected.
    private var caretView: OutlineTextView? {
        guard selection == nil, let view = activeView, view.window?.firstResponder === view else { return nil }
        return view
    }

    /// Waits main-queue turns until `done`, for at most `timeout`; false if it never was.
    private func wait(_ timeout: Duration, until done: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while !done() {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// One edit for a session, on the same undo stack as the keys' (one step, which ends the user's typing run and keeps the user's caret, so
    /// ⌘Z puts everything back together). It never sets the text of the view with the caret, so a text or note edit to the field the caret is in
    /// is refused here ("not yet": ticket 07 goes through the view). The user's caret moves only as the keys would move it
    /// (`OutlineActing.caretMove`); an edit that doesn't touch its row leaves it, and the view's text, alone. `allowed` is asked again after the
    /// waits, so a switch turned off meanwhile applies nothing.
    func performForSession(_ edit: OutlineEdit, allowed: () -> Bool) async -> SessionOutcome {
        guard load == .ready else { return SessionOutcome(refusal: load.problem ?? "the outline isn't ready") }
        // The caret on its way to a row lands first, and an input method composing in the caret's bullet finishes (its marked text isn't in the
        // tree yet, and a move would take the view away).
        guard await wait(.seconds(1), until: { pending == nil }) else {
            return SessionOutcome(refusal: "The user's caret is still moving to another bullet: try again")
        }
        guard await wait(.seconds(3), until: { caretView?.hasMarkedText() != true }) else {
            return SessionOutcome(refusal: "The user is composing text in a bullet: try again")
        }
        guard allowed(), load == .ready else { return SessionOutcome(refusal: "Panel access was turned off, or the outline closed, while this waited") }
        if let view = caretView, let target = Self.textTarget(of: edit),
           view.field == target.field, tree.bulletID(at: target.path) != nil, tree.bulletID(at: target.path) == tree.bulletID(at: view.rowPath) {
            return SessionOutcome(refusal: "Not yet: the user's caret is in that bullet's \(target.field == .note ? "note" : "text"), and a session can't change it there")
        }
        let user = selection == nil ? currentCaret() : nil
        let live = caretView != nil
        let before = tree
        let done = applyEdit(edit, typing: false, forSession: true, scope: OutlineActing.ignoresFilter(edit) ? OutlineScope() : nil)
        if let refusal = done.refusal { return SessionOutcome(refusal: refusal.reason) }
        guard tree != before else { return SessionOutcome() }
        if let user {
            let showingNow: (OutlinePath) -> Bool = { self.showing($0) }
            switch OutlineActing.caretMove(of: user, edit: edit, moved: done.run, editCaret: done.caret, showing: showingNow) {
            case .stay:
                break
            case .to(let target):
                place(target, live: live)
            case .nearest:
                if let near = nearestVisible(user.path) ?? rows.first?.path ?? crumbs.last?.path {
                    place(OutlineCaret(path: near, offset: (tree.text(at: near) ?? "").utf16.count), live: live)
                }
            }
        }
        return SessionOutcome(changed: true, run: done.run, caret: done.caret)
    }

    /// The row and field a text or note edit changes.
    private static func textTarget(of edit: OutlineEdit) -> (path: OutlinePath, field: OutlineField)? {
        switch edit {
        case .setText(let path, _): (path, .text)
        case .setNote(let path, _): (path, .note)
        default: nil
        }
    }

    /// The model's caret goes to `target`; the text view's too, but only if a bullet had the caret, as the keys do it.
    private func place(_ target: OutlineCaret, live: Bool) {
        remembered = target
        if live { moveCaret(to: target.path, field: usable(target, in: tree), .offset(target.offset)) }
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

    // MARK: Clipboard

    private static let ownType = NSPasteboard.PasteboardType(OutlineClipboard.pasteboardType)

    /// Copies the bullets at `paths` to the system clipboard, in the two forms together so that another app's copy replaces both: as indented
    /// text, and as Varnick's own copy. Says how many in the header. Never logs the text. A copy that `OutlineClipboard.copyLimit` cut short is
    /// made but said to be; with `wholeOnly` (a cut) it is refused instead, since the delete would remove bullets the clipboard never got.
    @discardableResult
    private func copy(_ paths: [OutlinePath], wholeOnly: Bool = false) -> Bool {
        let (drafts, cutShort) = OutlineClipboard.drafts(of: paths, in: tree)
        guard !drafts.isEmpty else { return false }
        if cutShort, wholeOnly {
            NSSound.beep()
            say("Too many bullets to cut: nothing was cut")
            return false
        }
        let board = NSPasteboard.general
        let own = OutlineClipboard.data(of: drafts)
        board.declareTypes(own == nil ? [.string] : [.string, Self.ownType], owner: nil)
        board.setString(OutlineClipboard.text(of: drafts), forType: .string)
        if let own { board.setData(own, forType: Self.ownType) }
        let count = paths.count == 1 ? "1 bullet" : "\(paths.count) bullets"
        say(cutShort ? "Copied \(count), cut short at \(OutlineClipboard.copyLimit) in all" : "Copied \(count)")
        return true
    }

    /// ⌘X on bullets selected: the copy, then the delete of the run, in one undo step (the delete's).
    private func cut(_ paths: [OutlinePath]) {
        guard copy(paths, wholeOnly: true) else { return }
        apply(.delete(OutlineRun(paths)))
    }

    /// What a paste makes, from the clipboard: Varnick's own copy first (a version this build doesn't know, or data that doesn't decode, goes by
    /// the text), then indented text. `minimumLines` is how many lines the text needs to count as bullets.
    private func pastedBullets(minimumLines: Int) -> [OutlineDraft]? {
        let board = NSPasteboard.general
        if let data = board.data(forType: Self.ownType), let drafts = OutlineClipboard.drafts(fromData: data), !drafts.isEmpty { return drafts }
        guard let text = board.string(forType: .string), OutlineClipboard.lineCount(of: text) >= minimumLines else { return nil }
        let drafts = OutlineClipboard.drafts(fromText: text)
        return drafts.isEmpty ? nil : drafts
    }

    /// ⌘V on bullets selected: whole bullets after the last one selected, even for one line of text.
    private func pasteAfterSelection(_ paths: [OutlinePath]) {
        guard let last = paths.last, let drafts = pastedBullets(minimumLines: 1) else { return NSSound.beep() }
        apply(.insert(drafts, at: .after(last)))
    }

    /// ⌘V in a bullet's text (`OutlineTextView.paste`): Varnick's own copy, or several lines, become whole bullets. Returns whether it did; if
    /// not, the text view puts one line in at the caret. The bullets take the place of an empty bullet, go first under a title, and otherwise
    /// go below the bullet, which keeps its text.
    func pasteBullets(into view: OutlineTextView) -> Bool {
        guard load == .ready, let drafts = pastedBullets(minimumLines: 2) else { return false }
        let path = view.rowPath
        let place: OutlineInsertion = tree.isTitle(path) ? .firstUnder(path) : tree.canReplace(path) ? .replacing(path) : .after(path)
        return apply(.insert(drafts, at: place)) == nil
    }

    /// ⌥⌘C: the bullet under the caret, or the bullets selected, are remembered, to be placed again as mirrors.
    private func copyAsMirror(_ paths: [OutlinePath]) {
        let bullets = paths.compactMap { tree.bulletID(at: $0) }
        guard !bullets.isEmpty else { return }
        mirrorToPlace = bullets
        say(bullets.count == 1 ? "Copied as a mirror" : "Copied \(bullets.count) bullets as mirrors")
    }

    /// ⌥⌘V: mirrors of the copied bullets, below the bullet that has the caret or after the last one selected. A bullet that is gone is left out;
    /// one that would end up inside itself refuses them all.
    private func placeMirror(after path: OutlinePath) {
        guard !mirrorToPlace.isEmpty else { return NSSound.beep() }
        // A refusal with a message has said so; one without (the bullets are gone, or this is nowhere to put them) still beeps.
        if let refusal = apply(.placeMirror(after: path, bullets: mirrorToPlace)), refusal.message == nil { NSSound.beep() }
    }

    /// Where a mirror is placed besides at `path`.
    func places(of path: OutlinePath) -> OutlinePlaces {
        if let known = placesCache[path] { return known }
        let places = tree.otherPlaces(of: path)
        placesCache[path] = places
        return places
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
        endSelection()
        var new = tree
        new.showsCompleted.toggle()
        new = new.ensuringBullet(now: Date())
        let before = rows
        setView(new)
        if let remembered, let moved = new.caretAfterHiding(remembered.path, from: before, scope: scope) {
            moveCaret(to: moved.path, .offset(moved.offset))
        } else {
            restoreCaret()
        }
    }

    // MARK: Filter

    /// Whether the filter field is where the caret is: the only text field in the outline, so a field editor is it.
    private var filterHasFocus: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true }

    /// ⌘F: the caret goes into the filter field.
    func focusFilter() { filterFocusRequest += 1 }

    /// The filter field has the keyboard: bullets selected are no longer.
    func filterTookFocus() { endSelection() }

    /// The filter's text changed: the rows follow as it is typed, and no bullet is kept in view for the caret any more.
    func setFilter(_ text: String) {
        filterText = text
        filterWords = OutlineTree.filterWords(text)
        filterKept = []
        refreshRows()
    }

    /// A click on a tag: the filter gains it, or loses it if it has it. The caret stays where it was, in a bullet that stays in view.
    func toggleTag(_ tag: String) {
        let selecting = selection != nil
        endSelection()
        var words = filterText.split(whereSeparator: \.isWhitespace).map(String.init)
        if let at = words.firstIndex(where: { OutlineTags.same($0, tag) }) { words.remove(at: at) } else { words.append(tag) }
        setFilter(words.joined(separator: " "))
        if let view = activeView { keep(view.rowPath) }
        // No text view has the caret while bullets are selected: it goes back where esc would put it, in view.
        if selecting, let remembered {
            keep(remembered.path)
            restoreCaret()
        }
    }

    /// Under a filter, the bullet the caret is in or goes to stays in view, matching or not.
    private func keep(_ path: OutlinePath) {
        guard !filterWords.isEmpty, filterKept.insert(path).inserted else { return }
        refreshRows()
    }

    /// ↓ or ↩ in the field: the caret goes to the first bullet that matches.
    private func goToFirstMatch() {
        if let first = rows.first(where: \.matched) { moveCaret(to: first.path, .offset(Int.max)) }
    }

    /// The disclosure triangle. The caret stays where it was.
    func toggleCollapse(_ path: OutlinePath) {
        guard filterWords.isEmpty, let row = rows.first(where: { $0.path == path }) else { return }
        endSelection()
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

    /// `selection` is what was selected when the step was taken (the paths in `tree`); `caret` is then where the selection started.
    private struct Step {
        let tree: OutlineTree
        let caret: OutlineCaret?
        var selection: OutlineSelection?
    }

    private static let undoLimit = 200
    /// Typing in one bullet is one step until this long a pause, or until the caret leaves the bullet.
    private static let typingPause: TimeInterval = 1

    private func currentCaret() -> OutlineCaret? {
        if selection != nil, let selectionOrigin { return selectionOrigin }
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
        undoStack.append(Step(tree: tree, caret: caret, selection: selection))
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
    }

    /// ⌘Z and ⌘⇧Z. The text views keep no undo of their own, so typing and structure undo in one order.
    private func undoOrRedo(redo: Bool) {
        guard load == .ready else { return }
        guard let step = redo ? redoStack.popLast() : undoStack.popLast() else { return }
        let here = Step(tree: tree, caret: currentCaret(), selection: selection)
        if redo { undoStack.append(here) } else { redoStack.append(here) }
        typingRun = nil
        endSelection()
        // Moving about isn't an edit: the zoom stays, unless the caret's row, or the selected rows, are outside it.
        var restored = step.tree.keepingView(of: tree)
        if let caret = step.caret { restored = restored.zoomShowing(caret.path) }
        if let first = step.selection?.run.first { restored = restored.zoomShowing(first) }
        // There is always a line to type in: Show completed turned off since may have hidden what the step brings back.
        restored = restored.ensuringBullet(now: Date())
        let before = rows
        if let caret = step.caret { keep(caret.path) }
        if !filterWords.isEmpty, let run = step.selection?.run { filterKept.formUnion(run) }
        use(restored)
        saver.changed(restored)
        // A step taken with bullets selected selects them again, when they all show.
        if let wanted = step.selection, wanted.run.allSatisfy(showing) {
            select(wanted, from: step.caret)
        } else if let caret = step.caret, showing(caret.path) {
            moveCaret(to: caret.path, field: usable(caret, in: restored), .offset(caret.offset))
        } else if let caret = step.caret, let moved = restored.caretAfterHiding(caret.path, from: before, scope: scope) {
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
        // A text view taking the caret (a click in text, or a caret sent to a row) ends the selection.
        dropSelection()
        activeView = view
        let note = view.field == .note ? view.rowPath : nil
        if notePath != note { notePath = note }
        keep(view.rowPath)
        selectionChanged(view)
    }

    func selectionChanged(_ view: OutlineTextView) {
        guard view === activeView else { return }
        remembered = OutlineCaret(path: view.rowPath, offset: view.selectedRange().location, field: view.field)
    }

    // MARK: Caret

    /// What a session's read shows (Panel access), from the model and never a text view. The caret is the model's own record, kept up to date as
    /// it moves; it is "in a bullet" only while the panel has the keyboard and one has it, else it is where it last was.
    func shownForSessions(panelHasKeyboard: Bool, onScreen: Bool) -> OutlineReading.Shown {
        OutlineReading.Shown(rows: rows, crumbs: crumbs, filterText: filterText, showsCompleted: showsCompleted,
                             caret: remembered.map { OutlineReading.Caret(caret: $0, inBullet: panelHasKeyboard && activeView != nil && selection == nil) },
                             selection: selection, onScreen: onScreen)
    }

    /// The caret goes back to where it was. A row that is hidden now (a collapsed parent) gives it to the nearest row still showing on its path,
    /// at the end of its text; a path that is gone gives it to the first bullet.
    func restoreCaret() {
        // Asked for while the file is still being read (the panel came up after a session showed the outline): the caret goes in when it arrives.
        if load == .loading { focusesOnLoad = true }
        guard load == .ready else { return }
        endSelection()
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
        endSelection()
        setView(zoomed)
        moveCaret(to: rows.first?.path ?? path, .offset(Int.max))
    }

    /// ⌘[ and the breadcrumbs: back up to `depth` bullets zoomed through (0 is Home), with the caret on the bullet the zoom came from.
    func zoomOut(to depth: Int) {
        let before = zoomPath
        guard load == .ready, depth >= 0, depth < before.placements.count,
              let zoomed = tree.zoomed(into: OutlinePath(placements: Array(before.placements.prefix(depth)))) else { return }
        endSelection()
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
        endSelection()
        if let last = rows.last?.path ?? crumbs.last?.path { moveCaret(to: last, .offset(Int.max)) }
    }

    /// Scrolls to the row, then moves the caret into its text view a tick later: no view update moves the first responder, and a row
    /// off screen has no text view until it is scrolled to.
    private func moveCaret(to path: OutlinePath, field: OutlineField = .text, _ place: OutlineCaretPlace) {
        keep(path)
        pending = CaretTarget(path: path, field: field, place: place)
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

    // MARK: Selection

    /// ⇧↑ or ⇧↓ at the edge of a bullet: it is selected whole, with the text selection dropped. `end` is the end of the text selection the keys
    /// were moving, which is where esc puts the caret back.
    private func startSelection(from view: OutlineTextView, at end: Int) {
        guard let started = tree.selecting(view.rowPath, scope: scope) else { return }
        view.setSelectedRange(NSRange(location: min(max(end, 0), (view.string as NSString).length), length: 0))
        select(started, from: OutlineCaret(path: view.rowPath, offset: view.selectedRange().location))
    }

    /// Bullets become selected: the window's first responder goes (the text view resigns as ever, `caretLeft`), so no key types into a bullet and
    /// no input method holds marked text.
    private func select(_ new: OutlineSelection, from origin: OutlineCaret?) {
        pending = nil
        queuedEvents = []
        typingRun = nil
        (activeView?.window ?? NSApp.keyWindow)?.makeFirstResponder(nil)
        selection = new
        selectionOrigin = origin
        if let origin { remembered = origin }
        scroll(to: new.moving)
    }

    /// Ends the selection and leaves `remembered` where esc would put the caret. No text view has the caret meanwhile, so whoever calls this
    /// puts it somewhere.
    private func endSelection() {
        guard let held = selection else { return }
        remembered = escapeCaret(held) ?? remembered
        dropSelection()
    }

    private func dropSelection() {
        if selection != nil { selection = nil }
        selectionOrigin = nil
    }

    /// The bullet the selection started in while it is still the fixed end, where it was; otherwise the end of the fixed end's text.
    private func escapeCaret(_ held: OutlineSelection) -> OutlineCaret? {
        if let origin = selectionOrigin, origin.path == held.fixed { return origin }
        return OutlineCaret(path: held.fixed, offset: (tree.text(at: held.fixed) ?? "").utf16.count)
    }

    /// ⇧↑ and ⇧↓ with bullets selected. At the top level of the zoom the key does nothing.
    private func extendSelection(_ held: OutlineSelection, by step: Int) {
        guard let next = tree.extending(held, by: step, scope: scope) else { return }
        selection = next
        scroll(to: next.moving)
    }

    /// A key while bullets are selected. Varnick's shortcuts go on, as does nothing else: any key not listed beeps and changes nothing.
    private func selectionKey(_ event: NSEvent, _ held: OutlineSelection) -> Bool {
        // The Paste shortcut's key is the outline's here; every other shortcut acts as always.
        let shortcut = Settings.shared.action(for: event)
        if let shortcut, shortcut != .paste { return false }
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        let command: NSEvent.ModifierFlags = .command, commandShift: NSEvent.ModifierFlags = [.command, .shift]
        let code = Int(event.keyCode)
        let run = OutlineRun(held.run)
        if shortcut == .paste {
            pasteAfterSelection(held.run)
            return true
        }
        switch (code, flags) {
        case (kVK_ANSI_C, command):
            copy(held.run)
        case (kVK_ANSI_X, command):
            cut(held.run)
        case (kVK_ANSI_V, command):
            pasteAfterSelection(held.run)
        case (kVK_Escape, []):
            restoreCaret()
        case (kVK_UpArrow, []), (kVK_LeftArrow, []):
            endSelection()
            if let first = held.run.first { moveCaret(to: first, .offset(0)) }
        case (kVK_DownArrow, []), (kVK_RightArrow, []):
            endSelection()
            if let last = held.run.last { moveCaret(to: last, .offset(Int.max)) }
        case (kVK_UpArrow, .shift):
            extendSelection(held, by: -1)
        case (kVK_DownArrow, .shift):
            extendSelection(held, by: 1)
        case (kVK_Tab, []):
            apply(.indent(run))
        case (kVK_Tab, .shift):
            apply(.outdent(run))
        case (kVK_UpArrow, commandShift):
            apply(.move(run, by: -1))
        case (kVK_DownArrow, commandShift):
            apply(.move(run, by: 1))
        case (kVK_Delete, []), (kVK_ForwardDelete, []), (kVK_Delete, commandShift):
            apply(.delete(run))
        case (kVK_Return, command), (kVK_ANSI_KeypadEnter, command):
            apply(.complete(run))
        case (kVK_ANSI_C, [.command, .option]):
            copyAsMirror(held.run)
        case (kVK_ANSI_V, [.command, .option]):
            if let last = held.run.last { placeMirror(after: last) }
        case (kVK_ANSI_Z, command), (kVK_ANSI_Z, commandShift):
            undoOrRedo(redo: flags == commandShift)
        // These end the selection, then do what they do.
        case (kVK_ANSI_LeftBracket, command):
            let zoomedIn = !tree.effectiveZoom.isEmpty
            endSelection()
            if zoomedIn { zoomOut(to: tree.effectiveZoom.count - 1) } else { restoreCaret() }
        case (kVK_ANSI_C, commandShift):
            toggleShowsCompleted()
        case (kVK_ANSI_F, command):
            endSelection()
            focusFilter()
        default:
            NSSound.beep()
        }
        return true
    }

    // MARK: Keys

    /// The keys the outline takes, as `SessionBoard.key` does: the switch below lists them. The End session, Mark session done and Restart
    /// session keys are taken and do nothing. The rest goes on; while an input method is composing, so does all but those three.
    func key(_ event: NSEvent) -> Bool {
        if let action = Settings.shared.action(for: event), action == .endPane || action == .doneSession || action == .restartSession {
            return true
        }
        // Bullets selected: no text view has the keyboard, so the outline takes every key but Varnick's shortcuts.
        if let selection, load == .ready { return selectionKey(event, selection) }
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
        let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
        let code = Int(event.keyCode)
        if code == kVK_Escape, flags.isEmpty {
            if composing { return false }
            // One level back: out of a note, then the filter clears (the caret goes back to its bullet), then the outline closes.
            if let view = activeView, view.field == .note, view.window?.firstResponder === view {
                leaveNote(view)
            } else if filterHasFocus || !filterText.isEmpty {
                setFilter("")
                restoreCaret()
            } else {
                model?.closeOutline()
            }
            return true
        }
        // ⌘Z and ⌘⇧Z are taken even when there is nothing to undo, so the Edit menu's never acts on a text view with no undo of its own.
        let command: NSEvent.ModifierFlags = .command, commandShift: NSEvent.ModifierFlags = [.command, .shift]
        if code == kVK_ANSI_Z, flags == command || flags == commandShift {
            // In the filter field they undo its own typing.
            if composing || filterHasFocus { return false }
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
        if code == kVK_ANSI_F, flags == command, load == .ready, !composing {
            focusFilter()
            return true
        }
        if load == .ready, !composing, filterHasFocus, flags.isEmpty,
           code == kVK_Return || code == kVK_ANSI_KeypadEnter || code == kVK_DownArrow {
            goToFirstMatch()
            return true
        }
        guard load == .ready, !composing, let view = activeView, view.window?.firstResponder === view else { return false }
        let selection = view.selectedRange()
        let path = view.rowPath
        let here = OutlineCaret(path: path, offset: selection.location, field: view.field)
        let atStart = selection.location == 0 && selection.length == 0
        if flags == [.command, .option], code == kVK_ANSI_C || code == kVK_ANSI_V {
            if code == kVK_ANSI_C { copyAsMirror([path]) } else { placeMirror(after: path) }
            return true
        }
        // In a note ↩ is a new line, which the text view does itself; the keys that mean the bullet still work.
        if view.field == .note {
            switch (code, flags) {
            case (kVK_Return, .shift), (kVK_ANSI_KeypadEnter, .shift):
                leaveNote(view)
            case (kVK_Return, command), (kVK_ANSI_KeypadEnter, command):
                apply(.complete(OutlineRun(here)))
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
            apply(.complete(OutlineRun(here)))
        case (kVK_Delete, []) where atStart:
            apply(.join(path))
        case (kVK_Delete, commandShift):
            apply(.delete(OutlineRun(path)))
        case (kVK_Tab, []):
            apply(.indent(OutlineRun(here)))
        case (kVK_Tab, .shift):
            apply(.outdent(OutlineRun(here)))
        case (kVK_UpArrow, []) where view.caretOnFirstLine:
            return cross(from: view, by: -1)
        case (kVK_DownArrow, []) where view.caretOnLastLine:
            return cross(from: view, by: 1)
        // ⇧↑ on the first wrapped line and ⇧↓ on the last select the whole bullet, by the end of the text selection the keys move; elsewhere
        // they select text.
        case (kVK_UpArrow, .shift) where view.movingEndOnFirstLine:
            startSelection(from: view, at: view.movingEnd ?? selection.location)
        case (kVK_DownArrow, .shift) where view.movingEndOnLastLine:
            startSelection(from: view, at: view.movingEnd ?? NSMaxRange(selection))
        case (kVK_UpArrow, commandShift):
            apply(.move(OutlineRun(here), by: -1))
        case (kVK_DownArrow, commandShift):
            apply(.move(OutlineRun(here), by: 1))
        case (kVK_UpArrow, command):
            // Under a filter every ancestor shows open, so a collapse would save a state nothing on screen shows.
            if filterWords.isEmpty { apply(.collapse(path, true)) }
        case (kVK_DownArrow, command):
            if filterWords.isEmpty { apply(.collapse(path, false)) }
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
