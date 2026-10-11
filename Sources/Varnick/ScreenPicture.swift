import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A picture of a window for a session's `look` (ADR 0023, option 07 of `sessions-cant-see-or-act-on-the-screen`): the capture the
/// text step makes (`ScreenText.capture`), cut to an area when asked, with the secure text fields the walk found painted black,
/// scaled and encoded to fit the socket. It shows everything else on the window, typed text included, and goes to Anthropic with the
/// session: what that means is in where-it-breaks.md, Screen access.
enum ScreenPicture {
    /// The long side, in pixels, that a picture is scaled down to: the size Claude reads without shrinking it again.
    static let longSide = 1568
    static let jpegQuality: CGFloat = 0.8
    /// Painted black around a secure field's frame, in points, for frames that are a little off.
    static let blackoutMargin: CGFloat = 4
    /// What a reply keeps for everything but the picture, before the text's own size: the JSON around it.
    static let replyHeadroom = 20_000

    /// The most bytes of picture that fit a reply with `textBytes` of text under the socket's line cap: base64 is four thirds, and
    /// the text counts twice for the escapes JSON may add.
    static func maxBytes(textBytes: Int) -> Int {
        max(0, PeerSocket.maxLine - replyHeadroom - 2 * textBytes) / 4 * 3
    }

    /// A picture ready to send, and what to tell the session of it.
    struct Made: Sendable {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int
        /// The part of the screen it shows, in screen points, the origin at the top left of the main display.
        var area: CGRect
        /// Secure fields inside `area` that were painted black.
        var hidden: Int

        var kind: String { mimeType == "image/png" ? "png" : "jpeg" }
        var pixelsPerPoint: CGFloat { area.width > 0 ? CGFloat(width) / area.width : 1 }
    }

    /// Why no picture was made; the message is the session's to read and the log names only the kind.
    enum Failure: Error {
        case outsideWindow
        case windowChanged
        case encoding
        case tooLarge

        var message: String {
            switch self {
            case .outsideWindow: "That area is outside the window"
            case .windowChanged: "The window changed size while it was captured: look again"
            case .encoding: "The picture could not be made"
            case .tooLarge: "The picture is too large to send"
            }
        }
    }

    /// Makes the picture of `capture`. `secure` are frames read from the window when it was at `was` (nil when unknown): they follow
    /// the window to where it was captured, and a window that changed size has none to follow, which fails the call rather than
    /// risk a field in the picture. `crop` is an area in screen points. The picture is at most `maxBytes`.
    static func make(_ capture: ScreenText.Capture, secure: [CGRect], windowWas was: CGRect?, crop: CGRect?, maxBytes: Int) throws -> Made {
        let window = capture.window
        let image = capture.image
        guard window.width >= 1, window.height >= 1, image.width > 0, image.height > 0 else { throw Failure.encoding }
        let imageSize = CGSize(width: image.width, height: image.height)

        let frames = try secure.map { frame -> CGRect in
            guard let was else { return frame }
            guard let moved = ScreenGeometry.moved(frame, from: was, to: window) else { throw Failure.windowChanged }
            return moved
        }

        let wanted = crop.map { $0.intersection(window) } ?? window
        guard !wanted.isNull, wanted.width >= 1, wanted.height >= 1 else { throw Failure.outsideWindow }
        let source = sourceRect(of: wanted, in: window, imageSize: imageSize)
        guard source.width >= 1, source.height >= 1, let cropped = image.cropping(to: source) else { throw Failure.outsideWindow }
        let area = CGRect(x: window.minX + source.minX * window.width / imageSize.width,
                          y: window.minY + source.minY * window.height / imageSize.height,
                          width: source.width * window.width / imageSize.width, height: source.height * window.height / imageSize.height)
        let hidden = frames.filter { $0.insetBy(dx: -blackoutMargin, dy: -blackoutMargin).intersects(area) }

        // The first size is the one asked for; a picture over the cap is made again at lower quality, then smaller.
        let base = scale(for: source.size)
        let attempts: [(scale: CGFloat, quality: CGFloat)] = [
            (base, jpegQuality), (base, 0.6), (base, 0.45),
            (base * 0.75, 0.6), (base * 0.55, 0.5), (base * 0.4, 0.45), (base * 0.25, 0.4),
        ]
        for (index, attempt) in attempts.enumerated() {
            let width = max(1, Int((source.width * attempt.scale).rounded()))
            let height = max(1, Int((source.height * attempt.scale).rounded()))
            let blackouts = hidden.map {
                outputRect(of: $0.insetBy(dx: -blackoutMargin, dy: -blackoutMargin), window: window, imageSize: imageSize, source: source,
                           output: CGSize(width: width, height: height))
            }
            guard let drawn = render(cropped, width: width, height: height, blackouts: blackouts) else { throw Failure.encoding }
            var best = encode(drawn, type: .jpeg, quality: attempt.quality).map { ($0, "image/jpeg") }
            // PNG only at the first size, and only when it is smaller: a window of flat colour and text often is.
            if index == 0, let png = encode(drawn, type: .png, quality: 1), png.count < (best?.0.count ?? .max) { best = (png, "image/png") }
            guard let (data, mimeType) = best else { throw Failure.encoding }
            if data.count <= maxBytes {
                return Made(data: data, mimeType: mimeType, width: width, height: height, area: area, hidden: hidden.count)
            }
        }
        throw Failure.tooLarge
    }

    // MARK: Pure parts

    /// The factor that brings the long side of `size` to `longSide` pixels; 1 for a picture that is already smaller.
    static func scale(for size: CGSize) -> CGFloat {
        let long = max(size.width, size.height)
        return long > CGFloat(longSide) ? CGFloat(longSide) / long : 1
    }

    /// The pixels of the capture that `area` (screen points, inside `window`) covers, rounded outwards to whole pixels, and no more
    /// than the capture holds. A thousandth of a pixel of float noise on an edge doesn't add a pixel.
    static func sourceRect(of area: CGRect, in window: CGRect, imageSize: CGSize) -> CGRect {
        let x = imageSize.width / window.width, y = imageSize.height / window.height
        let rect = CGRect(x: (area.minX - window.minX) * x, y: (area.minY - window.minY) * y, width: area.width * x, height: area.height * y)
        return rect.insetBy(dx: 0.001, dy: 0.001).integral.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Where a frame in screen points lands in the picture made of `source` (pixels of the capture) at the `output` size: pixels,
    /// the origin at the top left. Not cut to the picture.
    static func outputRect(of frame: CGRect, window: CGRect, imageSize: CGSize, source: CGRect, output: CGSize) -> CGRect {
        let x = imageSize.width / window.width, y = imageSize.height / window.height
        let toOutputX = output.width / source.width, toOutputY = output.height / source.height
        return CGRect(x: ((frame.minX - window.minX) * x - source.minX) * toOutputX,
                      y: ((frame.minY - window.minY) * y - source.minY) * toOutputY,
                      width: frame.width * x * toOutputX, height: frame.height * y * toOutputY)
    }

    // MARK: Drawing and encoding

    /// `image` scaled to the size on white (a window's corners are transparent, and JPEG has no alpha), then each of `blackouts` (top
    /// left origin) painted black. Painted after the scaling, so no resampling can carry a field's pixels past its edge.
    private static func render(_ image: CGImage, width: Int, height: Int, blackouts: [CGRect]) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for box in blackouts {
            // Whole pixels, rounded outwards.
            let flipped = CGRect(x: box.minX, y: CGFloat(height) - box.maxY, width: box.width, height: box.height)
            context.fill(flipped.insetBy(dx: -0.5, dy: -0.5).integral)
        }
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
