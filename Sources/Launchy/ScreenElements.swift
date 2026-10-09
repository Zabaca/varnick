import AppKit
import ApplicationServices
import Foundation

// The pure parts of pointing at the screen (ADR 0019): what an element is called to the model, the sign's note, the one
// coordinate conversion and where the arrow and its sign go. None of it reads an app, so each is a seam for a first test.

/// An element of another app's window, held to read its frame again before the arrow is drawn.
final class AXReference: @unchecked Sendable, Equatable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (a: AXReference, b: AXReference) -> Bool { CFEqual(a.element, b.element) }
}

/// An element of the focused window with a frame inside it and a label. Frames are Accessibility's (`ScreenGeometry`).
struct ScreenElement: Sendable {
    /// As macOS names the kind ("button", "pop up button", "switch").
    var role: String
    /// Title, description, value, help and placeholder, de-duplicated and cut to `ScreenElements.maxLabel`.
    var label: String
    /// What the note calls it: title, else description, else placeholder (a text's own words for text); empty when it has none.
    var name: String
    var frame: CGRect
    var enabled = true
    var underPointer = false
    /// The named enclosing groups, outermost first.
    var path: [String] = []
    var beside: String?
    var help: String?
    /// Text or a heading: listed, and the words other elements are described beside.
    var isText = false
    var reference: AXReference?

    /// As the model reads it (the eval's F3): `1 (switch) in Sound, beside "Play sound on startup"`.
    var description: String {
        var markers = ""
        if !enabled { markers += ", dimmed" }
        if underPointer { markers += ", under the pointer" }
        var text = "\(label.isEmpty ? "(no label)" : label) (\(role)\(markers))"
        if !path.isEmpty { text += " in " + path.suffix(3).joined(separator: " > ") }
        if let beside { text += ", beside \"\(beside)\"" }
        return text
    }
}

enum ScreenElements {
    static let maxLabel = 80
    /// A Choice takes 255 options; a window with more keeps the first 255 in tree order.
    static let maxListed = 255

    /// The text a person reads as an element's name when its own label is only a state: the nearest text in the same group on the
    /// same row to its left (within 450 points), else the nearest just above (within 30). As the eval's `beside`.
    static func beside(_ element: ScreenElement, among texts: [ScreenElement]) -> String? {
        guard !element.isText else { return nil }
        let frame = element.frame
        var best: (gap: CGFloat, label: String)?
        for text in texts where text.path == element.path {
            let t = text.frame
            let gap: CGFloat
            if abs(t.midY - frame.midY) <= max(8, frame.height / 2) && t.maxX >= frame.minX - 450 && t.maxX <= frame.minX + 4 {
                gap = frame.minX - t.maxX
            } else if frame.minY - t.maxY >= 0 && frame.minY - t.maxY <= 30 && t.minX < frame.maxX && frame.minX < t.maxX {
                gap = 1000 + frame.minY - t.maxY
            } else {
                continue
            }
            if best == nil || gap < best!.gap { best = (gap, text.label) }
        }
        return best.map { String($0.label.prefix(maxLabel)) }
    }

    /// One line of words, without the direction marks and object-replacement characters Accessibility leaves in labels.
    static func cleaned(_ text: String) -> String {
        let marks: Set<Character> = ["\u{200E}", "\u{200F}", "\u{FFFC}"]
        return text.filter { !marks.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The parts that differ, joined with " / ", each cut to 120 characters and the whole to `maxLabel`.
    static func label(from parts: [String?]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for part in parts {
            guard let part, case let text = cleaned(part), !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            kept.append(String(text.prefix(120)))
        }
        return String(kept.joined(separator: " / ").prefix(maxLabel))
    }

    /// What Launchy says and the sign shows: "Here's the Allow button."; for a state with text beside it, "Here's the switch for
    /// Play sound on startup."; for the element under the pointer, "That's the Share button." and the first sentence of its help.
    static func note(for element: ScreenElement) -> String {
        let called: String
        if !element.name.isEmpty {
            let name = String(element.name.prefix(60))
            called = name.lowercased().hasSuffix(element.role.lowercased()) ? name : "\(name) \(element.role)"
        } else if let beside = element.beside {
            called = "\(element.role) for \(beside)"
        } else if !element.label.isEmpty {
            called = "\(String(element.label.prefix(60))) \(element.role)"
        } else {
            called = element.role
        }
        guard element.underPointer else { return "Here's the \(called)." }
        var note = "That's the \(called)."
        if let help = element.help, let sentence = firstSentence(of: help) { note += " " + sentence }
        return note
    }

    private static func firstSentence(of text: String) -> String? {
        let plain = cleaned(text)
        var first: String?
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { sentence, _, _, stop in
            first = sentence?.trimmingCharacters(in: .whitespaces)
            stop = true
        }
        guard var sentence = first, !sentence.isEmpty else { return nil }
        if sentence.count > 120 { sentence = String(sentence.prefix(120)).trimmingCharacters(in: .whitespaces) + "…" }
        return ".!?…".contains(sentence.last!) ? sentence : sentence + "."
    }
}

// MARK: What a request comes to

/// The element a spoken request points at, with what the sign says.
struct ScreenTarget: Equatable {
    var reference: AXReference?
    /// As read; read again just before the arrow is drawn.
    var frame: CGRect
    var note: String
    /// Printed by `Launchy --ask`, never logged.
    var description: String
}

/// Why nothing is pointed at. Each is spoken with nothing drawn, and the timing line names its kind.
enum ScreenMiss: Equatable {
    /// No app, or no element with a label in its window.
    case nothingListed
    /// Jev found the thing not to be in the window.
    case notPresent
    case noPermission
    case chrome
    /// Chosen, then gone when the arrow was to be drawn.
    case gone
    /// Jev did not choose (the gate is closed, or it failed): Gemma never points.
    case jevFailed

    var spoken: String {
        switch self {
        case .nothingListed, .notPresent: "I can't see that on your screen."
        case .noPermission: "I need Accessibility permission to see your screen. It's in Settings, under Listening."
        case .chrome: "I can't see inside pages in Chrome."
        case .gone: "I can't see that on your screen any more."
        case .jevFailed: "I can't point at things right now."
        }
    }

    var logKind: String {
        switch self {
        case .nothingListed: "nothing listed"
        case .notPresent: "not present"
        case .noPermission: "no permission"
        case .chrome: "Chrome"
        case .gone: "gone"
        case .jevFailed: "Jev failed"
        }
    }
}

// MARK: Where things are

/// Accessibility frames are global with the origin at the top left of the main display and Y growing down; AppKit's have it at
/// the bottom left of the main display, growing up. This is the one place they are converted.
enum ScreenGeometry {
    @MainActor
    static var mainDisplayHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func appKit(_ frame: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func accessibility(_ point: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }
}

/// Where the ring, the sign and the arrow between them go, in AppKit coordinates.
struct ArrowLayout: Equatable {
    var ring: CGRect
    var sign: CGRect
    /// The arrow runs from the sign to the ring.
    var tail: CGPoint
    var tip: CGPoint

    enum Side: CaseIterable { case right, left, below, above }

    static let ringOutset: CGFloat = 7
    static let arrowLength: CGFloat = 96
    static let margin: CGFloat = 14

    /// The sign goes on the side with the most room, an arrow's length away, and is kept on the display. It covers the element
    /// only when no side has room.
    static func place(element: CGRect, screen: CGRect, sign size: CGSize) -> ArrowLayout {
        let ring = element.insetBy(dx: -ringOutset, dy: -ringOutset)
        func room(_ side: Side) -> CGFloat {
            switch side {
            case .right: screen.maxX - ring.maxX - size.width - arrowLength
            case .left: ring.minX - screen.minX - size.width - arrowLength
            case .below: ring.minY - screen.minY - size.height - arrowLength
            case .above: screen.maxY - ring.maxY - size.height - arrowLength
            }
        }
        let side = Side.allCases.max { room($0) < room($1) }!
        let bounds = screen.insetBy(dx: margin, dy: margin)
        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
                   y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)),
                   width: rect.width, height: rect.height)
        }
        func within(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(v, low), high) }
        switch side {
        case .right:
            let sign = clamped(CGRect(x: ring.maxX + arrowLength, y: ring.midY - size.height / 2, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.minX, y: sign.midY),
                               tip: CGPoint(x: ring.maxX, y: within(sign.midY, ring.minY, ring.maxY)))
        case .left:
            let sign = clamped(CGRect(x: ring.minX - arrowLength - size.width, y: ring.midY - size.height / 2, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.maxX, y: sign.midY),
                               tip: CGPoint(x: ring.minX, y: within(sign.midY, ring.minY, ring.maxY)))
        case .below:
            let sign = clamped(CGRect(x: ring.midX - size.width / 2, y: ring.minY - arrowLength - size.height, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.midX, y: sign.maxY),
                               tip: CGPoint(x: within(sign.midX, ring.minX, ring.maxX), y: ring.minY))
        case .above:
            let sign = clamped(CGRect(x: ring.midX - size.width / 2, y: ring.maxY + arrowLength, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.midX, y: sign.minY),
                               tip: CGPoint(x: within(sign.midX, ring.minX, ring.maxX), y: ring.maxY))
        }
    }
}
