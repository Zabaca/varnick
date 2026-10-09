import Foundation

/// A session's exchanges (ADR 0018): each prompt the user typed with the last text Claude wrote before the next, as the texts session
/// search embeds. Pure, so this Mac's sessions and a paired Mac's are built the same way.
enum SessionExchanges {
    /// Between a session's key and an exchange's position in the exchange's embedding key: `session:<id>#<n>`.
    static let separator = "#"
    /// An exchange with fewer characters than this (prompt and reply together) merges into the next.
    static let shortLength = 200
    /// The most characters of prompt and reply an exchange's text holds.
    static let bodyLimit = 1000

    static func key(session: String, position: Int) -> String { session + separator + String(position) }

    /// The session key an exchange key belongs to; nil for any other key.
    static func session(ofExchange key: String) -> String? {
        guard key.hasPrefix(FavoritesStore.sessionKeyPrefix), let at = key.lastIndex(of: Character(separator)),
              let position = Int(key[key.index(after: at)...]), position >= 0 else { return nil }
        return String(key[..<at])
    }

    /// One text per exchange, oldest first: the title, the folder's name, then the prompt and the reply, a line each.
    /// A reply a build didn't keep is missing, and empty here. Positions don't move as a session grows: only the last one or two
    /// change, since a short last exchange merges back into the one before until the next prompt arrives.
    static func texts(title: String, folder: String, prompts: [String], replies: [String]) -> [String] {
        var groups: [[String]] = []
        var open: [String] = [], openLength = 0
        for (i, prompt) in prompts.enumerated() {
            let reply = i < replies.count ? replies[i] : ""
            open += [prompt, reply]
            openLength += prompt.count + reply.count
            if openLength >= shortLength {
                groups.append(open)
                open = []
                openLength = 0
            }
        }
        if !open.isEmpty {
            if groups.isEmpty { groups = [open] } else { groups[groups.count - 1] += open }
        }
        return groups.map { ([title, folder] + cut($0.filter { !$0.isEmpty })).joined(separator: "\n") }
    }

    /// A session the sync lists, with its exchanges' texts.
    struct Listed {
        let key: String
        /// Unix seconds of its last prompt.
        let last: Int64
        let texts: [String]
    }

    /// What the sync counts as current for the sessions it lists, from `stored` (key to text, the vectors made with the current
    /// model), and the order to embed in: the sessions used last first. A session's old single vector is kept, as stored, until
    /// one of its exchanges has a vector, so search finds it by the old one meanwhile.
    static func plan(_ sessions: [Listed], stored: [String: String]) -> (current: [String: String], order: [String]) {
        var current: [String: String] = [:], order: [String] = []
        let withVectors = Set(stored.keys.compactMap(session(ofExchange:)))
        for listed in sessions.sorted(by: { $0.last != $1.last ? $0.last > $1.last : $0.key < $1.key }) {
            for (position, text) in listed.texts.enumerated() {
                let key = key(session: listed.key, position: position)
                current[key] = text
                order.append(key)
            }
            if !withVectors.contains(listed.key), let old = stored[listed.key] { current[listed.key] = old }
        }
        return (current, order)
    }

    /// The parts cut to `bodyLimit` characters in all, each in proportion to its length.
    private static func cut(_ parts: [String]) -> [String] {
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > bodyLimit else { return parts }
        var keep = parts.map { $0.count * bodyLimit / total }
        var spare = bodyLimit - keep.reduce(0, +)
        for i in keep.indices where spare > 0 && keep[i] < parts[i].count {
            keep[i] += 1
            spare -= 1
        }
        return zip(parts, keep).map { String($0.prefix($1)) }
    }
}
