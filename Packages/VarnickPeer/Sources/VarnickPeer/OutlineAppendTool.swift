import Foundation

// `outline_append`, the one write an automation's run may make to the user's Outline (ADR 0040's amendment of 2026-10-29): the rules that need no
// Outline, shared by `Varnick --mcp` (which lists the tool) and the running Varnick (which checks the call), so `make check-slots` runs them. The
// server never reads or acts; `OutlineAppendAccess` in the app answers the call. Nothing here holds or logs a heading, a text or a note.

/// `outline_append(heading, text, note?)`: a new last bullet under the top-level bullet named `heading`, made at the end of the top level when there is
/// none. It answers the new bullet's id and whether the heading was made, and never returns anything of the Outline.
public enum OutlineAppendTool {
    public static let name = "outline_append"
    /// The command-line argument that adds the tool to a server's list.
    public static let argument = "--outline-append"
    /// The tool's name in Claude Code, which is what an automation's allowed tools must hold for a run to be given it.
    public static var qualifiedName: String { "mcp__\(MCPServer.name)__\(name)" }

    public static let headingLimit = 80
    public static let textLimit = 300
    /// The longest heading and text in UTF-8 bytes, beside their characters: a character can be a letter with any number of combining marks, so a
    /// count of characters alone bounds nothing.
    public static let headingByteLimit = 320
    public static let textByteLimit = 1_200
    /// The note's longest size in UTF-8 bytes.
    public static let noteByteLimit = 20_000

    /// Whether an automation's allowed tools name the tool, by its exact rule. A server-wide rule (`mcp__varnick`) does not: the tool is opt-in by name.
    public static func isNamed(in allowedTools: [String]) -> Bool {
        allowedTools.contains { $0.trimmingCharacters(in: .whitespaces) == qualifiedName }
    }

    /// A call's arguments, checked: the heading and text trimmed, the note left as given (empty is none).
    public struct Entry: Equatable {
        public var heading: String
        public var text: String
        public var note: String?

        public init(heading: String, text: String, note: String?) {
            self.heading = heading
            self.text = text
            self.note = note
        }
    }

    /// The call's entry, or every problem with its arguments, one sentence each. Nothing has been changed when there are problems.
    public static func entry(heading: String?, text: String?, note: String?) -> (entry: Entry?, problems: [String]) {
        var problems: [String] = []
        func line(_ field: String, _ value: String?, limit: Int, byteLimit: Int) -> String {
            let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                problems.append("\(field) is required: 1 to \(limit) characters on one line")
            } else if trimmed.count > limit {
                problems.append("\(field) is \(trimmed.count) characters: it takes 1 to \(limit)")
            } else if trimmed.utf8.count > byteLimit {
                problems.append("\(field) is \(trimmed.utf8.count) bytes: it takes at most \(byteLimit) bytes as well as \(limit) characters")
            } else if trimmed.unicodeScalars.contains(where: isLineBreak) {
                problems.append("\(field) is one line with no line breaks")
            } else if trimmed.unicodeScalars.contains(where: isControl) {
                problems.append("\(field) can't hold tabs or other control characters")
            }
            return trimmed
        }
        let heading = line("heading", heading, limit: headingLimit, byteLimit: headingByteLimit)
        let text = line("text", text, limit: textLimit, byteLimit: textByteLimit)
        var kept: String?
        if let note, !note.isEmpty {
            if note.utf8.count > noteByteLimit {
                problems.append("note is \(note.utf8.count) bytes: it takes at most \(noteByteLimit)")
            } else if note.unicodeScalars.contains(where: { isControl($0) && $0 != "\n" && $0 != "\r" }) {
                problems.append("note can't hold tabs or other control characters (line breaks are fine)")
            }
            kept = note
        }
        return problems.isEmpty ? (Entry(heading: heading, text: text, note: kept), []) : (nil, problems)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool { scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value) }

    /// A scalar a text view takes as the end of a line: the ASCII breaks, next line (U+0085) and the line and paragraph separators. Tested on scalars,
    /// not characters, so a combining mark after one can't hide it.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool { (0x0a...0x0d).contains(scalar.value) || [0x85, 0x2028, 0x2029].contains(scalar.value) }

    /// The tool as `tools/list` gives it.
    public static let tool: [String: Any] = [
        "name": name,
        "description": "Files one bullet in the user's Outline, which lives on this Mac, without reading it. It finds the top-level bullet whose text is "
            + "exactly `heading` (case matters), makes it at the end of the top level if there is none, and adds a new last bullet under it with `text` "
            + "and the optional `note` (put a table or the full result in the note and a one-line summary in the text). It answers only the new "
            + "bullet's id and whether the heading was made: it reads, lists, moves, changes and deletes nothing else, so you cannot check the Outline "
            + "afterwards. One call adds one bullet. `heading` is 1 to \(headingLimit) characters, `text` 1 to \(textLimit), both on one line; `note` "
            + "is at most \(noteByteLimit) bytes and may have line breaks; `heading` and `text` are also at most \(headingByteLimit) and \(textByteLimit) bytes. A call that breaks a limit changes nothing and names each one, and so does one whose heading is marked done. It is refused "
            + "while the user has the Outline switched off in Varnick's Settings, or when its file can't be read. The user sees what you write, on "
            + "this Mac and on their Phone page, as a bullet like their own: write only what they asked this automation for.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "heading": ["type": "string", "description": "The top-level bullet to file it under, by its exact text, 1 to \(headingLimit) characters, one line. Made if absent."],
                "text": ["type": "string", "description": "The new bullet's text, 1 to \(textLimit) characters, one line."],
                "note": ["type": "string", "description": "Optional: the bullet's note, at most \(noteByteLimit) bytes, line breaks allowed."],
            ],
            "required": ["heading", "text"],
        ] as [String: Any],
    ]
}
