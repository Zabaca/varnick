// Draws Varnick.app's icon: the Fold (Sources/Varnick/FoldMark.swift) in the accent, centred on a clear background, as the ten
// PNGs of an iconset. `make app-bundle` compiles it together with FoldMark.swift and turns the folder into Varnick.icns with
// iconutil. A build product only: nothing it writes is committed.
//
// Usage: make-icon <iconset folder>
import AppKit

@main
struct MakeIcon {
    /// The mark fills the middle 824/1024 of each side, which leaves the margin macOS's icon grid expects.
    static let fill: CGFloat = 824 / 1024

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: make-icon <iconset folder>\n".utf8))
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
                    try png(pixels: points * scale).write(to: folder.appendingPathComponent(name))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
            exit(1)
        }
    }

    /// A `pixels` square image with exactly that many pixels (an NSImage would double them on a Retina display).
    static func png(pixels: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw CocoaError(.fileWriteUnknown) }
        let side = CGFloat(pixels)
        let mark = side * fill
        let image = FoldMark.image(.master, size: mark, color: FoldMark.accent)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: (side - mark) / 2, y: (side - mark) / 2, width: mark, height: mark))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
