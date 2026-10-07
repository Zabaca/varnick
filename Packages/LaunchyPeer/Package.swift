// swift-tools-version:6.2
import PackageDescription

// What a Launchy host's relay needs and nothing else: Foundation and POSIX, with no MLX, SwiftTerm or
// AppKit, so a Linux host builds it alone (ADR 0007, sessions-hosted-only-on-macs). The Mac app links the
// library by path; `launchy-peer` is the headless host's binary, built here with `--package-path`.
let package = Package(
    name: "LaunchyPeer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LaunchyPeer", targets: ["LaunchyPeer"]),
        .executable(name: "launchy-peer", targets: ["launchy-peer"]),
    ],
    targets: [
        .target(name: "LaunchyPeer", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "launchy-peer", dependencies: ["LaunchyPeer"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
