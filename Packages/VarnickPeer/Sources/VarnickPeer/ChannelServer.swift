import Foundation

// The channel server (option 01 of `sessions-cant-reach-each-other-reliably`): the MCP server the plugin Varnick loads into each Claude pane runs
// (`Varnick --channel --pane <id>`). It lists no tools. It declares Claude Code's `claude/channel` capability and pushes each message that waits in its
// pane's queue (`MessageQueue`) as a `notifications/claude/channel` line, in order, once Claude Code has said it is initialized. It never reads or acts
// on anything but its pane's queue. Its standard output is the protocol, so the replies and the pushes are written one line at a time under one lock.

public enum ChannelServer {
    /// Claude Code skips a channel on a connection of this protocol revision or later ("has no unsolicited notification path"): the server never agrees to
    /// one, and it keeps the older revision by answering `server/discover`, which Claude Code asks first, with "method not found".
    public static let firstUnsupportedRevision = "2026-07-28"

    public static let capability = "claude/channel"
    public static let notificationMethod = "notifications/claude/channel"

    /// The reply to one JSON-RPC message: `initialize` with the capability and the instructions, `tools/list` with no tools and `ping`; "method not found"
    /// for the rest, `server/discover` included; nil for a notification.
    public static func answer(_ line: String) -> [String: Any]? {
        MCPServer.answer(line, tools: [], experimental: [capability: [String: Any]()], instructions: SessionMessage.instructions) { _, _ in nil }
    }

    /// The line that pushes a message to the session: the text as `content`, the two attributes as `meta`.
    public static func notification(for message: SessionMessage.Queued) -> [String: Any] {
        ["jsonrpc": "2.0", "method": notificationMethod, "params": ["content": message.text, "meta": message.attributes]]
    }

    /// Whether a JSON-RPC line is the client's notice that it is initialized: the earliest a push is read.
    public static func isInitialized(_ line: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
        return object["id"] == nil && object["method"] as? String == "notifications/initialized"
    }

    private static let output = NSLock()

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        output.lock()
        defer { output.unlock() }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// How often the queue is looked at.
    public static let poll: TimeInterval = 0.25

    nonisolated(unsafe) private static var initialized = false
    private static let state = NSLock()

    /// Runs until standard input ends; the exit status is 0. The server's mark is written at once and dated again every `MessageQueue.beat`, and removed
    /// at the end.
    public static func run(pane: UUID) -> Int32 {
        MessageQueue.writeMark(for: pane)
        let pusher = Thread {
            var lastBeat = Date()
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: poll)
                if Date().timeIntervalSince(lastBeat) >= MessageQueue.beat {
                    MessageQueue.writeMark(for: pane)
                    lastBeat = Date()
                }
                push(pane)
            }
        }
        pusher.start()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if isInitialized(line) {
                state.lock()
                initialized = true
                state.unlock()
                push(pane)
            }
            if let reply = answer(line) { write(reply) }
        }
        pusher.cancel()
        MessageQueue.removeMark(for: pane)
        return 0
    }

    private static let pushing = NSLock()

    /// Hands each waiting message to Claude Code in order and removes it after the line is written. A push waits until the client is initialized.
    private static func push(_ pane: UUID) {
        state.lock()
        let ready = initialized
        state.unlock()
        guard ready else { return }
        pushing.lock()
        defer { pushing.unlock() }
        for (file, message) in MessageQueue.pending(for: pane) {
            write(notification(for: message))
            try? FileManager.default.removeItem(at: file)
        }
    }
}
