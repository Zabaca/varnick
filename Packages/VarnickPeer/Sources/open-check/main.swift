import Foundation
import VarnickPeer

// `make check-open`: the pure parts of `tab_open` (option 01 of `sessions-cant-start-sessions-in-other-projects`) and of the note option 04 gives the
// session it opens, over a table of cases, with no Varnick, no claude and no network: which project a word means, a session's name picked out of sample
// session files by session id (in a scratch folder), the note's paragraph and its saved form, and where the appended system prompt goes in the claude
// command. Option 06 adds the decision of `tab_done` (`TabDone`). Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot function. One `error:` line a failed case,
// exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-open: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

// MARK: Which project a word means

func project(_ path: String) -> Project { Project(path: path, lastUsed: nil) }
let kestrel = project("/Users/made-up/Projects/zabaca/kestrel")
let heron = project("/Users/made-up/Projects/zabaca/heron")
let otherHeron = project("/Users/made-up/Projects/personal/heron")
let kestrelTwo = project("/Users/made-up/Projects/other/kestrel-tools")
let listed = [kestrel, heron, otherHeron, kestrelTwo]

expect("a bare name that is unique", TabOpen.choose("kestrel", among: listed) == .found(kestrel), "\(TabOpen.choose("kestrel", among: listed))")
expect("a name matches in any case", TabOpen.choose("KESTREL", among: listed) == .found(kestrel))
expect("a leading # is dropped", TabOpen.choose("#kestrel", among: listed) == .found(kestrel))
expect("spaces around the word are dropped", TabOpen.choose("  kestrel \n", among: listed) == .found(kestrel))
expect("group/name", TabOpen.choose("personal/heron", among: listed) == .found(otherHeron))
expect("group/name in any case", TabOpen.choose("Zabaca/Heron", among: listed) == .found(heron))
expect("an ambiguous bare name matches nothing and says what would work",
       TabOpen.choose("heron", among: listed) == .ambiguous(["personal/heron", "zabaca/heron"]), "\(TabOpen.choose("heron", among: listed))")
expect("a name that is part of another project's is not a match", TabOpen.choose("tools", among: listed) == .unknown(["kestrel-tools"]), "\(TabOpen.choose("tools", among: listed))")
if case .unknown(let near) = TabOpen.choose("kest", among: listed) {
    expect("an unknown word suggests projects whose names contain it, with group/name where needed", near == ["kestrel", "kestrel-tools"], "\(near)")
} else {
    expect("an unknown word is unknown", false)
}
expect("a word with nothing near it suggests nothing", TabOpen.choose("zzz", among: listed) == .unknown([]))
expect("an empty word names nothing", TabOpen.choose("   ", among: listed) == .unknown([]))
expect("a deeper path of words names nothing", TabOpen.choose("a/b/c", among: listed) == .unknown([]))
expect("a project's folder as an absolute path", TabOpen.choose(kestrel.path, among: listed) == .found(kestrel))
expect("a path with a trailing slash", TabOpen.choose(kestrel.path + "/", among: listed) == .found(kestrel))
expect("a folder inside a project is not a project", TabOpen.choose(kestrel.path + "/Sources", among: listed) == .notAProject)
expect("a worktree under a project is not a project", TabOpen.choose(kestrel.path + "/.claude/worktrees/x", among: listed) == .notAProject)
expect("Home is not a project", TabOpen.choose("/Users/made-up", among: listed) == .notAProject)
expect("a path with no project listed is not a project", TabOpen.choose("/tmp", among: []) == .notAProject)
expect("a word names nothing among no projects", TabOpen.choose("kestrel", among: []) == .unknown([]))
expect("a project's token is its name, or group/name when another has that name",
       TabOpen.token(for: kestrel, among: listed) == "kestrel" && TabOpen.token(for: heron, among: listed) == "zabaca/heron")
let many = (0..<20).map { project("/p/g\($0)/app") }
if case .unknown(let near) = TabOpen.choose("ap", among: many) {
    expect("suggestions are cut", near.count == TabOpen.suggestionCount, "\(near.count)")
} else {
    expect("many near names are unknown", false)
}

// MARK: A session's name in Claude Code's own file

let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("check-open-\(UUID().uuidString)")
let sessions = scratch.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

func write(_ file: String, _ json: String) {
    try? Data(json.utf8).write(to: sessions.appendingPathComponent(file))
}
let mine = "0f3c2a9e-1111-4222-8333-944455566677"
let other = "aaaaaaaa-1111-4222-8333-944455566677"
write("101.json", #"{"pid":101,"sessionId":"\#(other)","cwd":"/made/up","name":"home-aa","kind":"interactive","status":"busy"}"#)
write("102.json", #"{"pid":102,"sessionId":"\#(mine)","cwd":"/made/up","startedAt":1,"peerFeatures":["a"],"asksForConvertedSkills":null,"name":"kestrel-4e","nameSource":"derived","kind":"interactive"}"#)
write("102.abc123.key", "not json and not a session file")
expect("a name is found by the session id", ClaudeSessionFile.name(ofSession: mine, in: sessions) == "kestrel-4e", "\(String(describing: ClaudeSessionFile.name(ofSession: mine, in: sessions)))")
expect("the id is compared in any case", ClaudeSessionFile.name(ofSession: mine.uppercased(), in: sessions) == "kestrel-4e")
expect("another session's file is never taken for it", ClaudeSessionFile.name(ofSession: other, in: sessions) == "home-aa")
expect("a session with no file has no name", ClaudeSessionFile.name(ofSession: "bbbbbbbb-1111-4222-8333-944455566677", in: sessions) == nil)
expect("an empty id has no name", ClaudeSessionFile.name(ofSession: "", in: sessions) == nil)
expect("a folder that does not exist has no names", ClaudeSessionFile.name(ofSession: mine, in: scratch.appendingPathComponent("none")) == nil)
write("103.json", "{ this is not json")
write("104.json", #"{"sessionId":7,"name":"x"}"#)
expect("an unreadable file is skipped, not fatal", ClaudeSessionFile.name(ofSession: mine, in: sessions) == "kestrel-4e")
let third = "cccccccc-1111-4222-8333-944455566677"
write("105.json", #"{"sessionId":"\#(third)","cwd":"/made/up"}"#)
expect("a file with no name gives none", ClaudeSessionFile.name(ofSession: third, in: sessions) == nil)
write("105.json", #"{"sessionId":"\#(third)","name":null}"#)
expect("a null name gives none", ClaudeSessionFile.name(ofSession: third, in: sessions) == nil)
write("105.json", #"{"sessionId":"\#(third)","name":"two\nlines"}"#)
expect("a name of two lines gives none", ClaudeSessionFile.name(ofSession: third, in: sessions) == nil)
write("105.json", #"{"sessionId":"\#(third)","name":"\#(String(repeating: "n", count: 81))"}"#)
expect("a name over 80 characters gives none", ClaudeSessionFile.name(ofSession: third, in: sessions) == nil)
write("105.json", #"{"sessionId":"\#(third)","name":"  spaced  "}"#)
expect("a name is trimmed", ClaudeSessionFile.name(ofSession: third, in: sessions) == "spaced")
write("105.json", #"{"sessionId":"\#(third)","name":"   "}"#)
expect("a blank name gives none", ClaudeSessionFile.name(ofSession: third, in: sessions) == nil)
expect("the folder is under CLAUDE_CONFIG_DIR when it is set",
       ClaudeSessionFile.folder(environment: ["CLAUDE_CONFIG_DIR": "/made/up/config"]).path == "/made/up/config/sessions")
expect("the folder is under .claude when it is not",
       ClaudeSessionFile.folder(environment: [:]).path == NSHomeDirectory() + "/.claude/sessions",
       ClaudeSessionFile.folder(environment: [:]).path)
expect("an empty CLAUDE_CONFIG_DIR counts as unset",
       ClaudeSessionFile.folder(environment: ["CLAUDE_CONFIG_DIR": ""]).path == NSHomeDirectory() + "/.claude/sessions")

// MARK: The note

let addressed = OpenerNote(session: "0f3c2a9e-1111-4222-8333-944455566677", name: "home-7d", project: "Home", tab: "Plan the week")
expect("an opener with an id and a name is addressed", addressed.addressed)
// The paragraph as settled with the user on 2026-11-06 (option 04), made-up values.
let settled = "This session was opened by another Claude session in Home, with Varnick's `tab_open`. "
    + "Its session id is 0f3c2a9e-1111-4222-8333-944455566677 and its name was home-7d when it opened you. You can reach it with SendMessage to its name. "
    + "Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. "
    + "Its name changes when it restarts: if a send fails, run `claude agents --json`, find the entry whose sessionId is the one above, and send to that entry's name. "
    + "If there is no such entry, that session isn't running: say so here in your own reply, and never send to a name the failure suggests instead. "
    + "The user can see this tab and type into it."
expect("the paragraph is the settled wording", addressed.paragraph == settled, addressed.paragraph)
expect("the paragraph is one line", !addressed.paragraph.contains("\n"))
expect("the paragraph never carries the tab's name when it has the address", !addressed.paragraph.contains("Plan the week"))
let unaddressed = OpenerNote(session: nil, name: nil, project: "Home", tab: "Plan the\nweek")
expect("an opener with no name is not addressed", !unaddressed.addressed)
expect("an opener with an id and no name is not addressed", !OpenerNote(session: "x", name: nil, project: "Home", tab: nil).addressed)
expect("without an address the paragraph names the project and tab and gives no id",
       unaddressed.paragraph.contains("in Home (its tab: Plan the week)") && !unaddressed.paragraph.contains("SendMessage") && !unaddressed.paragraph.contains("sessionId"),
       unaddressed.paragraph)
expect("without a tab it names the project alone", OpenerNote(session: nil, name: nil, project: "Home", tab: nil).paragraph.contains("in Home, with Varnick"),
       OpenerNote(session: nil, name: nil, project: "Home", tab: nil).paragraph)
expect("a long tab name is cut", OpenerNote(session: nil, name: nil, project: "Home", tab: String(repeating: "t", count: 200)).paragraph.contains(String(repeating: "t", count: 60) + "..."))
expect("a project name with a line break stays on one line", !OpenerNote(session: nil, name: nil, project: "a\nb", tab: nil).paragraph.contains("\n"))
let saved = try JSONEncoder().encode(addressed)
expect("the note survives its file", (try? JSONDecoder().decode(OpenerNote.self, from: saved)) == addressed, String(decoding: saved, as: UTF8.self))
let savedUnaddressed = try JSONEncoder().encode(unaddressed)
expect("a note with no address survives its file", (try? JSONDecoder().decode(OpenerNote.self, from: savedUnaddressed)) == unaddressed)

// The third form (option 01 of `sessions-cant-reach-each-other-reliably`): the opener could receive messages, so the new session reaches it with `send` to `opener`.
let messaging = OpenerNote(session: nil, name: nil, project: "Home", tab: "Plan the week", pane: UUID(), conversation: "0f3c2a9e-1111-4222-8333-944455566677")
let messaged = "This session was opened by another Claude session in Home (its tab: Plan the week), with Varnick's `tab_open`. "
    + "You can reach it with Varnick's `send`, with `to` set to `opener`; that works whatever restarts either of you. "
    + "Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. "
    + "If `send` says it can't be reached, say so here in your own reply, and never send to another pane in its place. "
    + "The user can see this tab and type into it."
expect("the third form is the settled wording", messaging.paragraph(messages: true) == messaged, messaging.paragraph(messages: true))
expect("the third form is one line, with no id, no name and no SendMessage",
       !messaging.paragraph(messages: true).contains("\n") && !messaging.paragraph(messages: true).contains("SendMessage") && !messaging.paragraph(messages: true).contains("0f3c2a9e"))
expect("an opener that could receive, in a session that cannot send, gets the old form", messaging.paragraph(messages: false) == messaging.paragraph && !messaging.paragraph.contains("`send`"))
expect("a session that can send but whose opener could not receive gets the old form", addressed.paragraph(messages: true) == settled && unaddressed.paragraph(messages: true) == unaddressed.paragraph)
let savedMessaging = try JSONEncoder().encode(messaging)
expect("the third form's note survives its file", (try? JSONDecoder().decode(OpenerNote.self, from: savedMessaging)) == messaging)

// MARK: Where the paragraph goes in the command

func arguments(append: String? = nil, resuming: String? = nil, prompt: String = "Say hello") -> [String] {
    ClaudeCommand.arguments(skipPermissions: false, agent: "builder", resuming: resuming, sessionID: "11111111-2222-4333-8444-555555555555",
                            prompt: prompt, problems: false, mcpConfig: "{}", appendSystemPrompt: append)
}
let plain = arguments()
expect("no note adds no flag", !plain.contains("--append-system-prompt"), "\(plain)")
let told = arguments(append: addressed.paragraph)
if let at = told.firstIndex(of: "--append-system-prompt") {
    expect("the paragraph is the flag's own argument", told[at + 1] == addressed.paragraph)
    expect("the flag comes before the session id and the prompt", at < told.firstIndex(of: "--session-id")! && at < told.firstIndex(of: "--")!, "\(told.prefix(12))")
    expect("the flag comes after the agent, as separate elements", at > told.firstIndex(of: "--agent")!)
} else {
    expect("a note adds the flag", false)
}
expect("the prompt stays the last operand after --", told.suffix(2) == ["--", "Say hello"], "\(told.suffix(2))")
expect("the prompt is unchanged by the note", Array(told.suffix(2)) == Array(plain.suffix(2)))
expect("everything else is the same with the note", told.filter { $0 != "--append-system-prompt" && $0 != addressed.paragraph } == plain)
let resumed = arguments(append: addressed.paragraph, resuming: "0f3c2a9e-1111-4222-8333-944455566677", prompt: "")
expect("a resume passes it again", resumed.contains("--append-system-prompt") && resumed.contains("--resume"), "\(resumed)")
expect("a resume has no prompt operand", !resumed.contains("--"))

// MARK: Whether a session may mark a tab Done (option 06)

let opener = UUID(), stranger = UUID(), helper = UUID()
func decide(_ panes: [TabDone.Pane], own: Bool = false, closing: Bool = false, control: TabDone.Control? = nil) -> TabDone.Refusal? {
    TabDone.decide(panes: panes, caller: opener, isCallersTab: own, isClosing: closing, control: control)
}
func mine(_ turn: Turn? = nil, by mark: UUID? = opener) -> TabDone.Pane { TabDone.Pane(id: UUID(), openedBy: mark, turn: turn) }

expect("a tab the caller opened and nobody has used is allowed", decide([mine()]) == nil)
expect("a helper that is waiting for its next prompt is allowed", decide([mine(.waiting)]) == nil)
expect("a helper stopped on an API error is allowed", decide([mine(.failed)]) == nil)
expect("a terminal beside the helper that the helper opened is allowed", decide([mine(.waiting), mine(by: helper)]) == nil)
expect("the caller's own tab is refused", decide([mine()], own: true) == .ownTab)
expect("the caller's own tab is refused before anything else", decide([mine(.working)], own: true, closing: true, control: .machine) == .ownTab)
expect("no pane with the caller's mark is refused", decide([mine(by: nil)]) == .notOpenedByCaller)
expect("another session's mark is refused", decide([mine(by: stranger)]) == .notOpenedByCaller)
expect("a tab with no pane is refused", decide([]) == .notOpenedByCaller)
expect("a pane with no mark beside the caller's is refused (the user added it or used it)", decide([mine(), mine(by: nil)]) == .notOpenedByCaller)
expect("the unmarked pane is refused whichever side it is on", decide([mine(by: nil), mine()]) == .notOpenedByCaller)
expect("a pane marked by another session beside the caller's is allowed", decide([mine(), mine(by: stranger)]) == nil)
expect("closing is refused", decide([mine()], closing: true) == .closing)
expect("not opened is told before closing", decide([mine(by: nil)], closing: true) == .notOpenedByCaller)
expect("working is refused", decide([mine(.working)]) == .working)
expect("background work is refused", decide([mine(.background)]) == .background)
for turn in [Turn.permission, .question, .plan, .input] {
    expect("a session waiting on the user (\(turn)) is refused", decide([mine(turn)]) == .waitingOnUser(turn), "\(String(describing: decide([mine(turn)])))")
}
expect("a session beside the helper that works is refused", decide([mine(.waiting), mine(.working, by: helper)]) == .working)
expect("waiting on the user is told before working", decide([mine(.working), mine(.permission, by: helper)]) == .waitingOnUser(.permission))
expect("working is told before background work", decide([mine(.background), mine(.working, by: helper)]) == .working)
expect("closing is told before a turn", decide([mine(.working)], closing: true) == .closing)
expect("control here is allowed", decide([mine()], control: .here) == nil)
expect("control by nobody is allowed", decide([mine()], control: .nobody) == nil)
expect("another machine's control is refused", decide([mine()], control: .machine) == .controlledElsewhere)
expect("mixed control is refused", decide([mine()], control: .mixed) == .changingHands)
expect("a turn is told before control", decide([mine(.working)], control: .machine) == .working)
expect("only dialogs and questions wait on the user",
       Turn.permission.waitsOnUser && Turn.question.waitsOnUser && Turn.plan.waitsOnUser && Turn.input.waitsOnUser
           && !Turn.working.waitsOnUser && !Turn.waiting.waitsOnUser && !Turn.background.waitsOnUser && !Turn.failed.waitsOnUser)
expect("every refusal has a log word of its own",
       Set([TabDone.Refusal.ownTab, .notOpenedByCaller, .closing, .working, .background, .waitingOnUser(.plan), .controlledElsewhere, .changingHands].map(\.word)).count == 8)

// MARK: Another machine's projects (option 07)

let now = Date(timeIntervalSince1970: 1_800_000_000)
func listed(_ path: String, hoursAgo: Double?) -> Project { Project(path: path, lastUsed: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }) }
func item(_ path: String, hoursAgo: Double? = nil, trusted: Bool? = true) -> ProjectSearch.Item { .init(project: listed(path, hoursAgo: hoursAgo), trusted: trusted) }
let deskItems = [
    item("/home/made-up/Projects/zabaca/kestrel", hoursAgo: 2),
    item("/home/made-up/Projects/tools/kestrel-cli", trusted: false),
    item("/home/made-up/Projects/zabaca/heron", hoursAgo: 30),
    item("/home/made-up/Projects/personal/heron", hoursAgo: 24 * 100, trusted: nil),
    item("/home/made-up/Projects/zabaca/alpha", hoursAgo: 0.5),
]
let whole = ProjectSearch.answer(machine: "the desktop", search: nil, items: deskItems, now: now).split(separator: "\n").map(String.init)
expect("the list's first line says where, how many and in which order", whole.first == "Projects on the desktop (5 of 5, most recently used by Claude first):", "\(whole.first ?? "")")
expect("those Claude used most recently come first, the rest by name",
       whole.dropFirst().map { $0.components(separatedBy: " · ")[0] } == ["alpha", "kestrel", "zabaca/heron", "personal/heron", "kestrel-cli"], "\(whole)")
expect("a line gives the word, the group, the path there, the age and the trust",
       whole[2] == "kestrel · group zabaca · /home/made-up/Projects/zabaca/kestrel · used by Claude 2 h ago · trusted", whole[2])
expect("an untrusted project says what to do", whole.last == "kestrel-cli · group tools · /home/made-up/Projects/tools/kestrel-cli · never used by Claude · not trusted: open a session there once before tab_open", whole.last ?? "")
expect("a machine on an older build says not known", whole[4].hasSuffix("used by Claude 3 mo ago · not known"), whole[4])
expect("minutes and days are told", ProjectSearch.used(now.addingTimeInterval(-600), now: now) == "used by Claude 10 min ago" && ProjectSearch.used(now.addingTimeInterval(-86_400 * 5), now: now) == "used by Claude 5 d ago"
       && ProjectSearch.used(now, now: now) == "used by Claude just now" && ProjectSearch.used(nil, now: now) == "never used by Claude")
expect("two projects that share a name each get their group/name word", whole.contains { $0.hasPrefix("zabaca/heron · group zabaca") } && whole.contains { $0.hasPrefix("personal/heron · group personal") })
let found = ProjectSearch.answer(machine: "the desktop", search: "kest", items: deskItems, now: now).split(separator: "\n").map(String.init)
expect("a word narrows by folder name", found.count == 3 && found[0] == "Projects on the desktop matching \"kest\" (2 of 5, most recently used by Claude first):", "\(found)")
expect("a word matches the group too and ignores case", ProjectSearch.answer(machine: nil, search: "PERSONAL", items: deskItems, now: now).contains("personal/heron") &&
       ProjectSearch.answer(machine: nil, search: "PERSONAL", items: deskItems, now: now).hasPrefix("Projects on this Mac matching \"PERSONAL\" (1 of 5"))
expect("a word that matches nothing says so and how many there are", ProjectSearch.answer(machine: "the desktop", search: "zzz", items: deskItems, now: now) == "No project on the desktop matching \"zzz\" (5 there). Try a shorter word, or leave `search` out to list them.")
expect("a machine with no projects says so", ProjectSearch.answer(machine: "the desktop", search: nil, items: [], now: now).hasPrefix("No projects on the desktop"))
let bulk = (0..<80).map { item("/p/g\($0 % 7)/app\(String(format: "%02d", $0))", hoursAgo: Double($0 + 1)) }
let capped = ProjectSearch.answer(machine: "the desktop", search: nil, items: bulk, now: now).split(separator: "\n").map(String.init)
expect("the list is cut at 50 lines with how many more match", capped.count == 52 && capped[0].contains("(50 of 80,") && capped.last == "30 more matches: give `search` a longer word to narrow them.", "\(capped.count) \(capped.last ?? "")")
expect("one more match is told in the singular", ProjectSearch.answer(machine: nil, search: nil, items: Array(bulk.prefix(51)), now: now).hasSuffix("1 more match: give `search` a longer word to narrow them."))
expect("a search word with a line break stays on one line", !ProjectSearch.answer(machine: nil, search: "a\nb", items: deskItems, now: now).split(separator: "\n")[0].contains("\nb"))

// What a peer's `projects` line carries, and a build before the field.
let withTrust = PeerProject(path: "/p/a", lastUsed: nil, trusted: false)
expect("the trust field survives the wire", PeerJSON.decode(PeerProject.self, from: PeerJSON.line(withTrust)) == withTrust)
expect("an older build's project line reads as not known", PeerJSON.decode(PeerProject.self, from: #"{"path":"/p/a"}"#)?.trusted == nil)
let trustConfig = Data(#"{"projects":{"/p/a":{"hasTrustDialogAccepted":true},"/p/b":{"hasTrustDialogAccepted":false}}}"#.utf8)
let listing = PeerProject.listing(of: [Project(path: "/p/a", lastUsed: nil), Project(path: "/p/b", lastUsed: nil), Project(path: "/p/c", lastUsed: nil)], config: trustConfig)
expect("a machine lists each project with its Claude Code's trust from one read", listing.map(\.trusted) == [true, false, false], "\(listing.map(\.trusted))")
expect("a config that cannot be read lists every project as not known", PeerProject.listing(of: [Project(path: "/p/a", lastUsed: nil)], config: nil).map(\.trusted) == [nil])

// MARK: Which machine a word means

let desk = (id: "id-desk", name: "Desk Mac Studio"), air = (id: "id-air", name: "Ana’s MacBook Air"), host = (id: "id-host", name: "build box 9"), laptop = (id: "id-pro", name: "Work MacBook Pro")
let machines = [desk, air, host, laptop]
func machine(_ word: String) -> MachineWord.Match { MachineWord.match(word, own: ["Home Mac", "this Mac"], peers: machines) }
expect("a machine's whole name, as board_read shows it", machine("Ana’s MacBook Air") == .peer("id-air"), "\(machine("Ana’s MacBook Air"))")
expect("one word of its name", machine("box") == .peer("id-host") && machine("studio") == .peer("id-desk"))
expect("the panel's ^ word, in any case", machine("^BuildBox9") == .peer("id-host") && machine("BUILD BOX 9") == .peer("id-host"))
expect("this Mac by either name", machine("this Mac") == .thisMac && machine("home mac") == .thisMac && machine("^homemac") == .thisMac)
expect("a word that fits two machines is ambiguous and names them", machine("macbook") == .ambiguous(["Ana’s MacBook Air", "Work MacBook Pro"]), "\(machine("macbook"))")
expect("a word that fits none is unknown", machine("desktop") == .unknown && machine("   ") == .unknown && machine("^") == .unknown)
expect("handles are the whole name run together and each word", MachineWord.handles(ofName: "Alex’s MacBook Pro") == ["alexsmacbookpro", "alexs", "macbook", "pro"])

// MARK: What a host decides before it opens a tab for a Mac

let hostProjects = [project("/home/made-up/Projects/zabaca/kestrel"), project("/home/made-up/Projects/zabaca/heron"), project("/home/made-up/Projects/personal/heron"),
                    project("/home/made-up/Projects/other/kestrel-tools")]
func decideOpen(_ word: String = "kestrel", agent: String? = nil, ready: Bool = true, why: String? = nil, opener: Bool = true, agents: [String] = ["builder"],
                trusted: Bool? = true) -> Result<Project, RemoteTabOpen.Refusal> {
    RemoteTabOpen.decide(word: word, among: hostProjects, agent: agent, ready: ready, notReadyBecause: why, hasOpener: opener, agentsIn: { _ in agents }, trusted: { _ in trusted })
}
func refusal(_ result: Result<Project, RemoteTabOpen.Refusal>) -> RemoteTabOpen.Refusal? { if case .failure(let refusal) = result { refusal } else { nil } }
expect("a trusted project with nothing else wrong is found", decideOpen() == .success(hostProjects[0]) || { if case .success(let p) = decideOpen() { p == hostProjects[0] } else { false } }())
expect("a host that is not ready refuses first, with its reason", refusal(decideOpen("nothing", ready: false, why: "its checklist hasn't passed")) == .notReady("its checklist hasn't passed"))
expect("a request with no opener is refused", refusal(decideOpen(opener: false)) == .noOpener)
expect("readiness is told before the opener", refusal(decideOpen(ready: false, opener: false)) == .notReady(nil))
expect("an ambiguous name is refused with the words that would work", refusal(decideOpen("heron")) == .ambiguous(["personal/heron", "zabaca/heron"]), "\(String(describing: refusal(decideOpen("heron"))))")
expect("an unknown name is refused with close names", refusal(decideOpen("kest")) == .unknown(["kestrel", "kestrel-tools"]))
expect("a folder that is not a project there is refused", refusal(decideOpen("/home/made-up/Projects/zabaca/kestrel/Sources")) == .notAProject)
expect("a project by its absolute path there is found", { if case .success(let p) = decideOpen("/home/made-up/Projects/zabaca/kestrel") { p == hostProjects[0] } else { false } }())
expect("an agent found there is allowed", { if case .success = decideOpen(agent: "builder") { true } else { false } }())
expect("an agent not found there is refused with those that are", refusal(decideOpen(agent: "planner")) == .unknownAgent(["builder"]))
expect("a blank agent is no agent", { if case .success = decideOpen(agent: "  ") { true } else { false } }())
expect("a folder its Claude Code has not trusted is refused", refusal(decideOpen(trusted: false)) == .untrusted(ClaudeTrust.abbreviated("/home/made-up/Projects/zabaca/kestrel")))
expect("a trust that cannot be told is no reason to refuse", { if case .success = decideOpen(trusted: nil) { true } else { false } }())
expect("the project is told before the agent, the agent before the trust", refusal(decideOpen("zzz", agent: "planner", trusted: false)) == .unknown([]) && refusal(decideOpen(agent: "planner", trusted: false)) == .unknownAgent(["builder"]))
expect("every refusal has a log word of its own", Set([RemoteTabOpen.Refusal.notReady(nil), .noOpener, .ambiguous([]), .unknown([]), .notAProject, .unknownAgent([]), .untrusted("~/x")].map(\.word)).count == 7)
let desktop = "the desktop"
expect("the refusal's words name the machine and point to project_search", RemoteTabOpen.words(.unknown(["kestrel"]), machine: desktop) ==
       "No project by that name on the desktop. Projects there with a similar name: kestrel. project_search lists the machine's projects.", RemoteTabOpen.words(.unknown(["kestrel"]), machine: desktop))
expect("an untrusted folder's words tell the user's step, naming the machine", RemoteTabOpen.words(.untrusted("~/x"), machine: desktop).contains("Claude Code on the desktop hasn't trusted ~/x") && RemoteTabOpen.words(.untrusted("~/x"), machine: desktop).contains("on the desktop once"))
expect("a host that is not ready says where to look", RemoteTabOpen.words(.notReady("Messages between sessions is off in its Settings"), machine: desktop).contains("the desktop isn't ready for messages (Messages between sessions is off in its Settings)"))
expect("no refusal's words are empty or run to two lines", [RemoteTabOpen.Refusal.notReady(nil), .noOpener, .ambiguous(["a"]), .unknown([]), .notAProject, .unknownAgent([]), .untrusted("~/x")].allSatisfy {
    let words = RemoteTabOpen.words($0, machine: desktop); return !words.isEmpty && !words.contains("\n") })
// What the asking side checks before any request: messages must go both ways.
func asker(_ on: Bool = true, channel: Bool = true, receives: Bool = true, macs: Bool = true) -> String? {
    RemoteTabOpen.askerRefusal(messagesOn: on, startsWithChannel: channel, callerReceives: receives, macsOn: macs)
}
expect("a session that can send, with the Also switch on, may ask", asker() == nil)
expect("messages off is refused, saying what to turn on", asker(false)?.contains("Messages between sessions is off in Settings") == true)
expect("messages not ready is refused", asker(channel: false)?.contains("isn't ready on this Mac") == true)
expect("a session without send is refused, saying to restart the pane", asker(receives: false)?.contains("restart") == true || asker(receives: false)?.contains("Restart") == true)
expect("the Also switch off is refused", asker(macs: false)?.contains("Also between my Macs and hosts is off") == true)
expect("the switch is told before the channel, the channel before the pane", asker(false, channel: false, receives: false, macs: false)?.contains("is off in Settings") == true && asker(channel: false, receives: false)?.contains("isn't ready") == true)

// The request and its notes cross the wire, and an open tab asks for nothing a device can send.
let ask = PeerOpenTabAsk(project: "kestrel", agent: "builder", prompt: "go", skipPermissions: false, id: "0f3c2a9e-1111-4222-8333-944455566677",
                         opener: PeerOpener(pane: "aaaaaaaa-1111-4222-8333-944455566677", conversation: "bbbbbbbb-1111-4222-8333-944455566677", project: "Home", tab: "Plan", macName: "Laptop"))
var openRequest = PeerRequest(.openTab)
openRequest.open = ask
openRequest.by = "cccccccc-1111-4222-8333-944455566677"
expect("the open request survives the wire", PeerJSON.decode(PeerRequest.self, from: PeerJSON.line(openRequest))?.open == ask)
expect("a device is refused the open request", PeerProtocol.isMacsOnly(.openTab))
expect("an old build's unknown operation is not decoded", PeerJSON.decode(PeerRequest.self, from: #"{"v":35,"op":"openTabNext"}"#) == nil)

// MARK: The note across machines (option 07)

let remote = OpenerNote(session: nil, name: nil, project: "home", tab: "Plan the release", pane: UUID(), conversation: "0f3c2a9e-1111-4222-8333-944455566677",
                        machine: "id-laptop", machineName: "the laptop")
let remoteWords = "This session was opened by another Claude session in home (its tab: Plan the release) on the laptop, with Varnick's `tab_open`. "
    + "You run on another machine, so its files are not yours. "
    + "You can reach it with Varnick's `send`, with `to` set to `opener`; that works whatever restarts either of you. "
    + "Send it your result when you finish, or a question when you need a decision it can make and the user hasn't. "
    + "If `send` says it can't be reached (that machine asleep, or that session closed), say so here in your own reply, and never send to another pane in its place. "
    + "The user can see this tab and type into it."
expect("the paragraph across machines is the settled wording", remote.paragraph(messages: true) == remoteWords, remote.paragraph(messages: true))
expect("it is one line, names no id and no SendMessage", !remote.paragraph(messages: true).contains("\n") && !remote.paragraph(messages: true).contains("SendMessage") && !remote.paragraph(messages: true).contains("0f3c2a9e"))
expect("a session that cannot send gets the form that gives no way back", !remote.paragraph(messages: false).contains("`send`") && remote.paragraph(messages: false) == remote.paragraph)
expect("the form on one machine is unchanged by the new fields", messaging.paragraph(messages: true) == messaged)
let savedRemote = try JSONEncoder().encode(remote)
expect("the note across machines survives its file", (try? JSONDecoder().decode(OpenerNote.self, from: savedRemote)) == remote)
expect("a note saved before the machine fields loads without them", { () -> Bool in
    let old = try? JSONDecoder().decode(OpenerNote.self, from: Data(#"{"project":"Home","pane":"AAAAAAAA-1111-4222-8333-944455566677"}"#.utf8))
    return old != nil && old?.machine == nil && old?.machineName == nil
}())
let remoteArguments = arguments(append: remote.paragraph(messages: true))
expect("the command carries the paragraph across machines", remoteArguments.contains(remote.paragraph(messages: true)) && remoteArguments.contains("--append-system-prompt"))

// MARK: Whether a session may mark Done a tab another machine hosts (option 07)

let me = "11111111-2222-4333-8444-555555555555", elsewhere = "99999999-2222-4333-8444-555555555555"
expect("every pane on this Mac's id is control here", TabDone.control(labels: [me, me.uppercased()], me: me) == .here)
expect("no running pane is control by nobody", TabDone.control(labels: [], me: me) == .nobody)
expect("panes labelled for another machine are that machine's", TabDone.control(labels: [elsewhere, elsewhere], me: me) == .machine)
expect("a pane with no label is the host's own", TabDone.control(labels: [nil], me: me) == .machine)
expect("some panes here and some elsewhere are changing hands", TabDone.control(labels: [me, elsewhere], me: me) == .mixed)
expect("two other machines are changing hands, not one machine's", TabDone.control(labels: [elsewhere, "88888888-2222-4333-8444-555555555555"], me: me) == .mixed)
expect("a tab this Mac controls, read from the host's status, is allowed", decide([mine(.waiting)], control: TabDone.control(labels: [me], me: me)) == nil)
expect("a tab taken over, read from the host's status, is refused", decide([mine(.waiting)], control: TabDone.control(labels: [elsewhere], me: me)) == .controlledElsewhere)
expect("a turn the host reports is refused", decide([mine(.working)], control: TabDone.control(labels: [me], me: me)) == .working)
// The host's own check, right before it closes the tab.
expect("the host allows a tab the asker controls with nothing in a turn", TabDone.hostRefusal(controls: [me, me], asker: me, turns: [.waiting, nil]) == nil)
expect("the host allows a tab with nothing running", TabDone.hostRefusal(controls: [], asker: me, turns: []) == nil)
expect("the host refuses a pane another machine holds", TabDone.hostRefusal(controls: [me, elsewhere], asker: me, turns: [.waiting]) == .controlledElsewhere)
expect("the host refuses a pane with no label", TabDone.hostRefusal(controls: [nil], asker: me, turns: [.waiting]) == .controlledElsewhere)
for turn in [Turn.working, .background, .permission, .question, .plan, .input] {
    expect("the host refuses a session in a \(turn) turn that started while the request travelled", TabDone.hostRefusal(controls: [me], asker: me, turns: [.waiting, turn]) == .busy)
}
expect("the host allows a session that failed or waits", TabDone.hostRefusal(controls: [me], asker: me, turns: [.failed, .waiting]) == nil)
expect("control is told before a turn", TabDone.hostRefusal(controls: [elsewhere], asker: me, turns: [.working]) == .controlledElsewhere)
expect("the host's words name the machine", TabDone.HostRefusal.busy.words(machine: "the desktop").contains("on the desktop") && TabDone.HostRefusal.controlledElsewhere.words(machine: "the desktop").contains("on the desktop"))

print("check-open: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
