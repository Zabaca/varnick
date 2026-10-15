import AppKit
import Combine
import VarnickPeer

extension NoticeKind {
    /// What the menu says: Needs you says which (`Turn.mark`), and an error says its kind when the reader knew it.
    var text: String {
        switch self {
        case .done: "Done"
        case .needsYou(let turn): turn.mark ?? "Needs you"
        case .failed(let failure):
            if let failure, failure != .other { "Stopped on an error (\(failure.word))" } else { "Stopped on an error" }
        }
    }

    /// Needs you and an error get the louder cue and the orange dot; Done is softer.
    var isUrgent: Bool {
        if case .done = self { return false }
        return true
    }

    /// A system sound's name.
    var soundName: String { isUrgent ? "Funk" : "Tink" }
}

/// The notices of sessions that need a look (option 01 of `sessions-finish-unnoticed`; vocabulary in CONTEXT.md, Notice): at most one a pane,
/// raised when a pane's turn changes by `NoticeRule`, listed in the menu bar's menu and marked by a dot on its icon. Nothing is kept across
/// a restart, and nothing about a session is logged.
@MainActor
final class SessionNotifier: ObservableObject {
    struct Notice: Identifiable, Equatable {
        /// The pane's id.
        let id: UUID
        var kind: NoticeKind
        var raisedAt: Date
    }

    /// The standing notices, newest first.
    @Published private(set) var notices: [Notice] = []
    private weak var model: LauncherModel?
    private var ticker: Task<Void, Never>?
    private var lastSound = Date.distantPast
    private var playing: NSSound?

    /// Reads the turns of this Mac's panes that nothing else reads, and clears what no longer stands, once a second while Varnick runs. A pane
    /// started since the launch reads its own turn, and a pane on a peer takes its host's every few seconds.
    func start(model: LauncherModel) {
        guard ticker == nil else { return }
        self.model = model
        model.checkZmx()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// A pane's turn changed word (`ClaudeSession.onTurnWordChange`).
    func turnChanged(in pane: ClaudeSession, from old: PaneTurn?, to new: PaneTurn) {
        guard let model, model.tabs.contains(where: { $0.contains(pane) }) else { return }
        // A pane showing a card isn't in control: the Mac that is notifies.
        let decision = NoticeRule.decide(from: old?.turn, to: new.turn, failure: new.failure, interrupted: new.interrupted,
                                         inControl: pane.away == nil, onScreen: model.isOnScreen(pane), switches: Settings.shared.noticeSwitches)
        switch decision {
        case .none: break
        case .clear: clear(pane.id)
        case .raise(let kind): raise(kind, for: pane.id)
        }
    }

    func clear(_ id: UUID) {
        guard notices.contains(where: { $0.id == id }) else { return }
        notices.removeAll { $0.id == id }
    }

    /// What a notice shows in the menu: the pane's title as the board shows it, its Mac when it isn't this one, and what it says.
    func menuTitle(of notice: Notice) -> String? {
        guard let pane = model?.claudePane(notice.id) else { return nil }
        let title = pane.label
        return ([title.count > 48 ? String(title.prefix(47)) + "…" : title] + [pane.hostName].compactMap { $0 } + [notice.kind.text])
            .joined(separator: " · ")
    }

    private func raise(_ kind: NoticeKind, for id: UUID) {
        notices.removeAll { $0.id == id }
        notices.insert(Notice(id: id, kind: kind, raisedAt: Date()), at: 0)
        play(kind)
    }

    /// One sound per notice; several in the same moment don't stack.
    private func play(_ kind: NoticeKind) {
        guard Date().timeIntervalSince(lastSound) > 0.5 else { return }
        lastSound = Date()
        playing = NSSound(named: kind.soundName)
        playing?.play()
    }

    /// Clears the notices of a pane now on screen, closed, or whose category was switched off.
    private func tick() {
        guard let model else { return }
        model.readDormantTurns()
        guard !notices.isEmpty else { return }
        let switches = Settings.shared.noticeSwitches
        let kept = notices.filter { notice in
            guard let pane = model.claudePane(notice.id) else { return false }
            return switches.isOn(notice.kind.category) && !model.isOnScreen(pane)
        }
        if kept != notices { notices = kept }
    }
}

/// The dot on the menu bar icon while any notice stands: orange if one is Needs you or an error, else the system's blue. An overlay on the
/// status button, so the icon keeps its two images (search, and Listening's waveform).
final class NoticeDot: NSView {
    var urgent = false {
        didSet { if urgent != oldValue { needsDisplay = true } }
    }

    static let diameter: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        (urgent ? NSColor.systemOrange : NSColor.systemBlue).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
