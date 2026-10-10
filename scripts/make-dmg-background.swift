// Draws the disk image's window background: the Fold (Sources/Varnick/FoldMark.swift) small above the middle, and an arrow from where
// Varnick sits to where the Applications shortcut sits (scripts/dmg-settings.json), on a mid-tone ground so the icon labels read whether
// Finder draws them black or white. No words. `make app-image` compiles it together with FoldMark.swift and writes `background.png`
// (640x400 pixels, 72 dpi) and `background@2x.png` (1280x800, 144 dpi), which dmgbuild combines into one Retina background. A build
// product only: nothing it writes is committed. The window is 640x400 points; keep the numbers here and in the settings file together.
//
// Usage: make-dmg-background <folder>
import AppKit

@main
struct MakeDmgBackground {
    static let width: CGFloat = 640
    static let height: CGFloat = 400
    /// Where the two icons' centres are, y down, as in the settings file: the arrow runs between them.
    static let appX: CGFloat = 160
    static let applicationsX: CGFloat = 480
    static let iconsY: CGFloat = 190
    /// Half an icon (128 points) and a gap, so the arrow touches neither an icon nor its label.
    static let iconHalf: CGFloat = 64 + 28

    static let ground = NSColor(srgbRed: 0x7a / 255, green: 0x74 / 255, blue: 0x6c / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0xf3 / 255, green: 0xec / 255, blue: 0xe2 / 255, alpha: 1)

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: make-dmg-background <folder>\n".utf8))
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png(scale: 1).write(to: folder.appendingPathComponent("background.png"))
            try png(scale: 2).write(to: folder.appendingPathComponent("background@2x.png"))
        } catch {
            FileHandle.standardError.write(Data("make-dmg-background: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The picture at `scale` pixels per point. Its size in points stays 640x400, which is what sets its resolution (72 or 144 dpi):
    /// `tiffutil -cathidpicheck` refuses two pictures that don't differ by exactly that.
    static func png(scale: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw CocoaError(.fileWriteUnknown) }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// In points, y up (AppKit's); the numbers above are y down, so they are flipped on the way in.
    static func draw() {
        ground.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let mark: CGFloat = 64
        FoldMark.image(.master, size: mark, color: ink)
            .draw(in: NSRect(x: (width - mark) / 2, y: height - 40 - mark, width: mark, height: mark))

        let y = height - iconsY
        let from = appX + iconHalf, to = applicationsX - iconHalf
        ink.setStroke()
        ink.setFill()
        let shaft = NSBezierPath()
        shaft.lineWidth = 6
        shaft.lineCapStyle = .round
        shaft.move(to: NSPoint(x: from, y: y))
        shaft.line(to: NSPoint(x: to - 14, y: y))
        shaft.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: to, y: y))
        head.line(to: NSPoint(x: to - 22, y: y + 14))
        head.line(to: NSPoint(x: to - 22, y: y - 14))
        head.close()
        head.fill()
    }
}
