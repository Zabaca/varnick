import AppKit
import CoreServices
import Quartz
import SwiftUI
import WebKit

// MARK: - Tree

/// The file tree beside a tab's panes (⌘⇧F). Folders list when opened; dependency and
/// build folders are hidden; it follows changes on disk (Claude editing files) through FSEvents.
@MainActor
final class FileTree: ObservableObject {
    struct Row: Identifiable, Equatable {
        let path: String
        let name: String
        let depth: Int
        let isDirectory: Bool
        var id: String { path }
    }

    @Published private(set) var root = ""
    @Published private(set) var rows: [Row] = []
    private(set) var expanded: Set<String> = []
    private var listings: [String: [(name: String, isDirectory: Bool)]] = [:]
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    /// Never shown: large, generated, and noisy on disk while building. Matched by name at
    /// any depth. Git-ignored files otherwise show (.scratch specs, .env).
    private static let hidden: Set<String> = [
        ".git", ".DS_Store", "node_modules", ".build", "dist", "target", ".next", ".venv",
        "__pycache__", "DerivedData",
    ]

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }

    /// Shows `path` (a no-op when it already is the root) and starts following it. Symlinks
    /// are resolved first: FSEvents reports real paths (/tmp is /private/tmp).
    func show(_ path: String) {
        let path = Self.realPath(path)
        guard path != root || stream == nil else { return }
        stop()
        root = path
        expanded = []
        listings = [:]
        rebuild()
        watch()
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    func toggle(_ row: Row) {
        guard row.isDirectory else { return }
        if expanded.remove(row.path) == nil { expanded.insert(row.path) }
        rebuild()
    }

    private func rebuild() {
        var out: [Row] = []
        func add(_ dir: String, depth: Int) {
            for entry in listing(dir) {
                let path = (dir as NSString).appendingPathComponent(entry.name)
                out.append(Row(path: path, name: entry.name, depth: depth, isDirectory: entry.isDirectory))
                if entry.isDirectory && expanded.contains(path) { add(path, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        if out != rows { rows = out }
    }

    /// Folders first, then files, by name; cached until FSEvents says the folder changed.
    private func listing(_ dir: String) -> [(name: String, isDirectory: Bool)] {
        if let cached = listings[dir] { return cached }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let entries = urls
            .map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) }
            .filter { !Self.hidden.contains($0.0) }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            .map { (name: $0.0, isDirectory: $0.1) }
        listings[dir] = entries
        return entries
    }

    private func watch() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let tree = Unmanaged<FileTree>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
            let everything = (0..<count).contains { flags[$0] & rescan != 0 }
            MainActor.assumeIsolated { tree.changed(changed, everything: everything) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// FSEvents names the folders whose contents changed: list those again. Changes inside
    /// never-shown folders (a build writing to .build) are skipped. `everything`: FSEvents
    /// dropped events or the root moved, so nothing cached can be trusted.
    private func changed(_ paths: [String], everything: Bool) {
        let shown = paths
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { !$0.split(separator: "/").contains { Self.hidden.contains(String($0)) } }
        guard everything || !shown.isEmpty else { return }
        if everything { listings = [:] } else { for dir in shown { listings[dir] = nil } }
        rebuild()
    }
}

struct FileTreeView: View {
    @ObservedObject var tree: FileTree
    /// Folder shown: the focused pane's.
    let root: String
    /// File open in the focused pane, highlighted.
    let selected: String?
    let onOpen: (String) -> Void

    static let width: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text((root as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help((root as NSString).abbreviatingWithTildeInPath)
            .padding(.horizontal, 10)
            .frame(height: 28)
            Theme.hairline.frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree.rows) { row in
                        FileRow(row: row, open: tree.expanded.contains(row.path), selected: row.path == selected)
                            .onTapGesture { row.isDirectory ? tree.toggle(row) : onOpen(row.path) }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1)))
        .onAppear { tree.show(root) }
        .onChange(of: root) { _, new in tree.show(new) }
        .onDisappear { tree.stop() }
    }
}

struct FileRow: View {
    let row: FileTree.Row
    let open: Bool
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .opacity(row.isDirectory ? 1 : 0)
            Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: 11))
                .foregroundStyle(row.isDirectory ? Theme.sourceColor("web").opacity(0.8) : .secondary)
                .frame(width: 16)
            Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 12)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(selected ? Theme.selection : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Viewer

/// A file pane of another machine's tab: its text is read from that machine (`file`), when the pane shows and when it is reloaded.
struct RemoteFile {
    let host: String
    let pane: UUID
}

/// A file pane's view: text (Markdown rendered, or as source) that reloads as the file
/// changes, keeping the scroll position; anything else (images, PDFs) in Quick Look.
final class FileViewer: NSView, WKNavigationDelegate {
    let url: URL
    let remote: RemoteFile?
    private var scroll: NSScrollView?
    private var text: NSTextView?
    private var preview: QLPreviewView?
    private var web: WKWebView?
    /// The page has loaded and takes new bodies through `render`.
    private var webReady = false
    /// A file of another machine: its host has answered, with the text or a refusal, so the "Reading" line is gone.
    private var showsAnswer = false
    /// Last text read, so toggling source doesn't read the file again.
    private var lastText: String?
    /// Markdown shown as text instead of rendered.
    var showsSource = false {
        didSet { if showsSource != oldValue, let lastText { showText(lastText) } }
    }
    var isMarkdown: Bool { Markdown.extensions.contains(url.pathExtension.lowercased()) }
    /// Markdown small enough to show as text, so it can be rendered (bigger goes to Quick Look).
    var rendersMarkdown: Bool {
        isMarkdown && ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) <= Self.textLimit
    }
    /// A link to another file in rendered Markdown; the model opens it in a file pane.
    var onOpenFile: (String) -> Void = { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
    private var watcher: DispatchSourceFileSystemObject?
    private var fontSize: Double
    private var loads = 0
    private var missingTries = 0
    private static let missingRetries: [Double] = [0.1, 0.3, 1, 3]

    /// Bigger files show in Quick Look rather than as text.
    nonisolated private static let textLimit = 5_000_000
    /// The page rendered Markdown is swapped into (Markdown.page), as a file so images can load.
    private static let page = FileManager.default.temporaryDirectory.appendingPathComponent("varnick-markdown.html")
    /// Rendered Markdown is prose: a little larger than the terminal's monospace reads better.
    private static let proseBump = 1.5

    init(path: String, fontSize: Double, remote: RemoteFile? = nil) {
        url = URL(fileURLWithPath: path)
        self.remote = remote
        self.fontSize = fontSize
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What takes keyboard focus (selection, ⌘C, arrows).
    var focusTarget: NSView { web ?? text ?? preview ?? self }

    /// Reads off the main thread; a newer load supersedes one still reading.
    func load() {
        loads += 1
        let load = loads, url = self.url
        if let remote {
            // Never a blank area: the pane says it is reading until the host's answer, or its refusal, replaces that.
            let host = PeerManager.shared.name(of: remote.host)
            if !showsAnswer { showText("Reading \(url.lastPathComponent) from \(host)…") }
            Task { [weak self] in
                let result = await PeerManager.shared.fileText(pane: remote.pane, on: remote.host)
                guard let self, load == self.loads else { return }
                self.showsAnswer = true
                switch result {
                case .success(let text): self.showText(text.isEmpty ? "\(self.url.lastPathComponent) is empty." : text)
                case .failure(let refusal): self.showText("\(refusal.message). ⌘R asks \(host) again.")
                }
            }
            return
        }
        Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
            guard let self, load == self.loads else { return }
            self.show(content)
        }
    }

    private enum Content: Sendable { case text(String), preview, missing }

    /// Text when it's small and valid UTF-8 without NULs, else Quick Look. Size first, and
    /// no memory mapping: the file may be rewritten while it's read (that's why it's loading).
    nonisolated private static func read(_ url: URL) -> Content {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return .missing }
        guard size <= textLimit else { return .preview }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        if !data.contains(0), let string = String(data: data, encoding: .utf8) { return .text(string) }
        return .preview
    }

    /// A missing file is usually being replaced (git checkout, an editor's save): look again
    /// a few times, backing off, before saying it's gone.
    private func show(_ content: Content) {
        switch content {
        case .text(let string): showText(string)
        case .preview: showPreview()
        case .missing:
            guard missingTries >= Self.missingRetries.count else {
                let delay = Self.missingRetries[missingTries]
                missingTries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.load() }
                return
            }
            showText("\(url.lastPathComponent) no longer exists.")
        }
        if case .missing = content {} else { missingTries = 0 }
        watch()
    }

    func setFontSize(_ size: Double) {
        fontSize = size
        text?.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if webReady, let lastText { render(lastText) }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }

    /// Only one of the text view, the web view and Quick Look is on screen.
    private func keep(_ view: NSView?) {
        if view !== scroll { scroll?.removeFromSuperview(); scroll = nil; text = nil }
        if view !== web { web?.removeFromSuperview(); web = nil; webReady = false }
        if view !== preview { preview?.removeFromSuperview(); preview = nil }
    }

    private func showText(_ string: String) {
        lastText = string
        if isMarkdown && !showsSource { return render(string) }
        if text == nil {
            keep(nil)
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = bounds
            scroll.autoresizingMask = [.width, .height]
            scroll.drawsBackground = false
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 6, height: 6)
            addSubview(scroll)
            self.scroll = scroll
            self.text = text
        }
        guard let text, let scroll else { return }
        let origin = scroll.contentView.bounds.origin
        text.string = string
        text.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.textColor = NSColor(white: 0.9, alpha: 1)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func showPreview() {
        lastText = nil
        keep(preview)
        if preview == nil, let view = QLPreviewView(frame: bounds, style: .normal) {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            preview = view
        }
        preview?.previewItem = url as NSURL
        preview?.refreshPreviewItem()
    }

    // MARK: Markdown

    /// The page loads once (a file of its own, so images next to the Markdown can load);
    /// later bodies are swapped into it, which keeps the scroll position.
    private func render(_ markdown: String) {
        if web == nil {
            keep(nil)
            // No script from the page itself; evaluateJavaScript (the body swap) still runs.
            let config = WKWebViewConfiguration()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let web = WKWebView(frame: bounds, configuration: config)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground")   // no white flash before the first paint
            addSubview(web)
            self.web = web
            try? Markdown.page.write(to: Self.page, atomically: true, encoding: .utf8)
            web.loadFileURL(Self.page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }
        guard webReady, let web else { return }   // didFinish renders lastText
        let body = Markdown.html(markdown, base: url.deletingLastPathComponent())
        guard let json = try? JSONEncoder().encode([body]), let array = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("document.documentElement.style.fontSize = '\(fontSize + Self.proseBump)px';"
            + "document.getElementById('doc').innerHTML = \(array)[0];")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        webReady = true
        if let lastText { render(lastText) }
    }

    /// Only the page's own load is allowed. Clicked links: files open in a file pane, folders
    /// (and apps) are revealed in Finder, web and mail links go to their app; anchors
    /// (`#section`) do nothing, as headings have no ids.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let target = action.request.url
        if action.navigationType != .linkActivated {
            // By the time this is asked, webView.url already names the page being loaded.
            let own = target?.resolvingSymlinksInPath().path == Self.page.resolvingSymlinksInPath().path
            return decisionHandler(own ? .allow : .cancel)
        }
        decisionHandler(.cancel)
        guard let target else { return }
        if ["http", "https", "mailto"].contains(target.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(target)
            return
        }
        // A path in a file of another machine is that machine's: it would name, reveal or open something else here.
        guard target.isFileURL, remote == nil else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            if target.fragment == nil { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        } else {
            onOpenFile(target.path)
        }
    }

    /// Editors and Claude often replace the file (write elsewhere, rename over it), which
    /// ends the watch on the old one; reload and watch whatever is at the path now.
    private func watch() {
        stop()
        guard remote == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            // A replaced file may not be back yet; `show` retries until it is.
            MainActor.assumeIsolated { self?.load() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

/// File pane bar: the path (relative to the tree it was opened from), Markdown source /
/// rendered, open in the default app, reveal in Finder, close.
struct FileBar: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        let path = session.record.file ?? ""
        HStack(spacing: 8) {
            Image(systemName: Theme.sourceSymbol("file")).font(.system(size: 11)).foregroundStyle(Theme.sourceColor("file"))
            Text(relative(path))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(path)
            if session.fileViewer?.rendersMarkdown == true {
                Button { session.showsSource.toggle() } label: {
                    Image(systemName: session.showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                }
                .help(session.showsSource ? "Show rendered" : "Show source")
            }
            // A file of another machine's tab isn't on this Mac to open.
            if session.fileViewer?.remote == nil {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open in default app")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
            CloseButton(help: CloseButton.paneHelp) { session.end() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Theme.tileFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.bottom, 4)
    }

    private func relative(_ path: String) -> String {
        let dir = session.record.directory
        return path.hasPrefix(dir + "/") ? String(path.dropFirst(dir.count + 1)) : (path as NSString).abbreviatingWithTildeInPath
    }
}
