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
    public static let officialMarketplace = "claude-plugins-official"
    public static let pinnedAnthropic = [
        Entry(marketplace: officialMarketplace, plugin: "discord"),
        Entry(marketplace: officialMarketplace, plugin: "telegram"),
        Entry(marketplace: officialMarketplace, plugin: "fakechat"),
        Entry(marketplace: officialMarketplace, plugin: "imessage"),
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
            // The entries go into machine policy, which applies to every account on the Mac, so only Anthropic's official marketplace is taken from a
            // file the user can write.
            entries = list.compactMap { item in
                guard let marketplace = item["marketplace"] as? String, marketplace == officialMarketplace, let plugin = item["plugin"] as? String,
                      !plugin.isEmpty else { return nil }
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

    // MARK: Installing it

    /// The owner Varnick's file and the drop-in folder (when it makes it) get: root, and a group no user is in.
    public static let installOwner = "root:wheel"

    /// What the administrator step runs as root (`sh -c`, with `installArguments` after it). The content travels in the command itself, base64, so no file a
    /// user can write is ever read as root (a source left in the support folder could be swapped, or made a link, while the password dialog waits). It
    /// refuses a drop-in folder or a target that is a link, makes the folder only when it is missing (an existing one's owner and mode are not touched),
    /// writes a new file beside the target, owned and mode 644, moves it into place, and reads the target back: one that differs is removed. Exit status:
    /// 11 the folder is a link, 12 it couldn't be made, 13 the target is a link, 14 the content couldn't be written, 15 it couldn't be put in place,
    /// 16 it read back differently (and was removed).
    public static let installScript = #"""
    dir="$1"; name="$2"; b64="$3"; owner="$4"
    [ ! -L "$dir" ] || exit 11
    [ -d "$dir" ] || /usr/bin/install -d -m 755 -o "${owner%%:*}" -g "${owner##*:}" "$dir" || exit 12
    dst="$dir/$name"; tmp="$dir/.$name.new"
    [ ! -L "$dst" ] || exit 13
    rm -f "$tmp"
    printf '%s' "$b64" | /usr/bin/base64 -D > "$tmp" || { rm -f "$tmp"; exit 14; }
    /usr/sbin/chown "$owner" "$tmp" && /bin/chmod 644 "$tmp" && /bin/mv -f "$tmp" "$dst" || { rm -f "$tmp"; exit 15; }
    printf '%s' "$b64" | /usr/bin/base64 -D | /usr/bin/cmp -s - "$dst" || { rm -f "$dst"; exit 16; }
    """#

    /// The arguments of `installScript` for a drop-in folder, the file's name, its content and the owner.
    public static func installArguments(folder: String, name: String = fileName, content: Data, owner: String = installOwner) -> [String] {
        ["-c", installScript, "sh", folder, name, content.base64EncodedString(), owner]
    }

    /// What an install's exit status means, in words for the row.
    public static func installFailure(status: Int32) -> String {
        switch status {
        case 11: "the policy's drop-in folder is a link, which Varnick won't write through"
        case 12: "the drop-in folder couldn't be made"
        case 13: "Varnick's file in the drop-in folder is a link, which Varnick won't write through"
        case 14, 15: "the file couldn't be put in place"
        case 16: "the file read back differently and was removed"
        default: "the command failed (status \(status))"
        }
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
