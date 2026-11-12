// swift-tools-version:6.2
import PackageDescription

// What a Varnick host's relay needs and nothing else: Foundation and POSIX, with no MLX, SwiftTerm or
// AppKit, so a Linux host builds it alone (ADR 0007, sessions-hosted-only-on-macs). The Mac app links the
// library by path; `varnick-peer` is the headless host's binary, built here with `--package-path`.
let package = Package(
    name: "VarnickPeer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VarnickPeer", targets: ["VarnickPeer"]),
        .executable(name: "varnick-peer", targets: ["varnick-peer"]),
        .executable(name: "slot-check", targets: ["slot-check"]),
        .executable(name: "runs-check", targets: ["runs-check"]),
        .executable(name: "voice-check", targets: ["voice-check"]),
        .executable(name: "work-check", targets: ["work-check"]),
        .executable(name: "open-check", targets: ["open-check"]),
        .executable(name: "message-check", targets: ["message-check"]),
    ],
    targets: [
        .target(name: "VarnickPeer", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "varnick-peer", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "slot-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "runs-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "voice-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "work-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "open-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "message-check", dependencies: ["VarnickPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
