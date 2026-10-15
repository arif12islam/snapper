import AppKit
import CoreImage
import CoreGraphics

/// Draws annotation objects. All drawing happens in image-pixel space with a TOP-LEFT origin,
/// so the caller must hand in a context that is already flipped (an NSView with isFlipped = true,
/// or an export context that was translated/scaled to match) and set as NSGraphicsContext.current.
enum AnnotationRenderer {
    private static var regionCache: [String: CGImage] = [:]
    private static let ciContext = CIContext()

    // MARK: - Public

    static func render(into ctx: CGContext, base: CGImage, objects: [AnnotationObject],
                       imageSize: CGSize, skipID: UUID? = nil, drawBase: Bool = true) {
        if drawBase { drawImage(ctx, base, in: CGRect(origin: .zero, size: imageSize)) }
        let sorted = objects.sorted(by: { $0.z < $1.z }).filter { $0.id != skipID }
        let spotlights = sorted.filter { $0.kind == .spotlight }
        var dimmed = false
        for object in sorted {
            if object.kind == .spotlight {
                // All spotlights share one dim layer, drawn at the first spotlight's depth.
                if !dimmed { drawSpotlights(spotlights, in: ctx, imageSize: imageSize); dimmed = true }
                continue
            }
            draw(object, in: ctx, base: base)
        }
    }

    private static func drawSpotlights(_ lights: [AnnotationObject], in ctx: CGContext, imageSize: CGSize) {
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: imageSize))
        for light in lights {
            let r = light.rect
            guard r.width > 1, r.height > 1 else { continue }
            if light.style.effectMode == 1 {
                path.addEllipse(in: r)
            } else {
                let radius = min(12, min(r.width, r.height) / 4)
                path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
            }
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: - Embedded images (combine screenshots)

    private static var embeddedCache: [UUID: CGImage] = [:]

    /// Stores an already-decoded picture so the first draw doesn't decode the PNG again.
    static func prime(_ id: UUID, image: CGImage) {
        if embeddedCache.count > 40 { embeddedCache.removeAll() }
        embeddedCache[id] = image
    }

    static func embeddedImage(for object: AnnotationObject) -> CGImage? {
        if let c = embeddedCache[object.id] { return c }
        guard let data = object.imageData, let rep = NSBitmapImageRep(data: data), let img = rep.cgImage else { return nil }
        if embeddedCache.count > 40 { embeddedCache.removeAll() }
        embeddedCache[object.id] = img
        return img
    }

    // MARK: - Smoothed freehand path

    /// Quadratic curves through the midpoints of successive points: removes jitter without lag.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let p = pts[i], n = pts[i + 1]
            path.addQuadCurve(to: CGPoint(x: (p.x + n.x) / 2, y: (p.y + n.y) / 2), control: p)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Renders the final bitmap (crop applied) for export.
    static func exportImage(base: CGImage, objects: [AnnotationObject], cropRect: CGRect?) -> CGImage? {
        let width = base.width, height = base.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Make (0,0) the top-left corner.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(into: ctx, base: base, objects: objects, imageSize: CGSize(width: width, height: height))
        NSGraphicsContext.current = previous

        guard let full = ctx.makeImage() else { return nil }
        if let crop = cropRect {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let c = crop.integral.intersection(bounds)
            if !c.isNull, c.width >= 2, c.height >= 2, let cropped = full.cropping(to: c) {
                return cropped
            }
        }
        return full
    }

    static func clearCache() { regionCache.removeAll(); embeddedCache.removeAll() }

    // MARK: - Numbers

    static func numberDiameter(for style: AnnotationStyle) -> CGFloat {
        max(style.fontSize * 1.35, 24)
    }

    private static func drawNumber(_ object: AnnotationObject, in ctx: CGContext) {
        let r = object.rect
        ctx.setFillColor(object.style.color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(max(2, r.width * 0.07))
        ctx.strokeEllipse(in: r.insetBy(dx: r.width * 0.035, dy: r.width * 0.035))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r.width * 0.55, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: object.text, attributes: attrs)
        let s = str.size()
        str.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
    }

    // MARK: - Callouts (text box with a pointer to a target)

    private static let calloutPadding = CGSize(width: 12, height: 8)

    private static func drawCallout(_ object: AnnotationObject, in ctx: CGContext) {
        let box = object.rect
        let tip = object.end
        let color = object.style.color
        let radius = min(10, box.height / 2)

        // One path for bubble and pointer, so there is no seam where they meet.
        let shape = CGMutablePath()
        shape.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)

        var pointer: CGPath?
        if !box.insetBy(dx: -2, dy: -2).contains(tip) {
            // The pointer leaves the side that faces the target, level with the target where the side is long
            // enough (so it never starts at a corner), and is a slim wedge ending in a rounded tip.
            let dx = tip.x - box.midX, dy = tip.y - box.midY
            let horizontal = abs(dx) / max(box.width, 1) > abs(dy) / max(box.height, 1)
            let half = min(max(box.height * 0.2, 5), 9)
            let a: CGPoint, b: CGPoint
            if horizontal {
                let x = dx > 0 ? box.maxX : box.minX
                let inward: CGFloat = dx > 0 ? -1 : 1
                let lo = box.minY + radius + half, hi = box.maxY - radius - half
                let y = lo <= hi ? min(max(tip.y, lo), hi) : box.midY
                a = CGPoint(x: x + inward, y: y - half)
                b = CGPoint(x: x + inward, y: y + half)
            } else {
                let y = dy > 0 ? box.maxY : box.minY
                let inward: CGFloat = dy > 0 ? -1 : 1
                let lo = box.minX + radius + half, hi = box.maxX - radius - half
                let x = lo <= hi ? min(max(tip.x, lo), hi) : box.midX
                a = CGPoint(x: x - half, y: y + inward)
                b = CGPoint(x: x + half, y: y + inward)
            }
            let p = CGMutablePath()
            p.move(to: a)
            p.addLine(to: tip)
            p.addLine(to: b)
            p.closeSubpath()
            shape.addPath(p)
            pointer = p
        }

        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(shape)
        ctx.fillPath()
        if let pointer {
            // A thin round-joined stroke softens the tip.
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round)
            ctx.addPath(pointer)
            ctx.strokePath()
        }
        ctx.restoreGState()

        if !object.text.isEmpty {
            let str = NSAttributedString(string: object.text, attributes: textAttributes(for: object))
            let size = str.size()
            str.draw(at: CGPoint(x: box.minX + calloutPadding.width, y: box.midY - size.height / 2))
        }
    }

    // MARK: - Text

    private static func textPadding(for style: AnnotationStyle) -> CGSize {
        switch style.textStyle {
        case 4, 5: return CGSize(width: 12, height: 8)
        default: return .zero
        }
    }

    static func textAttributes(for object: AnnotationObject) -> [NSAttributedString.Key: Any] {
        let s = object.style
        let size = s.fontSize
        if object.kind == .callout {
            return [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white]
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        switch s.textStyle {
        case 1:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .bold)
            attrs[.foregroundColor] = s.color
        case 2:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .heavy)
            attrs[.foregroundColor] = s.color
            attrs[.strokeColor] = NSColor.white
            attrs[.strokeWidth] = -4.0
        case 3:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
            attrs[.foregroundColor] = NSColor.black
            attrs[.backgroundColor] = s.color.withAlphaComponent(0.85)
        case 4:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
            attrs[.foregroundColor] = s.color
        case 5:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
            attrs[.foregroundColor] = NSColor.white
        case 6:
            attrs[.font] = NSFont(name: "Marker Felt Wide", size: size)
                ?? NSFont(name: "Marker Felt", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: .medium)
            attrs[.foregroundColor] = s.color
        default:
            attrs[.font] = NSFont.systemFont(ofSize: size, weight: .medium)
            attrs[.foregroundColor] = s.color
        }
        return attrs
    }

    static func textSize(for object: AnnotationObject) -> CGSize {
        let str = NSAttributedString(string: object.text.isEmpty ? " " : object.text,
                                     attributes: textAttributes(for: object))
        let s = str.size()
        let pad = object.kind == .callout ? calloutPadding : textPadding(for: object.style)
        return CGSize(width: ceil(s.width) + pad.width * 2, height: ceil(s.height) + pad.height * 2)
    }

    private static func drawText(_ object: AnnotationObject) {
        let attrs = textAttributes(for: object)
        let str = NSAttributedString(string: object.text, attributes: attrs)
        let pad = textPadding(for: object.style)
        let size = textSize(for: object)
        let box = CGRect(origin: object.start, size: size)

        switch object.style.textStyle {
        case 4:
            NSColor.white.setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
            path.fill()
            object.style.color.setStroke()
            path.lineWidth = 3
            path.stroke()
        case 5:
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        default:
            break
        }
        str.draw(at: CGPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }

    // MARK: - Object drawing

    static func draw(_ object: AnnotationObject, in ctx: CGContext, base: CGImage) {
        let style = object.style
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.setStrokeColor(style.color.cgColor)
        ctx.setFillColor(style.color.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if object.rotation != 0, object.supportsRotation {
            let r = object.rect
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.rotate(by: object.rotation * .pi / 180)
            ctx.translateBy(x: -r.midX, y: -r.midY)
        }

        switch object.kind {
        case .line:
            ctx.move(to: object.start)
            ctx.addLine(to: object.end)
            ctx.strokePath()

        case .arrow:
            if object.isCurvedArrow {
                drawCurvedArrow(ctx, from: object.start, control: object.curveControl, to: object.end, style: style)
            } else {
                drawArrow(ctx, from: object.start, to: object.end, style: style)
            }

        case .rectangle:
            let r = object.rect
            if style.filled { ctx.fill(r) } else { ctx.stroke(r) }

        case .ellipse:
            let r = object.rect
            if style.filled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r) }

        case .pencil:
            guard let first = object.points.first else { return }
            if object.points.count == 1 {
                ctx.fillEllipse(in: CGRect(x: first.x - style.lineWidth / 2, y: first.y - style.lineWidth / 2,
                                           width: style.lineWidth, height: style.lineWidth))
                return
            }
            ctx.addPath(smoothPath(object.points))
            ctx.strokePath()

        case .highlighter:
            guard let first = object.points.first else { return }
            let width = object.highlighterWidth
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(style.color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.butt)
            if object.points.count == 1 {
                ctx.setFillColor(style.color.withAlphaComponent(0.45).cgColor)
                ctx.fill(CGRect(x: first.x - width / 4, y: first.y - width / 2, width: width / 2, height: width))
                return
            }
            ctx.addPath(smoothPath(object.points))
            ctx.strokePath()

        case .spotlight:
            break   // drawn together in render()

        case .image:
            if let img = embeddedImage(for: object) {
                let r = object.rect
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(r)
                ctx.restoreGState()
                ctx.interpolationQuality = .high
                drawImage(ctx, img, in: r)
            }

        case .text:
            guard !object.text.isEmpty else { return }
            drawText(object)

        case .pixelate:
            if let img = pixelated(base: base, object: object) {
                ctx.interpolationQuality = .none
                drawImage(ctx, img, in: object.rect.integral)
            }

        case .blur:
            if let img = blurred(base: base, object: object) {
                drawImage(ctx, img, in: object.rect.integral)
            }

        case .number:
            drawNumber(object, in: ctx)

        case .callout:
            drawCallout(object, in: ctx)
        }
    }

    private static func drawCurvedArrow(_ ctx: CGContext, from tail: CGPoint, control: CGPoint, to tip: CGPoint,
                                        style: AnnotationStyle) {
        let length = hypot(tip.x - tail.x, tip.y - tail.y)
        guard length > 2 else { return }
        // Head points along the curve's tangent at the tip.
        let tx = tip.x - control.x, ty = tip.y - control.y
        let tl = max(hypot(tx, ty), 0.001)
        let dir = CGPoint(x: tx / tl, y: ty / tl)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let headLength = min(max(14, style.lineWidth * 4.5), length * 0.6)
        let headHalf = headLength * 0.5
        let base = CGPoint(x: tip.x - dir.x * headLength * 0.85, y: tip.y - dir.y * headLength * 0.85)

        ctx.move(to: tail)
        ctx.addQuadCurve(to: base, control: control)
        ctx.strokePath()
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - dir.x * headLength + perp.x * headHalf, y: tip.y - dir.y * headLength + perp.y * headHalf))
        ctx.addLine(to: CGPoint(x: tip.x - dir.x * headLength - perp.x * headHalf, y: tip.y - dir.y * headLength - perp.y * headHalf))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawArrow(_ ctx: CGContext, from tail: CGPoint, to tip: CGPoint, style: AnnotationStyle) {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 2 else { return }
        let dir = CGPoint(x: dx / length, y: dy / length)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let w = style.lineWidth
        let headLength = min(max(14, w * 4.5), length * 0.8)
        let headHalf = headLength * 0.5

        func point(_ base: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: base.x + dir.x * along + perp.x * across,
                    y: base.y + dir.y * along + perp.y * across)
        }
        func filledHead(at tipPoint: CGPoint, pointing sign: CGFloat) {
            let backAlong = -headLength * sign
            ctx.move(to: tipPoint)
            ctx.addLine(to: point(tipPoint, backAlong, headHalf))
            ctx.addLine(to: point(tipPoint, backAlong, -headHalf))
            ctx.closePath()
            ctx.fillPath()
        }

        switch style.arrowStyle {
        case 1: // open chevron head
            ctx.move(to: tail)
            ctx.addLine(to: tip)
            ctx.move(to: point(tip, -headLength, headHalf))
            ctx.addLine(to: tip)
            ctx.addLine(to: point(tip, -headLength, -headHalf))
            ctx.strokePath()

        case 2: // classic: uniform line with a filled head
            let base = point(tip, -headLength * 0.9, 0)
            ctx.move(to: tail)
            ctx.addLine(to: base)
            ctx.strokePath()
            filledHead(at: tip, pointing: 1)

        case 3: // double-ended
            let startBase = point(tail, headLength * 0.9, 0)
            let endBase = point(tip, -headLength * 0.9, 0)
            ctx.move(to: startBase)
            ctx.addLine(to: endBase)
            ctx.strokePath()
            filledHead(at: tip, pointing: 1)
            filledHead(at: tail, pointing: -1)

        default: // tapered: slim tail growing into a broad triangular head
            let tHead = min(max(20, w * 6), length * 0.7)
            let tHalf = tHead * 0.62
            let base = point(tip, -tHead, 0)
            let bodyHalf = max(1.5, w * 0.9)
            ctx.move(to: point(tail, 0, w * 0.15))
            ctx.addLine(to: point(base, 0, bodyHalf))
            ctx.addLine(to: point(base, 0, tHalf))
            ctx.addLine(to: tip)
            ctx.addLine(to: point(base, 0, -tHalf))
            ctx.addLine(to: point(base, 0, -bodyHalf))
            ctx.addLine(to: point(tail, 0, -w * 0.15))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: - Image helpers

    /// Draws a CGImage upright inside a flipped (top-left origin) context.
    static func drawImage(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func cropRegion(base: CGImage, rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 2, r.height >= 2 else { return nil }
        return base.cropping(to: r)
    }

    private static func cacheKey(_ tag: String, _ object: AnnotationObject) -> String {
        let r = object.rect.integral
        return "\(tag)-\(object.id.uuidString)-\(Int(r.minX))-\(Int(r.minY))-\(Int(r.width))-\(Int(r.height))"
    }

    private static func store(_ key: String, _ image: CGImage) {
        if regionCache.count > 60 { regionCache.removeAll() }
        regionCache[key] = image
    }

    // MARK: - Pixelate (randomised so it cannot be trivially reversed)

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static func pixelated(base: CGImage, object: AnnotationObject) -> CGImage? {
        let key = cacheKey("pix", object)
        if let cached = regionCache[key] { return cached }
        guard let region = cropRegion(base: base, rect: object.rect) else { return nil }
        let w = region.width, h = region.height

        guard let src = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let srcData = src.data else { return nil }
        src.draw(region, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = srcData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        guard let dst = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dstData = dst.data else { return nil }
        let out = dstData.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let block = max(6, Int(sqrt(Double(w * h)) / 16))
        var seed: UInt64 = 0
        for byte in withUnsafeBytes(of: object.id.uuid, { Array($0) }) { seed = seed &* 131 &+ UInt64(byte) }
        var rng = SeededGenerator(state: seed)

        var by = 0
        while by < h {
            var bx = 0
            let bh = min(block, h - by)
            while bx < w {
                let bw = min(block, w - bx)
                // Sample a random pixel inside the block rather than averaging.
                let sx = bx + Int.random(in: 0..<bw, using: &rng)
                let sy = by + Int.random(in: 0..<bh, using: &rng)
                let si = (sy * w + sx) * 4
                let r = pixels[si], g = pixels[si + 1], b = pixels[si + 2], a = pixels[si + 3]
                for y in by..<(by + bh) {
                    for x in bx..<(bx + bw) {
                        let di = (y * w + x) * 4
                        out[di] = r; out[di + 1] = g; out[di + 2] = b; out[di + 3] = a
                    }
                }
                bx += block
            }
            by += block
        }
        guard let image = dst.makeImage() else { return nil }
        store(key, image)
        return image
    }

    // MARK: - Blur

    private static func blurred(base: CGImage, object: AnnotationObject) -> CGImage? {
        let secure = object.style.effectMode == 1
        let key = cacheKey(secure ? "sblur" : "blur", object)
        if let cached = regionCache[key] { return cached }
        // Secure: blur a randomised pixelation, so no original pixels survive to be "unblurred".
        let source = secure ? pixelated(base: base, object: object) : cropRegion(base: base, rect: object.rect)
        guard let region = source else { return nil }
        let input = CIImage(cgImage: region)
        let radius = max(8.0, Double(min(region.width, region.height)) / (secure ? 5.0 : 8.0))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = ciContext.createCGImage(output, from: input.extent) else { return nil }
        store(key, image)
        return image
    }
}
