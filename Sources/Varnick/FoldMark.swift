import AppKit

/// The Fold, Varnick's mark: a V split down the middle with its right half offset. Drawn from
/// its points because a bare executable has no resource bundle to load an image file from.
/// The page (`site/`) carries the same master inline; the two change together.
enum FoldMark {
    /// Three drawings in a 64-unit box, y down, each two quadrilaterals (left half, right half).
    enum Drawing {
        /// The app icon, the page's mark and its favicon.
        case master
        /// The menu bar while not listening: the halves apart.
        case cutIdle
        /// The menu bar while listening: the halves lined up, raised to make room for the bar under the V (`bar`).
        case cutListening

        fileprivate var halves: [[CGPoint]] {
            switch self {
            case .master:
                [[(6, 4.5), (24, 4.5), (30.25, 27.94), (30.25, 51.13)],
                 [(58, 11.5), (40, 11.5), (33.75, 34.94), (33.75, 58.13)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
            case .cutIdle:
                [[(6, 5), (24, 5), (29.75, 26.56), (29.75, 50.67)],
                 [(58, 11), (40, 11), (34.25, 32.56), (34.25, 56.67)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
            case .cutListening:
                [[(6, 5.5), (24, 5.5), (29.75, 27.06), (29.75, 51.17)],
                 [(58, 5.5), (40, 5.5), (34.25, 27.06), (34.25, 51.17)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
            }
        }

        /// The listening mark: a short bar under the V, away from the notice dot at the top right, so it tells Listening from off at
        /// 16 pt (the 1.5 pt step of the halves alone did not).
        fileprivate var bar: CGRect? {
            self == .cutListening ? CGRect(x: 17, y: 56.5, width: 30, height: 6) : nil
        }
    }

    /// The drawing at `size` points square. A template ignores `color`: the menu bar colours it.
    static func image(_ drawing: Drawing, size: CGFloat, color: NSColor = .black, template: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = rect.width / 64
            color.setFill()
            for half in drawing.halves {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: half[0].x * scale, y: half[0].y * scale))
                for point in half.dropFirst() { path.line(to: CGPoint(x: point.x * scale, y: point.y * scale)) }
                path.close()
                path.fill()
            }
            if let bar = drawing.bar {
                NSBezierPath(roundedRect: CGRect(x: bar.minX * scale, y: bar.minY * scale, width: bar.width * scale, height: bar.height * scale),
                             xRadius: scale, yRadius: scale).fill()
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    /// What the menu bar icon shows (option 10 of `listening-never-answers`). The Fold stays the logo: these are variants of it.
    enum MenuLook: Equatable {
        /// Today's mark, the halves apart.
        case off
        /// The halves lined up, with a bar under the V.
        case listening
        /// Listening's mark in red, while it is the user's turn.
        case voiceWaiting
        /// The same while Varnick works or speaks; `dimmed` is the other half of the pulse.
        case voiceBusy(dimmed: Bool)

        var description: String {
            switch self {
            case .off: "Varnick"
            case .listening: "Varnick, listening"
            case .voiceWaiting: "Varnick, in voice mode, waiting for you"
            case .voiceBusy: "Varnick, in voice mode, working"
            }
        }
    }

    /// The menu bar's image: 16pt. Off and listening are templates, so the menu bar colours and highlights them. Voice mode's red is not: it
    /// doesn't invert when the menu opens, and colour is otherwise the notice dot's alone.
    static func menuBarImage(_ look: MenuLook) -> NSImage {
        let image: NSImage
        switch look {
        case .off: image = Self.image(.cutIdle, size: 16, template: true)
        case .listening: image = Self.image(.cutListening, size: 16, template: true)
        case .voiceWaiting: image = Self.image(.cutListening, size: 16, color: .systemRed)
        case .voiceBusy(let dimmed): image = Self.image(.cutListening, size: 16, color: NSColor.systemRed.withAlphaComponent(dimmed ? 0.4 : 1))
        }
        image.accessibilityDescription = look.description
        return image
    }

    /// The page's accent, `#8f3c12`.
    static let accent = NSColor(srgbRed: 0x8f / 255, green: 0x3c / 255, blue: 0x12 / 255, alpha: 1)

    /// The runtime app icon: the master in the accent on a clear background.
    static func appIcon() -> NSImage { image(.master, size: 512, color: accent) }
}
