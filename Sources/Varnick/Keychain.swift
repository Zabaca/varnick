import Foundation
import Security

/// API keys in the login keychain: encrypted at rest and readable only by Varnick (macOS asks
/// the user before another app, or a rebuilt Varnick, can read them).
enum Keychain {
    private static let service = "com.zabaca.varnick"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether an item is saved, without reading it: reading a key can make macOS ask the user, and Settings only needs to know.
    static func exists(_ account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// What the Keychain says of an item. Only `errSecItemNotFound` means it isn't there: any other failure (the user refusing access to a
    /// rebuilt app, a locked keychain) is an item that may well exist, which a key that must never change must not be made again over.
    enum Lookup: Equatable {
        case found(String)
        case absent
        case unreadable(OSStatus)
    }

    static func lookup(_ account: String) -> Lookup {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else { return .unreadable(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return .unreadable(errSecDecode) }
        return .found(text)
    }

    enum Addition: Equatable {
        case added
        /// An item with that account is there already (made meanwhile, or one the lookup could not read): it is kept.
        case duplicate
        case failed(OSStatus)
    }

    /// Adds an item with `SecItemAdd` alone and never deletes first, so an existing item is never lost: `save` replaces, which a key that every
    /// subscription is bound to must not do.
    static func addNew(_ value: String, for account: String) -> Addition {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: "Varnick \(account)", kSecValueData: Data(value.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return .added }
        return status == errSecDuplicateItem ? .duplicate : .failed(status)
    }

    static func save(_ value: String, for account: String) throws {
        delete(account)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: "Varnick \(account)", kSecValueData: Data(value.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
            throw NSError(domain: "Varnick", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func delete(_ account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
