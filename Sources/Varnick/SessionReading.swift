import Foundation
import VarnickPeer

/// A session's conversation as the text `session_read` gives (option 01 of `sessions-cant-search-sessions`): numbered exchanges, paged. Pure, so
/// this Mac's transcripts and a paired Mac's kept prompts read the same way.
enum SessionReading {
    /// About how many characters a call gives.
    static let pageLimit = 40_000
    /// A prompt or a text of Claude's is cut at this many characters.
    static let blockLimit = 8_000
    /// How many exchanges before the one `around` names the read starts.
    static let contextBefore = 2

    enum Start: Equatable {
        case first
        case around(Int)
        case after(Int)
        case last(Int)
        /// One exchange from a character of its text on: the rest of one too long for a call.
        case within(Int, offset: Int)
    }

    struct Page: Equatable {
        /// The exchanges shown, as "Exchanges 3 to 9 of 41." and then each one.
        var text: String
        /// The numbers shown; nil when none was.
        var shown: ClosedRange<Int>?
        /// The exchange to continue after, when some are left.
        var next: Int?
        /// When one exchange was longer than a call: it and the character to continue it from.
        var resume: Resume?
    }

    struct Resume: Equatable {
        var exchange: Int
        var offset: Int
    }

    static func page(_ exchanges: [TranscriptExchange], start: Start, limit: Int = pageLimit, zone: TimeZone = .current) -> Page {
        let total = exchanges.count
        let first: Int
        var skipped = 0
        switch start {
        case .first: first = 0
        case .around(let number): first = max(0, number - 1 - contextBefore)
        case .after(let number): first = max(0, number)
        case .last(let count): first = max(0, total - count)
        case .within(let number, let offset): (first, skipped) = (max(0, number - 1), offset)
        }
        guard first < total else {
            return Page(text: total == 0 ? "The conversation has no exchanges." : "Nothing after exchange \(first): the conversation has \(total) exchanges.",
                        shown: nil, next: nil)
        }
        var blocks: [String] = [], used = 0, last = first, resume: Resume?
        for index in first..<total {
            var block = render(exchanges[index], zone: zone)
            if index == first, skipped > 0 {
                block = "[continued from character \(skipped)]\n" + String(block.dropFirst(skipped))
            }
            if used + block.count > limit {
                guard blocks.isEmpty else { break }
                // One exchange alone is more than a call holds: its start now, and a call that continues it.
                let taken = limit - (skipped > 0 ? block.prefix { $0 != "\n" }.count + 1 : 0)
                block = String(block.prefix(limit))
                resume = Resume(exchange: exchanges[index].number, offset: skipped + taken)
            }
            blocks.append(block)
            used += block.count
            last = index
        }
        let numbers = exchanges[first].number...exchanges[last].number
        let head = "Exchanges \(numbers.lowerBound) to \(numbers.upperBound) of \(total)." + (resume == nil ? "" : " The last is cut here to fit the call.")
        return Page(text: ([head] + blocks).joined(separator: "\n\n"), shown: numbers,
                    next: resume == nil && last + 1 < total ? exchanges[last].number : nil, resume: resume)
    }

    /// A paired Mac's session as exchanges: the prompts it sent, each with Claude's last reply after it (none where it kept none).
    static func exchanges(prompts: [String], replies: [String]) -> [TranscriptExchange] {
        prompts.enumerated().map { index, prompt in
            let reply = index < replies.count ? replies[index] : ""
            return TranscriptExchange(number: index + 1, at: nil, prompt: prompt, parts: reply.isEmpty ? [] : [.claude(reply)])
        }
    }

    private static func render(_ exchange: TranscriptExchange, zone: TimeZone) -> String {
        var lines = ["[\(exchange.number)]" + (exchange.at.map { " " + stamp($0, zone: zone) } ?? "")]
        lines.append("User: " + cut(exchange.prompt))
        for part in exchange.parts {
            switch part {
            case .claude(let text): lines.append("Claude: " + cut(text))
            case .marker(let note): lines.append(note)
            }
        }
        if exchange.parts.isEmpty { lines.append("(Claude wrote no text)") }
        return lines.joined(separator: "\n")
    }

    private static func cut(_ text: String) -> String {
        guard text.count > blockLimit else { return text }
        return String(text.prefix(blockLimit)) + "\n[cut: \(text.count - blockLimit) more characters]"
    }

    /// "Tue Oct 20, 14:05" in `zone`.
    static func stamp(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
