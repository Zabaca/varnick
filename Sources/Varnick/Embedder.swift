import Foundation
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// Embeds page titles and search queries on this Mac with MLX. The model is downloaded once
/// (Settings › Models), loaded on first use and unloaded after a while idle.
@MainActor
final class Embedder: ObservableObject {
    enum State: Equatable {
        case unavailable, missing, downloading(Double), ready, failed(String)

        var isDownloading: Bool { if case .downloading = self { true } else { false } }
    }

    /// Stored with each vector. MLX's 8-bit Qwen3-Embedding gives the same vectors as Ollama's
    /// qwen3-embedding:0.6b (cosine 0.999), so archives embedded by either are kept.
    nonisolated static let modelKey = "qwen3-embedding:0.6b"
    static let downloadSize = "650 MB"
    private static let source = ModelSource(
        repo: "mlx-community/Qwen3-Embedding-0.6B-8bit", revision: "407ad2329cd30702720aafe83f74a1ba30fdfbca",
        files: ["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
                "added_tokens.json", "vocab.json", "merges.txt", "model.safetensors.index.json", "model.safetensors"])
    /// Added to a query and never to a page or session; the server embedder adds the same.
    nonisolated static let queryPrefix = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "
    nonisolated static let batchSize = 64
    private static let idleUnload: Duration = .seconds(600)

    @Published private(set) var state: State

    private let directory = URL.applicationSupportDirectory
        .appending(components: "Varnick", "models", "Qwen3-Embedding-0.6B-8bit")
    private var container: EmbedderModelContainer?
    private var loading: Task<EmbedderModelContainer, Error>?
    private var idleTimer: Task<Void, Never>?

    init() {
        if !MLXRuntime.hasMetalLibrary {
            state = .unavailable
        } else {
            state = FileManager.default.fileExists(atPath: directory.appending(path: "model.safetensors").path)
                ? .ready : .missing
        }
    }

    var isReady: Bool { state == .ready }

    /// Into a `.partial` folder first, so a cancelled download never looks complete.
    func download() async {
        switch state {
        case .missing, .failed: break
        case .unavailable, .downloading, .ready: return
        }
        state = .downloading(0)
        do {
            try await ModelDownload.run(Self.source, into: directory) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading(let shown) = self.state,
                          Int(fraction * 100) != Int(shown * 100) else { return }
                    self.state = .downloading(fraction)
                }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embed([Self.queryPrefix + text])[0]
    }

    /// L2-normalized vectors in input order. Batched shortest first, so each batch pads little.
    func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        let order = texts.indices.sorted { texts[$0].count < texts[$1].count }
        var out = [[Float]](repeating: [], count: texts.count)
        for start in stride(from: 0, to: order.count, by: Self.batchSize) {
            let batch = Array(order[start ..< min(start + Self.batchSize, order.count)])
            for (i, vector) in zip(batch, try await embed(batch.map { texts[$0] })) { out[i] = vector }
        }
        return out
    }

    private func embed(_ texts: [String]) async throws -> [[Float]] {
        let container = try await loaded()
        return await container.perform { context -> [[Float]] in
            let pad = context.tokenizer.eosTokenId ?? 0
            let ids = texts.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) }
            let width = ids.map(\.count).max() ?? 1
            let tokens = stacked(ids.map { MLXArray($0 + Array(repeating: pad, count: width - $0.count)) })
            // Padding is masked out of attention and out of last-token pooling.
            let mask = stacked(ids.map {
                MLXArray([Int32](repeating: 1, count: $0.count) + [Int32](repeating: 0, count: width - $0.count))
            })
            let output = context.model(tokens, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
            let pooled = context.pooling(output, mask: mask, normalize: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }

    /// Loads in about half a second; the first embedding after that adds ~200ms of shader setup.
    private func loaded() async throws -> EmbedderModelContainer {
        unloadWhenIdle()
        if let container { return container }
        if let loading { return try await loading.value }
        // Model folder deleted while Varnick runs: offer the download again.
        guard FileManager.default.fileExists(atPath: directory.appending(path: "model.safetensors").path) else {
            state = .missing
            throw CocoaError(.fileNoSuchFile)
        }
        MLXRuntime.capCache()
        let directory = directory
        let task = Task {
            try await EmbedderModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        container = loaded
        return loaded
    }

    /// The weights take ~650 MB of memory while loaded.
    private func unloadWhenIdle() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled, let self else { return }
            self.container = nil
            Memory.clearCache()
        }
    }
}
