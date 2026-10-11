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
    private static let budget = 44
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
                        Text(clipped(crumb.text)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    } else {
                        link(clipped(crumb.text)) { outline.zoomOut(to: crumb.path.placements.count) }
                    }
                case .gap:
                    separator
                    Text("…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
    }

    private func link(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1) }
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
                        BulletText(outline: outline, row: OutlineRow(path: title.path, bullet: "", depth: 0, text: title.text,
                                                                     hasChildren: false, collapsed: false), isTitle: true)
                            .id(title.id)
                            .padding(.vertical, 6)
                    }
                    ForEach(outline.rows) { row in
                        OutlineRowView(outline: outline, row: row).id(row.id)
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

    /// What each level of nesting indents by.
    static let indent: CGFloat = 18
    /// The disclosure triangle's width, and the height of a one-line row's dot and triangle.
    static let disclosureWidth: CGFloat = 12
    static let lineHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            disclosure
            dot
            BulletText(outline: outline, row: row)
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
    let row: OutlineRow
    /// The text of the bullet zoomed into, set large above the rows.
    var isTitle = false

    func makeCoordinator() -> Coordinator { Coordinator(outline: outline) }

    func makeNSView(context: Context) -> OutlineTextView {
        let view = OutlineTextView.make(path: row.path, outline: outline, font: isTitle ? OutlineTextView.titleFont : OutlineTextView.font)
        view.delegate = context.coordinator
        view.setTextQuietly(row.text)
        outline.register(view)
        return view
    }

    /// Nothing here publishes or moves the first responder (where-it-breaks, Sessions and tabs), and the text of the view with the caret is the user's:
    /// it is set only once the caret has left (`OutlineTextView.syncFromModel`).
    func updateNSView(_ view: OutlineTextView, context: Context) {
        context.coordinator.outline = outline
        guard view.window?.firstResponder !== view, view.string != row.text else { return }
        view.setTextQuietly(row.text)
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
            outline.textChanged(view.rowPath, view.string, selectionBefore: view.selectionBeforeChange)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? OutlineTextView else { return }
            outline.selectionChanged(view)
        }

        /// A bullet is one paragraph.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let text = replacementString else { return true }
            guard !text.contains(where: \.isNewline) else { return false }
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

    static let font = NSFont.systemFont(ofSize: 13)
    static let titleFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
    private var bulletFont = OutlineTextView.font

    /// TextKit 1 on purpose: the caret's line and x come from its layout manager.
    @MainActor
    static func make(path: OutlinePath, outline: Outline, font: NSFont) -> OutlineTextView {
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
        view.bulletFont = font
        view.font = font
        view.textColor = .labelColor
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
    }

    /// Takes the tree's text once the caret has left, since the outline never sets the text of the view that has it.
    @MainActor
    func syncFromModel() {
        if let text = outline?.text(at: rowPath) { setTextQuietly(text) }
    }

    @MainActor
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { outline?.caretEntered(self) }
        return accepted
    }

    @MainActor
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            syncFromModel()
            outline?.caretLeft()
        }
        return accepted
    }

    // A bullet is one paragraph: ↩ and ⇥ are the outline's (an input method that is composing gets them first).
    override func insertNewline(_ sender: Any?) {}
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) {}
    override func insertParagraphSeparator(_ sender: Any?) {}
    override func insertTab(_ sender: Any?) {}
    override func insertBacktab(_ sender: Any?) {}

    /// Several lines become several bullets (the outline places them); one line is typed in as it is.
    @MainActor
    override func paste(_ sender: Any?) {
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
        layoutManager?.defaultLineHeight(for: bulletFont) ?? 16
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
