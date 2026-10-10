import Foundation

/// Where Varnick's own files are (the metallib, the Phone page, the build stamp), so one binary runs from a checkout's build
/// folder or inside Varnick.app. Foundation only, so a harness compiles it alone (where-it-breaks, Peers).
enum ResourceFolder {
    struct Place: Equatable {
        /// The bundle's `Contents/Resources` when the executable is in a bundle, else the executable's own folder, where `make build` puts them.
        var folder: URL
        var inBundle: Bool
    }

    /// This process's, from its executable with links resolved: the relay runs through the `varnick-peer` link, and `Bundle.main` answers
    /// for the link's folder there.
    static let current: Place = Bundle.main.executableURL.map(place(of:)) ?? Place(folder: URL(fileURLWithPath: "/"), inBundle: false)

    /// A bundle is `<name>.app/Contents/MacOS/<executable>`, wherever it sits (one under `.build/app/` included).
    static func place(of executable: URL) -> Place {
        let resolved = executable.resolvingSymlinksInPath()
        let macOS = resolved.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        if macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app" {
            return Place(folder: contents.appendingPathComponent("Resources", isDirectory: true), inBundle: true)
        }
        return Place(folder: macOS, inBundle: false)
    }
}
