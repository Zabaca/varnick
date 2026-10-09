import ApplicationServices
import Foundation

/// The pure parts of pointing at the screen (ADR 0019): what a control is called to the model, the sign's note, the coordinate
/// conversion and where the arrow and its sign go. None of it touches an app, so each is a seam for a first test.

/// An element of another app's window, held to read its frame again before the arrow is drawn.
final class AXReference: @unchecked Sendable, Equatable {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
    static func == (a: AXReference, b: AXReference) -> Bool { CFEqual(a.element, b.element) }
}

/// A control, field, tab or the like in the window in front, with a label and a frame on a display. Frames are as Accessibility
/// gives them: global, with the origin at the top left of the main display (`ScreenGeometry`).
struct ScreenElement: Sendable {
    /// As the app words it ("button", "pop up button", "switch").
    var role: String
    /// Everything the app says of it, one line, at most `ScreenElements.maxLabel` characters: what the model reads.
    var label: String
    /// What the note calls it: its title, else its description, else its placeholder, else the text beside it.
    var name: String
    var frame: CGRect
    var enabled = true
    var underPointer = false
    var inDialog = false
    /// The named groups it sits in, outermost first.
    var path: [String] = []
    /// Which window it was read from, so the text beside it is looked for in the same window.
    var scope = 0
    var beside: String?
    var help: String?
    var reference: AXReference?

    /// A row is labelled by the first text inside it, which the walk finds after the row.
    var isRow = false

    /// One element as the model reads it (format F3 of the screen-pointing eval): the label, the kind in parentheses with its
    /// markers, the groups it sits in and the text beside it, e.g. `1 (switch), beside "Play sound on startup"`.
    var description: String {
        var markers = ""
        if !enabled { markers += ", dimmed" }
        if underPointer { markers += ", under the pointer" }
        if inDialog { markers += ", in a dialog" }
        var text = "\(label.isEmpty ? "(no label)" : label) (\(role)\(markers))"
        if !path.isEmpty { text += " in " + path.suffix(3).joined(separator: " > ") }
        if let beside { text += ", beside \"\(beside)\"" }
        return text
    }
}

/// Text read from a window (a label, a heading): never a candidate, only the words beside a control.
struct ScreenText: Sendable {
    var label: String
    var frame: CGRect
    var path: [String]
    var scope: Int
}

enum ScreenElements {
    static let maxLabel = 80
    static let maxCandidates = 150

    /// The text a person reads as a control's name when its own label is only a value (a switch's "1"): the nearest text in the
    /// same group on the same row to its left, else the nearest text just above it. As the eval's `beside`.
    static func beside(_ element: ScreenElement, among texts: [ScreenText]) -> String? {
        let frame = element.frame
        let centreY = frame.midY
        var best: (gap: CGFloat, label: String)?
        for text in texts where text.scope == element.scope && text.path == element.path {
            let t = text.frame
            let gap: CGFloat
            if abs(t.midY - centreY) <= max(8, frame.height / 2) && t.maxX >= frame.minX - 450 && t.maxX <= frame.minX + 4 {
                gap = frame.minX - t.maxX
            } else if frame.minY - t.maxY >= 0 && frame.minY - t.maxY <= 30 && t.minX < frame.maxX && frame.minX < t.maxX {
                // Above only when nothing is on the row.
                gap = 1000 + frame.minY - t.maxY
            } else {
                continue
            }
            if best == nil || gap < best!.gap { best = (gap, text.label) }
        }
        return best.map { String($0.label.prefix(maxLabel)) }
    }

    /// The elements the model chooses among: duplicates (same role, label and frame) dropped, at most `maxCandidates` kept in walk
    /// order, the one under the pointer always.
    static func capped(_ elements: [ScreenElement]) -> [ScreenElement] {
        var seen = Set<String>()
        var kept: [ScreenElement] = []
        for element in elements {
            let key = "\(element.role)|\(element.label)|\(Int(element.frame.minX)),\(Int(element.frame.minY)),\(Int(element.frame.width)),\(Int(element.frame.height))"
            guard seen.insert(key).inserted else { continue }
            if kept.count < maxCandidates || element.underPointer { kept.append(element) }
        }
        return kept
    }

    /// One line of words with the direction marks and object-replacement characters Accessibility leaves in labels removed.
    static func cleaned(_ text: String) -> String {
        let marks: Set<Character> = ["\u{200E}", "\u{200F}", "\u{FFFC}"]
        return text.filter { !marks.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The parts joined with " / " when they differ, each cut to 120 characters, the whole to `maxLabel`.
    static func label(from parts: [String?]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for part in parts {
            guard let part, case let text = cleaned(part), !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
            kept.append(String(text.prefix(120)))
        }
        return String(kept.joined(separator: " / ").prefix(maxLabel))
    }

    // MARK: The note

    /// What Launchy says and the sign shows. "Here's the Allow button.", or for the element under the pointer "That's the Share
    /// button." and the first sentence of its help.
    static func note(for element: ScreenElement) -> String {
        let name = String(element.name.prefix(60))
        var called = name
        if name.isEmpty { called = element.role }
        else if !name.lowercased().hasSuffix(element.role.lowercased()) { called = name + " " + element.role }
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
        return sentence.last.map { ".!?…".contains($0) } == true ? sentence : sentence + "."
    }
}

// MARK: What a request comes to

/// The element a spoken request points at, with what the sign says.
struct ScreenTarget: Equatable {
    var reference: AXReference?
    /// Accessibility coordinates, as read; read again just before the arrow is drawn.
    var frame: CGRect
    var note: String
    /// For `Launchy --ask`, which prints them; never logged.
    var role: String
    var label: String
}

/// Why nothing is pointed at. Each is spoken with nothing drawn, and the timing line names its kind.
enum ScreenMiss: String, Equatable {
    /// No element had a label and a frame, or no app was found to read.
    case none
    case belowThreshold
    case noPermission
    case chrome
    /// The element was there when chosen and gone when the arrow was to be drawn.
    case gone
    /// Jev did not choose (no key, the filter not on TypeSafe, or it failed): Gemma never points.
    case unavailable

    var spoken: String {
        switch self {
        case .none, .belowThreshold: "I can't see that on your screen."
        case .noPermission: "I need Accessibility permission to see your screen. It's in Settings, under Listening."
        case .chrome: "I can't see inside pages in Chrome."
        case .gone: "I can't see that on your screen any more."
        case .unavailable: "I can't look at your screen right now."
        }
    }

    var logKind: String {
        switch self {
        case .none: "none"
        case .belowThreshold: "below the threshold"
        case .noPermission: "no permission"
        case .chrome: "Chrome"
        case .gone: "gone"
        case .unavailable: "unavailable"
        }
    }
}

// MARK: Where things are

/// Accessibility frames are global with the origin at the top left of the main display, and Y growing down; AppKit's have it at
/// the bottom left of the main display, growing up. This is the one place they are converted.
enum ScreenGeometry {
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

    static let ringOutset: CGFloat = 7
    static let arrowLength: CGFloat = 96
    static let margin: CGFloat = 14

    /// The sign goes on the side of the element with the most room, a step away so the arrow shows between them, and is kept on
    /// the display. It never covers the element unless the element leaves no room on any side.
    static func place(element: CGRect, screen: CGRect, sign size: CGSize) -> ArrowLayout {
        let ring = element.insetBy(dx: -ringOutset, dy: -ringOutset)
        let room = (
            right: screen.maxX - ring.maxX - size.width - arrowLength,
            left: ring.minX - screen.minX - size.width - arrowLength,
            below: ring.minY - screen.minY - size.height - arrowLength,
            above: screen.maxY - ring.maxY - size.height - arrowLength)
        let side = [("right", room.right), ("left", room.left), ("below", room.below), ("above", room.above)]
            .max { $0.1 < $1.1 }!.0
        let bounds = screen.insetBy(dx: margin, dy: margin)
        func clamped(_ rect: CGRect) -> CGRect {
            CGRect(x: min(max(rect.minX, bounds.minX), max(bounds.minX, bounds.maxX - rect.width)),
                   y: min(max(rect.minY, bounds.minY), max(bounds.minY, bounds.maxY - rect.height)),
                   width: rect.width, height: rect.height)
        }
        func within(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(v, low), high) }
        switch side {
        case "right":
            let sign = clamped(CGRect(x: ring.maxX + arrowLength, y: ring.midY - size.height / 2, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.minX, y: sign.midY),
                               tip: CGPoint(x: ring.maxX, y: within(sign.midY, ring.minY, ring.maxY)))
        case "left":
            let sign = clamped(CGRect(x: ring.minX - arrowLength - size.width, y: ring.midY - size.height / 2, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.maxX, y: sign.midY),
                               tip: CGPoint(x: ring.minX, y: within(sign.midY, ring.minY, ring.maxY)))
        case "below":
            let sign = clamped(CGRect(x: ring.midX - size.width / 2, y: ring.minY - arrowLength - size.height, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.midX, y: sign.maxY),
                               tip: CGPoint(x: within(sign.midX, ring.minX, ring.maxX), y: ring.minY))
        default:
            let sign = clamped(CGRect(x: ring.midX - size.width / 2, y: ring.maxY + arrowLength, width: size.width, height: size.height))
            return ArrowLayout(ring: ring, sign: sign, tail: CGPoint(x: sign.midX, y: sign.minY),
                               tip: CGPoint(x: within(sign.midX, ring.minX, ring.maxX), y: ring.maxY))
        }
    }
}
