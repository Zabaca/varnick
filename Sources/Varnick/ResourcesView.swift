import SwiftUI

/// Resources (⌘⇧M, `!resources`): what Varnick's memory is made of, by tab, pane and helper, in place of the panel's content like the board.
/// It reads only what `Resources` published; the rows keep their order while it shows. Settings › Resources shows `ResourcesTable` too.
struct ResourcesView: View {
    @ObservedObject var resources: Resources
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "memorychip").foregroundStyle(.secondary)
                Text("Resources").font(.system(size: 15, weight: .semibold))
                Spacer()
                ResourcesHints()
                Button(action: close) { KeyHint(label: "Back", keys: ["esc"]) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, Theme.gutter)
            .frame(height: LauncherModel.searchHeight)
            .background(WindowDragArea())
            Theme.hairline.frame(height: 1)

            ResourcesTable(resources: resources, scrolls: true)
        }
    }
}

/// The keys besides ↑, ↓ and esc, which the view's header and Settings show their own way.
struct ResourcesHints: View {
    var body: some View {
        HStack(spacing: 14) {
            KeyHint(label: "Open", keys: ["→"])
            KeyHint(label: "Show", keys: ["↩"])
            ShortcutHint(label: "Close tab", action: .endPane)
        }
    }
}

/// The report as a table, or "Measuring…" until the first reading is back. In Settings it sits in the page's own scroll view (`scrolls` false),
/// whose reader brings the selected tab into view (`SettingsView`), since a reader inside the scroll view would not scroll it.
struct ResourcesTable: View {
    @ObservedObject var resources: Resources
    let scrolls: Bool
    /// The height of "Measuring…" in Settings, where nothing else gives the page a size yet.
    private static let measuringHeight: CGFloat = 120

    var body: some View {
        if let report = resources.report {
            ResourcesBody(resources: resources, report: report, app: resources.app, scrolls: scrolls)
        } else {
            Text("Measuring…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: scrolls ? nil : Self.measuringHeight, maxHeight: scrolls ? .infinity : nil)
        }
    }
}

private struct ResourcesBody: View {
    @ObservedObject var resources: Resources
    let report: ResourceReport
    let app: ResourceApp?
    let scrolls: Bool

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView { content }
                    .onChange(of: resources.selection) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if let app { appSplit(app) }
            if !report.tabs.isEmpty { section("Tabs", count: report.tabs.count) { ForEach(report.tabs) { tab in TabBlock(resources: resources, tab: tab) } } }
            if !report.helpers.isEmpty {
                section("Not in a tab") {
                    ForEach(report.helpers) { helper in
                        FigureRow(title: helper.helper.title, detail: ResourceFigure.processes(helper.processes.count), figure: helper.total)
                    }
                }
            }
            if !report.elsewhere.isEmpty {
                section("Tabs on other machines") {
                    ForEach(report.elsewhere) { tab in
                        FigureRow(title: tab.name, detail: "Runs on \(tab.host)", figure: tab.count > 0 ? tab.share : nil)
                    }
                }
            }
            if report.outsideCount > 0 {
                Text("Claude Code: \(ResourceFigure.processes(report.outsideCount)) in other apps and terminals · \(ResourceFigure.text(report.outsideTotal))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .opacity(0.6)
                    .padding(.horizontal, 10)
            }
            if !WebKitProcess.canTellResponsibility {
                Text("macOS's responsible-process call is missing here, so WebKit's shared processes and any page no pane names are not counted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Varnick \(ResourceFigure.text(report.total)) · \(ResourceFigure.processes(report.count))")
                .font(.system(size: 17, weight: .semibold))
            Text(report.kinds.map { "\($0.kind.title) \(ResourceFigure.text($0.total)) (\($0.count))" }.joined(separator: "  ·  "))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
    }

    /// The app's own memory in its three parts.
    private func appSplit(_ app: ResourceApp) -> some View {
        section("The app", figure: app.footprint) {
            FigureRow(title: "On-device models", detail: app.modelNames.isEmpty ? "none loaded" : app.modelNames.joined(separator: ", "),
                      figure: app.models)
            if let graphics = app.graphics { FigureRow(title: "Graphics", detail: "the app's own drawing", figure: graphics) }
            FigureRow(title: "Everything else", detail: "", figure: app.rest)
        }
    }

    private func section<Content: View>(_ title: String, count: Int? = nil, figure: UInt64? = nil, @ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                if let count { Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                Spacer()
                if let figure { Text(ResourceFigure.text(figure)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            rows()
        }
    }
}

/// A line of the view: a title, what it is, and its figure at the right.
private struct FigureRow: View {
    let title: String
    let detail: String
    let figure: UInt64?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let figure { Text(ResourceFigure.text(figure)).font(.system(size: 13).monospacedDigit()) }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// A tab's row with its Close, and below it, while it is open, its panes and their processes.
private struct TabBlock: View {
    @ObservedObject var resources: Resources
    let tab: ResourceTabRow

    var body: some View {
        let open = resources.expanded.contains(tab.id)
        let selected = resources.selection == tab.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                SourceTile(source: tab.kind, size: 26, symbol: tab.panes.count > 1 ? "rectangle.split.2x1" : nil)
                Text(tab.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(ResourceFigure.processes(tab.count)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(ResourceFigure.text(tab.total)).font(.system(size: 13).monospacedDigit())
                CloseButton(help: "Close tab" + (tab.panes.count > 1 ? " (\(tab.panes.count) panes)" : "")) { resources.closeTab(tab.id) }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { resources.toggle(tab.id) }

            if open {
                ForEach(tab.panes) { pane in
                    if tab.panes.count > 1 {
                        HStack(spacing: 8) {
                            Text(pane.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ResourceFigure.text(pane.total)).font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        }
                        .padding(.leading, 56)
                        .padding(.trailing, 10)
                        .frame(height: 24)
                    }
                    if pane.processes.isEmpty {
                        Text("Nothing running").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .padding(.leading, tab.panes.count > 1 ? 68 : 56).frame(height: 22)
                    }
                    ForEach(pane.processes) { process in
                        HStack(spacing: 8) {
                            Text(process.name).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ResourceFigure.text(process.footprint)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.leading, tab.panes.count > 1 ? 68 : 56)
                        .padding(.trailing, 10)
                        .frame(height: 20)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .id(tab.id)
    }
}
