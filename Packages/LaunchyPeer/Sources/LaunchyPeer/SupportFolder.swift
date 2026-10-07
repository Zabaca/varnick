import Foundation

/// Launchy's own folder, defined once for the app and the relay. `readers/` and `panes/` live in it,
/// and a relay from one build and the app from another must agree on it, so on a Mac the path never
/// moves: `~/Library/Application Support/Launchy`. A headless host points it at its state folder when
/// it starts (`url`), before anything reads it.
public enum SupportFolder {
    nonisolated(unsafe) private static var chosen: URL?

    public static var url: URL {
        get {
            chosen ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Launchy", isDirectory: true)
        }
        set { chosen = newValue }
    }
}
