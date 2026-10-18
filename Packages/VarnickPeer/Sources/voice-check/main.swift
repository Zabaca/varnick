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

// A working turn whose request was given up on (the deadline, or a cancel) is busy, not replaceable: a new session would end it.
func decideAbandoned(_ name: String, _ turn: PaneTurn?, abandoned: TimeInterval?, at seconds: TimeInterval, is expected: VoiceSession.Decision) {
    let got = VoiceSession.decide(held: free, turn: turn, opened: false, now: after(seconds), abandonedAt: abandoned.map(after))
    expect("decide: " + name, got == expected, "got \(got), wanted \(expected)")
}

decideAbandoned("a working turn after the deadline is busy", turn(.working, since: 0), abandoned: 60, at: 90, is: .busy)
decideAbandoned("a turn with background work after a cancel is busy", turn(.background, since: 0), abandoned: 10, at: 20, is: .busy)
decideAbandoned("a turn that isn't known after a cancel is busy", nil, abandoned: 10, at: 20, is: .busy)
decideAbandoned("busy for just under ten minutes", turn(.working, since: 0), abandoned: 0, at: 599, is: .busy)
decideAbandoned("past ten minutes a working session is replaced", turn(.working, since: 0), abandoned: 0, at: 600, is: .start(.working))
decideAbandoned("a working turn nobody gave up on is replaced as before", turn(.working, since: 0), abandoned: nil, at: 20, is: .start(.working))
decideAbandoned("a turn that finished since is reused", turn(.waiting, since: 40), abandoned: 10, at: 50, is: .send)
decideAbandoned("a turn waiting on the user is not made busy", turn(.question, since: 40), abandoned: 10, at: 50, is: .start(.needsUser))

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
expect("paste: a request is cut", VoicePaste.line(hint: "[h]", request: String(repeating: "a", count: 2000)).count == 3 + 1 + VoiceSession.maxRequestCharacters)
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
expect("search: a long query is cut", parsed(["query": String(repeating: "a", count: 2000)])?.query.count == VoiceSession.maxRequestCharacters)
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

// MARK: Voice mode on the phone (option 05 of `phone-page-is-only-a-browser-tab`, protocol 30)

let askID = "2b6b0d6e-8f0a-4c1e-9d3a-5a7c1e2f3b4d"
let otherID = "9c1a7d52-0e3b-4a6f-8d21-6b4e5f7a8c90"
let bytes = { (count: Int) in Data(repeating: 1, count: count) }

expect("protocol: this is 31", PeerProtocol.version == 31)

var voiceRequest = PeerRequest(.voiceAsk)
voiceRequest.voice = PeerVoiceAsk(id: askID, text: "what time is it", moment: 1_760_000_000, zone: "America/Denver", units: "us")
expect("wire: a voice request round-trips", PeerJSON.decode(PeerRequest.self, from: PeerJSON.line(voiceRequest))?.voice == voiceRequest.voice)
var voiceAnswer = PeerReply.success()
voiceAnswer.voice = PeerVoiceReply(id: askID, events: [PeerVoiceEvent(.taken), .answered(text: "It is noon.", audio: Data([1, 2, 3]))], next: 2, done: true)
let decodedAnswer = PeerJSON.decode(PeerReply.self, from: PeerJSON.line(voiceAnswer))
expect("wire: a voice reply round-trips", decodedAnswer?.voice == voiceAnswer.voice)
expect("wire: an event decodes from the page server's JSON",
       PeerJSON.decode(PeerVoiceReply.self, from: #"{"id":"x","events":[{"kind":"heard"}],"next":1}"#)?.events?.first?.kind == .heard)

// The hint: the phone's own moment, zone and units, as the host takes them.
let hostNow = Date(timeIntervalSince1970: 1_760_000_000)
let denver = TimeZone(identifier: "America/Denver")!
let hinted = PeerVoiceAsk(id: askID, moment: 1_760_003_600, zone: "Asia/Tokyo", units: "metric").hint(now: hostNow, hostZone: denver, hostUnits: .us)
expect("hint: the phone's moment, zone and units win", hinted.moment == Date(timeIntervalSince1970: 1_760_003_600) && hinted.zone.identifier == "Asia/Tokyo" && hinted.units == .metric)
let unhinted = PeerVoiceAsk(id: askID, moment: 1_760_000_000 + 3 * 86_400, zone: "Not/AZone", units: "furlongs").hint(now: hostNow, hostZone: denver, hostUnits: .us)
expect("hint: a moment days off, a zone and units it doesn't know are the host's", unhinted.moment == hostNow && unhinted.zone == denver && unhinted.units == .us)
expect("hint: nothing given is the host's", PeerVoiceAsk(id: askID).hint(now: hostNow, hostZone: denver, hostUnits: .metric).units == .metric)

// The events of the voice session, as the phone is told them.
expect("events: taken and looking up", PeerVoiceEvent.of(.taken, session: "s") == PeerVoiceEvent(.taken) && PeerVoiceEvent.of(.lookingUp, session: "s") == PeerVoiceEvent(.lookingUp))
expect("events: needs you carries the session to open", PeerVoiceEvent.of(.needsYou, session: "varnick-x") == PeerVoiceEvent(.needsYou, session: "varnick-x"))
expect("events: an answer is made by the Mac, with its audio", PeerVoiceEvent.of(.answered("x"), session: "s") == nil)
expect("events: a failure says a line and a kind", PeerVoiceEvent.of(.failed(.notTaken), session: "s") == PeerVoiceEvent(.failed, text: "Claude didn't take that.", failure: "not taken"))
expect("events: the deadline and no answer", PeerVoiceEvent.of(.deadline, session: "s")?.kind == .deadline && PeerVoiceEvent.of(.noAnswer, session: "s")?.kind == .noAnswer)
let answered = PeerVoiceEvent.answered(text: "It is noon in Denver. See [the clock](https://example.com/clock). Sources:\n- https://example.com", audio: nil)
expect("events: an answer carries its text and its spoken form", answered.text?.hasPrefix("It is noon") == true && answered.spoken == "It is noon in Denver. See the clock." && answered.audio == nil, "\(answered)")
expect("events: an answer that cleans to nothing is spoken as the line", PeerVoiceEvent.answered(text: "Sources:\n- a", audio: nil).spoken == "I couldn't answer that.")
expect("events: a long answer is cut", PeerVoiceEvent.answered(text: String(repeating: "word ", count: 5_000), audio: nil).text?.count == PeerVoiceEvent.maxAnswerCharacters)
expect("events: which ones end an ask", [PeerVoiceEvent.Kind.needsYou, .answered, .noAnswer, .failed, .deadline].allSatisfy { PeerVoiceEvent($0).ends }
       && ![PeerVoiceEvent.Kind.heard, .collected, .taken, .lookingUp].contains { PeerVoiceEvent($0).ends })

// Audio: the WAV the phone plays, and the samples.
let wav = VoiceAudio.wav(pcm16: Data([1, 0, 2, 0, 3, 0]), rate: 16_000)
expect("audio: a WAV is a 44 byte header and the samples", wav.count == 44 + 6 && wav.prefix(4) == Data("RIFF".utf8) && wav.dropFirst(8).prefix(8) == Data("WAVEfmt ".utf8)
       && wav.dropFirst(36).prefix(4) == Data("data".utf8))
expect("audio: its sizes are right", wav[4] == 42 && wav[40] == 6 && wav[24] == 0x80 && wav[25] == 0x3E, "\(Array(wav.prefix(44)))")
expect("audio: floats become 16-bit and back, clipped", VoiceAudio.floats(fromPCM16: VoiceAudio.pcm16(fromFloats: [0, 0.5, -0.5, 2, -2])).map { ($0 * 100).rounded() / 100 } == [0, 0.5, -0.5, 1, -1])
expect("audio: the peak", VoiceAudio.peak(ofPCM16: VoiceAudio.pcm16(fromFloats: [0, 0.25, -0.5, 0.1])) > 0.49 && VoiceAudio.peak(ofPCM16: bytes(0)) == 0)
expect("audio: a last odd byte is dropped", VoiceAudio.floats(fromPCM16: Data([0, 64, 7])).count == 1)

// The upload of an utterance in chunks.
var upload = VoiceUploads(limit: 2)
func add(_ id: String, _ seq: Int, last: Bool = false, size: Int = 32_000, rate: Int? = 16_000, at seconds: TimeInterval = 0) -> VoiceUploads.Outcome {
    upload.add(id: id, seq: seq, last: last, rate: rate, audio: bytes(size), now: t0.addingTimeInterval(seconds))
}
expect("upload: chunks in order, the last completes the utterance", add(askID, 0) == .more && add(askID, 1) == .more && add(askID, 2, last: true, size: 100) == .complete(bytes(64_100)))
expect("upload: it is gone once complete", upload.count == 0)
expect("upload: a chunk that skips is refused and drops the utterance", add(askID, 0) == .more && add(askID, 2) == .refused("That audio chunk is out of order") && upload.count == 0)
expect("upload: a first chunk that isn't the first", add(askID, 1) == .refused("That audio chunk is out of order"))
expect("upload: a chunk over the limit", add(askID, 0, size: VoiceAudio.maxChunkBytes + 2) == .refused("That audio chunk is the wrong size"))
expect("upload: an odd chunk", add(askID, 0, size: 31) == .refused("That audio chunk is the wrong size"))
expect("upload: another rate", add(askID, 0, rate: 48_000) == .refused("Voice mode sends 16 kHz audio"))
expect("upload: a chunk number below zero", add(askID, -1) == .refused("That audio chunk is out of order"))
var length = 0
var overrun: VoiceUploads.Outcome = .more
for seq in 0..<40 where overrun == .more {
    overrun = add(askID, seq, size: 48_000)
    length += 48_000
}
expect("upload: more than 30 seconds is refused", overrun == .refused("That request is too long: say less at once"), "\(overrun) at \(length)")
expect("upload: only so many at once", add("a", 0) == .more && add("b", 0) == .more && add("c", 0) == .refused("Too many requests are being sent"))
expect("upload: one that goes quiet is dropped", add("d", 0, at: 61) == .more && upload.count == 1)
expect("upload: the limit counts the live ones", add("e", 0, at: 62) == .more && add("f", 0, at: 63) == .refused("Too many requests are being sent"))

// The ledger: what the phone polls.
var ledger = VoiceLedger(limit: 3)
expect("ledger: an ask begins", ledger.begin(askID, now: t0) && ledger.busy())
expect("ledger: only one at a time, and no id twice", !ledger.begin(otherID, now: t0) && !ledger.begin(askID, now: t0))
ledger.add(PeerVoiceEvent(.heard, text: "hi"), to: askID, now: after(1))
ledger.add(PeerVoiceEvent(.taken), to: askID, now: after(2))
expect("ledger: the events so far, and where to ask next", ledger.read(askID, after: 0) == PeerVoiceReply(id: askID, events: [PeerVoiceEvent(.heard, text: "hi"), PeerVoiceEvent(.taken)], next: 2, done: false))
expect("ledger: only what came after", ledger.read(askID, after: 1)?.events == [PeerVoiceEvent(.taken)] && ledger.read(askID, after: 2)?.events == [])
expect("ledger: an `after` beyond the end or below zero is clamped", ledger.read(askID, after: 99)?.next == 2 && ledger.read(askID, after: -5)?.events?.count == 2)
ledger.add(PeerVoiceEvent(.answered, text: "a"), to: askID, now: after(3))
ledger.add(PeerVoiceEvent(.failed), to: askID, now: after(4))
expect("ledger: the end closes it, and nothing is added after", ledger.read(askID, after: 0)?.done == true && ledger.read(askID, after: 0)?.events?.count == 3 && !ledger.busy())
expect("ledger: an unknown ask is nothing", ledger.read(otherID, after: 0) == nil)
expect("ledger: the next ask can begin once it ended", ledger.begin(otherID, now: after(5)))
expect("ledger: a finished ask is kept 5 minutes", ledger.read(askID, after: 0) != nil)
ledger.add(PeerVoiceEvent(.deadline), to: otherID, now: after(6))
ledger.prune(now: after(3 + VoiceLedger.keep - 1))
expect("ledger: still there just before", ledger.read(askID, after: 0) != nil)
ledger.prune(now: after(3 + VoiceLedger.keep + 1))
expect("ledger: gone after", ledger.read(askID, after: 0) == nil && ledger.read(otherID, after: 0) != nil)
var crowded = VoiceLedger(limit: 2)
for (index, id) in ["a", "b", "c"].enumerated() {
    _ = crowded.begin(id, now: after(Double(index)))
    crowded.add(PeerVoiceEvent(.deadline), to: id, now: after(Double(index)))
}
expect("ledger: no more than its limit, the oldest goes", crowded.count == 2 && crowded.read("a", after: 0) == nil && crowded.read("c", after: 0) != nil)

// A phone's request ends only at "over" (protocol 31, ADR 0044's amendment of 2026-10-17): its segments are collected.
let runA = "5d0b5f2e-3c4d-4e6f-8a7b-9c0d1e2f3a4b"
let runB = "6e1c6a3f-4d5e-4f70-9b8c-0d1e2f3a4b5c"
var collector = VoiceCollector()
func segment(_ name: String, _ line: String, device: String = "phone", run: String = runA, at seconds: TimeInterval, canTake: Bool = true,
             is expected: VoiceCollector.Step) {
    let got = collector.add(line, device: device, run: run, now: after(seconds), canTake: canTake)
    expect("collector: " + name, got == expected, "got \(got), wanted \(expected)")
}

segment("a segment without over is collected, not asked", "what was I working on", at: 0, is: .collected("what was I working on"))
segment("a long pause between segments changes nothing", "yesterday afternoon", at: 30, is: .collected("what was I working on yesterday afternoon"))
segment("a segment that is only a cough adds nothing", " . ", at: 31, is: .collected("what was I working on yesterday afternoon"))
segment("over ends it, and is taken out", "the one about pantry over", at: 32, is: .take("what was I working on yesterday afternoon the one about pantry"))
segment("then the next request starts clean", "what time is it", at: 33, is: .collected("what time is it"))
expect("collector: it began with its first segment", collector.began(of: "phone") == after(33) && collector.began(of: "nobody") == nil)
segment("over alone ends it", "Over.", at: 34, is: .take("what time is it"))
expect("collector: nothing is left once it is taken", collector.began(of: "phone") == nil)
segment("over with nothing collected is nothing", "over", at: 35, is: .collected(""))
segment("over in the middle of a segment is not the end", "move it over there", at: 36, is: .collected("move it over there"))
segment("another phone has its own request", "set a timer", device: "other", at: 37, is: .collected("set a timer"))
segment("the first is still there", "now", at: 38, is: .collected("move it over there now"))
segment("a new Voice mode run drops what the last left", "hello", run: runB, at: 39, is: .collected("hello"))
segment("the other phone's request is not touched by it", "for ten minutes over", device: "other", at: 40, is: .take("set a timer for ten minutes"))
// Over while the voice session is on another request: kept, not lost, and taken at the next over.
segment("over while the voice session is busy is kept", "in Tokyo over", run: runB, at: 41, canTake: false, is: .busy("hello in Tokyo"))
segment("and its words stay on the request", "and Paris", run: runB, at: 42, is: .collected("hello in Tokyo and Paris"))
segment("then over takes it", "over", run: runB, at: 43, is: .take("hello in Tokyo and Paris"))
// The cap, from the first segment: taken as it stands when a segment arrives past it, or by the timer.
var long = VoiceCollector()
_ = long.add("one", device: "p", run: runA, now: after(100), canTake: true)
_ = long.add("x", device: "p", run: runA, now: after(130), canTake: true)
let capped = long.add("two", device: "p", run: runA, now: after(100 + VoiceCollector.maxSeconds + 1), canTake: true)
expect("collector: past the cap a request is taken as it stands", capped == .take("one x two"), "got \(capped)")
var timed = VoiceCollector()
_ = timed.add("one", device: "p", run: runA, now: after(100), canTake: true)
_ = timed.add("two", device: "p", run: runA, now: after(130), canTake: true)
expect("collector: the timer takes a request that began then", timed.takeDue(device: "p", began: after(99), canTake: true) == nil)
expect("collector: and not while the voice session is busy", timed.takeDue(device: "p", began: after(100), canTake: false) == .busy("one two"))
expect("collector: it is taken as it stands", timed.takeDue(device: "p", began: after(100), canTake: true) == .take("one two"))
expect("collector: once", timed.takeDue(device: "p", began: after(100), canTake: true) == nil)
var bulky = VoiceCollector()
let wordy = String(repeating: "word ", count: VoiceSession.maxRequestCharacters / 5 + 20)
if case .take(let said) = bulky.add(wordy, device: "p", run: runA, now: after(0), canTake: true) {
    expect("collector: at the character cap a request is taken, cut to it", said.count == VoiceSession.maxRequestCharacters)
} else {
    expect("collector: at the character cap a request is taken", false)
}
expect("collector: the cap is the Mac's", VoiceCollector.maxSeconds == 60 && VoiceSession.maxRequestCharacters == 1500)

// A segment's ledger entry is not an ask until its request is taken.
var segments = VoiceLedger(limit: 3)
expect("ledger: segments can be open together", segments.begin("s1", asking: false, now: t0) && segments.begin("s2", asking: false, now: t0) && !segments.busy())
segments.add(PeerVoiceEvent(.collected, text: "so far"), to: "s1", now: after(1))
expect("ledger: collected leaves a segment open, for the cap's take", segments.read("s1", after: 0)?.done == false)
segments.finish("s1", now: after(1))
expect("ledger: closing it ends it with no event", segments.read("s1", after: 0)?.done == true && segments.read("s1", after: 0)?.events?.count == 1)
segments.add(PeerVoiceEvent(.taken), to: "s1", now: after(1))
expect("ledger: nothing is added after", segments.read("s1", after: 0)?.events?.count == 1)
expect("ledger: a segment can begin beside an open one", segments.begin("s3", asking: false, now: after(1)))
segments.markAsking("s3")
expect("ledger: a request taken makes the host busy", segments.busy() && !segments.begin("ask", now: after(1)))
expect("ledger: a segment still can, the finished entry making room",
       segments.begin("s4", asking: false, now: after(2)) && segments.read("s1", after: 0) == nil && segments.count == 3)
segments.add(PeerVoiceEvent(.answered, text: "a"), to: "s3", now: after(3))
expect("ledger: the ask's end frees the host", !segments.busy())
var packed = VoiceLedger(limit: 2)
expect("ledger: when every entry is open there is no room", packed.begin("a", asking: false, now: t0) && packed.begin("b", asking: false, now: t0) && !packed.begin("c", asking: false, now: t0))

var runRequest = PeerRequest(.voiceAudio)
runRequest.voice = PeerVoiceAsk(id: askID, audio: "AAAA", seq: 0, last: true, rate: 16_000, run: runA)
expect("wire: a segment's Voice mode run round-trips", PeerJSON.decode(PeerRequest.self, from: PeerJSON.line(runRequest))?.voice?.run == runA)
expect("wire: collected decodes from the page server's JSON",
       PeerJSON.decode(PeerVoiceReply.self, from: #"{"id":"x","events":[{"kind":"collected","text":"hi"}],"next":1,"done":true}"#)?.events?.first == PeerVoiceEvent(.collected, text: "hi"))

// MARK: Voice mode on a Mac (option 10 of listening-never-answers)

func ends(_ name: String, _ outcome: VoiceMode.Outcome, endTool: Bool = false, is expected: Bool) {
    let got = VoiceMode.ends(after: outcome, endTool: endTool)
    expect("voice mode ends: " + name, got == expected, "got \(got), wanted \(expected)")
}

ends("an answer keeps it on", .answered, is: false)
ends("no answer keeps it on", .noAnswer, is: false)
ends("the deadline ends it: the turn is still working and a stray line must not meet it", .deadline, is: true)
ends("busy keeps it on", .busy, is: false)
ends("needs you ends it", .needsYou, is: true)
ends("a refusal ends it", .refused, is: true)
ends("a failure ends it", .failed, is: true)
for outcome in [VoiceMode.Outcome.answered, .noAnswer, .deadline, .busy, .needsYou, .refused, .failed] {
    ends("the end tool ends it after \(outcome)", outcome, endTool: true, is: true)
}
expect("ending: the end tool is Claude's", VoiceMode.ending(after: .answered, endTool: true) == .claude && VoiceMode.ending(after: .needsYou, endTool: true) == .claude)
expect("ending: needs you, and the rest", VoiceMode.ending(after: .needsYou, endTool: false) == .needsYou && VoiceMode.ending(after: .refused, endTool: false) == .failure
       && VoiceMode.ending(after: .failed, endTool: false) == .failure)
expect("ending: the deadline's own kind", VoiceMode.ending(after: .deadline, endTool: false) == .deadline)
expect("ending: the log words", VoiceMode.Ending.needsYou.rawValue == "needs you" && VoiceMode.Ending.minute.rawValue == "minute"
       && VoiceMode.Ending.deadline.rawValue == "deadline")

// The minute runs from the end of Varnick's last line, or from entering.
func over(_ name: String, since: TimeInterval = 0, speech: VoiceMode.Speech? = nil, at seconds: TimeInterval, is expected: Bool) {
    let got = VoiceMode.minuteOver(since: after(since), volatile: speech, now: after(seconds))
    expect("minute: " + name, got == expected, "got \(got), wanted \(expected)")
}

expect("minute: sixty seconds", VoiceMode.minute == 60 && VoiceMode.deadline(since: after(10)) == after(70))
over("not over at 59 s", at: 59, is: false)
over("over at 60 s", at: 60, is: true)
over("counted from the last line's end, not from the request", since: 100, at: 159, is: false)
over("counted from the last line's end: over", since: 100, at: 160, is: true)
over("speech begun before the deadline and heard a moment ago holds it open",
     speech: VoiceMode.Speech(start: after(58), arrived: after(60)), at: 61, is: false)
over("speech heard 2.5 s ago has had its final", speech: VoiceMode.Speech(start: after(58), arrived: after(58.5)), at: 61, is: true)
over("speech that began after the deadline holds nothing open", speech: VoiceMode.Speech(start: after(60.5), arrived: after(61)), at: 61.5, is: true)
over("speech before the minute began is not this minute's", since: 100, speech: VoiceMode.Speech(start: after(50), arrived: after(60)), at: 161, is: true)
over("the speech's end does not move the deadline", speech: VoiceMode.Speech(start: after(59), arrived: after(61)), at: 62, is: false)
over("but the final arriving does", speech: VoiceMode.Speech(start: after(59), arrived: after(61)), at: 63.6, is: true)
expect("minute: speech underway before a deadline of 8 s (the wake phrase alone)",
       VoiceMode.speechUnderway(until: after(8), volatile: VoiceMode.Speech(start: after(7.5), arrived: after(9)), now: after(10)))

// The line voice mode sends: a leading wake phrase is dropped, a line without one stays whole.
func line(_ name: String, _ text: String, afterWake: String?, is expected: String?) {
    let got = VoiceMode.requestText(of: text, afterWake: afterWake)
    expect("voice mode line: " + name, got == expected, "got \(got ?? "nil"), wanted \(expected ?? "nil")")
}

line("no wake phrase: the whole line", "and what about tomorrow", afterWake: nil, is: "and what about tomorrow")
line("a wake phrase and a request: the request", "Hey Varnick, what about tomorrow", afterWake: "what about tomorrow", is: "what about tomorrow")
line("the wake phrase alone is nothing", "Hey Varnick", afterWake: "", is: nil)
line("the wake phrase and a stray full stop is nothing", "Hey Varnick.", afterWake: ".", is: nil)
line("a line of punctuation is nothing", " . ", afterWake: nil, is: nil)
line("an empty line is nothing", "", afterWake: nil, is: nil)

// A request for the voice session ends only when the user says "over".
func overStep(_ name: String, _ text: String, collected: String = "", is expected: VoiceMode.OverStep) {
    let got = VoiceMode.overStep(line: text, collected: collected)
    expect("over: " + name, got == expected, "got \(got), wanted \(expected)")
}

overStep("a request and over is taken without it", "what time is it over", is: .take("what time is it"))
overStep("case and a full stop", "What time is it? Over.", is: .take("What time is it?"))
overStep("a comma before it", "what time is it, over", is: .take("what time is it"))
overStep("over alone is taken", "Over.", collected: "what time is it", is: .take("what time is it"))
overStep("over alone, any case and marks", " OVER! ", collected: "what time is it", is: .take("what time is it"))
overStep("over alone with nothing collected is ignored", "over", is: .ignore)
overStep("over and a mark alone with nothing collected is ignored", "Over.", is: .ignore)
overStep("a line without over goes on the request", "what time is it", is: .collect("what time is it"))
overStep("it goes after what was collected", "in Tokyo", collected: "what time is it", is: .collect("what time is it in Tokyo"))
overStep("a last line with over joins what was collected", "in Tokyo over", collected: "what time is it", is: .take("what time is it in Tokyo"))
overStep("over in the middle is not the end", "move it over there", is: .collect("move it over there"))
overStep("over at the start of a line is not the end", "over there is the shop", is: .collect("over there is the shop"))
overStep("a word ending in over is not over", "hangover", is: .collect("hangover"))
overStep("a longer word ending in over", "I want to take over", is: .take("I want to take"))
overStep("takeover is one word", "the takeover", is: .collect("the takeover"))
overStep("it's over is a whole word", "I think it's over", is: .take("I think it's"))
overStep("an empty line is ignored", "", is: .ignore)
overStep("a line of marks is ignored", " . ", collected: "what time is it", is: .ignore)
overStep("a long silence has no part in it", "still thinking", collected: "what time is it", is: .collect("what time is it still thinking"))
// A line as the Mac reads it: the wake phrase, the request and over in one line, or the request over several finals.
let wakeLine = "Hey Varnick, what time is it over"
let afterWake = "what time is it over"
overStep("the wake phrase, the request and over in one line", VoiceMode.requestText(of: wakeLine, afterWake: afterWake) ?? "", is: .take("what time is it"))
overStep("the wake phrase and over, with nothing between, is ignored", VoiceMode.requestText(of: "Hey Varnick over", afterWake: "over") ?? "", is: .ignore)
var joined = ""
for part in ["what was I working on", "yesterday afternoon", "the one about pantry"] {
    guard case .collect(let more) = VoiceMode.overStep(line: part, collected: joined) else { expect("over: a split request goes on", false, part); break }
    joined = more
}
overStep("a request split over several finals", "over", collected: joined, is: .take("what was I working on yesterday afternoon the one about pantry"))
expect("over: the voice session's request limit holds a minute of speech", VoiceSession.maxRequestCharacters >= 1000)

// Varnick's own voice coming back is not a line (a long-delay output outlasts the tail after its last sound).
let spokenLines = ["The weather in Paris is sunny and 72 degrees.", "I found two sessions about pantry."]
func echo(_ name: String, _ line: String, is expected: Bool) {
    let got = VoiceMode.isEcho(line, of: spokenLines)
    expect("echo: " + name, got == expected, "got \(got), wanted \(expected)")
}

echo("the same words", "the weather in Paris is sunny and 72 degrees", is: true)
echo("a part of them", "weather in Paris is sunny", is: true)
echo("one word misheard", "the weather in Paris is sunny and 70 degrees", is: true)
echo("the user's own request", "and what about tomorrow", is: false)
echo("a short line", "in Paris", is: false)
echo("the same words in another order", "is Paris sunny and in the weather", is: false)
echo("nothing said", "", is: false)
expect("echo: nothing was said by Varnick", !VoiceMode.isEcho("the weather in Paris is sunny", of: []))

// The voice hint, with and without voice mode.
let modeHint = VoiceHint.text(device: .mac, now: moment, timeZone: utc, units: .us, voiceMode: true)
expect("hint: voice mode adds its sentence and the end tool's name", modeHint.hasPrefix(String(hint.dropLast()))
       && modeHint.contains("Voice mode is on: this was heard without a wake phrase and may not be meant for you.")
       && modeHint.contains("call mcp__varnick__end_voice_mode.") && modeHint.hasSuffix("]"), modeHint)
expect("hint: without voice mode, the same as before", !hint.contains("Voice mode") && !hint.contains("end_voice_mode")
       && VoiceHint.text(device: .mac, now: moment, timeZone: utc, units: .us, voiceMode: false) == hint)
expect("hint: voice mode still starts with [", modeHint.hasPrefix("["))

print("check-voice: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
