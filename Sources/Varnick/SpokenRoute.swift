import Foundation

/// What a spoken request means, decided by a model and never by a word list (ADR 0037): Jev's route call, or, when Jev isn't used or
/// fails, the Text generation model asked the same questions in one prompt. Code builds the labels, reads the reply and acts on it.
struct SpokenRoute: Equatable {
    /// The answer of a choice that picks nothing.
    static let noneLabel = "none"
    /// "time", "do", `own`, `several` and each word are true from this probability, as measured.
    static let threshold = 0.5
    /// How many distinct words of the request are asked about, and how many of those may be the search words.
    static let maxAskedWords = 24
    static let maxSearchWords = 8

    /// The sources' probabilities, with "time" and "do"; nil when the fallback named no source.
    var sources: SpokenRouter.Sources?
    /// The request asks the current time, date or day here and now.
    var asksTime = false
    /// The request asks Varnick to do something it can't.
    var asksToDo = false
    /// The project it names or means, by its folder's name; nil for none.
    var project: String?
    /// The time it asks about; nil for none. A future window is kept as said.
    var window: SpokenTime.Window?
    /// Only the user's own things can answer it.
    var own = false
    /// It asks for several results rather than one.
    var several = false
    /// The words to search for, in the request's order.
    var words: [String] = []
}

/// The questions of one route call, for Jev (`jevBody`) and for the Text generation fallback (`fallbackPrompt`), worded once. The labels
/// of the project and window questions are built at each call, from the project index and the clock.
struct RouteQuestions {
    let request: String
    let screen: Bool
    let now: Date
    let calendar: Calendar
    let index: [ProjectIndex.Entry]
    let windows: [SpokenTime.Label]
    /// The distinct words of the request, in order, at most `SpokenRoute.maxAskedWords`.
    let words: [String]

    init(request: String, screen: Bool, index: [ProjectIndex.Entry], now: Date = Date(), calendar: Calendar = .current) {
        self.request = String(request.prefix(SpokenText.maxRequestCharacters))
        self.screen = screen
        self.now = now
        self.calendar = calendar
        self.index = index
        self.windows = SpokenTime.labels(now: now, calendar: calendar)
        self.words = Self.words(of: self.request)
    }

    // MARK: The wording

    // `ref` names the request: "`request`" for Jev, which reads it from the state, "the request" in the fallback's prompt.
    static func projectQuestion(_ ref: String, listed: Bool) -> String {
        "Which of the person's own projects\(listed ? ", listed above," : "") does \(ref) name or mean, if any? A project may be called by its folder name, another name, a near spelling or what it does."
            + (listed ? " Answer with the project's name, the word before its colon, or none." : "")
    }
    static let projectNone = "It names or means none of these projects, or uses a word in its ordinary sense (\"what's in the news today\")."
    static func windowQuestion(_ ref: String, today: Bool) -> String {
        "Which time does \(ref) ask about, if any?" + (today ? " `today` says when now is." : "")
    }
    static func ownQuestion(_ ref: String) -> String { "Does \(ref) ask about the person's own things?" }
    /// `projects` names the list of projects: "`projects`" for Jev, "the list above" in the fallback's prompt.
    static func ownTrue(projects: String) -> String {
        "It asks for one of their own pages, bookmarks or Claude sessions (\"find the page about…\", \"that article I read\"), about what they did, worked on, read or decided, or about one of the projects in \(projects) (\"what is <one of them>\"), by any name it has there."
    }
    static let ownFalse = "It asks for a fact about the world that anyone could look up, even about a topic they may have read about (\"what is MLX\", \"when does the library open\")."
    static func severalQuestion(_ ref: String) -> String { "Does \(ref) ask for several results rather than one?" }
    static let severalTrue = "It asks for more than one: which pages, all of my bookmarks, anything else like it, what else."
    static let severalFalse = "It asks for one thing: one page, one session, one fact or one answer."
    static let wordTrue = "It names the topic, a thing, a name or a project."
    static let wordFalse = "It is a word of asking, remembering or time, or a small grammatical word."
    static func wordQuestion(_ word: String, _ ref: String) -> String {
        "Is the word \"\(word)\" in \(ref) part of what to search the person's pages and sessions for?"
    }

    /// The distinct words of the request in order, with the punctuation around each dropped. Mechanical: which of them are searched
    /// for is the model's answer, word by word.
    static func words(of request: String) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        for raw in request.split(whereSeparator: \.isWhitespace) {
            let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",.?!:;\"()"))
            if !word.isEmpty, seen.insert(word.lowercased()).inserted { words.append(word) }
        }
        return Array(words.prefix(SpokenRoute.maxAskedWords))
    }

    // MARK: The questions

    private enum Kind {
        case choice([(label: String, criterion: String)])
        case yesNo(yes: String, no: String)
    }

    /// The questions in the order they are sent: source, action, project (when there are projects), window, own, several, then each word.
    /// For Jev the project question offers one label per project, in the index's order (most recently used first), and the windows keep
    /// theirs (by date); in the fallback's prompt the projects are listed once, apart.
    private func questions(jev: Bool) -> [(key: String, text: String, kind: Kind)] {
        let ref = jev ? "`request`" : "the request"
        let projectsRef = jev ? "`projects`" : "the list above"
        var questions: [(key: String, text: String, kind: Kind)] = [
            ("source", SpokenRouter.sourceQuestion(request: ref), .choice(SpokenRouter.sources(screen: screen))),
            ("action", SpokenRouter.actionQuestion(request: ref), .choice(SpokenRouter.actions(screen: screen))),
        ]
        if !index.isEmpty {
            let labels = jev ? zip(index, projects).map { ($0.name, $1) } : []
            questions.append(("folder", Self.projectQuestion(ref, listed: !jev), .choice(labels + [(SpokenRoute.noneLabel, Self.projectNone)])))
        }
        questions += [
            ("window", Self.windowQuestion(ref, today: jev), .choice(windows.map { ($0.id, $0.description) } + [(SpokenRoute.noneLabel, SpokenTime.noneDescription)])),
            ("own", Self.ownQuestion(ref), .yesNo(yes: Self.ownTrue(projects: projectsRef), no: Self.ownFalse)),
            ("several", Self.severalQuestion(ref), .yesNo(yes: Self.severalTrue, no: Self.severalFalse)),
        ]
        if jev {
            for (i, word) in words.enumerated() {
                questions.append(("w\(i + 1)", Self.wordQuestion(word, ref), .yesNo(yes: Self.wordTrue, no: Self.wordFalse)))
            }
        }
        return questions
    }

    /// The project index's entries as their criteria say them.
    var projects: [String] { index.map { $0.criterion(now: now, calendar: calendar) } }

    // MARK: For Jev

    /// What the questions read besides the request: today with the time, and the project index (listed once here, for the project and
    /// own questions to refer to).
    var state: [String: Any] {
        var state: [String: Any] = ["request": request, "today": SpokenTime.today(now: now, calendar: calendar, withTime: true)]
        if !index.isEmpty { state["projects"] = projects }
        return state
    }

    /// The request body: JSON written in order, since a label's place in a list is part of what was measured.
    func jevBody(model: String) -> Data {
        func text(_ string: String) -> String {
            (try? JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        func object(_ pairs: [(String, String)]) -> String { "{" + pairs.map { "\(text($0.0)):\($0.1)" }.joined(separator: ",") + "}" }
        let context = text(SpokenRouter.context(screen: screen, request: "`request`"))
        let json = questions(jev: true).map { question -> (String, String) in
            let criteria: [(String, String)]
            let kind: String
            switch question.kind {
            case .choice(let labels):
                var seen: Set<String> = []
                criteria = labels.filter { seen.insert($0.label).inserted }.map { ($0.label, text($0.criterion)) }
                kind = "choice"
            case .yesNo(let yes, let no):
                criteria = [("true", text(yes)), ("false", text(no))]
                kind = "noul"
            }
            return (question.key, object([("type", text(kind)),
                                          ("instructions", object([("context", context), ("question", text(question.text))])),
                                          ("criteria", object(criteria))]))
        }
        let stateData = (try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys)) ?? Data("{}".utf8)
        let body = object([("model", text(model)), ("state", String(decoding: stateData, as: UTF8.self)), ("questions", object(json))])
        return Data(body.utf8)
    }

    /// Jev's reply as the route. Throws when it isn't readable or lacks a question: that counts as a failure, and the Text generation
    /// model decides instead.
    func read(jev data: Data) throws -> SpokenRoute {
        struct Answer: Decodable {
            let probabilities: [String: Double]?
            let noul: Double?
        }
        struct Response: Decodable { let answers: [String: Answer] }
        let answers = try JSONDecoder().decode(Response.self, from: data).answers
        func choice(_ key: String) throws -> [String: Double] {
            guard let probabilities = answers[key]?.probabilities else { throw URLError(.cannotParseResponse) }
            return probabilities
        }
        func yes(_ key: String) throws -> Bool {
            guard let noul = answers[key]?.noul else { throw URLError(.cannotParseResponse) }
            return noul >= SpokenRoute.threshold
        }
        let (source, action) = (try choice("source"), try choice("action"))
        guard SpokenRouter.Sources.named(source) else { throw URLError(.cannotParseResponse) }
        var route = SpokenRoute()
        let sources = SpokenRouter.Sources(sources: source, actions: action)
        route.sources = sources
        route.asksTime = sources.time >= SpokenRoute.threshold
        route.asksToDo = sources.doing >= SpokenRoute.threshold
        if !index.isEmpty { route.project = named(Self.best(try choice("folder"))) }
        route.window = label(Self.best(try choice("window")))
        route.own = try yes("own")
        route.several = try yes("several")
        var kept: [String] = []
        for (i, word) in words.enumerated() {
            if try yes("w\(i + 1)") { kept.append(word) }
        }
        route.words = Array(kept.prefix(SpokenRoute.maxSearchWords))
        return route
    }

    /// The label a choice picked: the most likely.
    private static func best(_ probabilities: [String: Double]) -> String? {
        probabilities.max { $0.value < $1.value }?.key
    }

    private func named(_ label: String?) -> String? {
        guard let label, index.contains(where: { $0.name == label }) else { return nil }
        return label
    }

    private func label(_ id: String?) -> SpokenTime.Window? {
        windows.first { $0.id == id }?.window
    }

    // MARK: For the Text generation model

    /// The fallback's prompt: the same questions, the projects listed once for the project and own questions to refer to, and one line
    /// of JSON back. The example holds quoted placeholders, not values: a small model copied literal ones in the eval.
    var fallbackPrompt: String {
        var lines = [
            "You make the decisions for a request the person said aloud to Varnick, a launcher on their Mac.",
            SpokenRouter.context(screen: screen, request: "the request"),
            "Today: \(SpokenTime.today(now: now, calendar: calendar, withTime: true)).",
            "Request: \(request)", "",
        ]
        if !index.isEmpty { lines += ["Projects (the person's own, one per line):"] + projects.map { "- \($0)" } + [""] }
        lines.append("Answer each question with one of its labels.")
        for question in questions(jev: false) {
            switch question.kind {
            case .choice(let labels):
                lines.append("\(question.key): \(question.text)")
                lines += labels.map { "- \($0.label): \($0.criterion)" }
            case .yesNo(let yes, let no):
                lines.append("\(question.key): true or false. \(question.text) true: \(yes) false: \(no)")
            }
        }
        lines.append("words: the words of the request to search the person's pages and sessions for: those that name the topic, a thing, a name or a project, "
                     + "not words of asking, remembering or time, or small grammatical words. In the request's order, separated by spaces.")
        let folder = index.isEmpty ? "" : "\"folder\": \"<a project's name or none>\", "
        lines += ["", "Reply with one line of JSON and nothing else:",
                  "{\"source\": \"<a source label>\", \"action\": \"<an action label>\", \(folder)\"window\": \"<a time label or none>\", "
                  + "\"own\": \"<true or false>\", \"several\": \"<true or false>\", \"words\": \"<the words to search for>\"}"]
        return lines.joined(separator: "\n")
    }

    /// The fallback's reply as the route: the first `{…}`, read leniently, a bare `<…>` placeholder as a model may copy it included. A
    /// value outside its labels counts as none, false or no words. Nil when the reply holds no object, which is a failure.
    func read(fallback reply: String) -> SpokenRoute? {
        let quoted = reply.replacingOccurrences(of: #"(:\s*)(<[^<>"\n]*>)"#, with: "$1\"$2\"", options: .regularExpression)
        guard let open = quoted.firstIndex(of: "{"), let close = quoted.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(quoted[open...close].utf8)) as? [String: Any]
        else { return nil }
        // A placeholder copied from the example is no answer.
        func text(_ key: String) -> String? {
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespaces), !(value.hasPrefix("<") && value.hasSuffix(">")) else { return nil }
            return value
        }
        func flag(_ key: String) -> Bool {
            if let value = object[key] as? Bool { return value }
            return text(key)?.lowercased() == "true"
        }
        var route = SpokenRoute()
        let source = text("source")?.lowercased() ?? ""
        if SpokenRouter.sources(screen: screen).contains(where: { $0.label == source }) {
            let action = text("action")?.lowercased() ?? ""
            route.sources = SpokenRouter.Sources(sources: [source: 1], actions: [action: 1])
        }
        let action = text("action")?.lowercased()
        route.asksTime = action == "time"
        route.asksToDo = action == "do"
        route.project = named(text("folder").flatMap { name in index.first { $0.name.lowercased() == name.lowercased() }?.name })
        route.window = label(text("window")?.lowercased())
        route.own = flag("own")
        route.several = flag("several")
        route.words = Array((text("words") ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            .prefix(SpokenRoute.maxSearchWords))
        return route
    }
}
