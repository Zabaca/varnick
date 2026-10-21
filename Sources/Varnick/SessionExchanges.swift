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

    // The one rule for an exchange key: a session key (it holds no separator), the separator, then a position of digits only.
    // The same rule in Swift and in SQL (`isExchangeKeySQL`, `sessionKeySQL`), since the store and the sync read keys in SQL.

    /// The session key an exchange key belongs to; nil for any other key.
    static func session(ofExchange key: String) -> String? {
        guard key.hasPrefix(FavoritesStore.sessionKeyPrefix), let at = key.firstIndex(of: Character(separator)),
              key[..<at].count > FavoritesStore.sessionKeyPrefix.count else { return nil }
        let position = key[key.index(after: at)...]
        guard !position.isEmpty, position.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(key[..<at])
    }

    /// SQL true for an exchange key in `column`.
    static func isExchangeKeySQL(_ column: String) -> String {
        """
        (\(column) GLOB '\(FavoritesStore.sessionKeyPrefix)[^\(separator)]*\(separator)[0-9]*' \
        AND substr(\(column), instr(\(column), '\(separator)') + 1) NOT GLOB '*[^0-9]*')
        """
    }

    /// SQL for the session key of the exchange key in `column`.
    static func sessionKeySQL(_ column: String) -> String {
        "substr(\(column), 1, instr(\(column), '\(separator)') - 1)"
    }

    /// One text per exchange, oldest first: the title, the folder's name, then the prompt and the reply, a line each.
    /// A reply a build didn't keep is missing, and empty here. Positions don't move as a session grows: only the last one or two
    /// change, since a short last exchange merges back into the one before until the next prompt arrives.
    static func texts(title: String, folder: String, prompts: [String], replies: [String]) -> [String] {
        groups(prompts: prompts, replies: replies).map { group in
            let parts = group.flatMap { [prompts[$0], $0 < replies.count ? replies[$0] : ""] }
            return ([title, folder] + cut(parts.filter { !$0.isEmpty })).joined(separator: "\n")
        }
    }

    /// The prompts (by index) each exchange holds, oldest first: a prompt with its reply, merged into the next while together they are shorter
    /// than `shortLength`, the last merging back into the one before. Exchange `n` of the embedding keys is `groups[n]`.
    static func groups(prompts: [String], replies: [String]) -> [[Int]] {
        var groups: [[Int]] = []
        var open: [Int] = [], openLength = 0
        for (i, prompt) in prompts.enumerated() {
            let reply = i < replies.count ? replies[i] : ""
            open.append(i)
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
        return groups
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
