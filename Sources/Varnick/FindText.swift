import Foundation

/// The text `find` answers (option 01 of `sessions-cant-search-sessions`): a Sessions section, then a Pages section, each result starting with its
/// kind. Pure: `FindAccess` gathers what each result says, this only words it.
enum FindText {
    /// A Claude session found, with what the reply says of it.
    struct Session {
        var row: SearchResult
        /// The tab's name and where it stands ("Open", "Closed", "Done on <Mac>"), or nil with no tab known.
        var tab: String?
        /// The pane here that is on it: its id and the turn word.
        var pane: (id: String, turn: String?)?
        /// The paired Mac's name, nil for this Mac.
        var mac: String?
        var agent: String?
        var first: Date?
        var last: Date?
        var excerpt: String?
        /// The exchange the excerpt is from, which `session_read` takes as `around`.
        var exchange: Int?
        /// Listed by recency with no words to match: there is nothing to say of how it matched.
        var listed = false
    }

    /// A page or bookmark found.
    struct Page {
        var row: SearchResult
        /// The paired Mac's name when only that Mac visited it.
        var mac: String?
    }

    /// Why a meaning search did not run.
    enum Meaning: Equatable {
        case used, notAsked, noEmbedder, failed
    }

    static let excerptLimit = 300
    static let descriptionLimit = 300

    static func reply(sessions: [Session], pages: [Page], meaning: Meaning, now: Date, calendar: Calendar = .current) -> String {
        var lines: [String] = []
        if sessions.isEmpty, pages.isEmpty {
            lines.append("Nothing matched.")
        } else {
            let parts = [sessions.isEmpty ? nil : "\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
                         pages.isEmpty ? nil : "\(pages.count) page\(pages.count == 1 ? "" : "s")"].compactMap { $0 }
            lines.append(parts.joined(separator: " and ") + ", best first.")
        }
        switch meaning {
        case .noEmbedder: lines.append("Search by meaning is not available (no embedding model or server), so these are keyword matches only.")
        case .failed: lines.append("Search by meaning failed just now, so these are keyword matches only.")
        case .used, .notAsked: break
        }
        if !sessions.isEmpty {
            lines.append("")
            lines.append("Sessions:")
            for session in sessions { lines += block(of: session, now: now, calendar: calendar) }
        }
        if !pages.isEmpty {
            lines.append("")
            lines.append("Pages:")
            for page in pages { lines += block(of: page, now: now, calendar: calendar) }
        }
        return lines.joined(separator: "\n")
    }

    static func block(of found: Session, now: Date, calendar: Calendar = .current) -> [String] {
        let row = found.row
        let folderName = (row.url as NSString).lastPathComponent
        var lines = ["", "Claude session: " + oneLine(row.title)]
        lines.append("  project: \(folderName) (\(row.url)\(found.mac.map { " on " + $0 } ?? " on this Mac"))")
        if let agent = found.agent { lines.append("  agent: " + agent) }
        if let used = used(first: found.first, last: found.last ?? row.date, now: now, calendar: calendar) { lines.append("  used: " + used) }
        lines.append("  tab: " + (found.tab ?? "no tab"))
        if let pane = found.pane { lines.append("  open here: \(pane.id)" + (pane.turn.map { ", " + $0 } ?? "")) }
        if !found.listed { lines.append("  matched: " + matchWord(row.match) + (found.exchange.map { ", exchange \($0)" } ?? "")) }
        if let excerpt = found.excerpt, !excerpt.isEmpty { lines.append("  excerpt: " + excerpt) }
        lines.append("  conversation: " + row.sessionID)
        return lines
    }

    static func block(of found: Page, now: Date, calendar: Calendar = .current) -> [String] {
        let row = found.row
        var lines = ["", (row.source == "bookmark" ? "bookmark: " : "page: ") + oneLine(row.title)]
        lines.append("  address: " + row.url)
        if let site = site(of: row.url) { lines.append("  site: " + site) }
        if let date = row.date {
            lines.append("  \(row.source == "bookmark" ? "last visited or saved" : "last visited"): " + when(date, now: now, calendar: calendar)
                         + (found.mac.map { ", only on " + $0 } ?? ""))
        }
        lines.append("  matched: " + matchWord(row.match))
        if row.match != .semantic, let excerpt = excerpt(fromKeywordSnippet: row.snippet), !excerpt.isEmpty { lines.append("  excerpt: " + excerpt) }
        if let about = description(of: row), !about.isEmpty { lines.append("  about: " + about) }
        return lines
    }

    // MARK: Pieces

    static func matchWord(_ match: MatchKind) -> String {
        switch match {
        case .keyword: "words"
        case .semantic: "meaning"
        case .both: "words and meaning"
        }
    }

    /// The store's keyword snippet with its highlight marks turned into `**` markers, on one line.
    static func excerpt(fromKeywordSnippet snippet: String) -> String? {
        let marked = snippet.replacingOccurrences(of: FavoritesStore.hlStart, with: "**").replacingOccurrences(of: FavoritesStore.hlEnd, with: "**")
        let line = oneLine(marked)
        return line.isEmpty ? nil : cut(line, to: excerptLimit)
    }

    /// The start of the exchange a meaning match scored best on: the text it was embedded from, less its title and folder lines.
    static func excerpt(fromExchange text: String) -> String? {
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2).joined(separator: "\n")
        let line = oneLine(body)
        return line.isEmpty ? nil : cut(line, to: excerptLimit)
    }

    /// A page's own description, its History title when it differs and the search terms that led to it (the row's description, less the address it
    /// ends with), on one line and cut.
    static func description(of row: SearchResult) -> String? {
        var parts = row.description.components(separatedBy: "\n\n")
        if parts.last == row.url { parts.removeLast() }
        let line = oneLine(parts.joined(separator: " "))
        return line.isEmpty ? nil : cut(line, to: descriptionLimit)
    }

    static func site(of address: String) -> String? {
        URL(string: address)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    /// "first Tue Oct 20, 14:05, last Wed Oct 21, 09:12 (yesterday evening)".
    static func used(first: Date?, last: Date?, now: Date, calendar: Calendar = .current) -> String? {
        switch (first, last) {
        case (nil, nil): return nil
        case (let first?, nil): return "first " + when(first, now: now, calendar: calendar)
        case (nil, let last?): return "last " + when(last, now: now, calendar: calendar)
        case (let first?, let last?): return "first \(SessionReading.stamp(first)), last " + when(last, now: now, calendar: calendar)
        }
    }

    /// The date and time, and in words when it is within the past week.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let stamp = SessionReading.stamp(date, zone: calendar.timeZone)
        return (0..<7).contains(days) ? "\(stamp) (\(SpokenTime.when(date, now: now, calendar: calendar)))" : stamp
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func cut(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}
