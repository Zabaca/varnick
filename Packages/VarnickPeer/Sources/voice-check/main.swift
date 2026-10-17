import Foundation
import VarnickPeer

// `make check-voice`: the voice session's pure seams (option 09 of `listening-never-answers`) over a table of cases, with no Varnick, no zmx, no
// claude and no network. The one file it writes is a transcript in a scratch folder. One `error:` line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-voice: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

let utc = TimeZone(identifier: "UTC")!
let pane = UUID()
let t0 = Date(timeIntervalSince1970: 1_760_000_000)

func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
func turn(_ word: Turn, since seconds: TimeInterval) -> PaneTurn { PaneTurn(word, since: after(seconds)) }

// MARK: Which session takes a request

let free = VoiceSession.Held(pane: pane, requestInFlight: false)
let flying = VoiceSession.Held(pane: pane, requestInFlight: true)

func decide(_ name: String, _ held: VoiceSession.Held?, _ turn: PaneTurn?, opened: Bool = false, at seconds: TimeInterval,
            is expected: VoiceSession.Decision) {
    let got = VoiceSession.decide(held: held, turn: turn, opened: opened, now: after(seconds))
    expect("decide: " + name, got == expected, "got \(got), wanted \(expected)")
}

decide("no session starts the first", nil, nil, at: 0, is: .start(.first))
decide("a waiting session takes the next request", free, turn(.waiting, since: 0), at: 30, is: .send)
decide("a session idle for 9 minutes 59 seconds is reused", free, turn(.waiting, since: 0), at: 599, is: .send)
decide("a session idle for 10 minutes is not", free, turn(.waiting, since: 0), at: 600, is: .start(.idle))
decide("a working session starts a new one", free, turn(.working, since: 0), at: 5, is: .start(.working))
decide("a turn that ended with background work counts as working", free, turn(.background, since: 0), at: 5, is: .start(.working))
decide("a turn that isn't known counts as working", free, nil, at: 5, is: .start(.working))
decide("a session waiting on a permission, question, plan or input starts a new one", free, turn(.permission, since: 0), at: 5, is: .start(.needsUser))
decide("a question", free, turn(.question, since: 0), at: 5, is: .start(.needsUser))
decide("a plan", free, turn(.plan, since: 0), at: 5, is: .start(.needsUser))
decide("an input", free, turn(.input, since: 0), at: 5, is: .start(.needsUser))
decide("a turn that stopped on an error", free, turn(.failed, since: 0), at: 5, is: .start(.needsUser))
decide("a session the user opened is never typed into", free, turn(.waiting, since: 0), opened: true, at: 5, is: .start(.opened))
decide("a request in flight is busy", flying, turn(.waiting, since: 0), at: 5, is: .busy)
decide("a request in flight is busy even when the session is opened", flying, turn(.waiting, since: 0), opened: true, at: 5, is: .busy)

func ended(_ name: String, _ turn: PaneTurn?, opened: Bool = false, at seconds: TimeInterval, is expected: Bool) {
    let got = VoiceSession.idleEnded(turn: turn, startedAt: t0, opened: opened, now: after(seconds))
    expect("idle end: " + name, got == expected, "got \(got), wanted \(expected)")
}

ended("an unopened session idle for 10 minutes", turn(.waiting, since: 0), at: 600, is: true)
ended("not yet", turn(.waiting, since: 0), at: 599, is: false)
ended("one that stopped on an error", turn(.failed, since: 0), at: 700, is: true)
ended("a working one is left to finish", turn(.working, since: 0), at: 9000, is: false)
ended("one asking a question is ended after 10 minutes", turn(.question, since: 0), at: 600, is: true)
ended("one asking a question is not ended before", turn(.question, since: 0), at: 599, is: false)
ended("one waiting on a permission, plan or input", turn(.permission, since: 0), at: 9000, is: true)
ended("a plan", turn(.plan, since: 0), at: 9000, is: true)
ended("an input", turn(.input, since: 0), at: 9000, is: true)
ended("one with background work", turn(.background, since: 0), at: 600, is: true)
ended("one the user opened is never ended", turn(.waiting, since: 0), opened: true, at: 9000, is: false)
ended("one the user opened is never ended, whatever its turn", turn(.question, since: 0), opened: true, at: 9000, is: false)
ended("one with no known turn, started 10 minutes ago", nil, at: 600, is: true)
ended("one with no known turn, started a minute ago", nil, at: 60, is: false)

// MARK: The hint

let moment = Date(timeIntervalSince1970: 1_760_626_800)   // Thursday 2025-10-16 15:00 UTC
let hint = VoiceHint.text(device: .mac, now: moment, timeZone: utc, units: .us)
expect("hint: wording", hint == "[Said aloud to Varnick on this Mac on Thursday, October 16, 2025, 3:00 PM; US units. A voice reads your reply: answer in one or two short spoken sentences, with no lists, links, paths, code or Markdown, and say where the answer came from in a few words. Varnick's search tool (mcp__varnick__search) finds the user's pages, bookmarks and Claude sessions.]", hint)
expect("hint: starts with [ so it can't open a slash, bang or hash mode", hint.hasPrefix("["))
let phoneHint = VoiceHint.text(device: .phone, now: moment, timeZone: TimeZone(identifier: "Asia/Tokyo")!, units: .metric, searchTool: false)
expect("hint: phone, metric, another zone, no search tool",
       phoneHint.hasPrefix("[Said aloud to Varnick from the phone on Friday, October 17, 2025, 12:00 AM; metric units.") && !phoneHint.contains("search"), phoneHint)

// MARK: What is typed in

let said = VoicePaste.line(hint: "[hint]", request: "what's\nthe weather\t\u{1b}[201~ \u{1b}[200~ in  Paris\r")
expect("paste: no control byte and one line", !said.unicodeScalars.contains { $0.properties.generalCategory == .control }, said)
expect("paste: the hint, then the request, white space collapsed", said == "[hint] what's the weather [201~ [200~ in Paris", said)
expect("paste: a request is cut", VoicePaste.line(hint: "[h]", request: String(repeating: "a", count: 900)).count == 3 + 1 + VoiceSession.maxRequestCharacters)
expect("paste: C1 codes and DEL go", VoicePaste.sanitized("a\u{7f}b\u{85}c\u{9b}d") == "a b c d", VoicePaste.sanitized("a\u{7f}b\u{85}c\u{9b}d"))
expect("paste: an empty request", VoicePaste.line(hint: "[h]", request: " \n ") == "[h] ")

// MARK: The reply

func speakable(_ name: String, _ reply: String, is expected: String?) {
    let got = VoiceReply.speakable(reply)
    expect("speakable: " + name, got == expected, "got \(got ?? "nil"), wanted \(expected ?? "nil")")
}

speakable("two sentences of three", "It is sunny. It is 72 degrees. Bring a hat.", is: "It is sunny. It is 72 degrees.")
speakable("the Sources list goes", "The current stable version of Swift is 6.4, released 15 September 2026.\n\nSources: [Swift 6.4 Released](https://www.swift.org/blog/swift-6.4-released/), [Wikipedia](https://en.wikipedia.org/wiki/Swift)",
          is: "The current stable version of Swift is 6.4, released 15 September 2026.")
speakable("a bold Sources heading goes", "Costco closes at 8 PM.\n\n**Sources**\n- https://example.com/hours", is: "Costco closes at 8 PM.")
speakable("a link is its text and an address goes", "Per [the site](https://example.com/a) it opens at 9. See https://example.com/b for more.", is: "Per the site it opens at 9. See for more.")
speakable("markdown goes", "**Yes.** Use `make build` first.", is: "Yes. Use make build first.")
speakable("a sentence that begins with the word Sources stays", "Sources say it opens at nine.", is: "Sources say it opens at nine.")
speakable("only sources is nothing", "Sources:\n- https://example.com", is: nil)
speakable("an empty reply is nothing", "  \n", is: nil)

func stop(_ json: String, savedAt seconds: TimeInterval = 10, conversation: String = "abc", since: TimeInterval = 5) -> String? {
    VoiceReply.answer(inStop: Data(json.utf8), savedAt: after(seconds), conversation: conversation, since: after(since))
}

expect("stop: the message of this conversation", stop(#"{"session_id":"abc","last_assistant_message":"It printed spike-42.","hook_event_name":"Stop"}"#) == "It printed spike-42.")
expect("stop: trimmed", stop(#"{"session_id":"abc","last_assistant_message":"  Yes.\n"}"#) == "Yes.")
expect("stop: another conversation's input", stop(#"{"session_id":"xyz","last_assistant_message":"No."}"#) == nil)
expect("stop: an input saved before the request", stop(#"{"session_id":"abc","last_assistant_message":"Old."}"#, savedAt: 4) == nil)
expect("stop: no message field (an older Claude Code)", stop(#"{"session_id":"abc","background_tasks":[]}"#) == nil)
expect("stop: an empty message", stop(#"{"session_id":"abc","last_assistant_message":""}"#) == nil)
expect("stop: unreadable", stop("not json") == nil)

// The transcript's fallback, over a scratch file.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-check-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func entry(_ type: String, at seconds: TimeInterval, blocks: [[String: Any]]) -> String {
    let object: [String: Any] = ["type": type, "timestamp": iso.string(from: after(seconds)), "message": ["role": type, "content": blocks]]
    return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
}
func text(_ words: String) -> [[String: Any]] { [["type": "text", "text": words]] }
let transcript = scratch.appendingPathComponent("t.jsonl")
let lines = [
    entry("assistant", at: 1, blocks: text("An old answer.")),
    entry("user", at: 6, blocks: text("[Said aloud to Varnick] what is 6 times 7")),
    entry("assistant", at: 7, blocks: [["type": "tool_use", "id": "x", "name": "Bash", "input": ["command": "echo hi"]]]),
    entry("assistant", at: 8, blocks: text("It is 42.")),
    entry("assistant", at: 9, blocks: [["type": "tool_use", "id": "y", "name": "Bash", "input": [:]]]),
]
try? (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
expect("transcript: the last text since the request", TranscriptReader.lastAssistantText(path: transcript.path, since: after(5)) == "It is 42.")
expect("transcript: nothing since a later time", TranscriptReader.lastAssistantText(path: transcript.path, since: after(20)) == nil)
expect("transcript: no file", TranscriptReader.lastAssistantText(path: scratch.appendingPathComponent("none").path, since: after(0)) == nil)

// MARK: Watching a request

func observation(_ seconds: TimeInterval, taken: TimeInterval? = nil, web: TimeInterval? = nil, turn: PaneTurn? = nil, stop: String? = nil,
                 transcript: String? = nil, alive: Bool = true) -> VoiceWatch.Observation {
    VoiceWatch.Observation(now: after(seconds), takenAt: taken.map(after), webAt: web.map(after), turn: turn, stopAnswer: stop,
                           transcriptAnswer: transcript, paneAlive: alive)
}

/// Runs a script of observations through a watch sent at 100 s, and gathers the events with the time they came.
func watch(_ name: String, newSession: Bool = false, _ script: [VoiceWatch.Observation], is expected: [VoiceWatch.Event]) {
    var watch = VoiceWatch(sent: after(100), newSession: newSession)
    var got: [VoiceWatch.Event] = []
    for step in script { got += watch.observe(step) }
    expect("watch: " + name, got == expected, "got \(got), wanted \(expected)")
}

watch("taken, then answered", [
    observation(100.5, turn: turn(.waiting, since: 50)),
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(104, taken: 100.8, turn: turn(.waiting, since: 103.5), stop: "It is 42."),
], is: [.taken, .answered("It is 42.")])

watch("a waiting turn from before the request is not an answer", [
    observation(101, taken: 100.8, turn: turn(.waiting, since: 90), stop: "Old."),
    observation(103, taken: 100.8, turn: turn(.working, since: 102)),
], is: [.taken])

watch("looking up is said once", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(103, taken: 100.8, web: 102, turn: turn(.working, since: 100.8)),
    observation(105, taken: 100.8, web: 104, turn: turn(.working, since: 100.8)),
    observation(110, taken: 100.8, web: 104, turn: turn(.waiting, since: 109), stop: "It opens at nine."),
], is: [.taken, .lookingUp, .answered("It opens at nine.")])

watch("a web marker from an earlier request is not this one's", [
    observation(101, taken: 100.8, web: 60, turn: turn(.working, since: 100.8)),
], is: [.taken])

watch("the question ends the request", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(105, taken: 100.8, turn: turn(.question, since: 104)),
    observation(106, taken: 100.8, turn: turn(.question, since: 104)),
], is: [.taken, .needsYou])

watch("a turn that stopped on an error", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(105, taken: 100.8, turn: turn(.failed, since: 104)),
], is: [.taken, .failed(.turnFailed)])

watch("a turn that ended with background work is answered all the same", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(110, taken: 100.8, turn: turn(.background, since: 109), stop: "I started it."),
], is: [.taken, .answered("I started it.")])

watch("the transcript answers when the Stop input has none after the grace", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(109.5, taken: 100.8, turn: turn(.waiting, since: 109), transcript: "From the transcript."),
    observation(110.6, taken: 100.8, turn: turn(.waiting, since: 109), transcript: "From the transcript."),
], is: [.taken, .answered("From the transcript.")])

watch("an answerless turn", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(109, taken: 100.8, turn: turn(.waiting, since: 108)),
    observation(113, taken: 100.8, turn: turn(.waiting, since: 108)),
    observation(115, taken: 100.8, turn: turn(.waiting, since: 108)),
], is: [.taken, .noAnswer])

watch("not taken in 5 seconds", [
    observation(103, turn: turn(.waiting, since: 50)),
    observation(105.5, turn: turn(.waiting, since: 50)),
    observation(106, turn: turn(.waiting, since: 50)),
], is: [.failed(.notTaken)])

watch("a marker from before the request is not taken", [
    observation(103, taken: 90, turn: turn(.waiting, since: 50)),
    observation(106, taken: 90, turn: turn(.waiting, since: 50)),
], is: [.failed(.notTaken)])

watch("a new session has 30 seconds to take its first prompt", newSession: true, [
    observation(120, turn: turn(.working, since: 100)),
    observation(129, turn: turn(.working, since: 100)),
    observation(131, taken: 130.5, turn: turn(.working, since: 100)),
], is: [.taken])

watch("a new session that never takes it", newSession: true, [
    observation(120, turn: turn(.working, since: 100)),
    observation(131, turn: turn(.working, since: 100)),
], is: [.failed(.notTaken)])

watch("the pane is gone", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(102, taken: 100.8, alive: false),
], is: [.taken, .failed(.sessionGone)])

watch("the deadline ends the request and not the turn", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(159, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(161, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(165, taken: 100.8, turn: turn(.waiting, since: 164), stop: "Late."),
], is: [.taken, .deadline])

watch("an answer on the deadline's own moment is still the answer", [
    observation(101, taken: 100.8, turn: turn(.working, since: 100.8)),
    observation(161, taken: 100.8, turn: turn(.waiting, since: 160.5), stop: "Just in time."),
], is: [.taken, .answered("Just in time.")])

watch("the first observation can carry taken and the answer both", [
    observation(104, taken: 100.8, web: 102, turn: turn(.waiting, since: 103), stop: "Fast."),
], is: [.taken, .lookingUp, .answered("Fast.")])

// MARK: The search tool's arguments

func parsed(_ arguments: [String: Any]) -> VoiceSearchArguments? {
    if case .success(let found) = VoiceSearchArguments.parse(arguments) { return found }
    return nil
}

func refusal(_ arguments: [String: Any]) -> String? {
    if case .failure(let refusal) = VoiceSearchArguments.parse(arguments) { return refusal.message }
    return nil
}

expect("search: a query alone", parsed(["query": "  cheap flights "]) == VoiceSearchArguments(query: "cheap flights", project: nil, from: nil, to: nil))
expect("search: a project", parsed(["query": "login bug", "project": "pantry"])?.project == "pantry")
expect("search: a blank project is none", parsed(["query": "x", "project": "  "])?.project == nil)
expect("search: no query", refusal(["project": "pantry"])?.hasPrefix("query is required") == true)
expect("search: a blank query", refusal(["query": "   "])?.hasPrefix("query is required") == true)
expect("search: a number as the query", refusal(["query": 42]) == "query must be text, not a number or a boolean")
expect("search: a boolean as the project", refusal(["query": "x", "project": true]) == "project must be text, not a number or a boolean")
expect("search: a number as from", refusal(["query": "x", "from": 20261015]) == "from must be text, not a number or a boolean")
expect("search: a number as to", refusal(["query": "x", "to": 1.5])?.hasPrefix("to must be text") == true)
expect("search: an argument it doesn't take", refusal(["query": "x", "limit": 5])?.hasPrefix("limit is not an argument") == true)
expect("search: a long query is cut", parsed(["query": String(repeating: "a", count: 900)])?.query.count == VoiceSession.maxRequestCharacters)
let range = parsed(["query": "x", "from": "2026-10-15T09:00:00-07:00", "to": "2026-10-16T09:00:00-07:00"])
expect("search: a window with offsets", range?.window(now: after(0)) == DateInterval(start: Date(timeIntervalSince1970: 1_792_080_000), end: Date(timeIntervalSince1970: 1_792_166_400)),
       "\(String(describing: range?.window(now: after(0))))")
expect("search: a date alone", parsed(["query": "x", "from": "2026-10-15"])?.from != nil)
expect("search: only from runs to now", parsed(["query": "x", "from": "2026-10-15"])?.window(now: Date(timeIntervalSince1970: 1_792_300_000))?.end == Date(timeIntervalSince1970: 1_792_300_000))
expect("search: only to starts at the epoch", parsed(["query": "x", "to": "2026-10-15T00:00:00Z"])?.window(now: after(0))?.start == Date(timeIntervalSince1970: 0))
expect("search: no window without a time", parsed(["query": "x"])?.window(now: after(0)) == nil)
expect("search: a time that isn't one", refusal(["query": "x", "from": "yesterday"])?.hasPrefix("from must be an ISO 8601 time") == true)
expect("search: to before from", refusal(["query": "x", "from": "2026-10-16", "to": "2026-10-15"]) == "to is before from")

// MARK: Claude Code's warning for skip-permissions mode

func config(_ text: String?) -> URL {
    let file = scratch.appendingPathComponent("config-\(UUID().uuidString).json")
    if let text { try? text.write(to: file, atomically: true, encoding: .utf8) }
    return file
}

expect("skip warning: accepted", ClaudeTrust.skipPermissionsAccepted(file: config(#"{"bypassPermissionsModeAccepted":true,"projects":{}}"#)) == true)
expect("skip warning: not accepted", ClaudeTrust.skipPermissionsAccepted(file: config(#"{"bypassPermissionsModeAccepted":false}"#)) == false)
expect("skip warning: no key", ClaudeTrust.skipPermissionsAccepted(file: config(#"{"projects":{}}"#)) == false)
expect("skip warning: only that key, at the top", ClaudeTrust.skipPermissionsAccepted(file: config(#"{"projects":{"/x":{"bypassPermissionsModeAccepted":true}}}"#)) == false)
expect("skip warning: no file", ClaudeTrust.skipPermissionsAccepted(file: config(nil)) == nil)
expect("skip warning: unreadable", ClaudeTrust.skipPermissionsAccepted(file: config("not json")) == nil)

// MARK: The hooks

let settings = ClaudeCommand.hookSettings(problems: true, voice: true)
let plain = ClaudeCommand.hookSettings(problems: true)
expect("hooks: the voice entries are only in the voice session's settings", settings.contains(".varnick-voice-taken") && settings.contains(".varnick-voice-web")
       && !plain.contains(".varnick-voice"))
expect("hooks: the web marker has its matcher", settings.contains("^(WebSearch|WebFetch)$") || settings.contains(#"^(WebSearch|WebFetch)$"#))
expect("hooks: nothing changes for an ordinary session", ClaudeCommand.hookSettings(problems: false) == ClaudeCommand.hookSettings(problems: false, voice: false))
expect("hooks: the work-link PreToolUse entry stays beside the web marker", settings.contains("PreToolUse") && settings.components(separatedBy: "\"PreToolUse\"").count == 2)

print("check-voice: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
