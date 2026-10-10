import AppKit

/// What the Grant buttons in Settings share (Accessibility: `ScreenReader.askForAccess`, Screen Recording: `ScreenText.askForAccess`).
/// macOS shows a permission's prompt once per app and answers later requests silently, so a Varnick whose row was removed with −
/// never comes back by asking. The way back is the pane and Varnick's app selected in Finder, to drag into the list or pick with +.
enum PermissionGrant {
    /// Opens a Privacy & Security pane, such as `Privacy_Accessibility`.
    @MainActor
    static func openPane(_ anchor: String) {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(pane)
        }
    }

    /// Selects Varnick in Finder: the app (the lists take Varnick.app, not the executable inside it) or, outside one, the binary.
    /// False when there is nothing to show.
    @MainActor
    @discardableResult
    static func revealVarnick() -> Bool {
        guard let shown = ResourceFolder.current.bundle ?? Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([shown])
        return true
    }
}
