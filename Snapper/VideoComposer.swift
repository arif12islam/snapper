import AppKit
import AVFoundation
import CoreImage

/// Video editor settings.
struct VideoEditSettings: Equatable {
    enum Format: String, CaseIterable {
        case original = "Original", landscape = "Landscape 16:9", square = "Square 1:1",
             vertical = "Vertical 9:16", portrait = "Portrait 4:5"

        var aspect: BackgroundSettings.Aspect {
            switch self {
            case .original: return .auto
            case .landscape: return .sixteenNine
            case .square: return .square
            case .vertical: return .nineSixteen
            case .portrait: return .fourFive
            }
        }
    }

    var background = BackgroundSettings.off
    var format: Format = .original
    var smartZoom = false
    var zoomLevel: Double = 2.0
    var smoothCursor = true
    var cursorScale: Double = 1.5
    var clickEffects = true
    var motionBlur: Double = 0.4       // 0...1

    var isIdentity: Bool {
        background.isNone && format == .original && !smartZoom
    }
}

/// Builds an AVVideoComposition that applies the editor settings frame by frame with Core Image.
/// The same composition drives the live preview (AVPlayerItem) and the export.
final class VideoComposer: @unchecked Sendable {
    let settings: VideoEditSettings
    let log: CursorLog?
    private let sourceSize: CGSize
    private let outputSize: CGSize
    private let contentRect: CGRect          // in output pixels, bottom-left origin (Core Image)
    private let backdrop: CIImage?           // background + shadow, output size
    private let mask: CIImage?               // rounded corners mask, output size
    private let cursorImage: CIImage?
    private let cursorHotspot: CGPoint
    private let zoomTrack: [ZoomSegment]
    private let cameraPath: [SIMD3<Double>]   // zoom, focus x, focus y every `camStep` seconds

    struct ZoomSegment {
        var start: Double
        var end: Double
        var focus: CGPoint                   // normalised, top-left origin
    }

    init(settings: VideoEditSettings, sourceSize: CGSize, log: CursorLog?) {
        self.settings = settings
        self.log = log
        self.sourceSize = sourceSize

        // Layout: reuse the screenshot Background tool geometry, then scale so the long side stays at the source's.
        var bg = settings.background
        bg.aspect = settings.format.aspect
        if bg.isNone && settings.format != .original {
            // A format change needs something behind the video.
            bg.fill = .color("#000000")
            bg.padding = 0
            bg.shadow = 0
            bg.cornerRadius = 0
        }
        let lay = BackgroundMaker.layout(bg, contentSize: sourceSize)
        let longSource = max(sourceSize.width, sourceSize.height)
        let k = bg.isNone ? 1 : longSource / max(lay.canvasSize.width, lay.canvasSize.height)
        func even(_ v: CGFloat) -> CGFloat { max(2, CGFloat(Int((v).rounded()) / 2 * 2)) }
        let out = CGSize(width: even(lay.canvasSize.width * k), height: even(lay.canvasSize.height * k))
        outputSize = bg.isNone ? sourceSize : out
        // Convert the top-left content rect to Core Image's bottom-left space.
        let c = lay.contentRect
        contentRect = bg.isNone
            ? CGRect(origin: .zero, size: sourceSize)
            : CGRect(x: c.minX * k, y: out.height - c.maxY * k, width: c.width * k, height: c.height * k)

        if bg.isNone {
            backdrop = nil
            mask = nil
        } else {
            let tl = CGRect(x: c.minX * k, y: c.minY * k, width: c.width * k, height: c.height * k)
            backdrop = Self.renderBackdrop(bg, size: out, content: tl, scale: k)
            mask = Self.renderMask(bg, size: out, content: tl, scale: k)
        }

        if let img = NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cursorImage = CIImage(cgImage: img)
            let pts = NSCursor.arrow.image.size
            let hs = NSCursor.arrow.hotSpot
            // Hot spot in pixels from the bottom-left of the cursor image.
            let sx = CGFloat(img.width) / max(pts.width, 1)
            cursorHotspot = CGPoint(x: hs.x * sx, y: CGFloat(img.height) - hs.y * sx)
        } else {
            cursorImage = nil
            cursorHotspot = .zero
        }

        zoomTrack = settings.smartZoom ? Self.buildZoomTrack(log) : []
        cameraPath = settings.smartZoom ? Self.simulateCamera(track: zoomTrack, log: log, level: settings.zoomLevel) : []
    }

    var renderSize: CGSize { outputSize }

    // MARK: - Pre-rendered layers

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func renderBackdrop(_ s: BackgroundSettings, size: CGSize, content: CGRect, scale: CGFloat) -> CIImage? {
        guard let ctx = context(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        BackgroundMaker.drawFill(s, in: ctx, rect: CGRect(origin: .zero, size: size), flipped: true)
        let contentSize = CGSize(width: content.width / scale, height: content.height / scale)
        let r = BackgroundMaker.radius(s, contentSize: contentSize) * scale
        let sh = BackgroundMaker.shadowParams(s, contentSize: contentSize)
        let path = CGPath(roundedRect: content, cornerWidth: r, cornerHeight: r, transform: nil)
        if sh.alpha > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -sh.offset * scale), blur: sh.blur * scale,
                          color: NSColor.black.withAlphaComponent(sh.alpha).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    private static func renderMask(_ s: BackgroundSettings, size: CGSize, content: CGRect, scale: CGFloat) -> CIImage? {
        guard let ctx = context(size) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let contentSize = CGSize(width: content.width / scale, height: content.height / scale)
        let r = BackgroundMaker.radius(s, contentSize: contentSize) * scale
        ctx.addPath(CGPath(roundedRect: content, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    // MARK: - Smart zoom

    private static let zoomIn = 0.55, zoomOut = 0.7, hold = 2.2

    /// One zoom segment per click; clicks close together merge into one longer segment.
    private static func buildZoomTrack(_ log: CursorLog?) -> [ZoomSegment] {
        guard let clicks = log?.clicks, !clicks.isEmpty else { return [] }
        var segments: [ZoomSegment] = []
        for c in clicks {
            let start = max(0, c[0] - 0.5), end = c[0] + hold
            if var last = segments.last, start <= last.end + zoomOut {
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                segments.append(ZoomSegment(start: start, end: end, focus: CGPoint(x: c[1], y: c[2])))
            }
        }
        return segments
    }

    private static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static let camStep = 1.0 / 120

    /// Simulates a camera on critically damped springs, so zooming and panning ease in and out like a real
    /// camera operator instead of following the pointer directly. The camera only pans when the pointer nears
    /// the edge of the zoomed view (a dead zone), which removes the jitter of tracking every small movement.
    /// Precomputed once, so every frame reads the same path whatever order frames are rendered in.
    private static func simulateCamera(track: [ZoomSegment], log: CursorLog?, level: Double) -> [SIMD3<Double>] {
        guard let first = track.first, let last = track.last else { return [] }
        let endTime = max(last.end + 3, (log?.samples.last?.first ?? 0) + 0.5)
        let count = Int(endTime / camStep) + 2
        var path: [SIMD3<Double>] = []
        path.reserveCapacity(count)

        let wz = 2 * Double.pi * 0.8      // zoom spring: settles in about a second
        let wp = 2 * Double.pi * 0.5      // pan spring: softer, so the view glides
        let half = 0.5 / max(level, 1)
        let margin = half * 0.55
        var z = 1.0, vz = 0.0
        var fx = Double(first.focus.x), fy = Double(first.focus.y), vx = 0.0, vy = 0.0
        var tx = fx, ty = fy
        var seg = 0
        var wasActive = false

        for i in 0..<count {
            let t = Double(i) * camStep
            while seg < track.count, t > track[seg].end { seg += 1 }
            let active = seg < track.count && t >= track[seg].start
            let targetZoom = active ? level : 1.0

            if active && !wasActive {
                tx = Double(track[seg].focus.x)
                ty = Double(track[seg].focus.y)
                // Fully zoomed out, the focus is invisible: start right on the click.
                if z < 1.03 { fx = tx; fy = ty; vx = 0; vy = 0 }
            }
            wasActive = active

            if active, let p = log?.smoothedPosition(at: t, window: 0.3) {
                let dx = Double(p.x) - tx, dy = Double(p.y) - ty
                if abs(dx) > margin { tx += dx - (dx > 0 ? margin : -margin) }
                if abs(dy) > margin { ty += dy - (dy > 0 ? margin : -margin) }
            }
            // Keep the zoomed view inside the frame, so it never hits the edge and stops dead.
            tx = min(max(tx, half), 1 - half)
            ty = min(max(ty, half), 1 - half)

            vz += (wz * wz * (targetZoom - z) - 2 * wz * vz) * camStep
            z += vz * camStep
            vx += (wp * wp * (tx - fx) - 2 * wp * vx) * camStep
            fx += vx * camStep
            vy += (wp * wp * (ty - fy) - 2 * wp * vy) * camStep
            fy += vy * camStep
            path.append(SIMD3(max(1, z), fx, fy))
        }
        return path
    }

    /// Zoom factor and focus point (normalised, top-left origin) at time t.
    func camera(at t: Double) -> (zoom: CGFloat, focus: CGPoint) {
        guard settings.smartZoom, !cameraPath.isEmpty else { return (1, CGPoint(x: 0.5, y: 0.5)) }
        let f = max(0, t / Self.camStep)
        let i = min(Int(f), cameraPath.count - 1)
        let j = min(i + 1, cameraPath.count - 1)
        let k = min(max(f - Double(i), 0), 1)
        let c = cameraPath[i] + (cameraPath[j] - cameraPath[i]) * k
        return (CGFloat(c.x), CGPoint(x: c.y, y: c.z))
    }

    /// Source-space crop for a camera (pixels, bottom-left origin).
    private func cropRect(zoom: CGFloat, focus: CGPoint) -> CGRect {
        let w = sourceSize.width / zoom, h = sourceSize.height / zoom
        var x = focus.x * sourceSize.width - w / 2
        var y = (1 - focus.y) * sourceSize.height - h / 2
        x = min(max(x, 0), sourceSize.width - w)
        y = min(max(y, 0), sourceSize.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Frame

    func render(_ source: CIImage, at t: Double) -> CIImage {
        var frame = source.cropped(to: CGRect(origin: .zero, size: sourceSize))

        // 1. Cursor (drawn here when the video was recorded without it)
        if let log, log.cursorHidden, let cursor = cursorImage,
           let p = settings.smoothCursor ? log.smoothedPosition(at: t, window: 0.12) : log.position(at: t) {
            let scale = CGFloat(settings.cursorScale) * (sourceSize.width / 1440).clamped(0.8, 2.5)
            let px = p.x * sourceSize.width, py = (1 - p.y) * sourceSize.height
            if settings.clickEffects, let ring = clickRing(at: t, scale: scale) {
                frame = ring.composited(over: frame)
            }
            let placed = cursor
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: px - cursorHotspot.x * scale,
                                                   y: py - cursorHotspot.y * scale))
            frame = placed.composited(over: frame).cropped(to: CGRect(origin: .zero, size: sourceSize))
        }

        // 2. Smart zoom (with motion blur while the camera moves)
        let cam = camera(at: t)
        if cam.zoom > 1.001 {
            let r = cropRect(zoom: cam.zoom, focus: cam.focus)
            frame = frame
                .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                .transformed(by: CGAffineTransform(scaleX: cam.zoom, y: cam.zoom))
                .cropped(to: CGRect(origin: .zero, size: sourceSize))
            if settings.motionBlur > 0.01 {
                let next = camera(at: t + 1.0 / 30)
                let r2 = cropRect(zoom: next.zoom, focus: next.focus)
                let dx = (r2.midX - r.midX) * cam.zoom, dy = (r2.midY - r.midY) * cam.zoom
                let dz = abs(next.zoom - cam.zoom) * sourceSize.width * 0.5
                let speed = hypot(dx, dy) + dz
                if speed > 1.5 {
                    let radius = min(speed * CGFloat(settings.motionBlur) * 0.5, 24)
                    frame = frame.clampedToExtent()
                        .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: radius,
                                                                     kCIInputAngleKey: atan2(dy, dx)])
                        .cropped(to: CGRect(origin: .zero, size: sourceSize))
                }
            }
        }

        // 3. Place on the background
        guard let backdrop, let mask else { return frame }
        let k = contentRect.width / sourceSize.width
        let placed = frame
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: contentRect.minX, y: contentRect.minY))
        return placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: backdrop,
            kCIInputMaskImageKey: mask
        ]).cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Expanding ring for clicks in the last 0.45 s.
    private func clickRing(at t: Double, scale: CGFloat) -> CIImage? {
        guard let clicks = log?.clicks else { return nil }
        var result: CIImage?
        for c in clicks where t >= c[0] && t - c[0] < 0.45 {
            let k = CGFloat((t - c[0]) / 0.45)
            let radius = (14 + 26 * k) * scale
            let alpha = 0.6 * (1 - k)
            let center = CIVector(x: c[1] * sourceSize.width, y: (1 - c[2]) * sourceSize.height)
            let ring = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": radius * 0.82,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 0.8, blue: 0, alpha: alpha),
                "inputColor1": CIColor(red: 1, green: 0.8, blue: 0, alpha: 0)
            ])?.outputImage?.cropped(to: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            if let ring { result = result.map { ring.composited(over: $0) } ?? ring }
        }
        return result
    }

    // MARK: - Composition

    func makeComposition(for asset: AVAsset) async throws -> AVVideoComposition {
        let composer = self
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let t = request.compositionTime.seconds
            let out = composer.render(request.sourceImage, at: t)
            request.finish(with: out, context: nil)
        }
        comp.renderSize = outputSize
        return comp
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}
