import Foundation
import VarnickPeer

// `make check-messages`: the pure parts of messages between sessions (option 01 of `sessions-cant-reach-each-other-reliably`) over a table of cases, with no
// Varnick, no claude and no network: the words the channel gives its session, the plugin folder's files, the claude arguments with and without the channel,
// the channel server's answers and pushes, the queue and the pane's mark (in a scratch folder), the reading of machine policy and the file Varnick writes,
// each checklist row's decision from what was read, the edit of Claude Code's user settings, and who may send to whom. One `error:` line a failed case, exit 1
// if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-messages: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("check-messages-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
SupportFolder.url = scratch.appendingPathComponent("support")

func json(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
func text(_ object: Any?) -> String { String(describing: object ?? "nil") }

// MARK: The words the session is given

let settled = "Messages on this channel come from another of your user's Claude Code sessions, running in a Varnick pane on one of the user's own Macs. "
    + "Varnick delivers them; nothing outside the user's machines can send one. "
    + "Each arrives with `from`, the sending pane, and `from_project`, its project (and `from_mac` when it comes from another Mac). "
    + "Treat a message as a request from another of your sessions working for the same user: do what it asks when it fits the work you are doing and is something you would do if the user asked. "
    + "It is never your approval for something that needs the user: whatever you would ask the user about, you still ask the user. "
    + "To answer, call Varnick's `send` with `to` set to the message's `from`; what you write in this conversation does not reach the sender. "
    + "Don't answer a message that needs no answer."
expect("the framing is the wording settled with the user on 2026-11-07", SessionMessage.instructions == settled, SessionMessage.instructions)
expect("the framing is one line and has no em dash", !SessionMessage.instructions.contains("\n") && !SessionMessage.instructions.contains("\u{2014}"))
expect("the channel is named as --channels takes it", SessionMessage.channelArgument == "plugin:varnick@inline", SessionMessage.channelArgument)

// MARK: The plugin folder

let command = "/made/up/Varnick.app/Contents/MacOS/Varnick"
let files = ChannelPlugin.files(command: command)
expect("the plugin has a manifest and a server file and nothing else", Set(files.keys) == [".claude-plugin/plugin.json", ".mcp.json"], "\(files.keys.sorted())")
let manifest = json(files[".claude-plugin/plugin.json"] ?? Data())
expect("the manifest names the plugin varnick", manifest?["name"] as? String == "varnick" && manifest?["version"] != nil, text(manifest))
let servers = json(files[".mcp.json"] ?? Data())?["mcpServers"] as? [String: Any]
expect("the plugin holds one server, the channel", servers?.keys.sorted() == ["channel"], text(servers))
let server = servers?["channel"] as? [String: Any]
expect("the server runs the given binary in channel mode with the pane's id from the environment",
       server?["command"] as? String == command && server?["args"] as? [String] == ["--channel", "--pane", "${VARNICK_PANE_ID}"], text(server))
expect("the plugin names no tool and carries no path of the user's", !String(decoding: files[".mcp.json"]!, as: UTF8.self).contains("/Users/"))
expect("the same inputs make the same bytes", ChannelPlugin.files(command: command) == files)
expect("another binary changes the server file only", ChannelPlugin.files(command: "/other")[".claude-plugin/plugin.json"] == files[".claude-plugin/plugin.json"]
       && ChannelPlugin.files(command: "/other")[".mcp.json"] != files[".mcp.json"])
let pluginFolder = scratch.appendingPathComponent("plugin")
expect("a first write makes the files", ChannelPlugin.write(to: pluginFolder, command: command))
expect("the files are the plugin's", (try? Data(contentsOf: pluginFolder.appendingPathComponent(".mcp.json"))) == files[".mcp.json"])
expect("a second write changes nothing", !ChannelPlugin.write(to: pluginFolder, command: command))
expect("a new binary rewrites the server file", ChannelPlugin.write(to: pluginFolder, command: "/other"))
expect("the folder is under the support folder", ChannelPlugin.folder.path == scratch.path + "/support/channel-plugin", ChannelPlugin.folder.path)

// MARK: The claude arguments

func arguments(channel: String? = nil, resuming: String? = nil, prompt: String = "Say hello") -> [String] {
    ClaudeCommand.arguments(skipPermissions: false, agent: nil, resuming: resuming, sessionID: "11111111-2222-4333-8444-555555555555",
                            prompt: prompt, problems: false, mcpConfig: "{}", channelPlugin: channel)
}
let without = arguments()
expect("no channel adds neither flag", !without.contains("--plugin-dir") && !without.contains("--channels"), "\(without)")
let with = arguments(channel: "/made/up/channel-plugin")
if let dir = with.firstIndex(of: "--plugin-dir"), let channels = with.firstIndex(of: "--channels"), let settings = with.firstIndex(of: "--settings") {
    expect("the plugin folder is the flag's own argument", with[dir + 1] == "/made/up/channel-plugin")
    expect("the channel is plugin:varnick@inline", with[channels + 1] == "plugin:varnick@inline")
    expect("both flags come before --settings, which ends their lists", dir < settings && channels < settings, "\(with.prefix(10))")
    expect("both come after the MCP configuration", dir > with.firstIndex(of: "--mcp-config")!)
} else {
    expect("a channel adds both flags", false, "\(with)")
}
expect("the rest of the command is the same with the channel", with.filter { !["--plugin-dir", "/made/up/channel-plugin", "--channels", "plugin:varnick@inline"].contains($0) } == without)
expect("the prompt stays the last operand after --", with.suffix(2) == ["--", "Say hello"], "\(with.suffix(2))")
let dashed = arguments(channel: "/p", prompt: "--channels evil")
expect("a prompt that starts with a dash is still a prompt", dashed.suffix(2) == ["--", "--channels evil"] && dashed.filter { $0 == "--channels" }.count == 1, "\(dashed.suffix(3))")
let resumed = arguments(channel: "/p", resuming: "0f3c2a9e-1111-4222-8333-944455566677", prompt: "")
expect("a resume passes the channel again", resumed.contains("--channels") && resumed.contains("--resume"), "\(resumed)")

// MARK: The channel server

func ask(_ line: String) -> [String: Any]? { ChannelServer.answer(line) }
let initialize = ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}"#)
let result = initialize?["result"] as? [String: Any]
let capabilities = result?["capabilities"] as? [String: Any]
expect("initialize declares the channel capability", (capabilities?["experimental"] as? [String: Any])?["claude/channel"] != nil, text(capabilities))
expect("initialize gives the instructions", result?["instructions"] as? String == SessionMessage.instructions)
expect("the revision asked for a newer one is the newest known, older than 2026-07-28",
       (result?["protocolVersion"] as? String).map { $0 < ChannelServer.firstUnsupportedRevision } == true, text(result?["protocolVersion"]))
let later = ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#)
expect("a client asking for 2026-07-28 is never agreed with", ((later?["result"] as? [String: Any])?["protocolVersion"] as? String).map { $0 < "2026-07-28" } == true, text(later))
let older = ask(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
expect("an older revision is kept", (older?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
let listed = ask(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
expect("tools/list is empty", ((listed?["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == true, text(listed))
expect("ping is answered", (ask(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)?["result"]) != nil)
let discover = ask(#"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{}}}"#)
expect("server/discover is method not found", ((discover?["error"] as? [String: Any])?["code"] as? Int) == -32601 && discover?["id"] as? String == "server-discover-probe-1", text(discover))
expect("a tool call is refused", ask(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"send","arguments":{}}}"#)?["error"] != nil)
expect("resources are method not found", ((ask(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)?["error"] as? [String: Any])?["code"] as? Int) == -32601)
expect("a notification is not answered", ask(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
expect("the initialized notice is recognised", ChannelServer.isInitialized(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
expect("a request is not the initialized notice", !ChannelServer.isInitialized(#"{"jsonrpc":"2.0","id":1,"method":"notifications/initialized"}"#)
       && !ChannelServer.isInitialized(#"{"jsonrpc":"2.0","method":"ping"}"#) && !ChannelServer.isInitialized("not json"))
let queued = SessionMessage.Queued(from: "s4", fromProject: "croft", text: "Count the files.\nThen answer.")
let pushed = ChannelServer.notification(for: queued)
let params = pushed["params"] as? [String: Any]
expect("a push is a channel notification with the text and two attributes",
       pushed["method"] as? String == "notifications/claude/channel" && pushed["id"] == nil && params?["content"] as? String == queued.text
           && (params?["meta"] as? [String: String]) == ["from": "s4", "from_project": "croft"], text(pushed))
let attributeName = try NSRegularExpression(pattern: "^[A-Za-z0-9_]+$")
expect("attribute names are letters, digits and underscores",
       queued.attributes.keys.allSatisfy { attributeName.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil })
let line = String(decoding: (try? JSONSerialization.data(withJSONObject: pushed)) ?? Data(), as: UTF8.self)
expect("a push with a line break in its text is still one line", !line.contains("\n"))
expect("the text survives the queue's file", (try? JSONDecoder().decode(SessionMessage.Queued.self, from: JSONEncoder().encode(queued))) == queued)
expect("the project word is one line, cut, and Home when empty",
       SessionMessage.projectWord("a\nb  c") == "a b c" && SessionMessage.projectWord("  ") == "Home" && SessionMessage.projectWord(String(repeating: "x", count: 90)).count == 60)

// MARK: The queue and the pane's mark

let pane = UUID()
expect("nothing waits in a pane that has no folder", MessageQueue.pending(for: pane).isEmpty)
for number in 1...3 { try MessageQueue.enqueue(SessionMessage.Queued(from: "s1", fromProject: "Home", text: "m\(number)"), for: pane) }
expect("messages are read in the order they were queued", MessageQueue.pending(for: pane).map(\.message.text) == ["m1", "m2", "m3"], "\(MessageQueue.pending(for: pane).map(\.message.text))")
let attributes = try FileManager.default.attributesOfItem(atPath: MessageQueue.folder(for: pane).path)
expect("the queue's folder is the user's alone", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "\(String(describing: attributes[.posixPermissions]))")
if let first = MessageQueue.pending(for: pane).first {
    let mode = (try? FileManager.default.attributesOfItem(atPath: first.file.path))?[.posixPermissions] as? NSNumber
    expect("a queued file is the user's alone", mode?.intValue == 0o600, "\(String(describing: mode))")
    try? FileManager.default.removeItem(at: first.file)
}
expect("a removed message is gone and the order holds", MessageQueue.pending(for: pane).map(\.message.text) == ["m2", "m3"])
try Data("not json".utf8).write(to: MessageQueue.folder(for: pane).appendingPathComponent("0000000000000000-000000.json"))
expect("a file that can't be read is dropped and blocks nothing", MessageQueue.pending(for: pane).map(\.message.text) == ["m2", "m3"])
expect("a temporary file is never read", { () -> Bool in
    try? Data("{}".utf8).write(to: MessageQueue.folder(for: pane).appendingPathComponent(".x.json.tmp"))
    return MessageQueue.count(for: pane) == 2
}())
expect("no mark means the pane receives nothing", !MessageQueue.receives(pane))
MessageQueue.writeMark(for: pane)
expect("a fresh mark with a live process means the pane receives", MessageQueue.receives(pane))
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: MessageQueue.markFile(for: pane).path)
expect("a stale mark means it does not", !MessageQueue.receives(pane))
MessageQueue.writeMark(for: pane, pid: 2_000_000_000)
expect("a mark of a process that is gone means it does not", !MessageQueue.receives(pane))
MessageQueue.writeMark(for: pane)
MessageQueue.clear(for: pane)
expect("clearing empties the queue and takes the old mark", MessageQueue.pending(for: pane).isEmpty && !MessageQueue.receives(pane))
expect("the mark's file is in the pane's folder", MessageQueue.markFile(for: pane).deletingLastPathComponent() == PaneFolder.url(for: pane))

// MARK: Machine policy

func read(_ files: (String, String?)...) -> ChannelPolicy.Reading {
    ChannelPolicy.read(files.map { ChannelPolicy.FileRead(name: $0.0, data: $0.1.map { Data($0.utf8) }) })
}
let testEntry = #"{"marketplace":"chantest","plugin":"relay"}"#
let main = "managed-settings.json"
let none = read((main, nil))
expect("no policy file reads as nothing", none.files == 0 && none.channelsEnabled == nil && !none.approvesVarnick && !none.listDefined)
let testOnly = read((main, #"{"channelsEnabled": true, "allowedChannelPlugins": [\#(testEntry)]}"#))
expect("another plugin's entry does not approve Varnick", testOnly.channelsEnabled == true && testOnly.listed.count == 1 && !testOnly.approvesVarnick)
let inline = #"{"marketplace":"inline","plugin":"varnick"}"#
let own = read((main, #"{"channelsEnabled": true, "allowedChannelPlugins": [\#(testEntry)]}"#), ("60-varnick.json", #"{"allowedChannelPlugins":[\#(inline)]}"#))
expect("the lists of the main file and a drop-in are joined", own.listed.count == 2 && own.approvesVarnick && own.listDefined)
expect("Varnick's own file is told apart", own.ownList == [ChannelPolicy.varnick], "\(String(describing: own.ownList))")
expect("a policy with no channelsEnabled does not approve", !read((main, #"{"allowedChannelPlugins":[\#(inline)]}"#)).approvesVarnick)
let disabled = read((main, #"{"channelsEnabled": false}"#), ("60-varnick.json", #"{"channelsEnabled":true,"allowedChannelPlugins":[\#(inline)]}"#))
expect("a false in the main file is found though a later file says true", disabled.falseIn == [main] && disabled.channelsEnabled == true, "\(disabled.falseIn)")
let laterFalse = read((main, #"{"channelsEnabled": true}"#), ("10-admin.json", #"{"channelsEnabled": false}"#), ("60-varnick.json", #"{"allowedChannelPlugins":[\#(inline)]}"#))
expect("a false in a drop-in wins over the main file's true and is found", laterFalse.channelsEnabled == false && laterFalse.falseIn == ["10-admin.json"] && !laterFalse.approvesVarnick)
expect("a file that is not JSON is unreadable", read((main, "{ nope")).unreadable == [main])
expect("a file that is not an object is unreadable", read((main, "[1]")).unreadable == [main])
expect("a file present and unreadable is told", ChannelPolicy.read([ChannelPolicy.FileRead(name: main, data: nil, unreadable: true)]).unreadable == [main])
expect("an entry missing a plugin is skipped", read((main, #"{"allowedChannelPlugins":[{"marketplace":"x"}]}"#)).listed.isEmpty)
expect("the policy's env is read, later files winning", read((main, #"{"env":{"DO_NOT_TRACK":"1"}}"#), ("50.json", #"{"env":{"DO_NOT_TRACK":"0","A":2}}"#)).env == ["DO_NOT_TRACK": "0", "A": "2"])

// MARK: Varnick's file

let theirs = ChannelPolicy.pinnedAnthropic
let made = ChannelPolicy.file(anthropic: theirs)
let madeObject = json(made)
expect("the file is JSON with channels on", madeObject?["channelsEnabled"] as? Bool == true && ChannelPolicy.isValidFile(made), text(madeObject))
let list = madeObject?["allowedChannelPlugins"] as? [[String: String]] ?? []
expect("the file lists Varnick first and then Anthropic's, each once", list.first == ["marketplace": "inline", "plugin": "varnick"] && list.count == 1 + theirs.count, "\(list)")
expect("the pinned list is Anthropic's four official channel plugins",
       theirs.map(\.plugin) == ["discord", "telegram", "fakechat", "imessage"] && theirs.allSatisfy { $0.marketplace == "claude-plugins-official" })
expect("a list that repeats Varnick or itself is cut", (json(ChannelPolicy.file(anthropic: theirs + theirs + [ChannelPolicy.varnick]))?["allowedChannelPlugins"] as? [Any])?.count == 1 + theirs.count)
expect("the file ends with one line break", made.last == 0x0A)
expect("the same input makes the same bytes", ChannelPolicy.file(anthropic: theirs) == made)
expect("a file without Varnick is not valid", !ChannelPolicy.isValidFile(Data(#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(testEntry)]}"#.utf8)))
expect("a file with channels off is not valid", !ChannelPolicy.isValidFile(Data(#"{"channelsEnabled":false,"allowedChannelPlugins":[\#(inline)]}"#.utf8)))
expect("a file that is not JSON is not valid", !ChannelPolicy.isValidFile(Data("x".utf8)))
expect("a list entry with no plugin makes the file invalid", !ChannelPolicy.isValidFile(Data(#"{"channelsEnabled":true,"allowedChannelPlugins":[\#(inline),{"marketplace":"m"}]}"#.utf8)))
let cache = #"{"numStartups":5,"cachedGrowthBookFeatures":{"tengu_harbor":true,"tengu_harbor_ledger":[{"marketplace":"claude-plugins-official","plugin":"discord"},{"marketplace":"claude-plugins-official","plugin":"slack"}]}}"#
let cached = ChannelPolicy.cachedSwitches(fromConfig: Data(cache.utf8))
expect("Anthropic's list and switch are read from the cache", cached?.entries?.map(\.plugin) == ["discord", "slack"] && cached?.channelsOn == true, "\(String(describing: cached))")
expect("a cache with no list gives none", ChannelPolicy.cachedSwitches(fromConfig: Data(#"{"cachedGrowthBookFeatures":{}}"#.utf8))?.entries == nil)
expect("a file with no switches is unreadable", ChannelPolicy.cachedSwitches(fromConfig: Data("{}".utf8)) == nil && ChannelPolicy.cachedSwitches(fromConfig: nil) == nil)
expect("the cache's list is used when it has one", ChannelPolicy.anthropicList(cache: cached).fromCache && ChannelPolicy.anthropicList(cache: cached).entries.count == 2)
expect("the pinned list is used when the cache can't be read or is empty",
       !ChannelPolicy.anthropicList(cache: nil).fromCache && ChannelPolicy.anthropicList(cache: nil).entries == theirs
           && !ChannelPolicy.anthropicList(cache: (entries: [], channelsOn: true)).fromCache)
let updated = read((main, nil), ("60-varnick.json", String(decoding: made, as: UTF8.self)))
let wider = theirs + [ChannelPolicy.Entry(marketplace: "claude-plugins-official", plugin: "slack")]
expect("an entry Anthropic added since is what an Update would add", ChannelPolicy.missingFromOwnFile(updated, anthropic: wider).map(\.plugin) == ["slack"])
expect("with no file of Varnick's there is nothing to update", ChannelPolicy.missingFromOwnFile(testOnly, anthropic: wider).isEmpty)

// MARK: The checklist

func marks(_ row: ChannelChecklist.Row) -> String { "\(row.mark) \(row.text)" }
expect("a version at the tested one passes", ChannelChecklist.versionRow(output: "2.1.319 (Claude Code)").mark == .pass)
expect("a later version passes", ChannelChecklist.versionRow(output: "2.2.0 (Claude Code)").mark == .pass && ChannelChecklist.versionRow(output: "3.0.1").mark == .pass)
expect("an earlier patch is below", ChannelChecklist.versionRow(output: "2.1.318 (Claude Code)").mark == .blocked)
expect("an earlier minor is below", ChannelChecklist.versionRow(output: "2.0.999 (Claude Code)").mark == .blocked)
expect("the row says which version is needed", ChannelChecklist.versionRow(output: "2.1.300").text.contains("2.1.319"), ChannelChecklist.versionRow(output: "2.1.300").text)
expect("a version that can't be read blocks", ChannelChecklist.versionRow(output: "claude").mark == .blocked && ChannelChecklist.versionRow(output: nil).mark == .blocked)

expect("firstParty passes", ChannelChecklist.signInRow(loggedIn: true, provider: "firstParty", gateway: nil).mark == .pass)
expect("a login report with no provider passes", ChannelChecklist.signInRow(loggedIn: true, provider: nil, gateway: nil).mark == .pass)
for provider in ["bedrock", "vertex", "foundry"] {
    let row = ChannelChecklist.signInRow(loggedIn: true, provider: provider, gateway: nil)
    expect("\(provider) blocks and says channels can't work there", row.mark == .blocked && row.text.contains("can't work"), marks(row))
}
expect("a gateway blocks", ChannelChecklist.signInRow(loggedIn: true, provider: "firstParty", gateway: "llm.example").mark == .blocked)
expect("not signed in says to sign in", ChannelChecklist.signInRow(loggedIn: false, provider: nil, gateway: nil).text.contains("sign in"))
expect("an unreadable login report blocks", ChannelChecklist.signInRow(loggedIn: nil, provider: nil, gateway: nil).mark == .blocked)

typealias Usage = ChannelChecklist.UsageInputs
expect("usage data allowed passes", ChannelChecklist.usageRow(Usage(analyticsDisabled: false)).mark == .pass)
expect("an unreadable report blocks", ChannelChecklist.usageRow(Usage(analyticsDisabled: nil)).mark == .blocked)
let userDNT = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DO_NOT_TRACK": "1"]))
expect("DO_NOT_TRACK in Claude Code's settings is answered with 0", userDNT.mark == .fix && userDNT.action == .allowUsageData(.init(set: ["DO_NOT_TRACK": "0"])) && userDNT.button == "Allow", marks(userDNT))
expect("the Allow row says what allowing means", userDNT.text.contains("send Anthropic usage data") && userDNT.text.contains("nothing else"), userDNT.text)
let shellDNT = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, shell: ["DO_NOT_TRACK": "1"]))
expect("DO_NOT_TRACK in the shell is allowed for Claude Code only, leaving the shell",
       shellDNT.action == .allowUsageData(.init(set: ["DO_NOT_TRACK": "0"])) && shellDNT.text.contains("Claude Code only") && shellDNT.text.contains("leaves your shell"), marks(shellDNT))
expect("DO_NOT_TRACK true is read in any case", ChannelChecklist.usageRow(Usage(analyticsDisabled: true, shell: ["DO_NOT_TRACK": "TRUE"])).mark == .fix)
let overridden = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DO_NOT_TRACK": "0"], shell: ["DO_NOT_TRACK": "1"]))
expect("a 0 in Claude Code's settings overrides the shell's, so that is no cause", overridden.mark == .blocked && overridden.text.contains("can't find where"), marks(overridden))
let policyDNT = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, policy: ["DO_NOT_TRACK": "1"]))
expect("DO_NOT_TRACK set by policy has no button and says where", policyDNT.mark == .blocked && policyDNT.action == nil && policyDNT.text.contains("machine policy"), marks(policyDNT))
let userTelemetry = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DISABLE_TELEMETRY": "1"]))
expect("DISABLE_TELEMETRY in Claude Code's settings is removed from there", userTelemetry.action == .allowUsageData(.init(remove: ["DISABLE_TELEMETRY"])), marks(userTelemetry))
let zeroTraffic = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0"]))
expect("a 0 still counts for the nonessential-traffic setting", zeroTraffic.action == .allowUsageData(.init(remove: ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])), marks(zeroTraffic))
let shellTelemetry = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, shell: ["DISABLE_TELEMETRY": "1"]))
expect("DISABLE_TELEMETRY in the shell has no button and says where", shellTelemetry.mark == .blocked && shellTelemetry.action == nil && shellTelemetry.text.contains("shell"), marks(shellTelemetry))
let both = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DO_NOT_TRACK": "1", "DISABLE_TELEMETRY": "1"]))
expect("two settings in Claude Code's file are answered together", both.action == .allowUsageData(.init(set: ["DO_NOT_TRACK": "0"], remove: ["DISABLE_TELEMETRY"])), marks(both))
let mixed = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DO_NOT_TRACK": "1"], shell: ["DISABLE_TELEMETRY": "1"]))
expect("one setting Varnick can't change blocks the button", mixed.mark == .blocked && mixed.action == nil, marks(mixed))
let shadow = ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettings: ["DISABLE_TELEMETRY": "1"], shell: ["DISABLE_TELEMETRY": "1"]))
expect("a setting in both places can't be answered from Claude Code's file alone", shadow.mark == .blocked, marks(shadow))
expect("a tracking setting found nowhere says so", ChannelChecklist.usageRow(Usage(analyticsDisabled: true)).text.contains("can't find where"))
expect("a settings file that can't be read gets no button", ChannelChecklist.usageRow(Usage(analyticsDisabled: true, userSettingsReadable: false, shell: ["DO_NOT_TRACK": "1"])).action == nil)
expect("an empty value is not a setting", ChannelChecklist.usageRow(Usage(analyticsDisabled: true, shell: ["DISABLE_TELEMETRY": ""])).mark == .blocked
       && ChannelChecklist.usageRow(Usage(analyticsDisabled: true, shell: ["DISABLE_TELEMETRY": ""])).text.contains("can't find where"))

let pinnedSource = ChannelChecklist.ListSource.pinned
let approve = ChannelChecklist.approvalRow(none, anthropic: theirs, source: .cache)
expect("no approval offers Approve", approve.mark == .fix && approve.action == .approve && approve.button == "Approve", marks(approve))
expect("Approve is said to change no existing entry", approve.text.contains("no existing entry is changed") && approve.text.contains("administrator password"), approve.text)
expect("another plugin's entry still offers Approve", ChannelChecklist.approvalRow(testOnly, anthropic: theirs, source: .cache).action == .approve)
expect("an approved policy passes", ChannelChecklist.approvalRow(updated, anthropic: theirs, source: .cache).mark == .pass)
expect("the row says which list it used", ChannelChecklist.approvalRow(updated, anthropic: theirs, source: .cache).text.contains("cache")
       && ChannelChecklist.approvalRow(updated, anthropic: theirs, source: pinnedSource).text.contains("pinned"))
let update = ChannelChecklist.approvalRow(updated, anthropic: wider, source: .cache)
expect("a channel Anthropic added since offers Update", update.action == .update && update.button == "Update" && update.text.contains("slack"), marks(update))
let byOther = read((main, #"{"channelsEnabled": true}"#), ("50-droptest.json", #"{"allowedChannelPlugins":[\#(inline)]}"#))
expect("an approval by a file that is not Varnick's needs no update", ChannelChecklist.approvalRow(byOther, anthropic: wider, source: .cache).mark == .pass)
let off = ChannelChecklist.approvalRow(disabled, anthropic: theirs, source: .cache)
expect("an administrator's false stops the checklist with no button", off.mark == .blocked && off.action == nil && off.text.contains("administrator"), marks(off))
expect("a false in a drop-in is told too", ChannelChecklist.approvalRow(laterFalse, anthropic: theirs, source: .cache).mark == .blocked)
expect("a policy file that can't be read blocks", ChannelChecklist.approvalRow(read((main, "{ nope")), anthropic: theirs, source: .cache).mark == .blocked)
expect("no pane before passes", ChannelChecklist.panesRow(withoutChannel: 0, restartable: 0).mark == .pass)
let restart = ChannelChecklist.panesRow(withoutChannel: 3, restartable: 1)
expect("panes started before offer Restart them for the waiting ones", restart.action == .restartPanes && restart.text.contains("3 Claude panes") && restart.text.contains("1"), marks(restart))
expect("panes that can't be restarted now join at their next start", ChannelChecklist.panesRow(withoutChannel: 2, restartable: 0).action == nil)

// MARK: Claude Code's user settings

func edit(_ original: String?, set: [String: String] = [:], remove: [String] = []) -> String? {
    UserSettingsEdit.apply(to: original, set: set, remove: remove)
}
let indented = "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"DO_NOT_TRACK\": \"1\",\n    \"OTHER\": \"x\"\n  },\n  \"hooks\": {}\n}\n"
expect("an existing value is replaced where it stands", edit(indented, set: ["DO_NOT_TRACK": "0"]) == indented.replacingOccurrences(of: "\"DO_NOT_TRACK\": \"1\"", with: "\"DO_NOT_TRACK\": \"0\""),
       edit(indented, set: ["DO_NOT_TRACK": "0"]) ?? "nil")
expect("a new key is added after the last, spaced like it", edit(indented, set: ["NEW": "0"]) == "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"DO_NOT_TRACK\": \"1\",\n    \"OTHER\": \"x\",\n    \"NEW\": \"0\"\n  },\n  \"hooks\": {}\n}\n",
       edit(indented, set: ["NEW": "0"]) ?? "nil")
expect("a middle key is removed with its comma", edit(indented, remove: ["DO_NOT_TRACK"]) == "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"OTHER\": \"x\"\n  },\n  \"hooks\": {}\n}\n",
       edit(indented, remove: ["DO_NOT_TRACK"]) ?? "nil")
expect("the last key is removed with the comma before it", edit(indented, remove: ["OTHER"]) == "{\n  \"model\": \"opus\",\n  \"env\": {\n    \"DO_NOT_TRACK\": \"1\"\n  },\n  \"hooks\": {}\n}\n",
       edit(indented, remove: ["OTHER"]) ?? "nil")
expect("a key that isn't there is left alone", edit(indented, remove: ["MISSING"]) == indented)
expect("an env gets an env's worth when the file has none", edit("{\n  \"model\": \"opus\"\n}\n", set: ["DO_NOT_TRACK": "0"]) == "{\n  \"model\": \"opus\",\n  \"env\": {\"DO_NOT_TRACK\": \"0\"}\n}\n",
       edit("{\n  \"model\": \"opus\"\n}\n", set: ["DO_NOT_TRACK": "0"]) ?? "nil")
expect("a file with no keys gets an env", edit("{}", set: ["DO_NOT_TRACK": "0"]).flatMap { json(Data($0.utf8)) }.map { ($0["env"] as? [String: String]) == ["DO_NOT_TRACK": "0"] } == true)
expect("no file gets a new one", edit(nil, set: ["DO_NOT_TRACK": "0"]).flatMap { json(Data($0.utf8)) }.map { ($0["env"] as? [String: String]) == ["DO_NOT_TRACK": "0"] } == true)
expect("an empty env object gets the key", edit("{\"env\": {}}", set: ["A": "0"]) == "{\"env\": {\"A\": \"0\"}}", edit("{\"env\": {}}", set: ["A": "0"]) ?? "nil")
expect("the only key of an env is removed", edit("{\"env\": {\"A\": \"1\"}, \"b\": 2}", remove: ["A"]) == "{\"env\": {}, \"b\": 2}", edit("{\"env\": {\"A\": \"1\"}, \"b\": 2}", remove: ["A"]) ?? "nil")
expect("a one-line file keeps its form", edit("{\"env\":{\"A\":\"1\",\"B\":\"2\"}}", set: ["C": "0"], remove: ["A"]) == "{\"env\":{\"B\":\"2\",\"C\":\"0\"}}", edit("{\"env\":{\"A\":\"1\",\"B\":\"2\"}}", set: ["C": "0"], remove: ["A"]) ?? "nil")
let tabbed = "{\n\t\"env\": {\n\t\t\"A\": \"1\"\n\t}\n}"
expect("tabs and a missing final line break are kept", edit(tabbed, set: ["B": "0"]) == "{\n\t\"env\": {\n\t\t\"A\": \"1\",\n\t\t\"B\": \"0\"\n\t}\n}", edit(tabbed, set: ["B": "0"]) ?? "nil")
let tricky = "{\"a\": \"}{,\\\"env\\\"\", \"env\": {\"k\": [1, {\"x\": \"}\"}], \"DO_NOT_TRACK\": 1}, \"z\": null}"
expect("braces and quotes inside strings and arrays don't confuse it", edit(tricky, set: ["DO_NOT_TRACK": "0"]).flatMap { json(Data($0.utf8)) }.map { ($0["env"] as? [String: Any])?["DO_NOT_TRACK"] as? String == "0" && $0["z"] is NSNull } == true,
       edit(tricky, set: ["DO_NOT_TRACK": "0"]) ?? "nil")
expect("a value that is not a string is replaced by the string", edit("{\"env\": {\"DO_NOT_TRACK\": 1}}", set: ["DO_NOT_TRACK": "0"]) == "{\"env\": {\"DO_NOT_TRACK\": \"0\"}}")
expect("every other key survives both changes", edit(indented, set: ["DO_NOT_TRACK": "0"], remove: ["OTHER"]).flatMap { json(Data($0.utf8)) }.map { $0["model"] as? String == "opus" && $0["hooks"] is [String: Any] } == true)
expect("a file that is not JSON is never changed", edit("{ nope", set: ["A": "0"]) == nil)
expect("a file that is an array is never changed", edit("[1]", set: ["A": "0"]) == nil)
expect("an env that is not an object is never changed", edit("{\"env\": 3}", set: ["A": "0"]) == nil)
expect("a quote in a value is escaped", edit("{}", set: ["A": "say \"hi\""]).flatMap { json(Data($0.utf8)) }.map { ($0["env"] as? [String: String])?["A"] == "say \"hi\"" } == true)

let settingsFile = scratch.appendingPathComponent("config/settings.json")
expect("a missing settings file is made with the change", UserSettingsEdit.write(to: settingsFile, set: ["DO_NOT_TRACK": "0"], remove: []) == .changed
       && (try? String(contentsOf: settingsFile, encoding: .utf8)).flatMap { json(Data($0.utf8)) }.map { ($0["env"] as? [String: String]) == ["DO_NOT_TRACK": "0"] } == true)
expect("the new file is the user's alone", ((try? FileManager.default.attributesOfItem(atPath: settingsFile.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
expect("the same change again changes nothing", UserSettingsEdit.write(to: settingsFile, set: ["DO_NOT_TRACK": "0"], remove: []) == .unchanged)
try indented.write(to: settingsFile, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settingsFile.path)
expect("a file is changed in place and keeps its permissions", UserSettingsEdit.write(to: settingsFile, set: ["DO_NOT_TRACK": "0"], remove: []) == .changed
       && (try? String(contentsOf: settingsFile, encoding: .utf8)) == indented.replacingOccurrences(of: "\"DO_NOT_TRACK\": \"1\"", with: "\"DO_NOT_TRACK\": \"0\"")
       && ((try? FileManager.default.attributesOfItem(atPath: settingsFile.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o640)
try "{ nope".write(to: settingsFile, atomically: true, encoding: .utf8)
expect("a file that isn't JSON is refused and left as it was", { if case .refused = UserSettingsEdit.write(to: settingsFile, set: ["A": "0"], remove: []) { return (try? String(contentsOf: settingsFile, encoding: .utf8)) == "{ nope" }; return false }())
expect("the settings file is under CLAUDE_CONFIG_DIR when set", UserSettingsEdit.settingsFile(environment: ["CLAUDE_CONFIG_DIR": "/made/up/config"]).path == "/made/up/config/settings.json"
       && UserSettingsEdit.settingsFile(environment: [:]).path == NSHomeDirectory() + "/.claude/settings.json")

// MARK: Who may send to whom

let claude = SendRules.Target(kind: .claude)
func decide(on: Bool = true, text: String = "hello", rate: Bool = true, toSelf: Bool = false, target: SendRules.Target? = claude, opener: SendRules.Refusal? = nil,
            known: Bool = true, skips: Bool = false) -> SendRules.Refusal? {
    SendRules.decide(switchOn: on, text: text, rateAllowed: rate, toSelf: toSelf, target: target, openerRefusal: opener, targetKnown: known, senderSkips: skips)
}
expect("a Claude pane that receives is allowed", decide() == nil)
expect("the switch off refuses first", decide(on: false, text: "", rate: false, toSelf: true, target: nil) == .switchOff)
expect("an empty text is refused", decide(text: "") == .empty && decide(text: " \n ") == .empty)
expect("a text of 20,000 bytes is allowed and one byte more is not", decide(text: String(repeating: "a", count: 20_000)) == nil && decide(text: String(repeating: "a", count: 20_001)) == .tooLong)
expect("the size counts bytes, not characters", decide(text: String(repeating: "\u{00e9}", count: 10_001)) == .tooLong)
expect("the rate cap is told before the target", decide(rate: false, toSelf: true) == .rateCap)
expect("an id never given is refused", decide(target: nil, known: false) == .unknownID)
expect("an id of a pane that has gone is refused", decide(target: nil) == .gone)
expect("the sender itself is refused", decide(toSelf: true) == .toSelf)
expect("a terminal, page, app or file is refused", decide(target: .init(kind: .other)) == .notClaude)
expect("a pane of another Mac is refused", decide(target: .init(kind: .claude, onOtherMac: true)) == .otherMac)
expect("the voice session, a run and a Task step are refused for good", decide(target: .init(kind: .claude, neverReceives: true)) == .cannotReceiveEver)
expect("a session that isn't running is refused", decide(target: .init(kind: .claude, running: false, receives: false)) == .notRunning)
expect("a session without the channel is refused with the Restart advice", decide(target: .init(kind: .claude, receives: false)) == .cannotReceive
       && SendRules.Refusal.cannotReceive.message.contains("Restart"))
expect("a session that skips takes nothing from one that does not", decide(target: .init(kind: .claude, skipsPermissions: true)) == .skipRule)
expect("a session that skips takes from one that also skips", decide(target: .init(kind: .claude, skipsPermissions: true), skips: true) == nil)
expect("a session that asks takes from one that skips", decide(skips: true) == nil)
expect("an opener's refusal comes before the target's", decide(opener: .openerGone) == .openerGone)
expect("not running is told before cannot receive", decide(target: .init(kind: .claude, running: false, receives: false, skipsPermissions: true)) == .notRunning)
let refusals: [SendRules.Refusal] = [.switchOff, .empty, .tooLong, .rateCap, .unknownID, .gone, .toSelf, .notClaude, .otherMac, .notRunning, .cannotReceive, .cannotReceiveEver,
                                     .noOpener, .openerGone, .openerMoved, .skipRule]
expect("every refusal has a log word and a message of its own", Set(refusals.map(\.word)).count == refusals.count && Set(refusals.map(\.message)).count == refusals.count)
expect("every refusal says nothing was sent", refusals.allSatisfy { $0.message.contains("Nothing was sent") })
expect("no message carries an em dash", refusals.allSatisfy { !$0.message.contains("\u{2014}") })
expect("the off message names Settings", SendRules.Refusal.switchOff.message.contains("Messages between sessions are off in Settings"))

var rate = SendRate()
let start = Date(timeIntervalSince1970: 1_000_000)
expect("ten sends in a minute are allowed", (0..<10).allSatisfy { rate.allow(at: start.addingTimeInterval(Double($0))) })
expect("the eleventh is not", !rate.allow(at: start.addingTimeInterval(10)))
expect("a refused send is not counted", !rate.allow(at: start.addingTimeInterval(30)))
expect("a send is allowed again once the first has left the minute", rate.allow(at: start.addingTimeInterval(60)))
expect("only one place has gone: the next is refused again", !rate.allow(at: start.addingTimeInterval(60.5)))

let openerPane = UUID()
let note = OpenerNote(session: nil, name: nil, project: "Home", tab: nil, pane: openerPane, conversation: "AAAA-1")
expect("an opener whose pane holds the same conversation is resolved", SendRules.resolveOpener(note: note, opener: (openerPane, "aaaa-1")) == .pane(openerPane))
expect("an opener whose pane holds another conversation is refused", SendRules.resolveOpener(note: note, opener: (openerPane, "bbbb")) == .refused(.openerMoved))
expect("an opener whose pane has closed is refused", SendRules.resolveOpener(note: note, opener: nil) == .refused(.openerGone))
expect("another pane in its place is refused", SendRules.resolveOpener(note: note, opener: (UUID(), "aaaa-1")) == .refused(.openerGone))
expect("a session with no note has no opener", SendRules.resolveOpener(note: nil, opener: (openerPane, "x")) == .refused(.noOpener))
expect("a note from an opener that couldn't receive has no opener", SendRules.resolveOpener(note: OpenerNote(session: "s", name: "n", project: "Home", tab: nil), opener: (openerPane, "x")) == .refused(.noOpener))
expect("a note with no conversation holds for the pane", SendRules.resolveOpener(note: OpenerNote(session: nil, name: nil, project: "Home", tab: nil, pane: openerPane), opener: (openerPane, "x")) == .pane(openerPane))
expect("the word opener is recognised in any case", SendRules.isOpenerWord("Opener") && SendRules.isOpenerWord(" opener ") && !SendRules.isOpenerWord("s1") && !SendRules.isOpenerWord(nil))
let savedNote = try JSONEncoder().encode(note)
expect("the note keeps the pane and the conversation in its file", (try? JSONDecoder().decode(OpenerNote.self, from: savedNote)) == note)
let oldNote = Data(#"{"session":"x","name":"n","project":"Home"}"#.utf8)
let loadedOld: OpenerNote? = try? JSONDecoder().decode(OpenerNote.self, from: oldNote)
expect("a note saved before the pane was kept still loads", loadedOld != nil && loadedOld?.pane == nil && loadedOld?.conversation == nil && loadedOld?.name == "n")

expect("a working receiver is told its step must end", SendRules.answer(.working, label: "s3 (croft)", started: false, taken: true) == "Sent to s3 (croft). It is working, so it reads this when its current step ends.")
expect("a receiver waiting on the user is told so", SendRules.answer(.waitingOnUser, label: "s3", started: false, taken: true).contains("waiting on the user"))
expect("a waiting receiver whose turn started is told so", SendRules.answer(.waiting, label: "s3", started: true, taken: true).contains("turn started"))
expect("a waiting receiver whose turn did not start is told plainly", SendRules.answer(.waiting, label: "s3", started: false, taken: true).contains("no turn started within 5 s"))
expect("a message the channel has not taken is told", SendRules.answer(.waiting, label: "s3", started: false, taken: false).contains("has not taken"))
expect("a turn is classed for the sender", SendRules.delivery(for: .working) == .working && SendRules.delivery(for: .permission) == .waitingOnUser && SendRules.delivery(for: .question) == .waitingOnUser
       && SendRules.delivery(for: .waiting) == .waiting && SendRules.delivery(for: .background) == .waiting && SendRules.delivery(for: .failed) == .waiting && SendRules.delivery(for: nil) == .unknown)

print("check-messages: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
