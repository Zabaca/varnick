import AppKit
import Carbon
import SwiftUI
import VarnickPeer

/// The session board's Runs tab (option 01 of `prompts-cant-run-on-a-schedule`): every run of every automation, newest first. A run's state is the
/// pane's turn while the pane is here and what was recorded after; a slot that didn't run says why. ↩ opens a run: live while its tab is here, resumed
/// in a new tab once it has ended.
@MainActor
final class RunsBoard: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let automation: String
        /// When it started, else its slot.
        let when: Date
        let state: RunState
        let detail: String?
        let late: Bool
        let manual: Bool
        /// A session was started for it, so it can be opened.
        let opens: Bool
        /// Where it ran: this Mac, until runs can be on a headless host.
        let place: String

        /// "Running", "Waiting on you: Needs permission", a message's title, "Missed: over 12 hours old".
        var text: String {
            state == .message ? detail ?? state.text : detail.map { state.text + ": " + $0 } ?? state.text
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selection: UUID?
    /// Why the last ↩ did not open anything, shown over the list until the selection moves.
    @Published private(set) var refusal: String?
    weak var model: LauncherModel?

    /// How many runs the tab lists: each automation keeps twenty.
    private static let shown = 200

    func refresh() {
        guard let model else { return }
        var next: [Row] = []
        let here = PeerIdentity.name ?? "this Mac"
        for automation in model.automations.automations {
            for run in automation.runs {
                let now = model.displayed(run)
                next.append(Row(id: run.id, automation: automation.name, when: run.startedAt ?? run.slot, state: now.state, detail: now.detail,
                                late: run.late, manual: run.manual, opens: run.state.ran, place: here))
            }
        }
        next.sort { $0.when > $1.when }
        next = Array(next.prefix(Self.shown))
        if next != rows { rows = next }
        if let selection, !next.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = next.first?.id }
    }

    func key(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: if plain { openSelected() }
        case kVK_Escape where plain: model?.closeBoard()
        case kVK_UpArrow where plain: step(-1)
        case kVK_DownArrow where plain: step(1)
        case kVK_ANSI_D where plain, kVK_ANSI_E where plain, kVK_ANSI_R where plain: break
        default:
            guard let action = Settings.shared.action(for: event),
                  action == .endPane || action == .doneSession || action == .restartSession else { return false }
        }
        return true
    }

    private func step(_ delta: Int) {
        refusal = nil
        guard !rows.isEmpty else { return }
        let at = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        selection = rows[max(0, min(rows.count - 1, at + delta))].id
    }

    func openSelected() {
        if let selection { open(selection) }
    }

    func open(_ id: UUID) {
        selection = id
        guard let row = rows.first(where: { $0.id == id }), row.opens else {
            refusal = "That slot never ran, so there is nothing to open"
            return
        }
        refusal = model?.openRun(id)
    }
}

struct RunsBoardView: View {
    @ObservedObject var board: RunsBoard

    var body: some View {
        if board.rows.isEmpty {
            Text("No runs yet. Settings › Automations makes an automation, and Run now tries one.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let refusal = board.refusal {
                    Text(refusal).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.vertical, 6)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        // The times count from the clock, so they redraw each minute without the board publishing.
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            VStack(spacing: 6) {
                                ForEach(board.rows) { row in
                                    RunRowView(row: row, selected: board.selection == row.id, now: context.date)
                                        .id(row.id)
                                        .onTapGesture { board.open(row.id) }
                                }
                            }
                            .padding(6)
                        }
                    }
                    .onChange(of: board.selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct RunRowView: View {
    let row: RunsBoard.Row
    let selected: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.automation).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(row.text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if row.state == .waiting { OrangeMark(text: "Needs you") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.primary.opacity(0.26) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(row.opens ? 1 : 0.7)
    }

    private var color: Color {
        switch row.state {
        case .running: .blue
        case .waiting: .orange
        case .done, .message: .green
        case .stoppedAtLimit, .endedAfterWaiting, .couldntStart: .red
        case .skipped, .missed: .secondary
        }
    }

    /// "4m ago on this Mac", with how it started when it wasn't the clock's own minute.
    private var when: String {
        let age = SessionBoard.Card.duration(now.timeIntervalSince(row.when))
        var parts = [age == "0s" ? "just now" : age + " ago", row.place]
        if row.manual { parts.append("run now") } else if row.late { parts.append("late") }
        return parts.joined(separator: " · ")
    }
}
