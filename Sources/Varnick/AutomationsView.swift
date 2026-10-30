import SwiftUI
import VarnickPeer

/// Settings › Automations (option 01 of `prompts-cant-run-on-a-schedule`, slice 1: this Mac).
/// The list of this Mac's automations with each one's switch, next run, last outcome and Run now, and an editor for the fields.
struct AutomationsSettingsView: View {
    @ObservedObject var store: AutomationStore
    /// Their Runs, which each row's status reads and which can stop every check as the automations file can.
    @ObservedObject var runStore: TaskRunStore
    let model: LauncherModel
    @ObservedObject private var settings = Settings.shared
    /// The headless hosts' automations (protocol 29): their sections, and the editor when one is being edited there.
    @ObservedObject private var hostStore = HostAutomationStore.shared
    @State private var editing: Automation?
    @State private var editingIsNew = false
    /// What Run now answered, by automation: a refusal, or why the run could not start.
    @State private var notes: [UUID: String] = [:]
    /// The automation whose Delete was pressed once: the row asks, and a second press does it.
    @State private var confirmingDelete: UUID?

    /// Either file can't be read: nothing is run, saved or deleted (read through the stores this view observes, so it redraws when one changes).
    private var blocked: Bool { model.automationFilesProblem != nil }

    var body: some View {
        if let draft = editing {
            AutomationEditor(draft: draft, isNew: editingIsNew, projects: model.projects, onSave: { saved, resetsAnchor in
                if editingIsNew {
                    store.save(saved)
                } else {
                    // Only the fields the editor has go to the automation as it is now: the slot a check fired for since Edit was pressed is the
                    // store's, not the draft's.
                    store.update(saved.id) { current in
                        current.name = saved.name
                        current.prompt = saved.prompt
                        current.folder = saved.folder
                        current.agent = saved.agent
                        current.cadence = saved.cadence
                        current.timeZone = saved.timeZone
                        current.permissions = saved.permissions
                        current.allowedTools = saved.allowedTools
                        current.workingLimitMinutes = saved.workingLimitMinutes
                        // A new cadence or zone starts from now: the slots before it are not caught up.
                        if resetsAnchor { current.lastSlot = Date() }
                    }
                }
                editing = nil
            }, onCancel: { editing = nil })
        } else if let remote = hostStore.editing {
            AutomationEditor(draft: remote.draft, isNew: remote.isNew, projects: [], remote: remote,
                             onSave: { saved, _ in Task { await hostStore.saveEditing(saved) } }, onCancel: { hostStore.editing = nil })
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Each automation is a prompt this Mac's Varnick starts as a Claude session on a cadence, in a folder of yours, out of sight until you open it from the board's Runs tab or a notice; a slot missed by under 12 hours runs at the next wake or launch. Each run draws on your Claude plan, and one run of an automation goes at a time. Sessions can list, make, edit and switch these, and a mark shows what they did until you open, switch or press Seen; only you can delete one, run one now or set Skip.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            if let problem = store.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if let problem = runStore.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            ForEach([store.writeError, runStore.writeError].compactMap { $0 }, id: \.self) { error in
                Text(error).font(.system(size: 11.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            if !Zmx.isEnabled {
                Text("Keep sessions running is off, so a due run is recorded as one that couldn't start. Turn it on in Settings › Claude.")
                    .font(.system(size: 11.5)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
            }
            SectionLabel(text: PeerIdentity.name ?? "This Mac")
            if store.automations.isEmpty {
                Text("No automations yet.").font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 8)
            }
            ForEach(store.automations) { automation in
                row(automation)
            }
            HStack {
                Button("New automation") {
                    editingIsNew = true
                    editing = Automation(name: "", prompt: "", cadence: .daily(hour: 9, minute: 0))
                }
                .disabled(blocked)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            HostAutomationSections()
        }
    }

    private func row(_ automation: Automation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(automation.name.isEmpty ? "Untitled" : automation.name).font(.system(size: 13, weight: .medium))
                    Text(summary(automation)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Text(status(automation)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    if let mark = automation.mark {
                        // What a Claude session did to it through the automation tools: the only notice of it, until seen.
                        HStack(spacing: 8) {
                            Text(mark.line).font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                            Button("Seen") { store.update(automation.id) { $0.mark = nil } }
                                .controlSize(.small).disabled(blocked)
                        }
                    }
                }
                Spacer(minLength: 12)
                Button("Run now") { notes[automation.id] = model.runNow(automation.id) }
                    .disabled(blocked)
                Button("Edit") {
                    editingIsNew = false
                    // Opening the editor is seeing the mark.
                    store.update(automation.id) { $0.mark = nil }
                    editing = automation
                }
                .disabled(blocked)
                Button("Delete") { confirmingDelete = automation.id }
                    .disabled(blocked)
                Toggle("", isOn: Binding(get: { automation.enabled }, set: { on in
                    store.update(automation.id) { next in
                        next.enabled = on
                        next.mark = nil
                        // Switched on: nothing before now is caught up.
                        if on { next.lastSlot = Date() }
                    }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(blocked)
            }
            if let note = notes[automation.id] {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if confirmingDelete == automation.id {
                HStack(spacing: 8) {
                    Text("Delete \(automation.name.isEmpty ? "this automation" : "\"\(automation.name)\"") and its run list? A run still going stays as an ordinary tab.")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Button("Keep") { confirmingDelete = nil }
                    Button("Delete") {
                        confirmingDelete = nil
                        notes[automation.id] = nil
                        model.deleteAutomation(automation.id)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// "Daily at 9:00 · ~/Projects/x · @reviewer · Ask": the cadence, the folder, the agent and the permissions when it overrides Varnick's.
    private func summary(_ automation: Automation) -> String {
        var parts = [automation.cadence.label]
        parts.append(automation.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Home")
        if let agent = automation.agent { parts.append("@" + agent) }
        if let permissions = automation.permissions { parts.append(permissions.title) }
        return parts.joined(separator: " · ")
    }

    private func status(_ automation: Automation) -> String {
        var parts: [String] = []
        if !automation.enabled {
            parts.append("Off")
        } else if let next = AutomationSlot.next(automation.cadence, zone: automation.zone, after: Date()) {
            parts.append("Next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let last = runStore.runs(of: automation.id).first {
            // As last recorded (the check brings it up to date once a minute): the turn is read where a list is refreshed, never while one is drawn.
            parts.append("Last: " + (last.state == .message ? last.detail ?? last.state.text : last.state.text))
        }
        return parts.joined(separator: " · ")
    }
}

/// The fields of an automation: what Claude is asked, where, how often and with which permissions.
private struct AutomationEditor: View {
    @State var draft: Automation
    let isNew: Bool
    let projects: [Project]
    /// Set when the automation lives on a headless host: its folders and agents, its Skip permissions, and the host's refusal of the last Save.
    var remote: HostAutomationStore.Editing?
    /// The edited automation and whether its slots start from now (a new cadence or zone).
    let onSave: (Automation, Bool) -> Void
    let onCancel: () -> Void
    @ObservedObject private var settings = Settings.shared

    /// Cadence kinds the picker offers, with the values each takes held apart so switching back and forth keeps them.
    private enum Kind: String, CaseIterable, Identifiable {
        case minutes, hours, daily, weekdays, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .minutes: "Every few minutes"
            case .hours: "Every few hours"
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            }
        }
    }

    @State private var kind: Kind = .daily
    @State private var minuteStep = 15
    @State private var hourStep = 1
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 2
    @State private var toolsText = ""
    @State private var loaded = false
    /// The agents of the chosen folder, read when the editor opens and when the folder changes, never while the view is drawn.
    @State private var agentNames: [String] = []
    @State private var trustNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field("Name", detail: "Shown in the notice, the tab and the Runs tab.") {
                TextField("Morning summary", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 260)
            }
            field("Prompt", detail: "Goes to Claude as written, as the first message. To be told the result, say so in it (\"…and notify me with the count\").") {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 320, height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
            }
            field("Folder", detail: remote != nil ? "A project on the host, or Home, Varnick's own folder there for sessions that belong to no project. The host checks the folder, the agent and Claude Code's trust of it when you save."
                  : "A project, or Home, Varnick's own folder for sessions that belong to no project." + (trustNote.map { " " + $0 } ?? "")) {
                Picker("", selection: Binding(get: { draft.folder ?? "" }, set: { draft.folder = $0.isEmpty ? nil : $0 })) {
                    Text("Home").tag("")
                    ForEach(folders, id: \.self) { path in Text((path as NSString).abbreviatingWithTildeInPath).tag(path) }
                }
                .labelsHidden().frame(width: 260)
            }
            field("Agent", detail: remote != nil ? "A Claude Code agent of that folder on the host, or none."
                  : "A Claude Code agent of that folder, or none. Home has only your own, so to use a repo's agent, choose that repo as the folder.") {
                Picker("", selection: Binding(get: { draft.agent ?? "" }, set: { draft.agent = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    ForEach(agentNames, id: \.self) { name in Text("@" + name).tag(name) }
                }
                .labelsHidden().frame(width: 260)
            }
            field("When", detail: "Presets only, shortest 15 minutes, in this Mac's time zone (\(TimeZone.current.identifier)).") {
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                    switch kind {
                    case .minutes:
                        Picker("Every", selection: $minuteStep) {
                            ForEach(AutomationCadence.minuteSteps, id: \.self) { Text("\($0) minutes").tag($0) }
                        }.frame(width: 200)
                    case .hours:
                        Picker("Every", selection: $hourStep) {
                            ForEach(AutomationCadence.hourSteps, id: \.self) { Text($0 == 1 ? "hour" : "\($0) hours").tag($0) }
                        }.frame(width: 200)
                    case .daily, .weekdays, .weekly:
                        HStack(spacing: 6) {
                            if kind == .weekly {
                                Picker("", selection: $weekday) {
                                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                                }.labelsHidden().frame(width: 120)
                            }
                            Text("at")
                            Picker("", selection: $hour) {
                                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                            }.labelsHidden().frame(width: 64)
                            Text(":")
                            Picker("", selection: $minute) {
                                ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                            }.labelsHidden().frame(width: 64)
                        }
                    }
                }
            }
            field("Permissions", detail: permissionsDetail) {
                Picker("", selection: Binding(get: { draft.permissions?.rawValue ?? "" }, set: { draft.permissions = AutomationPermissions(rawValue: $0) })) {
                    Text(remote != nil ? "The host's setting (Skip permissions \(remote?.skipPermissions == true ? "on" : "off"))"
                         : "Varnick's setting (Skip permissions \(settings.skipPermissions ? "on" : "off"))").tag("")
                    ForEach(AutomationPermissions.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 260)
            }
            field("Allowed tools", detail: "Claude Code permission rules the run may use without asking, one a line (Bash(git status), Edit, WebSearch). They add to the ones you have.") {
                TextEditor(text: $toolsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 320, height: 56)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline))
            }
            field("Working limit", detail: "A run still working after this is ended; its conversation is kept, and opening it resumes it.") {
                Stepper(value: $draft.workingLimitMinutes, in: 5...1440, step: 5) {
                    Text("\(draft.workingLimitMinutes) minutes").font(.system(size: 11.5).monospacedDigit())
                }
                .frame(width: 200)
            }
            Text(warning)
                .font(.system(size: 11.5)).foregroundStyle(.orange)
                .padding(.horizontal, 14).padding(.vertical, 8)
            if let problem = remote?.problem {
                Text(problem).font(.system(size: 11.5)).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || remote?.saving == true)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear(perform: load)
        .onChange(of: draft.folder) { _, _ in readAgents() }
    }

    private func field<Content: View>(_ title: String, detail: String, @ViewBuilder _ content: () -> Content) -> some View {
        SettingRow(title: title, detail: detail) { content() }
    }

    /// The project folders, plus the folder the automation has if it is no longer one.
    private var folders: [String] {
        var paths = remote?.folders ?? projects.map(\.path)
        if let own = draft.folder, !paths.contains(own) { paths.insert(own, at: 0) }
        return paths
    }

    private func readAgents() {
        if let remote {
            // The host's agents come from the host, off the main actor; its own checks (trust, folder) are made when the host saves.
            let folder = draft.folder, host = remote.host
            Task {
                let found = await HostAutomationStore.shared.agents(in: folder, on: host)
                guard draft.folder == folder else { return }
                agentNames = draft.agent.map { own in found.contains(own) ? found : [own] + found } ?? found
            }
            return
        }
        let found = Agent.available(in: draft.folder ?? HomeFolder.path).map(\.name)
        agentNames = draft.agent.map { own in found.contains(own) ? found : [own] + found } ?? found
        trustNote = ClaudeTrust.note(for: draft.folder ?? HomeFolder.path)
    }

    /// What the run will start with, and the macOS grants it inherits (`panes-share-launchys-permissions`).
    private var permissionsDetail: String {
        switch draft.permissions {
        case nil: "Starts the way a prompt you type does: \(settings.skipPermissions ? "skipping permission checks, since Skip permissions is on" : "asking, since Skip permissions is off")."
        case .ask: "Claude's normal mode: the allowed tools run, anything else shows its dialog, and the run waits for you (Needs you)."
        case .allowedOnly: "Anything not allowed is refused with no dialog, and Claude goes on or ends; a run never waits on you for a permission. Claude Code's read-only tools and commands still run."
        case .skip: "Skips every permission check, whatever Skip permissions says."
        }
    }

    private var warning: String {
        if remote != nil {
            var text = "A run never gets Screen access or Panel access tools, and a headless host has no screen for a command to reach."
            let skips = draft.permissions == .skip || (draft.permissions == nil && remote?.skipPermissions == true)
            if skips { text += " With permission checks skipped every command the run tries is allowed, as the host's own user." }
            return text
        }
        var text = "A run never gets Screen access or Panel access tools. It does have this Mac's macOS permissions like every pane: a shell command it may run can reach the screen through Varnick's Accessibility and Screen Recording, with no tool for it."
        let skips = draft.permissions == .skip || (draft.permissions == nil && settings.skipPermissions)
        if skips { text += " With permission checks skipped that covers every command." }
        return text + " A headless host, which has no screen, will suit an automation that allows broad shell use once automations can run there."
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        readAgents()
        toolsText = draft.allowedTools.joined(separator: "\n")
        switch draft.cadence {
        case .minutes(let n): kind = .minutes; minuteStep = n
        case .hours(let n): kind = .hours; hourStep = n
        case .daily(let h, let m): kind = .daily; hour = h; minute = m
        case .weekdays(let h, let m): kind = .weekdays; hour = h; minute = m
        case .weekly(let d, let h, let m): kind = .weekly; weekday = d; hour = h; minute = m
        }
    }

    private func save() {
        var next = draft
        next.name = draft.name.trimmingCharacters(in: .whitespaces)
        next.allowedTools = toolsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cadence: AutomationCadence = switch kind {
        case .minutes: .minutes(minuteStep)
        case .hours: .hours(hourStep)
        case .daily: .daily(hour: hour, minute: minute)
        case .weekdays: .weekdays(hour: hour, minute: minute)
        case .weekly: .weekly(weekday: weekday, hour: hour, minute: minute)
        }
        let resets = cadence != draft.cadence || draft.timeZone != TimeZone.current.identifier || isNew
        next.cadence = cadence
        next.timeZone = TimeZone.current.identifier
        if isNew { next.lastSlot = Date() }
        onSave(next, resets)
    }
}
