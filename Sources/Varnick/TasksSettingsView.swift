import SwiftUI
import VarnickPeer

/// Settings › Tasks (option 01 of `work-cant-be-saved-or-chained`, slice 2a). Only while Tasks is on in Settings › Experimental. Each Task found from the
/// focused pane's folder and the user's own, with its mark (New or Changed by its contents, until Seen), its problems, and the grants of its Claude steps:
/// Varnick's setting by default, or Ask, Allowed tools only or Skip, and the allowed tools. A file can't grant itself anything, and a Task that is new or
/// changed since it was seen runs with Varnick's setting in place of Skip.
struct TasksSettingsView: View {
    @ObservedObject var catalog: TaskCatalog
    let model: LauncherModel
    @ObservedObject private var grants = TaskGrants.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A Task is a saved, named series of steps (Claude, Judge, Notify, another Task) with a typed input and result, written as a JSON file in a project's .varnick/tasks or in your own ~/.varnick/tasks and checked when it is read. !task lists them, asks for the input of one and starts a Run, and a Claude session can list, check and start them through Varnick's tools. The grants below are yours alone, kept here and never in the file: they govern the Claude steps of that Task. A Task that is new or changed since you pressed Seen runs with Varnick's Skip permissions setting in place of Skip, so a session that edits a Task you gave Skip can't give the new contents Skip.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            if let problem = model.taskRuns.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            SectionLabel(text: catalog.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Tasks")
            if catalog.files.isEmpty {
                Text(catalog.reading ? "Looking for Tasks…" : "No Tasks found from here.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 8)
            }
            ForEach(catalog.files) { file in
                TaskGrantRow(file: file, grants: grants)
            }
        }
        .onAppear { catalog.refresh(from: model.tasksPanel.folder) }
    }
}

private struct TaskGrantRow: View {
    let file: TaskFile
    @ObservedObject var grants: TaskGrants
    @State private var toolsText = ""

    private var grant: TaskGrant { grants.grant(for: file.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(file.name).font(.system(size: 13, weight: .medium))
                if let mark = grants.mark(of: file) {
                    WordBadge(text: mark.text)
                    Button("Seen") { grants.markSeen(file) }.controlSize(.small)
                }
                Spacer()
            }
            Text((file.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11)).foregroundStyle(.tertiary)
            if let summary = file.definition?.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            ForEach(file.problems, id: \.self) { problem in
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if file.isValid {
                HStack(spacing: 8) {
                    Text("Claude steps").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { grant.permissions?.rawValue ?? "" }, set: { choice in
                        var next = grant
                        next.permissions = AutomationPermissions(rawValue: choice)
                        grants.setGrant(next, for: file.path)
                    })) {
                        Text("Follow Varnick's Skip permissions setting").tag("")
                        ForEach(AutomationPermissions.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                }
                if grant.permissions == .skip, grants.mark(of: file) != nil {
                    Text("Skip applies once you have seen these contents: until then this Task follows Varnick's setting.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
                TextField("Allowed tools, one rule a line (Bash(git status), Edit)", text: $toolsText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .onChange(of: toolsText) { _, text in
                        var next = grant
                        next.allowedTools = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        grants.setGrant(next, for: file.path)
                    }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .onAppear { toolsText = grant.allowedTools.joined(separator: "\n") }
    }
}
