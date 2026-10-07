import Foundation
import LaunchyPeer

extension PaneFolder {
    /// What the old `scratch` folder held at its root, shared by every pane's folder.
    private static let sharedFiles = ["package.json", "vite.config.ts", "deno.lock", "node_modules"]

    /// Once, on the first launch after built-in Scratch went (ADR 0005): `scratch` becomes `panes`, and
    /// a link stays under the old name. Claude panes kept running in zmx from before have `scratch/<id>`
    /// in their environment, and their hook keeps writing the conversation file Launchy reads there.
    /// The shared files go; a pane's own folder is never touched. The link can go once no pane from
    /// before is running.
    static func migrateOldScratchFolder(in support: URL = SupportFolder.url) {
        let fm = FileManager.default
        let old = support.appendingPathComponent("scratch", isDirectory: true)
        let new = support.appendingPathComponent("panes", isDirectory: true)
        // The link counts as present too: fileExists follows it, so a second run does nothing.
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do { try fm.moveItem(at: old, to: new) } catch { return }
        try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: "panes")
        for file in sharedFiles { try? fm.removeItem(at: new.appendingPathComponent(file)) }
    }
}
