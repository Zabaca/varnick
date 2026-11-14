import Foundation

// Which processes are the Chromium engine's helpers (option 02 of `two-browser-panes`, step 7): a pure rule over plain facts, so `make check-engine` runs it
// over a table of cases. Resources (`ResourceReport.build`) asks it for the processes it gives the engine's one row; ADR 0048 has the rest.

public enum EngineHelpers {
    /// Whether a process is this Varnick's engine helper: its file lies inside the framework's Helpers folder (`folder`, links resolved, since the kernel
    /// reports a path so) and its parent is this process. The parent is what keeps another Varnick's helpers out when two run from one framework.
    public static func isHelper(path: String?, parent: Int32, ownPid: Int32, folder: String?) -> Bool {
        guard let folder, !folder.isEmpty, let path, parent == ownPid else { return false }
        return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
