import Foundation

public extension PeerPane {
    /// Whether an address can't be loaded from another machine: none yet, one that doesn't parse, a scheme other than http and https (`about:`
    /// and `file:` would load the viewer's own), or a host that is the machine itself: localhost and `*.localhost`, 127.0.0.0/8 however it is
    /// written (`127.1`, `2130706433`, `0x7f.1`), ::1, the unspecified addresses and IPv4-mapped IPv6. The only Swift copy; the page's and the
    /// proxy's is `isLocalAddress` in `PhonePage/page/tabrules.js`, and `tab.test.ts` holds the cases both answer alike.
    static func isLocalAddress(_ address: String) -> Bool {
        guard !address.isEmpty, let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        var host = (url.host ?? "").lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") { return true }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 {
            let number = UInt32(bigEndian: v4.s_addr)
            return number == 0 || number >> 24 == 127
        }
        // A host whose last part is a number is read as an IPv4 address by the URL standard, and one that isn't a valid one is no address.
        if let last = host.split(separator: ".", omittingEmptySubsequences: false).last, last.range(of: #"^(0[xX][0-9a-fA-F]*|[0-9]+)$"#, options: .regularExpression) != nil {
            return true
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            let zeros = bytes.prefix(10).allSatisfy { $0 == 0 }
            let mapped = zeros && bytes[10] == 0xff && bytes[11] == 0xff
            return mapped || (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] <= 1)
        }
        return false
    }
}
