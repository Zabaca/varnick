import Foundation

// The plugin folder Varnick keeps for its channel (option 01 of `sessions-cant-reach-each-other-reliably`): a manifest and one server, `channel`, which is
// Varnick's own binary in its channel mode. Written at each launch when it differs; loaded into a Claude pane with `--plugin-dir`, never installed into
// Claude Code, so a session outside Varnick never loads it. The server gets its pane's id from the pane's environment.

public enum ChannelPlugin {
    /// The folder's name in Varnick's support folder.
    public static let folderName = "channel-plugin"

    public static var folder: URL {
        SupportFolder.url.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The channel server's arguments after the binary; `${VARNICK_PANE_ID}` is expanded by Claude Code from the pane's environment, so `ps` shows the
    /// pane's id as it does for the tool server.
    public static let serverArguments = ["--channel", "--pane", "${VARNICK_PANE_ID}"]

    /// The plugin's files by path inside the folder, as bytes. `command` is the absolute path of the binary the server runs, written on this Mac at run time.
    /// `name` is the plugin's name, which only a check changes (to borrow a name the machine already approves).
    public static func files(command: String, name: String = SessionMessage.pluginName) -> [String: Data] {
        func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])) ?? Data()
        }
        return [
            ".claude-plugin/plugin.json": json(["name": name, "version": "1",
                                                "description": "Varnick's channel: pushes messages from the user's other sessions into this one. Loaded by Varnick for its own panes only."]),
            ".mcp.json": json(["mcpServers": [SessionMessage.serverName: ["command": command, "args": serverArguments]]]),
        ]
    }

    /// Writes what differs, by rename; a file the plugin doesn't have is left alone. Returns whether anything was written. Failures are not thrown:
    /// the channel is then missing from panes, which the checklist's test shows.
    @discardableResult
    public static func write(to folder: URL = folder, command: String, name: String = SessionMessage.pluginName) -> Bool {
        var wrote = false
        for (path, data) in files(command: command, name: name) {
            let file = folder.appendingPathComponent(path)
            if (try? Data(contentsOf: file)) == data { continue }
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
                try data.write(to: temporary)
                guard rename(temporary.path, file.path) == 0 else { try? FileManager.default.removeItem(at: temporary); continue }
                wrote = true
            } catch {
                continue
            }
        }
        return wrote
    }
}
