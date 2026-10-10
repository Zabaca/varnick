import Foundation

/// What a page says about itself in its <head>, the description a link preview shows.
/// Fetched without cookies, so a page behind a login gives nothing rather than its login screen's text.
struct PageMeta {
    var description = ""
    /// HTTP status; 0 when the request failed, worth trying again later.
    var status = 0

    private static let concurrency = 8
    private static let maxBytes = 512 * 1024
    private static let maxDescription = 500

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            // Many sites answer a non-browser agent with a block page.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml",
            "Accept-Language": "en",
        ]
        return URLSession(configuration: config)
    }()

    // Not fetched: internal hosts, and URLs that may carry a one-time token or act when opened.
    private static let skipHostSuffixes = [".local", ".internal", ".lan", ".home.arpa", ".ts.net"]
    private static let skipQueryNames: Set<String> = ["token", "code", "key", "sig", "signature", "secret", "auth", "session", "otp", "ticket"]
    private static let skipPathWords = ["unsubscribe", "verify", "confirm", "reset", "magic", "invite", "logout", "signout"]
    // Where a page that needs a login redirects to.
    private static let loginMarkers = ["login", "signin", "sign-in", "sign_in", "/auth", "/sso", "accounts.google.com"]
    private static let loginPhrases = ["log in", "login", "sign in", "sign-in"]

    static func worthFetching(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url), ["http", "https"].contains(parts.scheme),
              let host = parts.host?.lowercased(), host.contains("."),
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !skipHostSuffixes.contains(where: host.hasSuffix) else { return false }
        let path = parts.path.lowercased()
        return !skipPathWords.contains(where: path.contains)
            && !(parts.queryItems ?? []).contains { skipQueryNames.contains($0.name.lowercased()) }
    }

    /// Several at a time; results arrive in no particular order.
    static func fetchAll(_ urls: [String]) async -> [(url: String, meta: PageMeta)] {
        await withTaskGroup(of: (url: String, meta: PageMeta).self) { group in
            var pending = urls[...]
            for _ in 0 ..< concurrency {
                guard let url = pending.popFirst() else { break }
                group.addTask { (url, await fetch(url)) }
            }
            var results: [(url: String, meta: PageMeta)] = []
            while let result = await group.next() {
                results.append(result)
                if let url = pending.popFirst() { group.addTask { (url, await fetch(url)) } }
            }
            return results
        }
    }

    static func fetch(_ url: String) async -> PageMeta {
        guard let target = URL(string: url) else { return PageMeta() }
        do {
            let (bytes, response) = try await session.bytes(from: target)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let final = response.url?.absoluteString.lowercased() ?? ""
            // Sent to another host (mail.google.com → a Workspace sales page) means it isn't this page.
            guard (200 ..< 300).contains(status),
                  ["text/html", "application/xhtml+xml"].contains(response.mimeType ?? ""),
                  !loginMarkers.contains(where: final.contains),
                  site(response.url) == site(target) else {
                bytes.task.cancel()
                return PageMeta(status: status)
            }
            let found = description(in: try await head(bytes))
            let isLoginPage = loginPhrases.contains(where: found.lowercased().hasPrefix)
            return PageMeta(description: isLoginPage ? "" : found, status: status)
        } catch {
            return PageMeta()
        }
    }

    private static func site(_ url: URL?) -> String {
        let host = url?.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Reads until the head ends: meta tags live there, and a page body can be megabytes.
    private static func head(_ bytes: URLSession.AsyncBytes) async throws -> String {
        let end = Data("</head>".utf8), body = Data("<body".utf8)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count % 4096 == 0 else { continue }
            let recent = data.index(data.endIndex, offsetBy: -4096 - end.count, limitedBy: data.startIndex) ?? data.startIndex
            if data.count >= maxBytes || data.range(of: end, in: recent ..< data.endIndex) != nil
                || data.range(of: body, in: recent ..< data.endIndex) != nil { break }
        }
        bytes.task.cancel()
        return String(decoding: data, as: UTF8.self)
    }

    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\s[^>]*>", options: .caseInsensitive)
    private static let attribute = try! NSRegularExpression(
        pattern: "([a-zA-Z:_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")

    /// og:description, else the plain description, else Twitter's.
    static func description(in html: String) -> String {
        var found: [String: String] = [:]
        let ns = html as NSString
        for tag in metaTag.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: tag.range)
            var attrs: [String: String] = [:]
            for m in attribute.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let value = (2 ... 4).lazy.map { m.range(at: $0) }.first { $0.location != NSNotFound }
                    .map { (text as NSString).substring(with: $0) } ?? ""
                attrs[(text as NSString).substring(with: m.range(at: 1)).lowercased()] = value
            }
            guard let name = (attrs["property"] ?? attrs["name"])?.lowercased(), let content = attrs["content"] else { continue }
            if found[name] == nil { found[name] = content }
        }
        let raw = ["og:description", "description", "twitter:description"].lazy
            .compactMap { found[$0] }.map(clean).first { !$0.isEmpty } ?? ""
        return raw.count > maxDescription ? String(raw.prefix(maxDescription)) + "…" : raw
    }

    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                   "mdash": "—", "ndash": "–", "hellip": "…", "rsquo": "’", "lsquo": "‘",
                                   "rdquo": "”", "ldquo": "“", "middot": "·"]

    /// Entities decoded, whitespace collapsed.
    private static func clean(_ text: String) -> String {
        var out = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                let decoded: String? = name.hasPrefix("#x") || name.hasPrefix("#X")
                    ? UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
                    : name.hasPrefix("#") ? UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(String.init)
                    : entities[String(name)]
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
