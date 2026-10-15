import CryptoKit
import Foundation
import VarnickPeer

/// The Phone page server's push key on a Mac (`phone-page-is-only-a-browser-tab`, option 02): one P-256 key pair, made the first time the server
/// starts with the page on, whose private half rests in the Keychain as an item of its own and goes to the server in its environment alone. Every
/// browser subscription is bound to the public half, so the key must never change by itself: an existing item that can't be read (an ad-hoc build
/// may be refused after a rebuild) is never replaced, and the server starts without push until it can be read.
enum PhonePagePush {
    /// The Keychain item's account name.
    static let account = "phone-page-push-key"
    /// The label value of a server started with no push key.
    static let noKey = "none"

    struct Key: Equatable {
        /// The private JWK as one line of JSON: what the server's `VARNICK_PUSH_KEY` holds.
        var json: String
        /// The first 16 hex digits of the SHA-256 of the public point, `fingerprint` in `PhonePage/webpush.ts`.
        var fingerprint: String
    }

    /// The key, made if there was none. Nil when an item exists and can't be read now. Blocks on the Keychain (which may ask the user), so never on the main thread.
    static func current() -> Key? {
        if let saved = Keychain.read(account) { return key(fromJSON: saved) }
        guard !Keychain.exists(account) else { return nil }
        let made = make()
        do { try Keychain.save(made.json, for: account) } catch { return nil }
        return made
    }

    static func make() -> Key {
        // CryptoKit's x9.63 form of a private key is 04 || X || Y || the scalar.
        let bytes = [UInt8](P256.Signing.PrivateKey().x963Representation)
        return Key(json: jwk(x: Data(bytes[1..<33]), y: Data(bytes[33..<65]), d: Data(bytes[65..<97])), fingerprint: fingerprint(x: Data(bytes[1..<33]), y: Data(bytes[33..<65])))
    }

    /// A saved key read back. Nil for anything that isn't a P-256 private key of the right sizes.
    static func key(fromJSON text: String) -> Key? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["kty"] as? String == "EC", object["crv"] as? String == "P-256",
              let x = (object["x"] as? String).flatMap(decode), let y = (object["y"] as? String).flatMap(decode),
              let d = (object["d"] as? String).flatMap(decode), x.count == 32, y.count == 32, d.count == 32 else { return nil }
        return Key(json: jwk(x: x, y: y, d: d), fingerprint: fingerprint(x: x, y: y))
    }

    static func fingerprint(x: Data, y: Data) -> String {
        SHA256.hash(data: Data([4]) + x + y).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func jwk(x: Data, y: Data, d: Data) -> String {
        #"{"kty":"EC","crv":"P-256","x":"\#(encode(x))","y":"\#(encode(y))","d":"\#(encode(d))"}"#
    }

    private static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    /// What Settings says of each device: how many browsers of it the server holds a subscription for, from the server's file. Never an endpoint: only
    /// the device's id is read.
    static func counts(in phoneFolder: URL) -> [String: Int] {
        struct File: Decodable {
            struct Entry: Decodable { var device: String }
            var subscriptions: [Entry]
        }
        guard let data = try? Data(contentsOf: phoneFolder.appendingPathComponent("push-subscriptions.json")),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        return Dictionary(file.subscriptions.map { ($0.device.lowercased(), 1) }, uniquingKeysWith: +)
    }
}
