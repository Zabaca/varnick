import AppKit

/// What the Grant buttons in Settings share (Accessibility: `ScreenReader.askForAccess`, Screen Recording: `ScreenText.askForAccess`).
/// macOS shows a permission's prompt once per app and answers later requests silently, so a Varnick whose row was removed with −
/// never comes back by asking. The way back is the pane and Varnick's app selected in Finder, to drag into the list or pick with +.
enum PermissionGrant {
    enum Kind: Hashable { case accessibility, screenRecording }

    /// What Settings says once Varnick is in Finder.
    static let revealHint = "Drag Varnick into the list, or use + and pick it"

    /// The permissions whose Grant showed Varnick in Finder in this process, because the list still lacked it.
    @MainActor private(set) static var revealed: Set<Kind> = []
    /// The permissions whose Grant was pressed before in this process.
    @MainActor private static var asked: Set<Kind> = []

    /// Opens a Privacy & Security pane, such as `Privacy_Accessibility`.
    @MainActor
    static func openPane(_ anchor: String) {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(pane)
        }
    }

    /// Records a press of `kind`'s Grant, and says whether it had been pressed before in this process.
    @MainActor
    static func noteAsked(_ kind: Kind) -> Bool {
        asked.insert(kind).inserted == false
    }

    /// With `granted` still false, selects Varnick in Finder and sets `revealed` for `kind`: the app (the lists take Varnick.app, not
    /// the executable inside it) or, outside one, the executable.
    @MainActor
    static func revealIfMissing(_ kind: Kind, granted: Bool) {
        guard !granted, let shown = ResourceFolder.current.bundle ?? Bundle.main.executableURL?.resolvingSymlinksInPath() else { return }
        revealed.insert(kind)
        NSWorkspace.shared.activateFileViewerSelecting([shown])
    }
}
