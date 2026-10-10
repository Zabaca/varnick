import Foundation

/// A page saved in one Chrome profile, as the sync archives it.
struct Bookmark: Equatable {
    var url, name: String
    /// Every folder between the bookmark and its root, across all copies of the URL.
    var folders: [String]
    /// Unix seconds; 0 when Chrome doesn't know. The earliest copy's date.
    var added: Int64
    /// The date added of the copy whose name this is, so names can be compared across profiles.
    var named: Int64
}

enum ChromeBookmarks {
    /// The files in a profile folder that hold bookmarks: `Bookmarks`, and `AccountBookmarks` for those
    /// a signed-in profile syncs with its account. Same format; a profile may have either or both.
    static let fileNames = ["Bookmarks", "AccountBookmarks"]

    /// Reads one bookmarks file: one bookmark per URL, a URL filed in several folders pooling
    /// them, the most recently added copy's name winning. Chrome's top-level roots (bookmarks bar,
    /// other, mobile) are found by position under `roots` and left out of the folders, since every
    /// bookmark sits under one. Only pages that can't open outside Chrome are skipped; History's
    /// noise filters don't apply to a page saved on purpose. Nil when the file isn't a bookmarks file.
    static func parse(_ data: Data) -> [Bookmark]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return nil }
        var found: [Bookmark] = []
        func walk(_ node: [String: Any], _ folders: [String]) {
            switch node["type"] as? String {
            case "url":
                guard let url = (node["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty, !HistorySync.skipSchemes.contains(where: url.lowercased().hasPrefix) else { return }
                let name = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let added = unixSeconds(node["date_added"] as? String)
                found.append(Bookmark(url: url, name: name.isEmpty ? url : name, folders: folders, added: added, named: added))
            case "folder":
                let name = (node["name"] as? String ?? "")
                    .components(separatedBy: .newlines).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                for child in node["children"] as? [[String: Any]] ?? [] {
                    walk(child, name.isEmpty ? folders : folders + [name])
                }
            default: break
            }
        }
        for key in roots.keys.sorted() {
            guard let root = roots[key] as? [String: Any] else { continue }
            for child in root["children"] as? [[String: Any]] ?? [] { walk(child, []) }
        }

        return pool(found)
    }

    /// One bookmark per URL: folders pooled, the earliest date added kept, and the name of the copy
    /// whose name is newest. Also joins the bookmarks of a profile's several files.
    static func pool(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var byURL: [String: Bookmark] = [:]
        var order: [String] = []
        for bookmark in bookmarks {
            guard var pooled = byURL[bookmark.url] else {
                byURL[bookmark.url] = bookmark
                order.append(bookmark.url)
                continue
            }
            pooled.folders += bookmark.folders.filter { !pooled.folders.contains($0) }
            if bookmark.named > pooled.named {
                pooled.name = bookmark.name
                pooled.named = bookmark.named
            }
            if bookmark.added > 0 { pooled.added = pooled.added > 0 ? min(pooled.added, bookmark.added) : bookmark.added }
            byURL[bookmark.url] = pooled
        }
        return order.map { byURL[$0]! }
    }

    /// `date_added` is a string of microseconds since 1601; "0" or anything unreadable means unknown.
    private static func unixSeconds(_ chromeTime: String?) -> Int64 {
        guard let micros = chromeTime.flatMap({ Int64($0) }), micros > 0 else { return 0 }
        return max(0, HistorySync.unixSeconds(micros))
    }
}
