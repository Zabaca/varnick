// swift-tools-version:6.2
import PackageDescription

// The loop of a Task (docs/problems/tasks-cant-be-handed-to-varnick, option 01): every rule of it, and nothing else. Foundation only, with no
// web view, model or UI, so `task-check` can run it on an in-memory made-up shop with recorded answers, and nothing here can reach a page or
// a model except through the seams in Seams.swift. The Mac app links the library by path, as it does VarnickPeer.
let package = Package(
    name: "TaskHarness",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TaskHarness", targets: ["TaskHarness"]),
        .executable(name: "task-check", targets: ["task-check"]),
    ],
    targets: [
        .target(name: "TaskHarness", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "task-check", dependencies: ["TaskHarness"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
