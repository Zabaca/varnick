import Foundation

/// The one request path to a model server (ADR 0014), for Search embeddings and Text generation: an address on the
/// tailnet or this Mac is checked before anything is sent, and nothing sent or received is logged.
enum ModelServer {
    /// The Keychain account of the optional key (Settings › Models › Keys), sent as a bearer token when one is saved.
    static let keyAccount = "MODEL_SERVER_KEY"

    /// Kinds of failure the UI words; none holds the request, the reply or the key.
    enum Failure: LocalizedError, Equatable {
        case badAddress, notOnTailnet, notAnswering(String), status(Int), unreadable

        var errorDescription: String? {
            switch self {
            case .badAddress: "Not an http or https address"
            case .notOnTailnet: "Not on your tailnet"
            case .notAnswering(let reason): "Not answering: \(reason)"
            case .status(let code): "Not answering: \(Self.statusReason(code))"
            case .unreadable: "Not answering: the reply can't be read"
            }
        }

        /// What Settings shows after "Not answering:".
        var reason: String {
            switch self {
            case .notAnswering(let reason): reason
            case .status(let code): Self.statusReason(code)
            case .badAddress: "not an http or https address"
            case .unreadable: "the reply can't be read"
            case .notOnTailnet: "not on your tailnet"
            }
        }

        private static func statusReason(_ code: Int) -> String {
            switch code {
            case 401, 403: "status \(code), the server wants a key"
            case 404: "status 404, no such model or route"
            default: "status \(code)"
            }
        }
    }

    /// The address with the route added, without doubling a `/v1` it already ends in. Only `http` and `https`, with a host;
    /// a query, fragment or credentials in the address are dropped.
    static func url(_ address: String, route: String) -> URL? {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        parts.scheme = scheme
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        parts.path = path + (path.hasSuffix("/v1") ? "" : "/v1") + "/" + route
        return parts.url
    }

    /// The address's host, for Settings to name the machine; nil while the address isn't one.
    static func name(of address: String) -> String? {
        url(address, route: "")?.host
    }

    /// POSTs `body` as JSON to `route` at `address` and returns the 200 reply's bytes, once the name is resolved and every
    /// address is on the tailnet or this Mac. No redirect and no system proxy: the request goes only to that address.
    static func post(_ body: [String: Any], to route: String, at address: String, timeout: TimeInterval) async throws -> Data {
        guard let url = url(address, route: route), let host = url.host else { throw Failure.badAddress }
        guard try await resolvesOnlyToTailnetOrLoopback(host) else {
            NSLog("Varnick: model server refused: not on the tailnet")
            throw Failure.notOnTailnet
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = Keychain.read(keyAccount), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
            guard http.statusCode == 200 else {
                NSLog("Varnick: model server answered status \(http.statusCode)")
                throw Failure.status(http.statusCode)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            NSLog("Varnick: model server not answering (\(error.code.rawValue))")
            throw Failure.notAnswering(reason(for: error))
        }
    }

    /// Why a Check found no answer, for "Not answering: …"; nil when the address is off the tailnet.
    static func notAnsweringReason(_ error: Error) -> String? {
        guard let failure = error as? Failure else { return error.localizedDescription }
        return failure == .notOnTailnet ? nil : failure.reason
    }

    private static func reason(for error: URLError) -> String {
        switch error.code {
        case .timedOut: "timed out"
        case .cannotConnectToHost: "connection refused"
        case .cannotFindHost, .dnsLookupFailed: "name not found"
        case .notConnectedToInternet, .networkConnectionLost: "no network"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            "secure connection failed"
        case .appTransportSecurityRequiresSecureConnection: "plain http was refused"
        default: error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: The tailnet rule

    /// Whether every address `host` resolves to (an IP literal is its own) is on the tailnet or loopback. A name that
    /// doesn't resolve is "not answering", not "not on your tailnet".
    static func resolvesOnlyToTailnetOrLoopback(_ host: String) async throws -> Bool {
        let resolved = await Task.detached { addresses(of: host) }.value
        guard !resolved.isEmpty else { throw Failure.notAnswering("name not found") }
        return resolved.allSatisfy(isTailnetOrLoopback)
    }

    /// Raw bytes, 4 for IPv4 and 16 for IPv6. Blocks, so not on the main actor.
    nonisolated private static func addresses(of host: String) -> [[UInt8]] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0 else { return [] }
        defer { freeaddrinfo(head) }
        var found: [[UInt8]] = []
        var next = head
        while let info = next?.pointee {
            if info.ai_family == AF_INET, let sa = info.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { found.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }) }
            } else if info.ai_family == AF_INET6, let sa = info.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { found.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }) }
            }
            next = info.ai_next
        }
        return found
    }

    /// 100.64.0.0/10 and fd7a:115c:a1e0::/48 are Tailscale's; 127.0.0.0/8 and ::1 are this Mac. An IPv6 address that wraps
    /// an IPv4 one (::ffff:a.b.c.d) is judged by the IPv4 inside.
    nonisolated static func isTailnetOrLoopback(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 16 {
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return isTailnetOrLoopback(Array(bytes[12...])) }
            if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
            return bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 127 || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
