// swift-tools-version:6.2
import Foundation
import PackageDescription

// Varnick is a bare executable, so its Info.plist (bundle id, microphone and system audio usage
// strings) is linked into the binary; `make build` re-signs so the signature binds it, and
// relinks after an Info.plist-only change (SwiftPM doesn't track it).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "Varnick",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // Exact: the Makefile's prebuilt mlx.metallib has to match the MLX core inside mlx-swift.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        // Exact: its token ids are part of the relevance checkpoint's contract (ADR 0006).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
        // The relay's shared code: Foundation only, so a Linux host builds it alone.
        .package(path: "Packages/VarnickPeer"),
    ],
    targets: [
        .executableTarget(
            name: "Varnick",
            dependencies: [
                "SwiftTerm",
                .product(name: "VarnickPeer", package: "VarnickPeer"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Varnick",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        )
    ]
)
