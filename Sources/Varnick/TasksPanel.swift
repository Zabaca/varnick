import AppKit
import Carbon
import SwiftUI
import VarnickPeer

// The Tasks view (`!task`; option 01 of `work-cant-be-saved-or-chained`, slice 2a): in place of the panel's content, as Resources is. On this site comes
// first and opens the Website pane at once, as `!task` always has. The Tasks found from the focused pane's folder follow; an invalid one is dimmed and
// shows its problems. ↩ on a Task shows its form, drawn from its input schema; ↩ on the form checks the input and either names each wrong field or
// starts the Run, which the Runs tab shows.

@MainActor
final class TasksPanel: ObservableObject {
    weak var model: LauncherModel?

    /// A row of the list: On this site, or a Task file.
    enum Choice: Hashable {
        case site
        case task(String)
    }

    @Published var selection: Choice = .site
    /// The Task whose form shows; nil shows the list.
    @Published private(set) var formFile: TaskFile?
    /// What was typed, by field.
    @Published var values: [String: String] = [:]
    /// Why the form was not accepted, one line each.
    @Published private(set) var problems: [String] = []
    /// Why the chosen Task can't start.
    @Published private(set) var note: String?

    /// The folder the Tasks are found from: the focused pane's, or Home with no tab.
    var folder: String { model?.activeTab?.focused.record.directory ?? HomeFolder.path }

    func appear() {
        selection = .site
        formFile = nil
        problems = []
        note = nil
        model?.taskCatalog.refresh(from: folder)
    }

    func close() {
        formFile = nil
        values = [:]
        problems = []
        note = nil
    }

    /// The rows now: On this site, then the Tasks.
    var choices: [Choice] { [.site] + (model?.taskCatalog.files ?? []).map { .task($0.path) } }

    func file(at path: String) -> TaskFile? { model?.taskCatalog.files.first { $0.path == path } }

    // MARK: Keys

    /// ↑ and ↓ move, ↩ chooses, esc goes back; in a form only esc is taken, and ↩ is the field's own.
    func key(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection(KeyCombo.relevant).isEmpty
        guard plain else { return false }
        if formFile != nil {
            guard Int(event.keyCode) == kVK_Escape else { return false }
            back()
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape: model?.closeTasks()
        case kVK_UpArrow: move(-1)
        case kVK_DownArrow: move(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: choose(selection)
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        let rows = choices
        let at = rows.firstIndex(of: selection) ?? 0
        selection = rows[max(0, min(rows.count - 1, at + delta))]
        note = nil
    }

    func choose(_ choice: Choice) {
        selection = choice
        note = nil
        switch choice {
        case .site:
            model?.openTask()
        case .task(let path):
            guard let file = file(at: path) else { return }
            guard file.isValid else {
                note = "\(file.name) can't start until its problems are fixed."
                return
            }
            values = [:]
            problems = []
            formFile = file
        }
    }

    func back() {
        formFile = nil
        problems = []
    }

    // MARK: The form

    /// Checks what was typed against the Task's input schema: each wrong field is named under the form, or the Run starts and the Runs tab shows it.
    func submit() {
        guard let model, let file = formFile, let schema = file.definition?.input else { return }
        var input: [String: TaskValue] = [:]
        var found: [String] = []
        for field in schema.formFields {
            let typed = values[field.name] ?? ""
            let read = field.schema.value(fromText: typed)
            if let problem = read.problem {
                found.append("\(field.name) \(problem)")
            } else if let value = read.value {
                input[field.name] = value
            }
        }
        guard found.isEmpty else { return problems = found }
        switch model.taskHost.startRun(file, input: input, trigger: .byHand(at: Date()), folder: folder) {
        case .failure(let refusal):
            problems = refusal.problems
        case .success(let id):
            model.hideTasks()
            model.showBoard(.runs)
            model.board.runs.refresh()
            model.board.runs.selection = id
        }
    }
}

struct TasksView: View {
    @ObservedObject var panel: TasksPanel
    @ObservedObject var catalog: TaskCatalog
    @ObservedObject private var grants = TaskGrants.shared
    let close: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text(panel.formFile?.name ?? "Tasks").font(.system(size: 15, weight: .semibold))
                Spacer()
                if panel.formFile == nil {
                    KeyHint(label: "Choose", keys: ["↩"])
                }
                Button(action: { if panel.formFile != nil { panel.back() } else { close() } }) { KeyHint(label: "Back", keys: ["esc"]) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, Theme.gutter)
            .frame(height: LauncherModel.searchHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)

            if let file = panel.formFile, let schema = file.definition?.input {
                form(file, schema)
            } else {
                list
            }
        }
    }

    // MARK: The list

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                row(.site, title: TaskController.running == nil ? "On this site" : "Show the running one", detail: "A Website pane: a browser of Varnick's own where it works toward a goal on a site, step by step.",
                    problems: [], mark: nil)
                if catalog.reading, catalog.files.isEmpty {
                    Text("Looking for Tasks…").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.top, 8)
                }
                ForEach(catalog.files) { file in
                    row(.task(file.path), title: file.name, detail: file.definition?.summary.nilIfBlank ?? (file.isValid ? "" : "Not valid"),
                        problems: file.isValid ? [] : file.problems, mark: grants.mark(of: file)?.text)
                }
                if catalog.files.isEmpty, !catalog.reading {
                    Text("No Tasks are saved yet. A Task is a JSON file in .varnick/tasks of a project or in your own ~/.varnick/tasks: ask Claude to write one, and it is checked as it is read.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 8)
                }
                if let note = panel.note {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.top, 4)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ choice: TasksPanel.Choice, title: String, detail: String, problems: [String], mark: String?) -> some View {
        let selected = panel.selection == choice
        let dimmed = !problems.isEmpty
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: choice == .site ? "globe" : "list.bullet.rectangle").foregroundStyle(.secondary).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let mark { WordBadge(text: mark) }
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(problems, id: \.self) { problem in
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.selection : Theme.tileFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.primary.opacity(0.26) : Theme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.7 : 1)
        .onTapGesture { panel.choose(choice) }
    }

    // MARK: The form

    private func form(_ file: TaskFile, _ schema: TaskSchema) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let summary = file.definition?.summary.nilIfBlank {
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if schema.formFields.isEmpty {
                    Text("This Task takes no input.").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                ForEach(schema.formFields, id: \.name) { field in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(field.name + (field.isRequired ? " *" : "")).font(.system(size: 11.5, weight: .medium))
                        TextField(hint(field.schema), text: Binding(get: { panel.values[field.name] ?? "" }, set: { panel.values[field.name] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: field.name)
                            .onSubmit { panel.submit() }
                        if let summary = field.schema.summary {
                            Text(summary).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                ForEach(panel.problems, id: \.self) { problem in
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Start") { panel.submit() }
                    Button("Back") { panel.back() }
                    Text("Claude steps draw on your Claude subscription; nothing opens, and the Runs tab shows the Run.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = schema.formFields.first?.name }
    }

    /// What an empty field says: the type, and the options of an enum.
    private func hint(_ schema: TaskSchema) -> String { schema.word }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
