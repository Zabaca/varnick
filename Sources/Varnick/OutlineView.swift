import AppKit
import Combine
import SwiftUI

// MARK: - View

struct OutlineView: View {
    @ObservedObject var outline: Outline
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "list.bullet.indent").foregroundStyle(.secondary)
                OutlineCrumbs(outline: outline)
                if let notice = outline.notice { Text(notice).font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(1) }
                Spacer()
                Button { outline.toggleShowsCompleted() } label: {
                    KeyHint(label: outline.showsCompleted ? "Hide completed" : "Show completed", keys: ["⌘", "⇧", "C"])
                }
                .buttonStyle(.plain)
                Button(action: close) { KeyHint(label: "Close", keys: ["esc"]) }
                    .buttonStyle(.plain)
                ShortcutHint(label: "", action: .outline)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, Theme.gutter)
            .frame(height: LauncherModel.searchHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)

            switch outline.load {
            case .notLoaded, .loading:
                message("Loading…", detail: nil, actions: [])
            case .ready:
                OutlineRows(outline: outline)
            case .unreadable(let reason):
                message("outline.json couldn't be read", detail: reason,
                        actions: [("Reveal in Finder", { outline.revealInFinder() }), ("Start a new outline", { outline.startNew() })])
            case .newer:
                message("outline.json is from a newer Varnick", detail: nil, actions: [("Reveal in Finder", { outline.revealInFinder() })])
            }
        }
    }

    private func message(_ title: String, detail: String?, actions: [(String, () -> Void)]) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium))
            if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                ForEach(actions.indices, id: \.self) { i in
                    Button(actions[i].0, action: actions[i].1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Home, then each bullet zoomed through, each clickable but the last. When the trail is too long for the header the crumbs between the first and
/// the last drop out, nearest the first first, and one "…" stands for them.
private struct OutlineCrumbs: View {
    @ObservedObject var outline: Outline

    /// About how many characters the header leaves for the trail.
    private static let budget = 32
    private static let longest = 20

    private enum Item: Identifiable {
        case home
        case crumb(OutlineCrumb)
        case gap

        var id: String {
            switch self {
            case .home: "home"
            case .crumb(let crumb): crumb.id
            case .gap: "gap"
            }
        }
    }

    private func clipped(_ text: String) -> String {
        text.isEmpty ? "(empty)" : text.count > Self.longest ? String(text.prefix(Self.longest)) + "…" : text
    }

    private var items: [Item] {
        let crumbs = outline.crumbs
        var hidden = 0
        func size(_ shown: ArraySlice<OutlineCrumb>) -> Int { shown.reduce(0) { $0 + clipped($1.text).count } }
        // Crumbs after the first, nearest it first, go until the rest fit; the last stays.
        while crumbs.count - hidden > 2, size(crumbs[...]) - size(crumbs[1..<(1 + hidden)]) > Self.budget { hidden += 1 }
        var out: [Item] = [.home]
        for (i, crumb) in crumbs.enumerated() {
            if i == 0 || i > hidden { out.append(.crumb(crumb)) } else if i == 1 { out.append(.gap) }
        }
        return out
    }

    var body: some View {
        let last = outline.crumbs.last
        HStack(spacing: 6) {
            ForEach(items) { item in
                switch item {
                case .home:
                    if last == nil {
                        Text("Outline").font(.system(size: 15, weight: .semibold))
                    } else {
                        link("Home") { outline.zoomOut(to: 0) }
                    }
                case .crumb(let crumb):
                    separator
                    if crumb == last {
                        Button { outline.focusTitle() } label: {
                            Text(clipped(crumb.text)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        link(clipped(crumb.text)) { outline.zoomOut(to: crumb.path.placements.count) }
                    }
                case .gap:
                    separator
                    Text("…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
    }

    private func link(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            .buttonStyle(.plain)
    }
}

private struct OutlineRows: View {
    @ObservedObject var outline: Outline

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The zoomed bullet's own text, above what is nested under it.
                    if let title = outline.crumbs.last {
                        VStack(alignment: .leading, spacing: 0) {
                            BulletText(outline: outline, path: title.path, text: title.text, kind: .title, completed: title.completed)
                            if title.note != nil || outline.notePath == title.path {
                                BulletText(outline: outline, path: title.path, text: title.note ?? "", kind: .note, dimmed: title.completed,
                                           expanded: outline.notePath == title.path)
                            }
                        }
                        .id(title.id)
                        .padding(.vertical, 6)
                    }
                    ForEach(outline.rows) { row in
                        OutlineRowView(outline: outline, row: row, noteOpen: outline.notePath == row.path).id(row.id)
                    }
                    // A click below the last bullet puts the caret in it.
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { outline.focusLast() }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 8)
            }
            // The publisher sends before the value and the rows change, so the scroll waits a turn for the new row.
            .onReceive(outline.$scrollRequest.receive(on: DispatchQueue.main)) { request in
                if let request { proxy.scrollTo(request.row) }
            }
        }
    }
}

private struct OutlineRowView: View {
    let outline: Outline
    let row: OutlineRow
    /// The caret is in this row's note, or it was just opened: the note shows in full, and shows at all while it is empty.
    let noteOpen: Bool

    /// What each level of nesting indents by.
    static let indent: CGFloat = 18
    /// The disclosure triangle's width, and the height of a one-line row's dot and triangle.
    static let disclosureWidth: CGFloat = 12
    static let lineHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            disclosure
            dot
            VStack(alignment: .leading, spacing: 0) {
                BulletText(outline: outline, path: row.path, text: row.text, kind: .row, completed: row.completed, dimmed: row.dimmed)
                // A note shows while it has text, and while it has the caret (empty or not); then it shows in full.
                if row.note != nil || noteOpen {
                    BulletText(outline: outline, path: row.path, text: row.note ?? "", kind: .note, dimmed: row.dimmed, expanded: noteOpen)
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.vertical, 2)
    }

    /// A triangle on a bullet with bullets nested under it; the space is kept on the others so the dots line up.
    @ViewBuilder private var disclosure: some View {
        if row.hasChildren {
            Button { outline.toggleCollapse(row.path) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.collapsed ? 0 : 90))
                    .frame(width: Self.disclosureWidth, height: Self.lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: Self.disclosureWidth, height: Self.lineHeight)
        }
    }

    /// A click zooms into the bullet. A ring marks a collapsed bullet that has bullets nested under it.
    private var dot: some View {
        Button { outline.zoomIn(row.path) } label: {
            ZStack {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
                if row.hasChildren, row.collapsed {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 12, height: 12)
                }
            }
            .frame(width: 14, height: Self.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text view

/// A bullet's text: a small AppKit text view, wrapping at the row's width. A SwiftUI field can't tell the outline where the caret is, which
/// wrapped line it is on, or whether an input method is composing.
private struct BulletText: NSViewRepresentable {
    let outline: Outline
    let path: OutlinePath
    let text: String
    let kind: OutlineTextView.Kind
    /// Struck through, and dimmed (also for what is nested under a completed bullet).
    var completed = false
    var dimmed = false
    /// A note with the caret shows in full; the others are cut to two lines.
    var expanded = false

    func makeCoordinator() -> Coordinator { Coordinator(outline: outline) }

    /// A note without the caret shows two lines. The layout ends the second in "…" when it wraps; a third line break it can't see, so that adds
    /// the "…" itself, to what is shown only: the note's text view sets the full text back when the caret comes (`syncFromModel`).
    private var shown: String {
        guard kind == .note, !expanded else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 2 ? lines[0] + "\n" + lines[1] + "…" : text
    }

    func makeNSView(context: Context) -> OutlineTextView {
        let view = OutlineTextView.make(path: path, outline: outline, kind: kind)
        view.delegate = context.coordinator
        view.applyStyle(completed: completed, dimmed: dimmed)
        view.setExpanded(expanded)
        view.setTextQuietly(shown)
        outline.register(view)
        return view
    }

    /// Nothing here publishes or moves the first responder (where-it-breaks, Sessions and tabs), and the text of the view with the caret is the user's:
    /// it is set only once the caret has left (`OutlineTextView.syncFromModel`).
    func updateNSView(_ view: OutlineTextView, context: Context) {
        context.coordinator.outline = outline
        view.applyStyle(completed: completed, dimmed: dimmed)
        view.setExpanded(expanded)
        guard view.window?.firstResponder !== view, view.string != shown else { return }
        view.setTextQuietly(shown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: OutlineTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    static func dismantleNSView(_ view: OutlineTextView, coordinator: Coordinator) {
        coordinator.outline.unregister(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var outline: Outline

        init(outline: Outline) { self.outline = outline }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? OutlineTextView else { return }
            outline.textChanged(view, selectionBefore: view.selectionBeforeChange)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? OutlineTextView else { return }
            outline.selectionChanged(view)
        }

        /// A bullet is one paragraph; a note has line breaks.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let text = replacementString else { return true }
            guard (textView as? OutlineTextView)?.kind == .note || !text.contains(where: \.isNewline) else { return false }
            // Where the selection starts before it changes: where an undo puts the caret back.
            (textView as? OutlineTextView)?.selectionBeforeChange = textView.selectedRange().location
            return true
        }
    }
}

final class OutlineTextView: NSTextView {
    var rowPath = OutlinePath(placements: [])
    weak var outline: Outline?
    /// Where the selection started before the change the delegate is hearing of.
    var selectionBeforeChange: Int?


    /// A bullet's text, its note under it, or the text of the bullet zoomed into. The title has the path of the row it was zoomed from, and a
    /// note the path of its bullet, so the three are told apart by this.
    enum Kind {
        case row, title, note

        var font: NSFont {
            switch self {
            case .row: .systemFont(ofSize: 13)
            case .title: .systemFont(ofSize: 20, weight: .semibold)
            case .note: .systemFont(ofSize: 11.5)
            }
        }

        var color: NSColor { self == .note ? .secondaryLabelColor : .labelColor }
    }
    private(set) var kind = Kind.row
    var isTitle: Bool { kind == .title }
    var field: OutlineField { kind == .note ? .note : .text }

    static func registryKey(_ path: OutlinePath, kind: Kind) -> String {
        (kind == .title ? "title:" : kind == .note ? "note:" : "") + path.id
    }
    var registryKey: String { Self.registryKey(rowPath, kind: kind) }

    private var completed = false
    private var dimmed = false
    private var expanded = true

    /// TextKit 1 on purpose: the caret's line and x come from its layout manager.
    @MainActor
    static func make(path: OutlinePath, outline: Outline, kind: Kind) -> OutlineTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let view = OutlineTextView(frame: .zero, textContainer: container)
        view.rowPath = path
        view.outline = outline
        view.isRichText = false
        view.importsGraphics = false
        // The outline's own undo covers typing and structure in one order.
        view.allowsUndo = false
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.kind = kind
        view.font = kind.font
        view.textColor = kind.color
        view.focusRingType = .none
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        return view
    }

    /// Sets the text the way the outline does: not a user's edit, so the delegate hears nothing.
    func setTextQuietly(_ text: String) {
        guard string != text else { return }
        let selection = selectedRange()
        string = text
        setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        restyle()
    }

    /// Struck through and dimmed for a completed bullet, dimmed for what is nested under one: attributes of the text.
    func applyStyle(completed: Bool, dimmed: Bool) {
        guard completed != self.completed || dimmed != self.dimmed else { return }
        self.completed = completed
        self.dimmed = dimmed
        restyle()
    }

    private func restyle() {
        textColor = dimmed ? kind.color.withAlphaComponent(0.45) : kind.color
        let strike = NSUnderlineStyle.single.rawValue
        let whole = NSRange(location: 0, length: (string as NSString).length)
        if completed { textStorage?.addAttribute(.strikethroughStyle, value: strike, range: whole) } else { textStorage?.removeAttribute(.strikethroughStyle, range: whole) }
        typingAttributes[.strikethroughStyle] = completed ? strike : nil
    }

    /// A note with the caret shows in full; without it, two lines ending in "…".
    func setExpanded(_ expanded: Bool) {
        guard kind == .note, expanded != self.expanded, let container = textContainer else { return }
        self.expanded = expanded
        container.maximumNumberOfLines = expanded ? 0 : 2
        container.lineBreakMode = expanded ? .byWordWrapping : .byTruncatingTail
        layoutManager?.textContainerChangedGeometry(container)
        needsDisplay = true
    }

    /// Takes the tree's text once the caret has left, since the outline never sets the text of the view that has it.
    @MainActor
    func syncFromModel() {
        if let text = outline?.content(of: self) { setTextQuietly(text) }
    }

    @MainActor
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // A note shows two lines (and a "…" of its own) until now.
            if kind == .note { syncFromModel() }
            outline?.caretEntered(self)
        }
        return accepted
    }

    @MainActor
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            syncFromModel()
            outline?.caretLeft(self)
        }
        return accepted
    }

    // A bullet is one paragraph: ↩ and ⇥ are the outline's (an input method that is composing gets them first). A note takes ↩ as a line break.
    override func insertNewline(_ sender: Any?) { if kind == .note { super.insertNewline(sender) } }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { if kind == .note { super.insertNewlineIgnoringFieldEditor(sender) } }
    override func insertLineBreak(_ sender: Any?) { if kind == .note { super.insertLineBreak(sender) } }
    override func insertParagraphSeparator(_ sender: Any?) { if kind == .note { super.insertParagraphSeparator(sender) } }
    override func insertTab(_ sender: Any?) {}
    override func insertBacktab(_ sender: Any?) {}

    /// Several lines become several bullets (the outline places them); one line is typed in as it is.
    @MainActor
    override func paste(_ sender: Any?) {
        // A note keeps its line breaks.
        if kind == .note { return super.paste(sender) }
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let lines = string.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count > 1 {
            outline?.paste(self, lines: lines)
        } else if let line = lines.first {
            insertText(line, replacementRange: selectedRange())
        }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    // MARK: Layout

    private var lineHeight: CGFloat {
        layoutManager?.defaultLineHeight(for: kind.font) ?? 16
    }

    /// The height the text needs at `width`.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return lineHeight }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(max(layoutManager.usedRect(for: textContainer).height, lineHeight))
    }

    // MARK: Caret

    private var length: Int { (string as NSString).length }

    private func lineRect(atCharacter index: Int) -> NSRect? {
        guard let layoutManager, let textContainer, length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(max(index, 0), length - 1))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// The caret is on the first wrapped line, so ↑ leaves the bullet.
    var caretOnFirstLine: Bool {
        guard let here = lineRect(atCharacter: selectedRange().location), let first = lineRect(atCharacter: 0) else { return true }
        return here.minY == first.minY
    }

    /// The caret is on the last wrapped line, so ↓ leaves the bullet.
    var caretOnLastLine: Bool {
        guard let here = lineRect(atCharacter: NSMaxRange(selectedRange())), let last = lineRect(atCharacter: length - 1) else { return true }
        return here.minY == last.minY
    }

    /// Where the caret is, across, so the next bullet's caret can be put under it.
    func caretX() -> CGFloat {
        guard let layoutManager, let textContainer, length > 0 else { return 0 }
        let index = selectedRange().location
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return index >= length ? box.maxX : box.minX
    }

    func place(_ place: OutlineCaretPlace) {
        switch place {
        case .offset(let offset):
            setSelectedRange(NSRange(location: min(max(offset, 0), length), length: 0))
        case .x(let x, let bottom):
            guard let layoutManager, let textContainer, length > 0,
                  let rect = lineRect(atCharacter: bottom ? length - 1 : 0) else { return setSelectedRange(NSRange(location: 0, length: 0)) }
            var fraction: CGFloat = 0
            var index = layoutManager.characterIndex(for: NSPoint(x: x, y: rect.midY), in: textContainer,
                                                     fractionOfDistanceBetweenInsertionPoints: &fraction)
            // Past the middle of a character is after it, unless that is the start of the next line.
            if fraction > 0.5, index + 1 <= length, index + 1 == length || lineRect(atCharacter: index + 1)?.minY == rect.minY { index += 1 }
            setSelectedRange(NSRange(location: min(index, length), length: 0))
        }
    }
}
