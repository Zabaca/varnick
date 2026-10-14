import Foundation

/// Everything a spoken request means, decided by a model and never by a word list (ADR 0037): Jev's one route call, or, when Jev isn't
/// used or fails, the Text generation model asked the same questions in one prompt. Code only builds the labels the questions offer
/// from data (the calendar, the project index), reads the reply and acts on what was chosen.
struct SpokenDecisions: Equatable {
    /// The answer of a choice that picks nothing.
    static let noneLabel = "none"
    /// "time", "do", `own`, `several` and each word are true from this probability, as measured.
    static let threshold = 0.5
    /// How many distinct words of the request are asked about, and how many of those may be the search words.
    static let maxAskedWords = 24
    static let maxSearchWords = 8

    /// The sources' probabilities, with "time" and "do"; nil when the fallback named no source.
    var route: SpokenRouter.Route?
    /// The request asks the current time, date or day here and now.
    var asksTime = false
    /// The request asks Varnick to do something it can't.
    var asksToDo = false
    /// The project it names or means, by its folder's name; nil for none.
    var folder: String?
    /// The time it asks about; nil for none. A future window is kept as said.
    var window: SpokenTime.Window?
    /// Only the user's own things can answer it.
    var own = false
    /// It asks for several results rather than one.
    var several = false
    /// The words to search for, in the request's order.
    var words: [String] = []
}

/// The questions of one decisions call, for Jev (`jevQuestions`) and for the Text generation fallback (`fallbackPrompt`), worded
/// once: the labels of `folder` and `window` are built at each call, from the project index and from the clock.
struct DecisionQuestions {
    let request: String
    let screen: Bool
    let now: Date
    let calendar: Calendar
    let index: [ProjectIndex.Entry]
    let windows: [SpokenTime.Label]
    /// The distinct words of the request, in order, at most `SpokenDecisions.maxAskedWords`.
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

    static let folderQuestion = "Which of the person's own projects does `request` name or mean, if any? A project may be called by its folder name, another name, a near spelling or what it does."
    static let folderNone = "It names or means none of these projects, or uses a word in its ordinary sense (\"what's in the news today\")."
    static let windowQuestion = "Which time does `request` ask about, if any? `today` says when now is."
    static let ownQuestion = "Does `request` ask about the person's own things?"
    static let ownTrue = "It asks for one of their own pages, bookmarks or Claude sessions (\"find the page about…\", \"that article I read\"), about what they did, worked on, read or decided, or about one of their own projects (those in `projects`: \"what is <one of them>\"), by any name it has there."
    static let ownFalse = "It asks for a fact about the world that anyone could look up, even about a topic they may have read about (\"what is MLX\", \"when does the library open\")."
    static let severalQuestion = "Does `request` ask for several results rather than one?"
    static let severalTrue = "It asks for more than one: which pages, all of my bookmarks, anything else like it, what else."
    static let severalFalse = "It asks for one thing: one page, one session, one fact or one answer."
    static let wordTrue = "It names the topic, a thing, a name or a project."
    static let wordFalse = "It is a word of asking, remembering or time, or a small grammatical word."

    static func wordQuestion(_ word: String) -> String {
        "Is the word \"\(word)\" in `request` part of what to search the person's pages and sessions for?"
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
        return Array(words.prefix(SpokenDecisions.maxAskedWords))
    }

    /// The project index's entries as their criteria say them.
    var projects: [String] { index.map { $0.criterion(now: now, calendar: calendar) } }

    // MARK: For Jev

    /// What the questions read besides the request: today with the time, and the project index (listed once here, for the folder and
    /// own questions to refer to).
    var state: [String: Any] {
        ["request": request, "today": SpokenTime.today(now: now, calendar: calendar, withTime: true), "projects": projects]
    }

    var jevQuestions: [String: Any] {
        let context = SpokenRouter.context(screen: screen)
        func choice(_ question: String, _ criteria: [(label: String, criterion: String)]) -> [String: Any] {
            ["type": "choice", "instructions": ["context": context, "question": question],
             "criteria": Dictionary(criteria.map { ($0.label, $0.criterion) }, uniquingKeysWith: { first, _ in first })]
        }
        func yesNo(_ question: String, _ yes: String, _ no: String) -> [String: Any] {
            ["type": "noul", "instructions": ["context": context, "question": question], "criteria": ["true": yes, "false": no]]
        }
        let criteria = projects
        var questions: [String: Any] = [
            "source": choice(SpokenRouter.sourceQuestion, SpokenRouter.sources(screen: screen)),
            "action": choice(SpokenRouter.actionQuestion, SpokenRouter.actions(screen: screen)),
            "folder": choice(Self.folderQuestion, criteria.indices.map { (index[$0].name, criteria[$0]) } + [(SpokenDecisions.noneLabel, Self.folderNone)]),
            "window": choice(Self.windowQuestion, windows.map { ($0.id, $0.description) } + [(SpokenDecisions.noneLabel, SpokenTime.noneDescription)]),
            "own": yesNo(Self.ownQuestion, Self.ownTrue, Self.ownFalse),
            "several": yesNo(Self.severalQuestion, Self.severalTrue, Self.severalFalse),
        ]
        for (i, word) in words.enumerated() { questions["w\(i + 1)"] = yesNo(Self.wordQuestion(word), Self.wordTrue, Self.wordFalse) }
        return questions
    }

    /// Jev's reply as the decisions. Throws when it isn't readable or lacks a question: that counts as a failure, and the Text
    /// generation model decides instead.
    func read(jev data: Data) throws -> SpokenDecisions {
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
            return noul >= SpokenDecisions.threshold
        }
        let (source, action) = (try choice("source"), try choice("action"))
        guard source["history"] != nil || source["bookmarks"] != nil || source["sessions"] != nil else { throw URLError(.cannotParseResponse) }
        let (folder, window) = (try choice("folder"), try choice("window"))
        var decisions = SpokenDecisions()
        decisions.route = SpokenRouter.Route(history: source["history"] ?? 0, bookmarks: source["bookmarks"] ?? 0, sessions: source["sessions"] ?? 0,
                                             screen: source["screen"] ?? 0, time: action["time"] ?? 0, doing: action["do"] ?? 0)
        decisions.asksTime = decisions.route?.time ?? 0 >= SpokenDecisions.threshold
        decisions.asksToDo = decisions.route?.doing ?? 0 >= SpokenDecisions.threshold
        decisions.folder = named(Self.best(folder))
        decisions.window = label(Self.best(window))
        decisions.own = try yes("own")
        decisions.several = try yes("several")
        var kept: [String] = []
        for (i, word) in words.enumerated() {
            if try yes("w\(i + 1)") { kept.append(word) }
        }
        decisions.words = Array(kept.prefix(SpokenDecisions.maxSearchWords))
        return decisions
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

    /// The fallback's prompt: the same questions, the projects listed once for the folder and own questions to refer to, and one line
    /// of JSON back. The example holds placeholders, not values: a small model copied literal ones in the eval.
    var fallbackPrompt: String {
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "`request`", with: "the request") }
        func labels(_ pairs: [(label: String, criterion: String)]) -> [String] { pairs.map { "- \($0.label): \($0.criterion)" } }
        var lines = [
            "You make the decisions for a request the person said aloud to Varnick, a launcher on their Mac.",
            plain(SpokenRouter.context(screen: screen)),
            "Today: \(SpokenTime.today(now: now, calendar: calendar, withTime: true)).",
            "Request: \(request)", "",
        ]
        lines += ["Projects (the person's own, one per line):"] + projects.map { "- \($0)" } + [""]
        lines.append("Answer each question with one of its labels.")
        lines.append("source: " + plain(SpokenRouter.sourceQuestion))
        lines += labels(SpokenRouter.sources(screen: screen))
        lines.append("action: " + plain(SpokenRouter.actionQuestion))
        lines += labels(SpokenRouter.actions(screen: screen))
        lines.append("folder: " + plain(Self.folderQuestion).replacingOccurrences(of: "own projects", with: "own projects, listed above,")
                     + " Answer with the project's name, the word before its colon, or none.")
        lines.append("- none: \(Self.folderNone)")
        lines.append("window: " + plain(Self.windowQuestion).replacingOccurrences(of: " `today` says when now is.", with: ""))
        lines += labels(windows.map { ($0.id, $0.description) } + [(SpokenDecisions.noneLabel, SpokenTime.noneDescription)])
        lines.append("own: true or false. \(plain(Self.ownQuestion)) true: \(Self.ownTrue.replacingOccurrences(of: "those in `projects`", with: "those listed above")) false: \(Self.ownFalse)")
        lines.append("several: true or false. \(plain(Self.severalQuestion)) true: \(Self.severalTrue) false: \(Self.severalFalse)")
        lines.append("words: the words of the request to search the person's pages and sessions for: those that name the topic, a thing, a name or a project, "
                     + "not words of asking, remembering or time, or small grammatical words. In the request's order, separated by spaces.")
        lines += ["", "Reply with one line of JSON and nothing else:",
                  "{\"source\": \"<a source label>\", \"action\": \"<an action label>\", \"folder\": \"<a project's name or none>\", "
                  + "\"window\": \"<a time label or none>\", \"own\": <true or false>, \"several\": <true or false>, \"words\": \"<the words to search for>\"}"]
        return lines.joined(separator: "\n")
    }

    /// The fallback's reply as the decisions: the first `{…}`, read leniently. A value outside its labels counts as none, false or no
    /// words. Nil when the reply holds no object, which is a failure.
    func read(fallback reply: String) -> SpokenDecisions? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [String: Any]
        else { return nil }
        func text(_ key: String) -> String? { (object[key] as? String)?.trimmingCharacters(in: .whitespaces) }
        func flag(_ key: String) -> Bool {
            if let value = object[key] as? Bool { return value }
            return text(key)?.lowercased() == "true"
        }
        var decisions = SpokenDecisions()
        let sources = SpokenRouter.sources(screen: screen).map(\.label)
        if let source = text("source")?.lowercased(), sources.contains(source) {
            decisions.route = SpokenRouter.Route(history: source == "history" ? 1 : 0, bookmarks: source == "bookmarks" ? 1 : 0,
                                                 sessions: source == "sessions" ? 1 : 0, screen: source == "screen" ? 1 : 0)
        }
        let action = text("action")?.lowercased()
        decisions.asksTime = action == "time"
        decisions.asksToDo = action == "do"
        decisions.folder = named(text("folder").flatMap { name in index.first { $0.name.lowercased() == name.lowercased() }?.name })
        decisions.window = label(text("window")?.lowercased())
        decisions.own = flag("own")
        decisions.several = flag("several")
        decisions.words = Array((text("words") ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            .prefix(SpokenDecisions.maxSearchWords))
        return decisions
    }
}
