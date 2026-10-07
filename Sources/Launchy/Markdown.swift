import Foundation

/// Markdown to HTML for file panes, from Foundation's own parser (no dependency). Text is
/// escaped and only http/https/mailto/file links are kept, so the file can't add HTML or script.
enum Markdown {
    static let extensions: Set<String> = ["md", "markdown"]
    private static let linkSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// The document body. Relative links and images resolve against `base` (the file's folder).
    static func html(_ markdown: String, base: URL) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let doc = try? AttributedString(markdown: markdown, options: options, baseURL: base) else {
            return "<pre>" + escape(markdown) + "</pre>"
        }
        var out = ""
        // Blocks open around the current run, outermost first.
        var open: [PresentationIntent.IntentType] = []
        for run in doc.runs {
            // Components come innermost first.
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < min(open.count, blocks.count), open[shared].identity == blocks[shared].identity { shared += 1 }
            for k in (shared..<open.count).reversed() { out += close(open[k], inHeader: open[..<k].contains(where: isHeaderRow)) }
            for k in shared..<blocks.count {
                out += self.open(blocks[k], around: blocks[..<k], first: blocks.indices.contains(k + 1) ? blocks[k + 1] : nil)
            }
            open = blocks
            if case .thematicBreak = blocks.last?.kind { continue }   // its text is a placeholder "⸻"
            out += inline(String(doc[run.range].characters), run: run, inCode: blocks.contains(where: isCodeBlock))
        }
        for k in open.indices.reversed() { out += close(open[k], inHeader: open[..<k].contains(where: isHeaderRow)) }
        return out
    }

    /// `first`: the block just inside this one, which for a list is its first item (an ordered
    /// list can start at any number).
    private static func open(_ block: PresentationIntent.IntentType, around: ArraySlice<PresentationIntent.IntentType>,
                             first: PresentationIntent.IntentType?) -> String {
        switch block.kind {
        case .paragraph: "<p>"
        case .header(let level): "<h\(level)>"
        case .orderedList:
            if case .listItem(let ordinal) = first?.kind, ordinal != 1 { "<ol start=\"\(ordinal)\">" } else { "<ol>" }
        case .unorderedList: "<ul>"
        case .listItem: "<li>"
        case .codeBlock(let language): language.map { "<pre><code class=\"language-\(escape($0))\">" } ?? "<pre><code>"
        case .blockQuote: "<blockquote>"
        case .thematicBreak: "<hr>"
        case .table: "<table>"
        case .tableHeaderRow: "<thead><tr>"
        case .tableRow: "<tr>"
        case .tableCell(let column):
            (around.contains(where: isHeaderRow) ? "<th" : "<td") + align(column, around) + ">"
        @unknown default: "<div>"
        }
    }

    private static func close(_ block: PresentationIntent.IntentType, inHeader: Bool) -> String {
        switch block.kind {
        case .paragraph: "</p>"
        case .header(let level): "</h\(level)>"
        case .orderedList: "</ol>"
        case .unorderedList: "</ul>"
        case .listItem: "</li>"
        case .codeBlock: "</code></pre>"
        case .blockQuote: "</blockquote>"
        case .thematicBreak: ""
        case .table: "</table>"
        case .tableHeaderRow: "</tr></thead>"
        case .tableRow: "</tr>"
        case .tableCell: inHeader ? "</th>" : "</td>"
        @unknown default: "</div>"
        }
    }

    /// A column's alignment from the table's `:--` / `:-:` / `--:` row.
    private static func align(_ column: Int, _ around: ArraySlice<PresentationIntent.IntentType>) -> String {
        for block in around {
            guard case .table(let columns) = block.kind, columns.indices.contains(column) else { continue }
            switch columns[column].alignment {
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            default: return ""
            }
        }
        return ""
    }

    private static func isHeaderRow(_ block: PresentationIntent.IntentType) -> Bool {
        if case .tableHeaderRow = block.kind { return true }
        return false
    }

    private static func isCodeBlock(_ block: PresentationIntent.IntentType) -> Bool {
        if case .codeBlock = block.kind { return true }
        return false
    }

    private static func inline(_ text: String, run: AttributedString.Runs.Run, inCode: Bool) -> String {
        if inCode { return escape(text) }
        if let image = run.imageURL {
            return "<img src=\"\(escape(image.absoluteString))\" alt=\"\(escape(text))\">"
        }
        let style = run.inlinePresentationIntent ?? []
        if style.contains(.lineBreak) { return "<br>" }
        if style.contains(.softBreak) { return " " }
        var html = style.contains(.code) ? "<code>\(escape(text))</code>" : escape(text)
        if style.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if style.contains(.emphasized) { html = "<em>\(html)</em>" }
        if style.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if let link = run.link, linkSchemes.contains(link.scheme?.lowercased() ?? "") {
            html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
        }
        return html
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// The page the body is swapped into (so a reload keeps the scroll position), styled
    /// like the panes: dark, system font, monospaced code. Text size is set with the body.
    static let page = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: dark; font-size: 14px; }
        body { margin: 0; padding: 14px 22px 40px; background: #1a1a1a; color: #e4e4e4;
               font: 1rem/1.55 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 52rem; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .5em; color: #fff; }
        h1 { font-size: 1.7rem; border-bottom: 1px solid #333; padding-bottom: .3em; }
        h2 { font-size: 1.35rem; border-bottom: 1px solid #2c2c2c; padding-bottom: .25em; }
        h3 { font-size: 1.12rem; } h4, h5, h6 { font-size: 1rem; }
        body > :first-child { margin-top: .3em; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 .9em; }
        li > p { margin: 0 0 .25em; } ul, ol { padding-left: 1.6em; }
        a { color: #6ea8fe; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: .88em ui-monospace, SFMono-Regular, Menlo, monospace; background: #2a2a2a;
               padding: .12em .35em; border-radius: 4px; }
        pre { background: #222; padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; font-size: .86em; line-height: 1.45; }
        blockquote { border-left: 3px solid #444; padding: 0 0 0 1em; color: #aaa; margin-left: 0; }
        hr { border: 0; border-top: 1px solid #333; margin: 1.5em 0; }
        table { border-collapse: collapse; } th, td { border: 1px solid #3a3a3a; padding: .35em .7em; }
        th { background: #252525; text-align: left; }
        img { max-width: 100%; } del { color: #888; }
        </style></head><body><div id="doc"></div></body></html>
        """
}
