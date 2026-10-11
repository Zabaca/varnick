import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Writes short text on this Mac with Gemma 4 E2B on MLX (ADR 0012). The model is downloaded once
/// (Settings › Models), loaded on first use and unloaded after a while idle.
@MainActor
final class TextGenerator: ObservableObject {
    enum State: Equatable {
        case unavailable, missing, downloading(Double), ready, failed(String)

        var isDownloading: Bool { if case .downloading = self { true } else { false } }
    }
    enum Failure: LocalizedError {
        case notReady
        var errorDescription: String? { "Text generation isn't set up" }
    }

    static let downloadSize = "3.6 GB"
    private static let source = ModelSource(
        repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        files: ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json",
                "chat_template.jinja", "processor_config.json", "model.safetensors.index.json", "model.safetensors"],
        sizes: ["model.safetensors": 3_550_670_554, "tokenizer.json": 32_169_626])
    private static let idleUnload: Duration = .seconds(600)

    @Published private(set) var state: State
    /// The failed state came from loading the installed copy, not from a download: Settings then offers
    /// Download again beside Retry.
    @Published private(set) var failedToLoad = false

    private static let directory = URL.applicationSupportDirectory
        .appending(components: "Varnick", "models", "gemma-4-e2b-it-4bit")
    private var directory: URL { Self.directory }
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var idleTimer: Task<Void, Never>?

    /// Only checks that the files exist: this runs on the main thread at launch, and touches no MLX.
    init() {
        state = !MLXRuntime.hasMetalLibrary ? .unavailable : Self.installed(Self.directory) ? .ready : .missing
    }

    private static func installed(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "model.safetensors").path)
    }

    var isReady: Bool { state == .ready }

    /// The model is on disk, without a generator: Settings tells an install that already answers with it at launch.
    static var isInstalled: Bool { installed(directory) }

    // MARK: Download

    /// Into a `.partial` folder first; an installed copy is replaced only once the new one is complete.
    func download() async {
        switch state {
        case .missing, .failed: break
        case .unavailable, .downloading, .ready: return
        }
        state = .downloading(0)
        failedToLoad = false
        do {
            try await ModelDownload.run(Self.source, into: directory) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading(let shown) = self.state,
                          Int(fraction * 100) != Int(shown * 100) else { return }
                    self.state = .downloading(fraction)
                }
            }
            container = nil
            state = .ready
        } catch {
            NSLog("Varnick: text generation download failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    /// A failed load stays failed until the user acts: the same files would fail on every request.
    func retry() async {
        guard case .failed = state, failedToLoad else { return }
        failedToLoad = false
        state = Self.installed(directory) ? .ready : .missing
        _ = try? await loaded()
    }

    // MARK: Generation

    /// One reply to `prompt` as a fresh chat with no history, greedy, at most `maxTokens` new tokens.
    func generate(_ prompt: String, maxTokens: Int) async throws -> String {
        guard state == .ready else { throw Failure.notReady }
        let container = try await loaded()
        return try await withError {
            let session = ChatSession(container, generateParameters: .init(maxTokens: maxTokens, temperature: 0))
            return try await session.respond(to: prompt)
        }
    }

    /// Loads in about 1.3 s; the first reply after that adds ~2.8 s of shader setup.
    func loaded() async throws -> ModelContainer {
        unloadWhenIdle()
        if let container { return container }
        if let loading { return try await loading.value }
        // Model folder deleted while Varnick runs: back to "no model".
        guard Self.installed(directory) else {
            state = .missing
            throw CocoaError(.fileNoSuchFile)
        }
        guard MLXRuntime.hasMetalLibrary else {
            state = .unavailable
            throw Failure.notReady
        }
        MLXRuntime.capCache()
        let directory = directory
        let task = Task {
            try await withError {
                try await LLMModelFactory.shared.loadContainer(from: directory, using: #huggingFaceTokenizerLoader())
            }
        }
        loading = task
        defer { loading = nil }
        do {
            let loaded = try await task.value
            container = loaded
            return loaded
        } catch {
            NSLog("Varnick: text generation failed to load: \(error)")
            failedToLoad = true
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The weights take about 2.5 GB of MLX memory while loaded.
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
