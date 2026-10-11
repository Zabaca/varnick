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
                OutlineFilterField(outline: outline)
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

/// The filter (⌘F): the rows follow what is typed; ↓ or ↩ goes to the first match, esc clears it. `Outline.key` takes those keys, since the monitor
/// sees them before this field does.
private struct OutlineFilterField: View {
    @ObservedObject var outline: Outline
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Filter", text: Binding(get: { outline.filterText }, set: { outline.setFilter($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .frame(width: 110)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        // A click in the field ends a selection of bullets; the caret goes back to its bullet when the filter clears.
        .onChange(of: focused) { _, isFocused in
            if isFocused { DispatchQueue.main.async { outline.filterTookFocus() } }
        }
        // The caret is in a bullet's text view, so it has to let go first, as search does (`focusSearch`).
        .onChange(of: outline.filterFocusRequest) { _, _ in
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
                focused = true
            }
        }
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

    /// What a mirror's dot says: the other places, each as Home and the crumbs down to its parent.
    static func tooltip(_ places: OutlinePlaces) -> String {
        guard !places.named.isEmpty else { return "A mirror" }
        let lines = places.named.map { (["Home"] + $0.map { clipped($0.text) }).joined(separator: " › ") }
        return (["Also in:"] + lines + (places.more > 0 ? ["and \(places.more) more"] : [])).joined(separator: "\n")
    }

    private func clipped(_ text: String) -> String { Self.clipped(text) }

    static func clipped(_ text: String) -> String {
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
                        BulletTexts(outline: outline, path: title.path, text: title.text, kind: .title, note: title.note,
                                    noteOpen: outline.notePath == title.path, completed: title.completed, dimmed: title.completed)
                            .id(title.id)
                            .padding(.vertical, 6)
                    }
                    let looks = SelectedLook.looks(of: outline.rows, selection: outline.selection)
                    ForEach(Array(outline.rows.enumerated()), id: \.element.id) { index, row in
                        OutlineRowView(outline: outline, row: row, noteOpen: outline.notePath == row.path,
                                       highlight: row.matched ? outline.filterWords : [], filtering: !outline.filterWords.isEmpty,
                                       selected: looks[index]).id(row.id)
                    }
                    if outline.rows.isEmpty, !outline.filterWords.isEmpty {
                        Text("No bullets match").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.vertical, 6)
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

/// A bullet's text (or the title's) and, under it, its note. A note shows while it has text, and while it has the caret (empty or not); then it
/// shows in full.
private struct BulletTexts: View {
    let outline: Outline
    let path: OutlinePath
    let text: String
    let kind: OutlineTextView.Kind
    let note: String?
    let noteOpen: Bool
    var completed = false
    var dimmed = false
    var highlight: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BulletText(outline: outline, path: path, text: text, kind: kind, completed: completed, dimmed: dimmed, highlight: highlight)
            if note != nil || noteOpen {
                BulletText(outline: outline, path: path, text: note ?? "", kind: .note, dimmed: dimmed, expanded: noteOpen, highlight: highlight)
            }
        }
    }
}

/// How a row sits in the block of selected bullets: the selected bullets and what is nested under them read as one block.
private struct SelectedLook {
    /// The depth of the selected bullet the row is, or is nested under: the fill starts at its dot for the whole block.
    let depth: Int
    let startsBlock: Bool
    let endsBlock: Bool

    /// One entry for each row, nil for the rows that aren't selected. Rows come in the order of a walk, so what is nested under a selected
    /// bullet follows it.
    static func looks(of rows: [OutlineRow], selection: OutlineSelection?) -> [SelectedLook?] {
        guard let selection else { return Array(repeating: nil, count: rows.count) }
        let roots = Set(selection.run)
        var under: OutlinePath?
        var depths: [Int?] = []
        for row in rows {
            if roots.contains(row.path) {
                under = row.path
            } else if let root = under, !row.path.placements.starts(with: root.placements) {
                under = nil
            }
            depths.append(under.map { row.depth - (row.path.placements.count - $0.placements.count) })
        }
        return depths.indices.map { i in
            depths[i].map { SelectedLook(depth: $0, startsBlock: i == 0 || depths[i - 1] == nil, endsBlock: i == depths.count - 1 || depths[i + 1] == nil) }
        }
    }
}

private struct OutlineRowView: View {
    let outline: Outline
    let row: OutlineRow
    /// The caret is in this row's note, or it was just opened: the note shows in full, and shows at all while it is empty.
    let noteOpen: Bool
    /// The filter's words, to mark in the text and the note when this bullet matches.
    let highlight: [String]
    /// A filter is on: every ancestor shows open, so there is no triangle to click.
    let filtering: Bool
    /// The row is selected, or nested under a selected bullet.
    let selected: SelectedLook?

    /// What each level of nesting indents by.
    static let indent: CGFloat = 18
    /// The disclosure triangle's width, and the height of a one-line row's dot and triangle.
    static let disclosureWidth: CGFloat = 12
    static let lineHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            disclosure
            dot
            BulletTexts(outline: outline, path: row.path, text: row.text, kind: .row, note: row.note, noteOpen: noteOpen,
                        completed: row.completed, dimmed: row.dimmed, highlight: highlight)
        }
        .padding(.leading, CGFloat(row.depth) * Self.indent)
        .padding(.vertical, 2)
        // From the selected bullet's dot to the right edge, joined to the rows above and below it into one block.
        .background(alignment: .leading) {
            if let selected {
                let corner: CGFloat = 6
                UnevenRoundedRectangle(topLeadingRadius: selected.startsBlock ? corner : 0, bottomLeadingRadius: selected.endsBlock ? corner : 0,
                                       bottomTrailingRadius: selected.endsBlock ? corner : 0, topTrailingRadius: selected.startsBlock ? corner : 0,
                                       style: .continuous)
                    .fill(Theme.selection)
                    .padding(.leading, CGFloat(selected.depth) * Self.indent + Self.disclosureWidth + 4)
            }
        }
    }

    /// A triangle on a bullet with bullets nested under it; the space is kept on the others so the dots line up.
    @ViewBuilder private var disclosure: some View {
        if row.hasChildren, !filtering {
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

    /// A click zooms into the bullet. An outer ring marks a collapsed bullet that has bullets nested under it, an inner one in the tag colour a
    /// mirror (the tooltip says where else it is).
    private var dot: some View {
        Button { outline.zoomIn(row.path) } label: {
            ZStack {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
                if row.mirrored {
                    Circle().strokeBorder(Theme.mirror, lineWidth: 1).frame(width: 9, height: 9)
                }
                if row.hasChildren, row.collapsed {
                    Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 13, height: 13)
                }
            }
            .frame(width: 14, height: Self.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.mirrored ? OutlineCrumbs.tooltip(outline.places(of: row.path)) : "")
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
    /// Filter words to mark in the text.
    var highlight: [String] = []

    func makeCoordinator() -> Coordinator { Coordinator(outline: outline) }

    func makeNSView(context: Context) -> OutlineTextView {
        let view = OutlineTextView.make(path: path, outline: outline, kind: kind)
        view.delegate = context.coordinator
        view.applyStyle(completed: completed, dimmed: dimmed, highlight: highlight)
        view.setExpanded(expanded)
        view.setTextQuietly(text)
        outline.register(view)
        return view
    }

    /// Nothing here publishes or moves the first responder (where-it-breaks, Sessions and tabs), and the text of the view with the caret is the user's:
    /// it is set only once the caret has left (`OutlineTextView.syncFromModel`).
    func updateNSView(_ view: OutlineTextView, context: Context) {
        context.coordinator.outline = outline
        view.applyStyle(completed: completed, dimmed: dimmed, highlight: highlight)
        view.setExpanded(expanded)
        guard view.window?.firstResponder !== view, view.string != text else { return }
        view.setTextQuietly(text)
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
            view.selectionChanged(from: (notification.userInfo?["NSOldSelectedCharacterRange"] as? NSValue)?.rangeValue)
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

        var color: NSColor {
            switch self {
            case .row, .title: .labelColor
            case .note: .secondaryLabelColor
            }
        }

        /// What tells its view apart from the others with the same path.
        var registryPrefix: String {
            switch self {
            case .row: ""
            case .title: "title:"
            case .note: "note:"
            }
        }
    }
    private(set) var kind = Kind.row
    var isTitle: Bool { kind == .title }
    var field: OutlineField { kind == .note ? .note : .text }

    static func registryKey(_ path: OutlinePath, kind: Kind) -> String {
        kind.registryPrefix + path.id
    }
    var registryKey: String { Self.registryKey(rowPath, kind: kind) }

    /// How much of its colour a dimmed (completed) bullet keeps.
    private static let dimAlpha: CGFloat = 0.45

    private var completed = false
    private var dimmed = false
    private var highlight: [String] = []
    private var expanded = true
    /// An input method was composing when the style last changed; its marked text is left alone until it is done.
    private var restyleWaiting = false

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

    /// A session's edit to the text the user is typing in (Panel access), put in as a key would be: the view is asked first, only the part that
    /// differs is replaced, the selection is set again around it, and `didChangeText` lets the outline apply it. False if the view refused.
    /// Nothing is awaited in here, so no key lands between the steps.
    @MainActor
    func replaceAsKey(with new: String) -> Bool {
        guard let change = OutlineActing.smallestChange(from: string, to: new) else { return true }
        let selected = selectedRange()
        guard shouldChangeText(in: change.range, replacementString: change.replacement) else { return false }
        // The typing attributes carry the font, which an empty view's text storage has no run to take from.
        textStorage?.replaceCharacters(in: change.range, with: NSAttributedString(string: change.replacement, attributes: typingAttributes))
        setSelectedRange(OutlineActing.selection(selected, afterReplacing: change.range, withLength: (change.replacement as NSString).length))
        didChangeText()
        return true
    }

    /// Struck through and dimmed for a completed bullet, dimmed for what is nested under one: attributes of the text.
    func applyStyle(completed: Bool, dimmed: Bool, highlight: [String]) {
        // Marks are found again each time while there are some: the text may have been typed into since.
        guard completed != self.completed || dimmed != self.dimmed || highlight != self.highlight || !highlight.isEmpty || restyleWaiting else { return }
        self.completed = completed
        self.dimmed = dimmed
        self.highlight = highlight
        restyle()
    }

    private func restyle() {
        restyleWaiting = hasMarkedText()
        guard !restyleWaiting else { return }
        textColor = dimmed ? kind.color.withAlphaComponent(Self.dimAlpha) : kind.color
        let strike = NSUnderlineStyle.single.rawValue
        let whole = NSRange(location: 0, length: (string as NSString).length)
        if completed { textStorage?.addAttribute(.strikethroughStyle, value: strike, range: whole) } else { textStorage?.removeAttribute(.strikethroughStyle, range: whole) }
        typingAttributes[.strikethroughStyle] = completed ? strike : nil
        // Tags in the accent colour (dimmed with the rest of a completed bullet).
        let tags = OutlineTags.ranges(in: string)
        for tag in tags { textStorage?.addAttribute(.foregroundColor, value: NSColor(Theme.tag).withAlphaComponent(dimmed ? Self.dimAlpha : 1), range: tag) }
        // The filter's words, wherever they are in the text, ignoring case and accents; a tag word marks that tag only.
        textStorage?.removeAttribute(.backgroundColor, range: whole)
        typingAttributes[.backgroundColor] = nil
        let text = string as NSString
        for word in highlight where !word.isEmpty {
            if OutlineTags.isTagWord(word) {
                for tag in tags where OutlineTags.key(text.substring(with: tag)) == word {
                    textStorage?.addAttribute(.backgroundColor, value: NSColor(Theme.highlight), range: tag)
                }
                continue
            }
            var from = 0
            while from < text.length {
                let found = text.range(of: word, options: OutlineTree.matchOptions, range: NSRange(location: from, length: text.length - from))
                if found.location == NSNotFound { break }
                textStorage?.addAttribute(.backgroundColor, value: NSColor(Theme.highlight), range: found)
                from = NSMaxRange(found)
            }
        }
    }

    /// Tags are coloured as they are typed.
    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    /// The window makes a view first responder before it sees the mouse-down, so a click on a tag here is refused it: no caret moves in.
    override var acceptsFirstResponder: Bool {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window,
           tag(at: convert(event.locationInWindow, from: nil)) != nil { return false }
        return super.acceptsFirstResponder
    }

    /// A click on a tag filters by it, and places no caret.
    override func mouseDown(with event: NSEvent) {
        if let tag = tag(at: convert(event.locationInWindow, from: nil)) {
            outline?.toggleTag(tag)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func tag(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, length > 0 else { return nil }
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard let range = OutlineTags.ranges(in: string).first(where: { NSLocationInRange(index, $0) }) else { return nil }
        // The index of the nearest character: the point has to be on the tag itself, not beside it on a short line.
        let box = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: textContainer)
        return box.contains(point) ? (string as NSString).substring(with: range) : nil
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

    /// A cut-short note ends in "…" when more is hidden. The layout puts it there itself when the second line wraps; when that line ends at a line
    /// break the text goes on past it unmarked, so it is drawn here, after the last laid-out line.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard kind == .note, !expanded, let layoutManager, let textContainer else { return }
        let laidOut = layoutManager.glyphRange(for: textContainer)
        guard laidOut.length > 0, NSMaxRange(laidOut) < layoutManager.numberOfGlyphs else { return }
        let rest = (string as NSString).substring(from: layoutManager.characterIndexForGlyph(at: NSMaxRange(laidOut)))
        let last = NSMaxRange(laidOut) - 1
        guard !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              layoutManager.truncatedGlyphRange(inLineFragmentForGlyphAt: last).location == NSNotFound else { return }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: kind.font, .foregroundColor: textColor ?? kind.color]
        let ellipsis = "…" as NSString
        // On a line that fills the width it goes back inside the bounds.
        ellipsis.draw(at: NSPoint(x: min(used.maxX, bounds.width - ellipsis.size(withAttributes: attributes).width), y: used.minY),
                      withAttributes: attributes)
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
            // Laid out in full now, so a caret placed on its last line is on a line that shows.
            setExpanded(true)
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

    /// Varnick's own copy, or several lines, become whole bullets (the outline makes them, below this one); one line is typed in as it is.
    @MainActor
    override func paste(_ sender: Any?) {
        // A note keeps its line breaks.
        if kind == .note { return super.paste(sender) }
        if outline?.pasteBullets(into: self) == true { return }
        let lines = NSPasteboard.general.string(forType: .string).map(OutlineClipboard.lines(of:))
        if let line = lines?.first { insertText(line, replacementRange: selectedRange()) }
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

    private func isOnFirstLine(_ index: Int) -> Bool {
        guard let here = lineRect(atCharacter: index), let first = lineRect(atCharacter: 0) else { return true }
        return here.minY == first.minY
    }

    private func isOnLastLine(_ index: Int) -> Bool {
        guard let here = lineRect(atCharacter: index), let last = lineRect(atCharacter: length - 1) else { return true }
        return here.minY == last.minY
    }

    /// The caret is on the first wrapped line, so ↑ leaves the bullet.
    var caretOnFirstLine: Bool { isOnFirstLine(selectedRange().location) }

    /// The caret is on the last wrapped line, so ↓ leaves the bullet.
    var caretOnLastLine: Bool { isOnLastLine(NSMaxRange(selectedRange())) }

    /// The end of the text selection that the shift keys move, as far as it can be told: the caret itself without a selection, the end a key
    /// moved otherwise. Nil for a selection made with the mouse, or by the program.
    private(set) var movingEnd: Int?

    /// Called on every change of the selection, with where it was. Only a key can say which end moved: the end that stayed is the other one.
    func selectionChanged(from old: NSRange?) {
        let now = selectedRange()
        if now.length == 0 {
            movingEnd = now.location
        } else if let old, NSApp.currentEvent?.type == .keyDown, now.location == old.location, now.length != old.length {
            movingEnd = NSMaxRange(now)
        } else if let old, NSApp.currentEvent?.type == .keyDown, NSMaxRange(now) == NSMaxRange(old), now.location != old.location {
            movingEnd = now.location
        } else {
            movingEnd = nil
        }
    }

    /// ⇧↑ selects the whole bullet when the end being moved is on its first line (the selection's start when that can't be told, as ↑ goes by it).
    var movingEndOnFirstLine: Bool { isOnFirstLine(movingEnd ?? selectedRange().location) }

    /// ⇧↓ likewise on the last line (the selection's end).
    var movingEndOnLastLine: Bool { isOnLastLine(movingEnd ?? NSMaxRange(selectedRange())) }

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
