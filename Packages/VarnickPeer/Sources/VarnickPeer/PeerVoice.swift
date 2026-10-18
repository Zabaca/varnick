import Foundation

// Voice mode on the phone (option 05 of `phone-page-is-only-a-browser-tab`, protocols 30 and 31): what a phone's Phone page and a host say to each
// other about the host's voice session (`VoiceSession`, option 09 of `listening-never-answers`). Three requests, each one short relay process:
//   `voiceAudio`  one chunk of a segment's audio, 16-bit little-endian mono, in order; the last chunk ends the segment. A segment is what the page
//                 heard between two pauses, not a request: the user's request ends only when they say "over" (ADR 0044's amendment of 2026-10-17).
//                 The Mac turns the segment into text with Listening's transcriber and adds it to the request being collected for that device and
//                 Voice mode run (`VoiceCollector`); it asks the voice session only when a segment ends with "over".
//   `voiceAsk`    the same ask when the asker has the text already.
//   `voiceStatus` the events of a segment (or ask) from `after` on, polled about once a second like `task_run_status`: collected (the request so far,
//                 which ends a segment that did not end the request), or heard (the whole request, once it ended), taken, looking up, needs you (with
//                 the voice session's zmx session, to open), answered (the text, the spoken form and its audio as a WAV), no answer, failed or past
//                 the deadline.
// Only a Mac answers; a headless host has no transcriber or voice yet. Everything here is a pure function of what was said and when: the Mac's
// adapter (`VoiceRemote`) keeps the ledger and does the transcribing, the asking and the voice.
// Rules that break: docs/agents/where-it-breaks.md, Voice mode on the phone.

/// A voice request's body (`PeerRequest.voice`). Which fields are read depends on the request.
public struct PeerVoiceAsk: Codable, Equatable, Sendable {
    /// The ask's id, a lowercase uuid the Phone page's server chooses. A `voiceAudio` utterance's chunks and its `voiceStatus` polls share it.
    public var id: String
    /// `voiceAsk`: the request, as text.
    public var text: String?
    /// `voiceAudio`: the chunk's audio, base64 of 16-bit little-endian mono samples at `rate`.
    public var audio: String?
    /// `voiceAudio`: the chunk's place in the segment, from 0, and whether it is the last.
    public var seq: Int?
    public var last: Bool?
    public var rate: Int?
    /// `voiceAudio` (protocol 31): the Voice mode run the segment belongs to, a lowercase uuid the page chooses at Start. Segments of one device and one
    /// run make one request; a segment of another run drops what the last one left collected, which is how a request is dropped when the mode ends.
    public var mode: String?
    /// The asker's moment (unix seconds), time zone (an IANA identifier) and units (`us` or `metric`) for the voice hint, on the last chunk or the ask.
    public var moment: Int64?
    public var zone: String?
    public var units: String?
    /// `voiceStatus`: the number of events the asker has already, so a reply carries only the rest.
    public var after: Int?

    public init(id: String, text: String? = nil, audio: String? = nil, seq: Int? = nil, last: Bool? = nil, rate: Int? = nil, mode: String? = nil,
                moment: Int64? = nil, zone: String? = nil, units: String? = nil, after: Int? = nil) {
        self.id = id
        self.text = text
        self.audio = audio
        self.seq = seq
        self.last = last
        self.rate = rate
        self.mode = mode
        self.moment = moment
        self.zone = zone
        self.units = units
        self.after = after
    }

    /// The moment, zone and units of the ask, each as the host takes it: a moment within two days of `now` (else now), a zone it knows (else its own)
    /// and units it knows (else the host's).
    public func hint(now: Date, hostZone: TimeZone, hostUnits: VoiceHint.Units) -> (moment: Date, zone: TimeZone, units: VoiceHint.Units) {
        let said = moment.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let at = said.flatMap { abs($0.timeIntervalSince(now)) <= 2 * 86_400 ? $0 : nil } ?? now
        let askerZone = zone.flatMap { TimeZone(identifier: $0) } ?? hostZone
        let askerUnits: VoiceHint.Units = units == "us" ? .us : units == "metric" ? .metric : hostUnits
        return (at, askerZone, askerUnits)
    }
}

/// One thing that happened to an ask, as `voiceStatus` lists it. The kind travels as text, so one a build doesn't know is skipped by the page.
public struct PeerVoiceEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The whole request, as the Mac made it of the segments up to the one that ended it with "over" (`text`, without the "over"). The voice
        /// session is asked next.
        case heard
        /// A segment was added to the request being collected (`text`: all of it so far, empty when nothing is collected). It ends the segment's own
        /// events: the request goes on until a segment ends with "over". The page shows `text` as the user's line, still being built, and replaces
        /// what it showed before.
        case collected
        /// The voice session took the request.
        case taken
        /// Claude is going to the web.
        case lookingUp
        /// A question or plan waits for the user (`session`: the voice session's zmx session, which the page opens with take).
        case needsYou
        /// The answer (`text`), what is said of it (`spoken`) and its audio as a WAV (`audio`, base64; none when it was too long or couldn't be made).
        case answered
        /// The turn ended and no text was found.
        case noAnswer
        /// It failed (`failure`: a kind; `text`: a line for the user).
        case failed
        /// The phone stops waiting; the turn goes on.
        case deadline
    }

    public var kind: Kind
    public var text: String?
    public var spoken: String?
    public var audio: String?
    public var session: String?
    public var failure: String?

    public init(_ kind: Kind, text: String? = nil, spoken: String? = nil, audio: String? = nil, session: String? = nil, failure: String? = nil) {
        self.kind = kind
        self.text = text
        self.spoken = spoken
        self.audio = audio
        self.session = session
        self.failure = failure
    }

    /// Whether the ask is over once this has happened.
    public var ends: Bool {
        switch kind {
        case .heard, .taken, .lookingUp: false
        case .collected, .needsYou, .answered, .noAnswer, .failed, .deadline: true
        }
    }

    /// An event of the voice session as the phone is told it. `answered` is made by the Mac with the audio (`answered(text:audio:)`).
    public static func of(_ event: VoiceWatch.Event, session: String) -> PeerVoiceEvent? {
        switch event {
        case .taken: PeerVoiceEvent(.taken)
        case .lookingUp: PeerVoiceEvent(.lookingUp)
        case .needsYou: PeerVoiceEvent(.needsYou, session: session)
        case .answered: nil
        case .noAnswer: PeerVoiceEvent(.noAnswer)
        case .failed(let failure): PeerVoiceEvent(.failed, text: failure.line, failure: failure.kind)
        case .deadline: PeerVoiceEvent(.deadline)
        }
    }

    /// The answer, the words a voice says of it (`VoiceReply.speakable`, or the line for an answer that cleans to nothing) and the audio if any.
    public static func answered(text: String, audio: Data?) -> PeerVoiceEvent {
        PeerVoiceEvent(.answered, text: String(text.prefix(maxAnswerCharacters)), spoken: VoiceReply.speakable(text) ?? VoiceReply.nothingSpeakable,
                       audio: audio?.base64EncodedString())
    }

    /// The most of an answer's text a reply carries: a reply line is 1,000,000 bytes at most, and the audio takes most of it.
    public static let maxAnswerCharacters = 8_000
}

extension VoiceWatch.Failure {
    /// The kind for the log and the wire: never a reason's own words.
    public var kind: String {
        switch self {
        case .notTaken: "not taken"
        case .turnFailed: "turn failed"
        case .sessionGone: "session gone"
        }
    }

    /// The line the phone shows, worded as the Mac's Hey Varnick says it.
    public var line: String {
        switch self {
        case .notTaken: "Claude didn't take that."
        case .turnFailed, .sessionGone: "Claude Code isn't answering."
        }
    }
}

extension VoiceReply {
    /// What a voice says when an answer cleans to nothing.
    public static let nothingSpeakable = "I couldn't answer that."
}

/// A `voiceAsk` or `voiceAudio` reply's and a `voiceStatus` reply's body (`PeerReply.voice`).
public struct PeerVoiceReply: Codable, Equatable, Sendable {
    public var id: String
    /// `voiceStatus`: the events from the request's `after` on, the number to ask `after` next, and whether the ask is over.
    public var events: [PeerVoiceEvent]?
    public var next: Int?
    public var done: Bool?

    public init(id: String, events: [PeerVoiceEvent]? = nil, next: Int? = nil, done: Bool? = nil) {
        self.id = id
        self.events = events
        self.next = next
        self.done = done
    }
}

// MARK: - Audio

public enum VoiceAudio {
    /// The rate a phone sends. A page resamples to it; a chunk that says another rate is refused.
    public static let uploadRate = 16_000
    /// The longest utterance (30 s of 16-bit mono) and chunk (1.5 s) the host takes. A chunk is part of a request that the relay gets as one
    /// base64 argument of at most 120,000 bytes (`argumentLimit` in relay.ts), and JSON inside base64 inside base64 is 1.8 times the audio.
    public static let maxUtteranceBytes = 30 * uploadRate * 2
    public static let maxChunkBytes = 48_000
    /// The most of an answer's audio the reply carries, as a WAV (a reply line is 1,000,000 bytes at most, and base64 makes a third more).
    public static let maxReplyBytes = 640_000
    /// The rate the answer's audio is sent at: speech, small enough for about 20 s in a reply.
    public static let replyRate = 16_000
    /// An utterance with no chunk for this long is dropped.
    public static let uploadIdle: TimeInterval = 60

    /// 16-bit little-endian mono PCM as a WAV file.
    public static func wav(pcm16 data: Data, rate: Int) -> Data {
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        var header = Data("RIFF".utf8)
        header.append(contentsOf: le32(36 + data.count))
        header.append(contentsOf: Data("WAVEfmt ".utf8))
        header.append(contentsOf: le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16))
        header.append(contentsOf: Data("data".utf8))
        header.append(contentsOf: le32(data.count))
        return header + data
    }

    /// Float samples (-1...1) as 16-bit little-endian PCM, clipped.
    public static func pcm16(fromFloats samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    /// 16-bit little-endian PCM as float samples. A last odd byte is dropped.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return (0..<(bytes.count / 2)).map { Float(Int16(bitPattern: UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8)) / 32768 }
    }

    /// The loudest sample of 16-bit PCM, 0 to 1: an utterance of silence isn't sent to the transcriber.
    public static func peak(ofPCM16 data: Data) -> Float {
        floats(fromPCM16: data).reduce(0) { max($0, abs($1)) }
    }
}

/// The utterances being uploaded, by ask id. A chunk is taken only in order from 0, within the size limits, so a request can't make the host hold more
/// than `maxUtteranceBytes` for each of `limit` utterances at once.
public struct VoiceUploads {
    public enum Outcome: Equatable {
        /// Taken; more is to come.
        case more
        /// The last chunk came: the whole utterance.
        case complete(Data)
        /// Not taken, and the utterance is dropped. The reason is for the asker.
        case refused(String)
    }

    private struct Held {
        var bytes = Data()
        var next = 0
        var touched: Date
    }

    public let limit: Int
    private var held: [String: Held] = [:]

    public init(limit: Int = 4) { self.limit = limit }

    public var count: Int { held.count }

    public mutating func add(id: String, seq: Int, last: Bool, rate: Int?, audio: Data, now: Date) -> Outcome {
        prune(now: now)
        guard seq >= 0 else { return refuse(id, "That audio chunk is out of order") }
        guard rate == nil || rate == VoiceAudio.uploadRate else { return refuse(id, "Voice mode sends 16 kHz audio") }
        guard audio.count <= VoiceAudio.maxChunkBytes, audio.count.isMultiple(of: 2) else { return refuse(id, "That audio chunk is the wrong size") }
        var entry = held[id] ?? Held(touched: now)
        if held[id] == nil, held.count >= limit { return .refused("Too many requests are being sent") }
        guard seq == entry.next else { return refuse(id, "That audio chunk is out of order") }
        guard entry.bytes.count + audio.count <= VoiceAudio.maxUtteranceBytes else { return refuse(id, "That request is too long: say less at once") }
        entry.bytes.append(audio)
        entry.next += 1
        entry.touched = now
        if last {
            held[id] = nil
            return .complete(entry.bytes)
        }
        held[id] = entry
        return .more
    }

    private mutating func refuse(_ id: String, _ reason: String) -> Outcome {
        held[id] = nil
        return .refused(reason)
    }

    /// Drops utterances that have had no chunk for `VoiceAudio.uploadIdle`.
    public mutating func prune(now: Date) {
        held = held.filter { now.timeIntervalSince($0.value.touched) < VoiceAudio.uploadIdle }
    }
}

// MARK: - The request being collected

/// The request a phone is saying, collected from its segments (protocol 31): what the user said between two pauses is a segment, the Mac transcribes
/// each, and the request ends only when a segment ends with "over" (`VoiceMode.overStep`, the rule Hey Varnick follows at the Mac, ADR 0044's amendment
/// of 2026-10-17). Kept by device, in memory, and for one Voice mode run: a segment of another run starts again. Segments are added in the order they
/// were sent (the page sends them one after another and the Mac applies them in that order), never by silence.
public struct VoiceCollector {
    /// What a segment does to the request.
    public enum Step: Equatable {
        /// The request goes on and now reads this (empty when the segment held nothing and nothing was collected).
        case collected(String)
        /// The request is over and reads this: ask the voice session.
        case take(String)
    }

    /// Collected text is forgotten this long after its last segment: the user went away, or ended Voice mode.
    public static let idle: TimeInterval = 60
    /// The cap, as at the Mac (`SpokenRequests.maxSeconds`): a request still collecting this long after its first segment, or at
    /// `VoiceSession.maxRequestCharacters`, is taken as it stands when a segment arrives, not by a clock.
    public static let maxSeconds: TimeInterval = 60

    private struct Pending {
        var text: String
        var mode: String
        var began: Date
        var touched: Date
    }

    private var pending: [String: Pending] = [:]

    public init() {}

    public var count: Int { pending.count }

    /// Adds a segment's `line` to the request of `device` in Voice mode run `mode`.
    public mutating func add(_ line: String, device: String, mode: String, now: Date) -> Step {
        prune(now: now)
        if pending[device]?.mode != mode { pending[device] = nil }
        let held = pending[device]
        switch VoiceMode.overStep(line: line, collected: held?.text ?? "") {
        case .ignore:
            return .collected(held?.text ?? "")
        case .take(let text):
            pending[device] = nil
            return .take(String(text.prefix(VoiceSession.maxRequestCharacters)))
        case .collect(let text):
            let kept = String(text.prefix(VoiceSession.maxRequestCharacters))
            let began = held?.began ?? now
            if kept.count >= VoiceSession.maxRequestCharacters || now.timeIntervalSince(began) > Self.maxSeconds {
                pending[device] = nil
                return .take(kept)
            }
            pending[device] = Pending(text: kept, mode: mode, began: began, touched: now)
            return .collected(kept)
        }
    }

    /// Forgets what no segment has added to for `idle`.
    public mutating func prune(now: Date) {
        pending = pending.filter { now.timeIntervalSince($0.value.touched) < Self.idle }
    }
}

// MARK: - The ledger

/// What has happened to each ask or segment, for `voiceStatus` to list. One ask is in flight at a time on a host (the voice session's own rule), but
/// any number of segments are being transcribed or collected (an entry that is not `asking`); finished ones are kept a few minutes so the phone can read
/// their last events, and no more than `limit` are kept.
public struct VoiceLedger {
    private struct Entry {
        var events: [PeerVoiceEvent] = []
        var done = false
        var asking: Bool
        var touched: Date
    }

    /// A finished ask is kept this long after its last event.
    public static let keep: TimeInterval = 300
    public let limit: Int
    private var entries: [String: Entry] = [:]

    public init(limit: Int = 16) { self.limit = limit }

    public var count: Int { entries.count }

    /// Whether an ask is going: begun and not over. A segment that is only being collected is not.
    public func busy() -> Bool { entries.values.contains { $0.asking && !$0.done } }

    /// Opens an ask (`asking`) or a segment. False when an ask is going already and this is one, when the id is in use, or when `limit` entries are all
    /// still open.
    public mutating func begin(_ id: String, asking: Bool = true, now: Date) -> Bool {
        prune(now: now)
        guard entries[id] == nil, !(asking && busy()) else { return false }
        if entries.count >= limit {
            guard let oldest = entries.filter({ $0.value.done }).min(by: { $0.value.touched < $1.value.touched })?.key else { return false }
            entries[oldest] = nil
        }
        entries[id] = Entry(asking: asking, touched: now)
        return true
    }

    /// A segment's request was taken: the entry is an ask now, and the host is busy until it ends.
    public mutating func markAsking(_ id: String) { entries[id]?.asking = true }

    /// Adds an event to an open ask; an event after the ask's end is dropped.
    public mutating func add(_ event: PeerVoiceEvent, to id: String, now: Date) {
        guard var entry = entries[id], !entry.done else { return }
        entry.events.append(event)
        entry.done = event.ends
        entry.touched = now
        entries[id] = entry
    }

    /// The events from `after` on and the number to ask next; nil for an ask the ledger doesn't hold.
    public func read(_ id: String, after: Int) -> PeerVoiceReply? {
        guard let entry = entries[id] else { return nil }
        let from = max(0, min(after, entry.events.count))
        return PeerVoiceReply(id: id, events: Array(entry.events[from...]), next: entry.events.count, done: entry.done)
    }

    public mutating func prune(now: Date) {
        entries = entries.filter { !$0.value.done || now.timeIntervalSince($0.value.touched) < Self.keep }
    }
}
