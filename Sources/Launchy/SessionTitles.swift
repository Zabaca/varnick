import Foundation
import LaunchyPeer

/// What a pane keeps of a conversation's title (`SessionRecord.titleRecord`): the title text generation wrote for
/// it, or a mark that it wrote none, so the conversation is never asked about again.
struct TitleRecord: Codable, Equatable {
    /// The conversation it is for; the pane's next one (after /clear or /resume) has none yet.
    var conversation: String
    var title: String?
    var failed: Bool?
    /// What the user named the conversation in Claude Code with /rename; it outranks `title`.
    var name: String?

    /// The name, else the generated title while Session titles is on.
    func shown(titlesOn: Bool) -> String? { name ?? (titlesOn ? title : nil) }
}

/// Session titles (Settings › Claude): text generation names a conversation from the first prompt the user typed
/// in it. The prompt and the title are never logged.
enum SessionTitles {
    /// First characters of the prompt that are given to the model: the start carries the gist.
    static let promptCharacters = 1500
    static let maxTokens = 24
    private static let maxTitleCharacters = 60

    /// The title prompt, in one place so it can be tuned with `Launchy --title`.
    private static let template = """
        Write a short title for a coding session, from the request that started it.
        Rules: 2 to 6 words. Name the specific thing the request is about (the feature, bug, file, tool or question), not the act of asking. Sentence case. No quotes, no punctuation at the end.
        Reply with the title only.

        Request:
        {prompt}
        """

    static func request(for prompt: String) -> String {
        template.replacingOccurrences(of: "{prompt}", with: String(prompt.prefix(promptCharacters)))
    }

    /// The first prompt typed (a bare slash command doesn't count) and the /rename name, if any, from the whole
    /// file, so not on the main actor. Nil while the transcript holds no prompt.
    nonisolated static func look(inTranscript path: String) -> (prompt: String?, name: String?)? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let session = TranscriptReader.read(data, folder: url.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        return (session.prompts.first { !($0.hasPrefix("/") && !$0.contains(where: \.isWhitespace)) },
                session.customTitle.isEmpty ? nil : session.customTitle)
    }

    /// Nil when the reply holds no title.
    @MainActor
    static func title(forPrompt prompt: String, using generator: any TextGenerating) async throws -> String? {
        clean(try await generator.generate(request(for: prompt), maxTokens: maxTokens))
    }

    static func clean(_ reply: String) -> String? {
        var line = reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        if line.lowercased().hasPrefix("title:") { line = String(line.dropFirst("title:".count)) }
        let wrapping = CharacterSet(charactersIn: "\"'`*#“”‘’ ")
        line = line.trimmingCharacters(in: wrapping)
        while let last = line.last, ".!:;,".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: wrapping)
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > maxTitleCharacters {
            let cut = line.prefix(maxTitleCharacters)
            line = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
        }
        return line.isEmpty ? nil : line
    }
}
