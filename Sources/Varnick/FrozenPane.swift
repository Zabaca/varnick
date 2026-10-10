import AppKit
import VarnickPeer
import SwiftTerm
import SwiftUI

/// A terminal view with no process behind it, for a session's frozen screen. Whatever the
/// screen's history asked of a terminal (mouse, focus and paste reports) goes nowhere: `send` drops
/// it, and `FrozenScreenContainer` keeps clicks and keys from reaching the view at all.
final class FrozenTerminalView: TerminalView {
    /// What the terminal was last drawn from. With a grid the font never costs the buffer (see
    /// `fittingFontSize`), so only a new screen draws again; without one the pane's width and the font wrap it.
    private struct Drawn: Equatable {
        var serial: Int
        var grid: PeerGrid?
        var wrap: Wrap?

        struct Wrap: Equatable {
            var pane: CGSize
            var font: CGFloat
        }
    }

    private var screen = PeerScreen(text: "")
    private var serial = -1
    private var pane = CGSize.zero
    private var drawn: Drawn?
    private var fontSize: CGFloat = 0
    /// The font size chosen for this pane, grid and user font size, so a pane that only moves doesn't measure again.
    private var fit: (pane: CGSize, grid: PeerGrid, userSize: CGFloat, size: CGFloat)?

    override func send(source: Terminal, data: ArraySlice<UInt8>) {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The scroller's drag reaches only the delegate, so reading back is noticed there.
        terminalDelegate = scrollWatcher
        scrollWatcher.onScroll = { [weak self] in self?.resumeIfAtBottom() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The terminal's delegate, which only hears of scrolls: the view has no process to send to, and
    /// links, the bell and the clipboard go nowhere.
    private final class ScrollWatcher: TerminalViewDelegate {
        var onScroll: () -> Void = {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) { onScroll() }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
    private let scrollWatcher = ScrollWatcher()

    /// A newer screen than the one drawn, kept while the user reads scrollback: drawing it would put the
    /// view back at the bottom under them. It is drawn once they scroll down again (`resumeIfAtBottom`).
    private var held: (screen: PeerScreen, serial: Int)?
    /// Called when the view starts or stops holding a newer screen back.
    var onPausedChange: (Bool) -> Void = { _ in }

    /// Scrolled up from the bottom: the screen has scrollback and the viewport isn't at its end.
    private var isScrolledBack: Bool { canScroll && scrollPosition < 1 }

    /// Draws the screen from scratch once the pane has a size. With a grid the terminal keeps that
    /// grid at any pane size and the font shrinks to fit; without one the screen wraps to the pane.
    func show(_ screen: PeerScreen, serial: Int) {
        if serial != self.serial {
            if self.serial >= 0, isScrolledBack {
                if held == nil { notifyPaused(true) }
                held = (screen, serial)
                return
            }
            self.screen = screen
            self.serial = serial
            if held != nil {
                held = nil
                notifyPaused(false)
            }
        }
        layOut(in: pane)
    }

    /// The user may have scrolled to the bottom: draws the newest screen that was held back.
    func resumeIfAtBottom() {
        guard let held, !isScrolledBack else { return }
        show(held.screen, serial: held.serial)
    }

    /// Deferred: `show` runs inside a SwiftUI update, which must not publish state.
    private func notifyPaused(_ paused: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onPausedChange(paused) }
    }

    /// Places the terminal in a pane of `pane` points (the container's bounds), drawing again only if the
    /// screen or what it wraps to changed. The user's font size is read here.
    func layOut(in pane: CGSize) {
        self.pane = pane
        guard pane.width > 20, pane.height > 20 else { return }
        let userSize = Settings.shared.fontSize
        var now = Drawn(serial: serial, grid: screen.grid)
        if let grid = screen.grid {
            let wanted = measure(fittingFontSize(grid, in: pane, userSize: userSize), grid)
            // A fraction over, so float rounding can't drop a column or a row; pinned top-left (the view isn't flipped).
            frame = CGRect(x: 0, y: (pane.height - wanted.height).rounded(.down),
                           width: wanted.width + Self.slack, height: wanted.height + Self.slack)
        } else {
            setFontSize(userSize)
            frame = CGRect(origin: .zero, size: pane)
            now.wrap = Drawn.Wrap(pane: pane, font: userSize)
        }
        guard drawn != now else { return }
        drawn = now
        let terminal = getTerminal()
        terminal.resetToInitialState()
        feed(text: screen.text)
        terminal.hideCursor()
    }

    private static let slack: CGFloat = 0.01

    private func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The grid's frame at a font size, measured on this view since SwiftTerm rounds cells to whole points
    /// and pixels.
    private func measure(_ size: CGFloat, _ grid: PeerGrid) -> CGSize {
        setFontSize(size)
        let terminal = getTerminal()
        if terminal.cols != grid.cols || terminal.rows != grid.rows { resize(cols: grid.cols, rows: grid.rows) }
        return getOptimalFrameSize().size
    }

    /// The font size for this pane. A font change resizes SwiftTerm's terminal to the view's frame and
    /// loses its buffer, so the trials run with the frame at zero, which SwiftTerm skips.
    private func fittingFontSize(_ grid: PeerGrid, in pane: CGSize, userSize: CGFloat) -> CGFloat {
        if let fit, fit.pane == pane, fit.grid == grid, fit.userSize == userSize { return fit.size }
        frame.size = .zero
        let size = FrozenFit.fontSize(in: pane, atMost: userSize) { measure($0, grid) }
        fit = (pane, grid, userSize, size)
        return size
    }
}

/// The largest font size at which a screen's grid fits a pane, never above the user's own. Pure: the
/// caller says how big the grid's frame is at a font size, since that is the terminal's to measure.
enum FrozenFit {
    static let step: CGFloat = 0.25
    /// A technical minimum for a font, not a readability floor: the text shrinks as far as the pane needs.
    static let smallest: CGFloat = 1

    static func fontSize(in pane: CGSize, atMost maximum: CGFloat, frame: (CGFloat) -> CGSize) -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let wanted = frame(size)
            return wanted.width <= pane.width && wanted.height <= pane.height
        }
        let widest = frame(maximum)
        guard widest.width > pane.width || widest.height > pane.height else { return maximum }
        // The ratio is only a first guess, since cells round up to whole points.
        let ratio = min(pane.width / widest.width, pane.height / widest.height)
        var size = max(((maximum * ratio) / step).rounded(.down) * step, smallest)
        if fits(size) {
            while size + step < maximum, fits(size + step) { size += step }
        } else {
            while size > smallest {
                size -= step
                if fits(size) { break }
            }
        }
        return max(size, smallest)
    }
}

/// Holds the frozen terminal and stands in front of it for the mouse: a click never makes the
/// terminal first responder (it would take keys), and only scrolling is passed on. A click focuses
/// the pane instead, since the app's mouse monitor only knows live terminals, pages and files.
final class FrozenScreenContainer: NSView {
    let terminal = FrozenTerminalView(frame: .zero)
    var onClick: () -> Void = {}
    /// ↩ on the focused pane: Take over.
    var onReturn: () -> Void = {}
    /// The pane had focus when this was made, so it takes it once it is in a window.
    var wantsFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        terminal.allowMouseReporting = false
        terminal.nativeBackgroundColor = NSColor(white: 0.1, alpha: 1)
        terminal.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func layout() {
        super.layout()
        terminal.layOut(in: bounds.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    /// The one focus target of a card's frozen pane (`ClaudeSession.focus`): it takes keys so that
    /// they stop here, instead of reaching a live neighbour that kept first responder. ↩ takes over.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn() }
    }

    /// Called when the card starts or stops being shown: this view is on screen (its tab is active and
    /// Settings isn't open, or it would have no window) and its window is visible (the panel isn't hidden
    /// or covered, as for Settings › Peers' refresh loop). Read when it joins a window, never assumed.
    var onShownChange: (Bool) -> Void = { _ in }
    private var shown = false
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = window.map {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0,
                                                   queue: .main) { [weak self] _ in self?.updateShown() }
        }
        updateShown()
        guard wantsFocus, let window else { return }
        wantsFocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func updateShown() {
        let now = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard now != shown else { return }
        shown = now
        onShownChange(now)
    }

    deinit { occlusionObserver.map(NotificationCenter.default.removeObserver) }

    override func scrollWheel(with event: NSEvent) {
        terminal.scrollWheel(with: event)
        terminal.resumeIfAtBottom()
    }
}

struct FrozenScreenView: NSViewRepresentable {
    let session: ClaudeSession
    /// The pane has focus: a new container takes it.
    let focused: Bool
    let onClick: () -> Void

    func makeNSView(context: Context) -> FrozenScreenContainer {
        let container = FrozenScreenContainer(frame: .zero)
        container.wantsFocus = focused
        session.frozenContainer = container
        container.terminal.onPausedChange = { [weak session] paused in session?.setFramesPaused(paused) }
        // A new view holds no screen back, so an older one's pause is over. (Deferred: a view update can't publish.)
        DispatchQueue.main.async { [weak session] in session?.setFramesPaused(false) }
        container.onShownChange = { [weak session] shown in session?.cardShown(shown) }
        update(container)
        return container
    }

    func updateNSView(_ container: FrozenScreenContainer, context: Context) { update(container) }

    private func update(_ container: FrozenScreenContainer) {
        container.onClick = onClick
        container.onReturn = { [weak session] in
            if let session, !session.confirmingEnd { session.takeOver() }
        }
        container.terminal.show(session.screen.content, serial: session.screen.serial)
    }
}

/// What a Claude pane shows while another Mac is in control of its session: the session's last
/// screen under a bar that says which Mac and offers Take over. The pane's own client has exited,
/// and the session runs on. Closing it asks first on the session's host (the only pane the session
/// has there) and just closes the view on a peer.
struct FrozenPane: View {
    @ObservedObject var session: ClaudeSession
    let mac: String
    /// This pane has focus, and so ↩ takes over: focus is on the frozen screen's container, which
    /// drops every other key (`FrozenScreenContainer`).
    let focused: Bool
    /// A click focuses the pane.
    let onClick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            bar
            FrozenScreenView(session: session, focused: focused, onClick: onClick)
                .padding(.leading, 8)
                .padding(.trailing, 3)
                .padding(.vertical, 5)
        }
        .background(Color(nsColor: NSColor(white: 0.1, alpha: 1)))
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.confirmingEnd ? "End this session? It's controlled on \(mac)." : session.controlledText(mac))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if session.confirmingEnd {
                Button("End session", role: .destructive) { session.endSession() }
                Button("Keep running") { session.keepSession() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button { session.takeOver() } label: {
                    HStack(spacing: 6) {
                        Text(session.takingOver ? "Taking over…" : "Take over")
                        if focused && !session.takingOver { Text("↩").foregroundStyle(.secondary) }
                    }
                }
                .disabled(session.takingOver)
            }
        }
        .controlSize(.small)
        .padding(.leading, 10)
        // Clear of the Done and × a terminal pane shows over its corner while hovered (`TerminalLeaf`).
        .padding(.trailing, DoneButton.reserved)
        .frame(height: Self.barHeight)
        .background(Theme.tileFill)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }

    static let barHeight: CGFloat = 38

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// What stops the view following the session: the user reading back, else a failed take over, else the
    /// live screen lost (the time it stopped, and why when there is a reason). Else where the screen is from.
    private var note: String? {
        if session.confirmingEnd { return nil }
        if session.framesPaused { return "Paused while you read back. Scroll to the bottom to follow." }
        if let failure = session.screen.failure { return failure }
        // With no screen yet there is no last one to name: the reason alone.
        if let stopped = session.screen.stoppedAt, session.screen.serial > 0 {
            return "Last screen at \(Self.time.string(from: stopped))" + (session.screen.readerFailure.map { ". \($0)" } ?? "")
        }
        if let failure = session.screen.readerFailure { return failure }
        if session.screen.serial == 0 { return "Reading the screen…" }
        return session.runsOnText + " and keeps running. Closing this view \(session.isOnPeer ? "leaves it running" : "asks whether to end it")."
    }
}
