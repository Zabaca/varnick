import AppKit
import Carbon
import SwiftUI
import VarnickPeer

// A Task's Run on the session board's Runs tab (option 01 of `work-cant-be-saved-or-chained`, slice 2a): its row in the list, and its view, which
// shows in place of the list on ↩. The view is written from the Run's records: its steps as lines marked with who acted, its result as fields, a line for
// each child that opens that child, the Task's mark if it has one, and Open tab and Stop. Esc goes back to the list.

extension RunsBoard {
    /// The rows of the Runs that no automation started.
    func taskRows(model: LauncherModel, place: String) -> [Row] {
        model.taskRuns.runs.filter { $0.trigger.automation == nil }.map { run in
            var detail = run.detail
            if detail == nil, run.state.isGoing, let index = run.inFlightIndex { detail = "at \(run.steps[index].name)" }
            return Row(id: run.id, automation: run.task, when: run.startedAt ?? run.trigger.slot, state: run.state, detail: detail, late: false,
                       manual: false, count: 1, opens: true, place: place, mark: nil, isTask: true, startedBy: run.trigger.startedBy)
        }
    }

    func showDetail(of id: UUID) {
        selection = id
        refusal = nil
        detail = id
    }

    func closeDetail() {
        detail = nil
    }

    /// The keys of a Run's view: Esc goes back to the list, ↩ opens the Run's tab. Anything else is the window's.
    func detailKey(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            closeDetail()
        case kVK_Return where plain, kVK_ANSI_KeypadEnter where plain:
            if let detail { refusal = model?.openTaskRunTab(detail) }
        case kVK_UpArrow where plain, kVK_DownArrow where plain:
            break
        default:
            guard let action = Settings.shared.action(for: event),
                  action == .endPane || action == .doneSession || action == .restartSession else { return false }
        }
        return true
    }
}

struct TaskRunView: View {
    @ObservedObject var board: RunsBoard
    /// The Runs file's store, which the view reads so it redraws as the Run goes on.
    @ObservedObject var store: TaskRunStore
    let id: UUID
    @ObservedObject private var grants = TaskGrants.shared

    private var model: LauncherModel? { board.model }

    var body: some View {
        if let run = store.run(id) {
            content(run)
                .task(id: run.task) { model?.taskCatalog.refresh(from: run.folder ?? HomeFolder.path) }
        } else {
            VStack(spacing: 8) {
                Text("That Run is gone.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Button("Back") { board.closeDetail() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ run: TaskRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header(run)
                if let mark = markText(run) {
                    Text(mark).font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                }
                if let refusal = board.refusal {
                    Text(refusal).font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                SectionLabel(text: "Steps")
                if run.lines.isEmpty {
                    Text("No step has started.").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 8)
                }
                ForEach(Array(run.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
                if let detail = run.detail, !run.state.isGoing || run.state == .waiting {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(run.state == .failed ? Color.red : Color.secondary).padding(.horizontal, 8)
                }
                if let result = run.result?.object, !result.isEmpty {
                    SectionLabel(text: "Result")
                    ForEach(result.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(key).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Text(result[key]!.inText).font(.system(size: 12)).textSelection(.enabled)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                if !run.input.isEmpty {
                    SectionLabel(text: "Input")
                    ForEach(run.input.keys.sorted(), id: \.self) { key in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(key).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                            Text(run.input[key]!.inText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                buttons(run)
            }
            .padding(10)
        }
    }

    private func header(_ run: TaskRun) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(run.state)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.task).font(.system(size: 13, weight: .medium))
                Text(run.state.text + (run.state.isGoing ? "" : run.endedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Text(run.trigger.startedBy + (run.trigger.parent.map { _ in " · step \(run.trigger.parentStep ?? "")" } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if run.state == .waiting { OrangeMark(text: "Needs you") }
        }
    }

    private func lineView(_ line: TaskRunLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.actor)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.tileFill, in: Capsule())
                .frame(width: 64, alignment: .trailing)
            Text(line.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let child = line.child, store.run(child) != nil {
                Button("Open") { board.showDetail(of: child) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
    }

    private func buttons(_ run: TaskRun) -> some View {
        HStack(spacing: 8) {
            Button("Back") { board.closeDetail() }
            if run.steps.contains(where: { $0.pane != nil }) {
                Button("Open tab") { board.refusal = model?.openTaskRunTab(run.id) }
            }
            if run.state.isGoing, let model {
                Button("Stop") { model.taskHost.stop(run.id) }
            }
            if run.steps.last?.state == .interrupted, let model {
                Button("Retry") { model.taskHost.advance(run.id, .retry) }
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    /// "New: a session wrote it" for a Task nobody has looked at, by contents: the Task's file is found again by name.
    private func markText(_ run: TaskRun) -> String? {
        guard let model, let file = TaskFiles.find(run.task, in: model.taskCatalog.files), let mark = grants.mark(of: file) else { return nil }
        return "\(mark.text): this Task's file hasn't been seen since it " + (mark == .new ? "appeared" : "changed") + ". Settings › Tasks has Seen."
    }

    private func color(_ state: RunState) -> Color {
        switch state {
        case .running: .blue
        case .waiting: .orange
        case .done, .message: .green
        case .stoppedAtLimit, .endedAfterWaiting, .couldntStart, .failed: .red
        case .skipped, .missed, .stopped: .secondary
        }
    }
}
