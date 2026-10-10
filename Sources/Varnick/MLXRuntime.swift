import Foundation
import MLX

/// What every MLX model in the process shares (the embedder, the local reranker and text generation).
enum MLXRuntime {
    /// MLX aborts the whole app when it can't find its Metal shaders (a plain `swift build`; `make build` adds them), so nothing touches
    /// MLX without this. The shaders are the resource folder's `mlx.metallib`; when it is there, MLX is told the path before its first
    /// call, so it doesn't guess at the binary's folder.
    static var hasMetalLibrary: Bool { metalLibraryFound }
    private static let metalLibraryFound: Bool = {
        let metallib = ResourceFolder.current.folder.appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: metallib.path) else { return false }
        GPU.metallib = metallib
        return true
    }()

    /// MLX keeps freed GPU buffers for reuse, by default up to the lesser of 1.5 times the GPU's recommended working set
    /// and 0.95 of RAM, which comes to about 95% of RAM.
    /// Set once, by whichever model loads first; call only after `hasMetalLibrary`.
    static func capCache() { _ = cacheCapped }
    private static let cacheCapped: Void = { Memory.cacheLimit = 64 * 1024 * 1024 }()
}
