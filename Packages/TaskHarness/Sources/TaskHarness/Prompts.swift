import Foundation

/// What System 2 is told and what it may answer: the pilots' wording (agent-lab hybrid-browser-15), kept in one place as the contract with the
/// eval. A change here is a change to re-measure.
public enum Prompts {
    /// The first message of each Claude conversation of a task.
    public static func role(task: String) -> String {
        """
        You are System 2 of a web agent. A fast model, System 1, drives a browser on a web site: each step it picks one action the harness lists (click a link or button, read a text block out as the answer, go back, say the task is done). The harness fills forms itself from a value bank you write. You are called when System 1 is unsure, when the harness needs values for a form, or when a read needs a judgement. Reply with only a JSON object, never prose.
        The person types passwords, one-time codes and card numbers in the page themselves, ticks the terms, and allows every form submit; you never see those values.
        The task: \(JSON.string(task).text)
        """
    }

    /// The task's values, asked in the background when the task starts.
    public static let taskBank = """
        The task just started; System 1 is navigating. From the task alone, write every value a form on this site may need (name, email, phone, address parts, country, delivery choice, whether to accept terms, ...).
        Reply with only {"bank": [{"key": "<what the value means, e.g. full name, phone, postcode>", "value": "<the value as it should be typed or chosen>"}, ...]}; "ASK_USER" for anything only the person can give (a password, a one-time code or a card number, which they type themselves and you never see, or the choice to accept terms). When you later correct a value, reuse its key.
        """

    /// Values for fields, asked in the background.
    public static func form(why: String, address: String, fields: String) -> String {
        """
        The harness needs values for this form (\(why)). Page: \(address).
        Fields:
        \(fields)
        Reply with only {"bank": [{"key": "<what the value means, e.g. full name, email, postcode>", "value": "<the value, exactly as it should be typed or the option's label>", "field": "<field id>"}, ...]}.
        One entry per field you can fill from the task; "" for an optional field to leave empty; "true" for a box to tick; "ASK_USER" for anything only the person can give (a password, a one-time code or a card number, which they type themselves and you never see, or the choice to accept terms). To correct a value, reuse its key: the new entry replaces the old.
        """
    }

    /// A guidance call. `page` is the whole page the first time Claude sees it, then what changed.
    public static func guide(why: String, page: String, form: String, harness: String, trail: String, options: String) -> String {
        """
        Why you are called: \(why)
        \(page)
        \(form)What the harness knows:
        \(harness)
        Trail (every page in order, the action taken there, what it led to):
        \(trail)
        System 1's options now:
        \(options)
        Reply with one JSON object:
        - {"do": "guide", "choose": "<option id>", "hint": "<one short sentence>"}: System 1 decides again with your suggestion marked.
        - {"do": "act", "choose": "<option id>"}: the harness does it now.
        - {"do": "fix_field", "field": "<field id or label>", "value": "<value>"}: the harness refills that field (and checks it) and System 1 carries on.
        - {"do": "wait"}: a fix the harness is running will settle this; System 1 waits for it.
        - {"do": "explore", "hint": "<what to look for>"}: System 1 takes its own best next step, with your hint as a prior.
        - {"do": "not_sure"}, {"do": "not_a_page_problem", "why": "<what is really wrong>"}, {"do": "continue"}.
        The harness fills form fields from the value bank (fixes run in the background and are checked digit by digit), the person fills passwords, one-time codes and card fields, ticks the terms and allows every submit, and going back from a form page loses nothing the harness can't refill.
        """
    }

    /// A read the code checks cannot decide.
    public static func finalRead(address: String, text: String) -> String {
        "System 1 wants to answer the task with this text from \(address):\n\(JSON.string(text).text)\nDoes it state the answer the task asks for? Reply with only {\"verdict\": \"yes\"} or {\"verdict\": \"no\"}."
    }

    // MARK: System 1's questions

    /// The state every System 1 question of a turn reads, and the wording of the turn's questions.
    public static let context = "A web agent is doing `task` on a web site in a browser. `page` lists the page's links and buttons and its text blocks. Choose the next step."

    public static func shapeQuestion() -> Question {
        .choice("shape", "What shape does the answer to `task` take?", AnswerShape.allCases.map { ($0.rawValue, $0.criterion) })
    }

    /// The prompt for Claude when it makes System 1's choices: the same state and questions, one JSON object back.
    public static func fallback(state: JSON, questions: [Question]) -> String {
        var lines = [
            "You are System 1 of a web agent: the fast model that picks each step. The state is JSON; answer every question below.",
            "State: \(state.text)", "",
        ]
        for q in questions {
            switch q.kind {
            case .choice(let options):
                lines.append("\(q.key): \(q.text) Pick exactly one label:")
                lines += options.map { "- \($0.label): \($0.criterion)" }
            case .noul:
                lines.append("\(q.key): \(q.text) Answer with a probability from 0 to 1 that it is true.")
            }
        }
        lines += ["", "Reply with only one JSON object, {\"<question key>\": <the label picked, as a string, or the probability as a number>, ...}, never prose."]
        return lines.joined(separator: "\n")
    }

    /// Claude's reply as answers: a picked label gets probability 1 and the others 0; a number is the probability. A question left out or a
    /// label that isn't offered is missing from the result, which the caller counts as a failure.
    public static func readFallback(_ reply: String, questions: [Question]) -> [String: Answer]? {
        guard let object = JSON.firstObject(in: reply) else { return nil }
        var out: [String: Answer] = [:]
        for q in questions {
            guard let value = object[q.key] else { continue }
            switch q.kind {
            case .choice(let options):
                guard let label = value.string, options.contains(where: { $0.label == label }) else { continue }
                out[q.key] = .choice(Dictionary(uniqueKeysWithValues: options.map { ($0.label, $0.label == label ? 1.0 : 0.0) }))
            case .noul:
                if let p = value.double { out[q.key] = .noul(min(1, max(0, p))) } else if let b = value.bool { out[q.key] = .noul(b ? 1 : 0) }
            }
        }
        return out.count == questions.count ? out : nil
    }
}
