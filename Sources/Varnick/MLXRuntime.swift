import Foundation
import MLX

/// What every MLX model in the process shares (the embedder, the local reranker and text generation).
enum MLXRuntime {
    /// MLX aborts the whole app when its Metal shaders aren't next to the binary (a plain
    /// `swift build`; `make build` adds them), so nothing touches MLX without this.
    static var hasMetalLibrary: Bool {
        guard let binary = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        return FileManager.default.fileExists(atPath: binary.deletingLastPathComponent().appending(path: "mlx.metallib").path)
    }

    /// MLX keeps freed GPU buffers for reuse, by default up to the lesser of 1.5 times the GPU's recommended working set
    /// and 0.95 of RAM, which comes to about 95% of RAM.
    /// Set once, by whichever model loads first; call only after `hasMetalLibrary`.
    static func capCache() { _ = cacheCapped }
    private static let cacheCapped: Void = { Memory.cacheLimit = 64 * 1024 * 1024 }()
}
