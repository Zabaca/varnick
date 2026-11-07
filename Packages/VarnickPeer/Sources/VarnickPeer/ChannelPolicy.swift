import Foundation

// Machine policy for Varnick's channel (option 01 of `sessions-cant-reach-each-other-reliably`): Claude Code registers a plugin's channel only when the
// machine's managed settings say `channelsEnabled` and list the plugin. Varnick never rewrites the Mac's existing policy file; it adds a file of its own in
// the policy's drop-in folder, which Claude Code joins with the main file (tested 2026-11-07, Claude Code 2.1.319). The reading and the file are here, with no
// Mac state, so `make check-messages` runs them over a table of cases. Writing the file as root is `MessagesSetup` in the app.

public enum ChannelPolicy {
    /// A plugin as the managed settings name it.
    public struct Entry: Equatable, Hashable, Codable, Sendable {
        public var marketplace: String
        public var plugin: String

        public init(marketplace: String, plugin: String) {
            self.marketplace = marketplace
            self.plugin = plugin
        }
    }

    /// Varnick's own plugin: a folder loaded with `--plugin-dir` is in the marketplace `inline`.
    public static let varnick = Entry(marketplace: SessionMessage.marketplace, plugin: SessionMessage.pluginName)

    /// Anthropic's approved channel plugins as Claude Code's cache listed them on 2026-11-07 (Discord, Telegram, a test chat and iMessage, all from Anthropic's
    /// official marketplace). Used only when the cache can't be read: a policy list replaces Anthropic's, so Varnick's file repeats it to leave those working.
    public static let pinnedAnthropic = [
        Entry(marketplace: "claude-plugins-official", plugin: "discord"),
        Entry(marketplace: "claude-plugins-official", plugin: "telegram"),
        Entry(marketplace: "claude-plugins-official", plugin: "fakechat"),
        Entry(marketplace: "claude-plugins-official", plugin: "imessage"),
    ]

    /// Where Claude Code reads machine policy on a Mac: the main file and the folder of drop-ins beside it.
    public static let directory = "/Library/Application Support/ClaudeCode"
    public static let mainFileName = "managed-settings.json"
    public static let dropInFolderName = "managed-settings.d"
    /// Varnick's own drop-in. Its name is Varnick's, so an Approve or Update replaces only it and Remove approval deletes only it.
    public static let fileName = "60-varnick.json"

    // MARK: Reading

    /// One policy file as the disk gave it: absent, readable, or present and unreadable (permissions, not JSON).
    public struct FileRead: Equatable, Sendable {
        public var name: String
        public var data: Data?
        public var unreadable: Bool

        public init(name: String, data: Data?, unreadable: Bool = false) {
            self.name = name
            self.data = data
            self.unreadable = unreadable
        }
    }

    public struct Reading: Equatable, Sendable {
        /// How many policy files exist.
        public var files = 0
        /// Files that exist and couldn't be read as a JSON object.
        public var unreadable: [String] = []
        /// `channelsEnabled` as Claude Code takes it: the main file's, then each drop-in's in name order, the later one winning. Nil when no file sets it.
        public var channelsEnabled: Bool?
        /// The files that set it false.
        public var falseIn: [String] = []
        /// Whether any file sets `allowedChannelPlugins` (which then replaces Anthropic's list), and the plugins all the files list.
        public var listDefined = false
        public var listed: Set<Entry> = []
        /// What Varnick's own file lists, nil when it is not there.
        public var ownList: [Entry]?
        /// The `env` the policy sets, later files winning: a tracking setting can be set here.
        public var env: [String: String] = [:]

        public init() {}

        /// Varnick's plugin is approved: listed, and channels are on.
        public var approvesVarnick: Bool { channelsEnabled == true && listed.contains(ChannelPolicy.varnick) }
    }

    /// The reading of the policy files in the order Claude Code reads them: the main file, then the drop-ins sorted by name.
    public static func read(_ files: [FileRead]) -> Reading {
        var reading = Reading()
        for file in files {
            if file.unreadable { reading.files += 1; reading.unreadable.append(file.name); continue }
            guard let data = file.data else { continue }
            reading.files += 1
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                reading.unreadable.append(file.name)
                continue
            }
            if let enabled = object["channelsEnabled"] as? Bool {
                reading.channelsEnabled = enabled
                if !enabled { reading.falseIn.append(file.name) }
            }
            if let list = object["allowedChannelPlugins"] as? [[String: Any]] {
                reading.listDefined = true
                let entries = list.compactMap { item -> Entry? in
                    guard let marketplace = item["marketplace"] as? String, let plugin = item["plugin"] as? String else { return nil }
                    return Entry(marketplace: marketplace, plugin: plugin)
                }
                reading.listed.formUnion(entries)
                if file.name == fileName { reading.ownList = entries }
            }
            if file.name == fileName, reading.ownList == nil { reading.ownList = [] }
            if let env = object["env"] as? [String: Any] {
                for (key, value) in env {
                    if let text = value as? String { reading.env[key] = text } else if let number = value as? NSNumber { reading.env[key] = number.stringValue }
                }
            }
        }
        return reading
    }

    // MARK: Anthropic's list

    /// Anthropic's approved channel plugins, and its switch for channels, as Claude Code's own file caches them with its feature switches (undocumented,
    /// read on 2.1.319): a hint and a source, never a gate on its own. Nil when the file can't be read; `entries` is nil when the cache holds no list.
    public static func cachedSwitches(fromConfig data: Data?) -> (entries: [Entry]?, channelsOn: Bool?)? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = object["cachedGrowthBookFeatures"] as? [String: Any] else { return nil }
        var entries: [Entry]?
        if let list = features["tengu_harbor_ledger"] as? [[String: Any]] {
            entries = list.compactMap { item in
                guard let marketplace = item["marketplace"] as? String, let plugin = item["plugin"] as? String else { return nil }
                return Entry(marketplace: marketplace, plugin: plugin)
            }
        }
        return (entries, features["tengu_harbor"] as? Bool)
    }

    /// The list Varnick's file repeats: the cache's when it has one, else the pinned copy; and which it was.
    public static func anthropicList(cache: (entries: [Entry]?, channelsOn: Bool?)?) -> (entries: [Entry], fromCache: Bool) {
        if let entries = cache?.entries, !entries.isEmpty { return (entries, true) }
        return (pinnedAnthropic, false)
    }

    // MARK: The file

    /// What Varnick's drop-in holds: channels on, and Varnick's plugin first in the list with Anthropic's after it. Sorted keys, indented, one trailing line break.
    public static func file(anthropic: [Entry]) -> Data {
        var list: [[String: String]] = [["marketplace": varnick.marketplace, "plugin": varnick.plugin]]
        for entry in anthropic where entry != varnick && !list.contains(where: { $0["marketplace"] == entry.marketplace && $0["plugin"] == entry.plugin }) {
            list.append(["marketplace": entry.marketplace, "plugin": entry.plugin])
        }
        let object: [String: Any] = ["channelsEnabled": true, "allowedChannelPlugins": list]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    /// Whether `data` is the file `file(anthropic:)` makes, as JSON and for the two keys Claude Code's schema reads: `channelsEnabled` true and a list of
    /// entries that each name a marketplace and a plugin, Varnick's among them.
    public static func isValidFile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["channelsEnabled"] as? Bool == true,
              let list = object["allowedChannelPlugins"] as? [[String: Any]], !list.isEmpty else { return false }
        let entries = list.compactMap { item -> Entry? in
            guard let marketplace = item["marketplace"] as? String, let plugin = item["plugin"] as? String, !marketplace.isEmpty, !plugin.isEmpty else { return nil }
            return Entry(marketplace: marketplace, plugin: plugin)
        }
        return entries.count == list.count && entries.contains(varnick)
    }

    /// Anthropic's entries that the effective policy list lacks: what an Update would add. Empty when Varnick has no file of its own to update.
    public static func missingFromOwnFile(_ reading: Reading, anthropic: [Entry]) -> [Entry] {
        guard let own = reading.ownList else { return [] }
        return anthropic.filter { !own.contains($0) }
    }
}
