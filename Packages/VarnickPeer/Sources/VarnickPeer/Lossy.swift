import Foundation

/// Decodes one element of a saved list, or nothing, so one bad entry doesn't take the rest.
public struct Lossy<Element: Decodable>: Decodable {
    public var value: Element?
    public init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
}
