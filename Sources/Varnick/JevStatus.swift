import Foundation

/// A TypeSafe call that answered with a status other than 200. It carries the number only, never the response body or the key, so a
/// log can say "HTTP 402" (a spent budget) where it used to say a bare `URLError -1011`.
struct JevStatus: Error, CustomStringConvertible {
    let code: Int

    var description: String { "HTTP \(code)" }

    /// Throws `JevStatus` for a status other than 200, and `URLError(.badServerResponse)` for a reply that isn't HTTP.
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw JevStatus(code: http.statusCode) }
    }
}
