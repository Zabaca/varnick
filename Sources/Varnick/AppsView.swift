import AppKit
import SwiftUI

extension AppCatalog.Places {
    /// This Mac's: the release's catalog (the resource folder, so a checkout build and the app read one path), the user's apps and skills.
    static func live(running: Set<String>) -> AppCatalog.Places {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return AppCatalog.Places(
            catalog: ResourceFolder.current.folder.appendingPathComponent("apps", isDirectory: true),
            apps: home.appendingPathComponent(".varnick/custom-apps", isDirectory: true),
            skills: home.appendingPathComponent(".claude/skills", isDirectory: true),
            trash: { url in
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                return result as URL?
            },
            running: running)
    }
}

extension AppCatalog {
    /// Launch: refreshes the installed apps whose catalog entry changed, off the main thread, once the saved tabs are restored.
    static func refreshAtLaunch(running: Set<String>) {
        Task.detached(priority: .utility) {
            for (name, outcome) in refresh(.live(running: running)) {
                switch outcome {
                case .updated: NSLog("Varnick: updated the catalog app \(name)")
                case .waiting: NSLog("Varnick: the catalog app \(name) has an update that waits for its panes to close")
                case .failed(let reason): NSLog("Varnick: updating the catalog app \(name) failed: \(reason)")
                }
            }
        }
    }
}

/// Settings › Apps: one switch per app. The rows are read from disk each time the section shows and after each change. Reading, and a
/// switch's copy or move to the Trash, run off the main thread (a catalog app's folder can hold many files); the row's switch waits.
struct AppsSettingsView: View {
    let openAppFolders: () -> Set<String>
    @State private var rows: [AppCatalog.Row] = []
    @State private var running: Set<String> = []
    /// What the last try on an app was refused or failed for, by app; cleared by the next change to it.
    @State private var messages: [String: String] = [:]
    /// Apps whose switch is being worked on.
    @State private var busy: Set<String> = []
    /// Counts reads, so a slow one that finishes late doesn't replace a newer one.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("These apps come from Varnick's catalog: reviewed in its repository and shipped with this release. Turning one on copies it into your custom apps, so it shows in the split picker in every project.")
                Text("An app runs with your rights, and its panes have Varnick's macOS permissions. Apps need Bun.")
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.bottom, 6)
            if rows.isEmpty {
                Text("This release has no apps in its catalog.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
            }
            ForEach(rows) { row in
                CatalogAppRow(row: row, note: notes(for: row), busy: busy.contains(row.id),
                              isOn: Binding(get: { row.state == .on }, set: { change(row, to: $0) }))
            }
            HStack(spacing: 12) {
                Text("To make an app of your own, ask Claude in a session to make a custom app.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer(minLength: 16)
                Button("Show apps folder") { showAppsFolder() }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .onAppear { reload() }
    }

    private func reload() {
        let running = openAppFolders()
        generation += 1
        let mine = generation
        Task { @MainActor in
            let read = await Task.detached(priority: .userInitiated) { AppCatalog.rows(.live(running: running)) }.value
            guard mine == generation else { return }
            self.running = running
            rows = read
        }
    }

    /// What a row says under its description, orange for a refusal or failure.
    private func notes(for row: AppCatalog.Row) -> [(text: String, orange: Bool)] {
        let name = row.entry.folderName
        var notes: [(String, Bool)] = []
        if let message = messages[name] { notes.append((message, true)) }
        if row.state == .userApp { notes.append(("A custom app of yours has this name, so it can't be turned on. Rename or remove yours first.", true)) }
        if !row.inCatalog { notes.append(("This release's catalog no longer has it. It stays until you turn it off.", false)) }
        if row.state == .on {
            notes.append(("Edits to the installed copy are replaced at the next update. To change the app, copy it under another name.", false))
        }
        if let failure = row.refreshFailure {
            notes.append(("The last update failed: \(failure). It tries again at the next launch.", true))
        } else if row.updatePending {
            notes.append((running.contains(name) ? "A newer version waits for its panes to close, and installs at the next launch after."
                                                 : "A newer version installs at the next launch.", false))
        }
        if row.skillNotLinked { notes.append(("Its skill isn't linked: something else is at ~/.claude/skills/\(name).", true)) }
        return notes
    }

    private func change(_ row: AppCatalog.Row, to on: Bool) {
        let name = row.entry.folderName
        guard !busy.contains(name) else { return }
        messages[name] = nil
        busy.insert(name)
        let running = openAppFolders()
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> AppCatalog.Change in
                let places = AppCatalog.Places.live(running: running)
                return on ? AppCatalog.turnOn(name, places) : AppCatalog.turnOff(name, places)
            }.value
            switch result {
            case .turnedOn, .alreadyOn, .turnedOff, .notInstalled: break
            case .userApp: messages[name] = "A custom app of yours has this name."
            case .panesOpen: messages[name] = "Close the panes that run it first, then turn it off."
            case .failed(let reason): messages[name] = "\(on ? "Couldn't turn it on" : "Couldn't turn it off"): \(reason)"
            }
            busy.remove(name)
            reload()
        }
    }

    /// Makes the folder first when nothing has been installed or made yet, so there is something to show.
    private func showAppsFolder() {
        let folder = AppCatalog.Places.live(running: []).apps
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// A catalog app's row, built like `SettingRow` with its icon, the manifest's description and what it fetches.
private struct CatalogAppRow: View {
    let row: AppCatalog.Row
    let note: [(text: String, orange: Bool)]
    let busy: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: CustomApp.symbol(for: row.entry.icon)).font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.entry.name).font(.system(size: 13, weight: .medium))
                if !row.entry.description.isEmpty {
                    Text(row.entry.description).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text(row.entry.network.isEmpty ? "Network use: none declared" : "Fetches: \(row.entry.network)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(Array(note.enumerated()), id: \.offset) { _, item in
                    Text(item.text).font(.system(size: 11.5)).foregroundStyle(item.orange ? Color.orange : Color.secondary)
                }
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(row.state == .userApp || busy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
