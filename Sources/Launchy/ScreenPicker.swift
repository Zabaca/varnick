import Foundation

/// Asks TypeSafe's Jev which element of the window in front a spoken request means (ADR 0019): one call with a `target` choice
/// over the elements and a `present` yes/no over the same list, as measured in the screen-pointing eval (agent-lab 20fb286,
/// shape C, format F3). Under the decide step's gate only (the filter on TypeSafe and a key saved). Gemma never points.
///
/// What goes: the request text, the window's title, and each element's label, kind in parentheses (with dimmed, under the pointer,
/// in a dialog), named groups and the text beside it. Never a field's value, an app's name, a frame or an image.
struct ScreenPicker {
    let apiKey: String
    var model = SpokenRouter.pinnedModel
    var endpoint = SpokenRouter.pinnedEndpoint

    /// An element is pointed at when Jev's `present` is at least this: the eval's untuned 0.5 pointed right on 87 of 97 and at
    /// 1 of 28 elements that were not there.
    static let pointFrom = 0.5

    /// Jev's choice and how sure it is the thing is in the list at all.
    struct Pick: Equatable {
        var index: Int
        /// The chosen element's share of the `target` choice.
        var target: Double
        var present: Double
        var isConfident: Bool { present >= ScreenPicker.pointFrom }
    }

    private static let context = "The person said `request` aloud to Launchy, a launcher on their Mac, about the window in front of them, titled `window`. Launchy will point an arrow at the element of that window they mean. Each element is described by its label, its kind in parentheses, the groups it sits in and the text beside it."
    private static let presentQuestion = "Is the thing the person asks about in `request` one of `elements`?"
    private static let presentTrue = "One of `elements` is the control, item or text the person asks about."
    private static let presentFalse = "None of `elements` is what the person asks about: it is not in this window."

    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The request body. The elements are written in the order given: that order is what the model reads, and a JSON object built
    /// from a dictionary would shuffle it.
    static func body(model: String, request: String, windowTitle: String, descriptions: [String]) -> Data {
        let criteria = descriptions.enumerated().map { "\(json("e\($0.offset + 1)")):\(json($0.element))" }.joined(separator: ",")
        let text = """
            {"model":\(json(model)),"state":{"request":\(json(String(request.prefix(SpokenText.maxRequestCharacters)))),\
            "window":\(json(windowTitle))},"questions":{\
            "target":{"type":"choice","instructions":{"context":\(json(context)),\
            "question":\(json("Which element does the person mean in `request`?"))},"criteria":{\(criteria)}},\
            "present":{"type":"noul","instructions":{"context":\(json(context)),"elements":\(json(descriptions)),\
            "question":\(json(presentQuestion))},"criteria":{"true":\(json(presentTrue)),"false":\(json(presentFalse))}}}}
            """
        return Data(text.utf8)
    }

    /// The most probable element of `target` (the earlier one among elements described alike, which the model cannot tell apart)
    /// and `present`; nil when the reply holds neither.
    static func pick(fromResponse data: Data, descriptions: [String]) -> Pick? {
        struct Choice: Decodable { let probabilities: [String: Double] }
        struct Noul: Decodable { let noul: Double }
        struct Answers: Decodable { let target: Choice; let present: Noul }
        struct Response: Decodable { let answers: Answers }
        guard !descriptions.isEmpty, let answers = try? JSONDecoder().decode(Response.self, from: data).answers else { return nil }
        var best: (index: Int, probability: Double)?
        for (key, probability) in answers.target.probabilities {
            guard key.hasPrefix("e"), let number = Int(key.dropFirst()), (1...descriptions.count).contains(number) else { continue }
            let index = number - 1
            if best == nil || probability > best!.probability || (probability == best!.probability && index < best!.index) {
                best = (index, probability)
            }
        }
        guard var chosen = best else { return nil }
        if let alike = descriptions.indices.first(where: { descriptions[$0] == descriptions[chosen.index] }) { chosen.index = alike }
        return Pick(index: chosen.index, target: chosen.probability, present: answers.present.noul)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = SpokenRouter.timeout
        config.timeoutIntervalForResource = SpokenRouter.timeout
        return URLSession(configuration: config)
    }()

    /// Throws on a network error, a timeout, a status other than 200 or a reply that can't be read.
    func pick(_ request: String, windowTitle: String, elements: [ScreenElement]) async throws -> Pick {
        let descriptions = elements.map(\.description)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.body(model: model, request: request, windowTitle: windowTitle, descriptions: descriptions)
        let (data, response) = try await Self.session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let pick = Self.pick(fromResponse: data, descriptions: descriptions) else {
            throw URLError(.badServerResponse)
        }
        return pick
    }
}
