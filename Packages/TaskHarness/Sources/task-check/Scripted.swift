import Foundation
import TaskHarness

/// System 1 as a recorded policy: what Jev chose and scored on the pilots' pages, as rules over the state and the questions. Nothing is
/// asked of a model, so the check is the same on every run.
final class ScriptedSystem1: System1 {
    struct Policy {
        var shape: AnswerShape = .free
        /// The text of the action to pick on a page, by address; the first option containing it wins. Nil picks "Ask Claude".
        var wanted: (_ address: String, _ call: Int) -> String? = { _, _ in nil }
        var confidence = 0.9
        /// A preview's score, from the link's label and its preview text.
        var score: (_ label: String, _ preview: String) -> Double = { _, _ in 0.1 }
        /// Pages System 1 calls the end of the task.
        var doneAt: Set<String> = []
        /// A text counts as holding the answer when it contains this.
        var keyword = ""
    }

    let name: String
    var policy: Policy
    /// Every call: the state's text and the question keys.
    private(set) var calls: [(state: String, keys: [String])] = []
    private(set) var lastNextOptions: [String] = []
    var failFromCall: Int?
    /// Raised to say Jev cannot be used at all (the relevance filter left TypeSafe).
    var unavailable = false
    private var count = 0
    private var nextCalls = 0

    init(name: String = "Jev", policy: Policy) {
        self.name = name
        self.policy = policy
    }

    struct Failure: Error {}

    func ask(state: JSON, questions: [Question]) async throws -> [String: Answer] {
        count += 1
        calls.append((state.text, questions.map(\.key)))
        if unavailable { throw System1Unavailable("the relevance filter left TypeSafe") }
        if let failFromCall, count >= failFromCall { throw Failure() }
        let address = state["page"]?["address"]?.string ?? state["page"]?.string ?? ""
        var out: [String: Answer] = [:]
        for q in questions { out[q.key] = answer(q, state: state, address: address) }
        return out
    }

    private func spread(_ labels: [String], pick: String?, p: Double) -> Answer {
        let rest = labels.filter { $0 != pick }
        var d: [String: Double] = [:]
        for l in labels { d[l] = l == pick ? p : (1 - p) / Double(max(1, rest.count)) }
        return .choice(d)
    }

    private func answer(_ q: Question, state: JSON, address: String) -> Answer {
        let text = state.text
        switch q.kind {
        case .choice(let options):
            let labels = options.map(\.label)
            if q.key == "shape" { return spread(labels, pick: policy.shape.rawValue, p: policy.confidence) }
            if q.key == "next" {
                nextCalls += 1
                lastNextOptions = options.map(\.criterion)
                let wanted = policy.wanted(address, nextCalls)
                let pick = wanted.flatMap { w in options.first { $0.criterion.contains(w) } } ?? options.first { $0.criterion.contains("Ask Claude") }
                return spread(labels, pick: pick?.label, p: policy.confidence)
            }
            if q.key == "map" {
                if q.text.hasPrefix("Which option") {
                    let value = between(q.text, "fits the value \"", "\"")
                    let pick = options.first { $0.criterion.contains("\"\(value)\"") }
                    return spread(labels, pick: pick?.label ?? "none", p: policy.confidence)
                }
                let field = between(q.text, "the field \"", "\"").lowercased()
                let pick = options.first { o in
                    guard o.label != "none" else { return false }
                    let key = between(o.criterion, "The bank entry ", ":").lowercased()
                    return !key.isEmpty && (field.contains(key) || key.contains(field))
                }
                return spread(labels, pick: pick?.label ?? "none", p: policy.confidence)
            }
            return spread(labels, pick: labels.first, p: 0.5)
        case .noul:
            if q.key == "done" { return .noul(policy.doneAt.contains(address) ? 0.95 : 0.05) }
            if q.key == "holds" { return .noul(!policy.keyword.isEmpty && text.lowercased().contains(policy.keyword.lowercased()) ? 0.8 : 0.2) }
            if q.key.hasPrefix("pv") || q.key.hasPrefix("fx") {
                let label = between(q.text, "\"", "\"")
                let preview = state["previews"]?[label]?.string ?? ""
                return .noul(policy.score(label, preview))
            }
            if q.key.hasPrefix("t"), let i = Int(q.key.dropFirst()) {
                let t = state["texts"]?[String(i)]?.string ?? ""
                return .noul(!policy.keyword.isEmpty && t.lowercased().contains(policy.keyword.lowercased()) ? 0.9 : 0.1)
            }
            if q.key.hasPrefix("r") {
                let want = between(q.text, "meant to hold \"", "\"")
                let got = between(q.text, "now shows \"", "\"")
                return .noul(want == got ? 0.95 : 0.1)
            }
            return .noul(0.5)
        }
    }

    private func between(_ s: String, _ a: String, _ b: String) -> String {
        guard let start = s.range(of: a) else { return "" }
        let rest = s[start.upperBound...]
        guard let end = rest.range(of: b) else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}

/// System 2 as recorded replies: the values Claude wrote for the pilots' sign-up task, steering replies from a queue, and a verdict for a final read.
final class ScriptedSystem2: System2 {
    private(set) var messages: [(role: System2Role, text: String)] = []
    /// What Claude writes for the task's values at the start.
    var taskBank: [(key: String, value: String)] = []
    /// Field values by lower-cased label, for a form request.
    var fieldValues: [String: String] = [:]
    var guidance: [String] = []
    var verdict = "yes"
    /// Raised to make every call fail.
    var failing = false

    func ask(_ role: System2Role, _ message: String, preface: String) async throws -> String {
        messages.append((role, preface + "\n" + message))
        if failing { throw ScriptedSystem1.Failure() }
        if message.contains("Does it state the answer the task asks for?") { return "{\"verdict\": \"\(verdict)\"}" }
        if role == .values {
            if message.contains("The task just started") {
                return JSON.object(["bank": .array(taskBank.map { .object(["key": .string($0.key), "value": .string($0.value)]) })]).text
            }
            var entries: [JSON] = []
            for line in message.split(separator: "\n") where line.hasPrefix("{\"id\"") {
                guard let field = JSON.parse(Data(line.utf8)), let id = field["id"]?.string, let label = field["label"]?.string else { continue }
                entries.append(.object(["key": .string(label), "value": .string(fieldValues[label.lowercased()] ?? ""), "field": .string(id)]))
            }
            return JSON.object(["bank": .array(entries)]).text
        }
        return guidance.isEmpty ? "{\"do\": \"continue\"}" : guidance.removeFirst()
    }
}

/// The person: answers each ask as scripted, and types into the page like a person would.
final class ScriptedUser: TaskUser {
    var decisions: [Decision] = []
    private(set) var asked: [String] = []
    private(set) var askedKinds: [GateKind] = []
    private(set) var needed: [String] = []
    /// What the person does when told to type something: in the page, then Resume.
    var onNeedsYou: (String) -> Void = { _ in }
    var onWillDo: () -> Void = {}

    func decide(_ label: String, kind: GateKind) async -> Decision {
        asked.append(label)
        askedKinds.append(kind)
        let d = decisions.isEmpty ? .allow : decisions.removeFirst()
        if d == .willDo { onWillDo() }
        return d
    }

    func needsYou(_ what: String) async -> Bool {
        needed.append(what)
        onNeedsYou(what)
        return true
    }
}
