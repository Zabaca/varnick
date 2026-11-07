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

print("check-open: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
