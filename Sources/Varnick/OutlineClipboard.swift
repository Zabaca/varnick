import Foundation

// The Outline's two clipboard forms (docs/problems/no-outline-in-varnick, option 01, Copying and pasting bullets): bullets as indented text, which any
// app can paste, and as Varnick's own copy, which keeps what text can't. Foundation only: it takes and returns text and data and never touches the
// pasteboard, so `--outline-check` runs it. The outline reads and writes the pasteboard.

/// One bullet to be made from a copy or a paste, with the bullets nested under it. It holds no ids: a paste always makes new bullets.
struct OutlineDraft: Equatable, Codable {
    var text: String
    var note: String?
    var completed: Date?
    /// The placement was collapsed.
    var collapsed: Bool
    var children: [OutlineDraft]

    init(text: String, note: String? = nil, completed: Date? = nil, collapsed: Bool = false, children: [OutlineDraft] = []) {
        self.text = text
        self.note = note
        self.completed = completed
        self.collapsed = collapsed
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case text, note, completed, collapsed, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        completed = try c.decodeIfPresent(Date.self, forKey: .completed)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        children = try c.decodeIfPresent([OutlineDraft].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(completed, forKey: .completed)
        if collapsed { try c.encode(true, forKey: .collapsed) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }
}

/// The one writer and reader of both forms. Panel access's `add` is to read indented text through `drafts(fromText:)`.
enum OutlineClipboard {
    /// The pasteboard type of Varnick's own copy.
    static let pasteboardType = "com.zabaca.varnick.outline"
    /// The own copy's version. A copy of another version is not read, and the paste falls back to the text.
    static let currentVersion = 1
    /// How many bullets a copy holds at most: a mirror nested under a copied bullet is written at every place it shows, which can multiply.
    static let copyLimit = 100_000

    // MARK: Writing

    /// The bullets at `run` (rows of `tree`), each with everything nested under it, whether it shows or not. `cutShort` is set when `copyLimit`
    /// left some out: such a copy must never be the one a cut deletes.
    static func drafts(of run: [OutlinePath], in tree: OutlineTree) -> (drafts: [OutlineDraft], cutShort: Bool) {
        var budget = copyLimit
        var cutShort = false
        let drafts = run.compactMap { path in tree.placement(at: path).flatMap { draft($0, in: tree, budget: &budget, cutShort: &cutShort) } }
        return (drafts, cutShort)
    }

    private static func draft(_ placement: OutlinePlacement, in tree: OutlineTree, budget: inout Int, cutShort: inout Bool) -> OutlineDraft? {
        guard let bullet = tree.bullets[placement.bullet] else { return nil }
        guard budget > 0 else {
            cutShort = true
            return nil
        }
        budget -= 1
        var children: [OutlineDraft] = []
        for child in bullet.children {
            if let made = draft(child, in: tree, budget: &budget, cutShort: &cutShort) { children.append(made) }
        }
        return OutlineDraft(text: bullet.text, note: bullet.note?.isEmpty == false ? bullet.note : nil, completed: bullet.completed,
                            collapsed: placement.collapsed == true && !children.isEmpty, children: children)
    }

    /// One line for each bullet: "- " and its text (a lone "-" for an empty one), two spaces in for each level. No note, completion or collapse.
    static func text(of drafts: [OutlineDraft]) -> String {
        var lines: [String] = []
        func walk(_ drafts: [OutlineDraft], depth: Int) {
            for draft in drafts {
                lines.append(String(repeating: "  ", count: depth) + (draft.text.isEmpty ? "-" : "- " + draft.text))
                walk(draft.children, depth: depth + 1)
            }
        }
        walk(drafts, depth: 0)
        return lines.joined(separator: "\n")
    }

    private struct Envelope: Codable {
        var version: Int
        var bullets: [OutlineDraft]
    }

    /// Varnick's own copy: JSON with a version, holding no ids.
    static func data(of drafts: [OutlineDraft]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Envelope(version: currentVersion, bullets: drafts))
    }

    // MARK: Reading

    /// The bullets of Varnick's own copy; nil for a version this build doesn't know and for data that doesn't decode.
    static func drafts(fromData data: Data) -> [OutlineDraft]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] as? Int == currentVersion else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Envelope.self, from: data))?.bullets
    }

    /// How many lines of `text` are not blank.
    static func lineCount(of text: String) -> Int { lines(of: text).count }

    /// The lines of `text` that are not blank.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Indented text from any app, or from the outline once its own copy is gone. Every line that isn't blank is a bullet. A line nests under the
    /// nearest line above it that is indented less, and lines indented alike are siblings; how much deeper doesn't matter. A tab counts as four
    /// spaces. After the indent one marker ("-", "*", "+" or "•", then a space or the end of the line) is dropped; numbers and checkboxes stay.
    static func drafts(fromText text: String) -> [OutlineDraft] {
        var texts: [String] = []
        var parents: [Int?] = []
        var open: [(indent: Int, node: Int)] = []
        for line in lines(of: text) {
            var indent = 0
            var rest = Substring(line)
            while let first = rest.first, first == " " || first == "\t" {
                indent += first == "\t" ? 4 : 1
                rest = rest.dropFirst()
            }
            if let marker = rest.first, "-*+•".contains(marker) {
                let after = rest.dropFirst()
                if after.isEmpty { rest = after } else if after.first == " " { rest = after.dropFirst() }
            }
            while let top = open.last, top.indent >= indent { open.removeLast() }
            parents.append(open.last?.node)
            texts.append(String(rest))
            open.append((indent, texts.count - 1))
        }
        var children = Array(repeating: [Int](), count: texts.count)
        var top: [Int] = []
        for (i, parent) in parents.enumerated() { if let parent { children[parent].append(i) } else { top.append(i) } }
        // A child comes after its parent, so building from the end has every child ready.
        var built = [OutlineDraft?](repeating: nil, count: texts.count)
        for i in stride(from: texts.count - 1, through: 0, by: -1) {
            built[i] = OutlineDraft(text: texts[i], children: children[i].compactMap { built[$0] })
        }
        return top.compactMap { built[$0] }
    }
}
