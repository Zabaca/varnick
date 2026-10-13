import CryptoKit
import Foundation
import MLX
import Tokenizers

enum LocalRerankerError: LocalizedError {
    case notFound(String)
    case unsupported(String)
    case nonFinite
    case wrongScoreCount

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "Missing \(what)"
        case .unsupported(let why): why
        case .nonFinite: "The model gave a non-finite answer"
        case .wrongScoreCount: "The model scored a different number of pages than it was given"
        }
    }
}

/// The checkpoint folder as Laya saves it, checked before anything is loaded from it.
struct LayaCheckpoint {
    /// The only files copied in. The folder also holds eval scores and logs.
    static let files = ["model.safetensors", "encoder/config.json", "tokenizer/tokenizer.json",
                        "tokenizer/tokenizer_config.json", "rl_agent_config.json"]
    /// The token parity was measured for exactly this file; swift-transformers `fatalError`s on others,
    /// so it never sees one that doesn't match.
    static let tokenizerSHA256 = "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30"

    let encoder: ModernBertConfig
    let headLayers: Int
    let temperature: Float

    private struct Agent: Decodable {
        struct Question: Decodable, Equatable {
            let type, instructions: String
            let criteria: [String: String]
        }
        let headLayers: Int?
        let format: String?
        let question: Question?
        let temperatureByOptions: [String: Double]?
        // `launchy_format` and `launchy_question` are keys in the checkpoint's own config, a file this repository doesn't make
        // (the app was called Launchy then), so they keep their names.
        enum CodingKeys: String, CodingKey {
            case headLayers = "head_layers", format = "launchy_format", question = "launchy_question"
            case temperatureByOptions = "temperature_by_options"
        }
    }

    static func read(_ directory: URL) throws -> LayaCheckpoint {
        for file in files where !FileManager.default.fileExists(atPath: directory.appending(path: file).path) {
            throw LocalRerankerError.notFound(file)
        }
        let tokenizer = try Data(contentsOf: directory.appending(path: "tokenizer/tokenizer.json"))
        guard SHA256.hash(data: tokenizer).map({ String(format: "%02x", $0) }).joined() == tokenizerSHA256 else {
            throw LocalRerankerError.unsupported("tokenizer.json isn't the one this build was checked against")
        }
        let encoder: ModernBertConfig
        do {
            encoder = try JSONDecoder().decode(ModernBertConfig.self, from: Data(contentsOf: directory.appending(path: "encoder/config.json")))
        } catch let error as DecodingError {
            throw LocalRerankerError.unsupported("The encoder config couldn't be read (\(error.errorSummary))")
        }
        try encoder.validate()
        let agent = try JSONDecoder().decode(Agent.self, from: Data(contentsOf: directory.appending(path: "rl_agent_config.json")))
        let minimal = Agent.Question(type: "noul", instructions: "?", criteria: ["true": "y", "false": "n"])
        guard agent.format == "minimal", agent.question == minimal else {
            throw LocalRerankerError.unsupported("The checkpoint wasn't trained on the minimal row")
        }
        guard let headLayers = agent.headLayers, headLayers > 0 else {
            throw LocalRerankerError.unsupported("The agent config has no head_layers")
        }
        guard let temperature = agent.temperatureByOptions?["noul:2"] else {
            throw LocalRerankerError.unsupported("The agent config has no noul temperature")
        }
        return LayaCheckpoint(encoder: encoder, headLayers: headLayers, temperature: Float(min(5, max(0.5, temperature))))
    }
}

private extension DecodingError {
    /// The key at fault, never the data.
    var errorSummary: String {
        switch self {
        case .keyNotFound(let key, _): "no \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.map(\.stringValue).joined(separator: ".")
        @unknown default: "unreadable"
        }
    }
}

/// Owns the loaded model, tokenizer and question prefix. Scoring runs inside with no awaits.
actor LayaScorer {
    private static let maxLength = 512
    /// [CLS] "noul question: ?" [SEP] [MASK] " false: n" [MASK] " true: y" [SEP]. Laya's own builder, so
    /// the checkpoint is refused if the tokenizer builds anything else.
    private static let expectedPrefix = [50281, 79, 3941, 1953, 27, 3736, 50282, 50284, 3221, 27, 295, 50284, 2032, 27, 340, 50282]
    private static let expectedMarkers: [Int32] = [7, 11]

    private let model: LayaModel
    private let tokenizer: any Tokenizer
    private let prefix: [Int]
    private let markers: MLXArray
    private let separator, pad: Int
    private let temperature: Float

    init(directory: URL) async throws {
        guard MLXRuntime.hasMetalLibrary else { throw LocalRerankerError.unsupported("Needs mlx.metallib: build with make") }
        MLXRuntime.capCache()
        let checkpoint = try LayaCheckpoint.read(directory)
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory.appending(path: "tokenizer"))

        // A missing name returns [UNK]'s id, not nil.
        guard let unknown = tokenizer.convertTokenToId("[UNK]") else { throw LocalRerankerError.unsupported("The tokenizer has no [UNK]") }
        let id = { (name: String) throws -> Int in
            guard let id = tokenizer.convertTokenToId(name), id != unknown else {
                throw LocalRerankerError.unsupported("The tokenizer has no \(name)")
            }
            return id
        }
        let (cls, sep, mask, pad) = (try id("[CLS]"), try id("[SEP]"), try id("[MASK]"), try id("[PAD]"))
        let encode = { (text: String) in tokenizer.encode(text: text, addSpecialTokens: false) }
        var ids = [cls] + encode("noul question: ?") + [sep]
        var markers = [Int32]()
        for option in [" false: n", " true: y"] {
            markers.append(Int32(ids.count))
            ids += [mask] + encode(option)
        }
        ids.append(sep)
        guard ids == Self.expectedPrefix, markers == Self.expectedMarkers else {
            throw LocalRerankerError.unsupported("The tokenizer doesn't build the question the checkpoint was trained on")
        }

        let model = try withError {
            let model = LayaModel(checkpoint.encoder, headLayers: checkpoint.headLayers)
            try model.loadWeights(from: directory.appending(path: "model.safetensors"))
            return model
        }
        self.model = model
        self.tokenizer = tokenizer
        self.prefix = ids
        self.markers = MLXArray(markers)
        self.separator = sep
        self.pad = pad
        self.temperature = checkpoint.temperature
    }

    /// What gets tokenized for one page. Cut and replaced by Unicode scalars, as Python does: Swift's
    /// defaults count grapheme clusters, so a mark after "[MASK]" would otherwise keep it.
    nonisolated static func state(query: String, site: String, title: String) -> String {
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: title.unicodeScalars.prefix(60))
        return "\(query)\n\(site)\n\(String(cut))".replacingOccurrences(of: "[MASK]", with: " ", options: .literal)
    }

    /// Probability that each page is what the search is after, in page order, in one forward pass.
    /// `site` is the page URL's lowercased host, as training lowercased it.
    func relevance(query: String, pages: [(site: String, title: String)]) throws -> [Double] {
        try Task.checkCancellation()   // a stale search is skipped, not queued
        guard !pages.isEmpty else { return [] }
        let room = Self.maxLength - prefix.count - 1
        let rows = pages.map { page in
            prefix + tokenizer.encode(text: Self.state(query: query, site: page.site, title: page.title), addSpecialTokens: false).prefix(room) + [separator]
        }
        // Right-padded to the longest row with an explicit mask.
        let width = rows.map(\.count).max()!
        let ids = rows.flatMap { $0.map(Int32.init) + [Int32](repeating: Int32(pad), count: width - $0.count) }
        let valid = rows.flatMap { [Bool](repeating: true, count: $0.count) + [Bool](repeating: false, count: width - $0.count) }
        let logits = try withError {
            model(MLXArray(ids, [rows.count, width]), valid: MLXArray(valid, [rows.count, width]), markers: markers)
                .asArray(Float.self)
        }
        guard logits.count == 2 * pages.count else { throw LocalRerankerError.wrongScoreCount }
        guard logits.allSatisfy(\.isFinite) else { throw LocalRerankerError.nonFinite }
        return pages.indices.map { Double(1 / (1 + exp(-(logits[2 * $0 + 1] - logits[2 * $0]) / temperature))) }
    }
}

/// Judges the relevance filter on this Mac with a checkpoint imported once from a folder (ADR 0006).
/// Loads on first use, unloads when idle like the embedder, and never falls back to TypeSafe.
@MainActor
final class LocalReranker: ObservableObject, RelevanceJudge {
    enum State: Equatable { case unavailable, missing, importing, ready, failed(String) }

    @Published private(set) var state: State
    /// Why the last import failed; the state stays as it was.
    @Published private(set) var importError: String?

    let backend = RelevanceBackend.local
    let pause = Duration.zero   // runs right after the semantic pass, which has waited for its own pause

    private static let idleUnload: Duration = .seconds(600)
    private static let directory = URL.applicationSupportDirectory.appending(components: "Varnick", "models", "laya-relevance")

    private var scorer: LayaScorer?
    /// Whether the weights are in memory now (they drop after 10 idle minutes), for the Resources view.
    var isLoaded: Bool { scorer != nil }
    private var loading: Task<LayaScorer, Error>?
    /// Bumped when an import replaces the model, so a load that started before it isn't kept.
    private var generation = 0
    private var idleTimer: Task<Void, Never>?

    /// Only checks that the files exist: this runs on the main thread at launch, and touches no MLX.
    init() {
        state = !MLXRuntime.hasMetalLibrary ? .unavailable : Self.installed ? .ready : .missing
    }

    private static var installed: Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "model.safetensors").path)
    }

    var isReady: Bool { state == .ready }

    // MARK: Import

    /// Checks `folder`, copies its five files next to the embedding model and trial-loads the copy, off the
    /// main actor. Any failure removes the copy and leaves the installed model as it was.
    func importCheckpoint(from folder: URL) async {
        switch state {
        case .missing, .ready, .failed: break
        case .unavailable, .importing: return
        }
        let before = state
        state = .importing
        importError = nil
        let target = Self.directory
        do {
            try await Task.detached(priority: .userInitiated) { try await Self.install(from: folder, to: target) }.value
            scorer = nil
            loading = nil
            generation += 1
            state = .ready
        } catch {
            NSLog("Varnick: relevance model import failed: \(error)")
            importError = error.localizedDescription
            state = before
        }
    }

    private nonisolated static func install(from folder: URL, to target: URL) async throws {
        _ = try LayaCheckpoint.read(folder)
        let partial = target.appendingPathExtension("partial")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        do {
            for file in LayaCheckpoint.files {
                let copy = partial.appending(path: file)
                try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: folder.appending(path: file), to: copy)
            }
            // The question prefix must match, and one row must score finite.
            let scorer = try await LayaScorer(directory: partial)
            _ = try await scorer.relevance(query: "test", pages: [(site: "example.com", title: "Example")])
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: partial)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: partial, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        Memory.clearCache()
    }

    // MARK: Scoring

    func relevance(query: String, candidates: [SearchResult]) async throws -> [Double] {
        let pages = candidates.map { (site: URL(string: $0.url)?.host?.lowercased() ?? "", title: $0.title) }
        let scorer = try await loaded()
        let scores = try await scorer.relevance(query: query.trimmingCharacters(in: .whitespaces), pages: pages)
        guard scores.count == candidates.count else { throw LocalRerankerError.wrongScoreCount }
        return scores
    }

    /// A failed load turns the filter off until Retry: the same checkpoint would fail on every search.
    func retry() async {
        guard case .failed = state else { return }
        state = Self.installed ? .ready : .missing
        _ = try? await loaded()
    }

    /// Loads in about 0.2 s from the page cache; the first call after that adds shader setup.
    private func loaded() async throws -> LayaScorer {
        unloadWhenIdle()
        if let scorer { return scorer }
        if let loading { return try await loading.value }
        // Model folder deleted while Varnick runs: back to "no model".
        guard Self.installed else {
            state = .missing
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = Self.directory
        let started = generation
        let task = Task.detached { try await LayaScorer(directory: directory) }
        loading = task
        defer { if started == generation { loading = nil } }
        do {
            let loaded = try await task.value
            if started == generation { scorer = loaded }
            return loaded
        } catch {
            NSLog("Varnick: relevance model failed to load: \(error)")
            if started == generation { state = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// The weights take about 0.85 GB of MLX memory at peak while loaded.
    private func unloadWhenIdle() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled, let self else { return }
            self.scorer = nil
            Memory.clearCache()
        }
    }
}
