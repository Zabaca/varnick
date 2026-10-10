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
        /// The menu bar while listening: the halves lined up.
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
                [[(6, 8), (24, 8), (29.75, 29.56), (29.75, 53.67)],
                 [(58, 8), (40, 8), (34.25, 29.56), (34.25, 53.67)]].map { $0.map { CGPoint(x: $0.0, y: $0.1) } }
            }
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
            return true
        }
        image.isTemplate = template
        return image
    }

    /// The menu bar's image: 16pt, a template so the menu bar colours and highlights it.
    static func menuBarImage(listening: Bool) -> NSImage {
        let image = image(listening ? .cutListening : .cutIdle, size: 16, template: true)
        image.accessibilityDescription = "Varnick"
        return image
    }

    /// The page's accent, `#8f3c12`.
    static let accent = NSColor(srgbRed: 0x8f / 255, green: 0x3c / 255, blue: 0x12 / 255, alpha: 1)

    /// The runtime app icon: the master in the accent on a clear background.
    static func appIcon() -> NSImage { image(.master, size: 512, color: accent) }
}
