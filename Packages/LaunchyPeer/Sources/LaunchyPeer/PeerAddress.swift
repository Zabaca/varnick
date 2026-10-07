import Foundation

/// What a peer is reached at: the one rule for an address, whether a Mac runs ssh with it or a headless
/// host stores it.
public enum PeerAddress {
    /// What a person would type after `ssh`: user, host and port characters, never a leading `-`
    /// (which ssh would read as an option) and no whitespace.
    public static func isValid(_ address: String) -> Bool {
        guard !address.isEmpty, address.utf8.count <= 255, !address.hasPrefix("-") else { return false }
        return address.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._:%-[]".contains($0)) }
    }
}
