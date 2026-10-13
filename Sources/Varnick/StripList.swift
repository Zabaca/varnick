import AppKit
import Carbon
import SwiftUI

/// A list that opens under the tab strip from a chip: the hidden tabs' (`TabStrip.hiddenList`) and the projects' (`TabStrip.projectList`).
/// It is an overlay on the Claude pane, so the keyboard never leaves the focused pane; `key` takes ↑ ↓ ↩ and esc while it is open.
@MainActor
final class StripList: ObservableObject {
    /// What Panel access calls it when it refuses because of it.
    let name: String
    weak var model: LauncherModel?
    @Published private(set) var isOpen = false
    /// The highlighted row.
    @Published var selection = 0
    /// Where the chip and the open list are, in the window's space (the top left origin SwiftUI's `.global` has), for a click to tell outside.
    var chipFrame = CGRect.null
    var listFrame = CGRect.null
    /// How many rows it has now, and what choosing one does.
    var count: () -> Int = { 0 }
    var choose: (Int) -> Void = { _ in }

    /// A list shows up to this many rows, then scrolls.
    static let rows = 8

    init(name: String) { self.name = name }

    /// Opens with `index` highlighted, closing the other list and reading the turns for its marks; closes when open.
    func toggle(selecting index: Int = 0) {
        if isOpen { return close(refocus: true) }
        guard let model else { return }
        model.strip.closeList()
        selection = index
        isOpen = true
        model.startSummaryTicker()
    }

    /// Closes the list. The keyboard was never taken from the pane, but a click that closed it may have moved it, so it goes back.
    func close(refocus: Bool = false) {
        guard isOpen else { return }
        isOpen = false
        if refocus, let tab = model?.activeTab, model?.showsTerminal == true { tab.focus(tab.focused) }
    }

    /// Chooses a row and closes the list.
    func pick(_ index: Int) {
        guard (0..<count()).contains(index) else { return }
        close()
        choose(index)
    }

    /// A click while the list is open: outside it, and not on the chip (which toggles), closes it. The click goes on to what it landed on.
    func mouseDown(_ event: NSEvent) {
        guard isOpen, let view = event.window?.contentView else { return }
        let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
        if !listFrame.contains(point), !chipFrame.contains(point) { close() }
    }

    /// The list's keys while it is open, taken before the shortcuts and the panes: ↑ ↓ ↩ esc. Others go on.
    func key(_ event: NSEvent) -> Bool {
        guard isOpen, model?.renamingTab == nil, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape: close(refocus: true)
        case kVK_UpArrow: selection = max(selection - 1, 0)
        case kVK_DownArrow: selection = min(selection + 1, max(count() - 1, 0))
        case kVK_Return, kVK_ANSI_KeypadEnter: pick(selection)
        default: return false
        }
        return true
    }
}

extension View {
    /// Reports where the chip that opens `list` is, for `StripList.mouseDown`.
    func opens(_ list: StripList) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { list.chipFrame = $0 }
    }
}

/// The box a list under the strip draws its rows in: material, scrolling to the highlighted row (a row is `.id(index)`).
struct StripListBox<Rows: View>: View {
    @ObservedObject var list: StripList
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let rows: Rows

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) { rows }
                    .padding(.vertical, 4)
            }
            .onChange(of: list.selection) { _, now in proxy.scrollTo(now) }
        }
        .frame(width: width, height: height)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { list.listFrame = $0 }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}
