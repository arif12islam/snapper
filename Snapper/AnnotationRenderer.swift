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

    /// The area the export covers when annotations reach beyond the picture (image space, top-left origin).
    static func canvasRect(imageSize: CGSize, objects: [AnnotationObject]) -> CGRect {
        let image = CGRect(origin: .zero, size: imageSize)
        var r = image
        for o in objects where o.kind != .spotlight {
            let box = o.rect
            if image.contains(box) { continue }
            let pad = o.style.lineWidth + (o.kind == .magnifier ? 14 : 2)
            r = r.union(box.insetBy(dx: -pad, dy: -pad))
        }
        return r.integral
    }

    /// Renders the final bitmap (crop applied) for export. Without a crop the picture grows to include any
    /// annotation drawn outside it (transparent where there is no picture).
    static func exportImage(base: CGImage, objects: [AnnotationObject], cropRect: CGRect?, expand: Bool = true) -> CGImage? {
        let width = base.width, height = base.height
        let imageSize = CGSize(width: width, height: height)
        let canvas = (expand && cropRect == nil) ? canvasRect(imageSize: imageSize, objects: objects)
                                                 : CGRect(origin: .zero, size: imageSize)
        let cw = max(Int(canvas.width), 1), ch = max(Int(canvas.height), 1)
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        // Make the canvas's top-left corner the origin of image space.
        ctx.translateBy(x: -canvas.minX, y: CGFloat(ch) + canvas.minY)
        ctx.scaleBy(x: 1, y: -1)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        render(into: ctx, base: base, objects: objects, imageSize: imageSize)
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
            drawShape(object.rect, ellipse: false, style: style, in: ctx)

        case .ellipse:
            drawShape(object.rect, ellipse: true, style: style, in: ctx)

        case .magnifier:
            drawMagnifier(object, in: ctx, base: base)

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

    // MARK: - Shapes (rectangle / ellipse)

    /// Shape styles: 0 rounded outline, 1 sharp outline, 2 tinted (outline plus a light fill), 3 solid.
    private static func drawShape(_ r: CGRect, ellipse: Bool, style: AnnotationStyle, in ctx: CGContext) {
        guard r.width > 0, r.height > 0 else { return }
        let path = CGMutablePath()
        if ellipse {
            path.addEllipse(in: r)
        } else if style.shapeStyle == 1 {
            path.addRect(r)
        } else {
            let radius = min(max(style.lineWidth * 2.5 + 4, 8), min(r.width, r.height) / 2)
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        }
        switch style.shapeStyle {
        case 3:
            ctx.addPath(path)
            ctx.fillPath()
        case 2:
            ctx.addPath(path)
            ctx.setFillColor(style.color.withAlphaComponent(0.2).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.strokePath()
        default:
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    // MARK: - Magnifier

    private static func magPath(_ r: CGRect, round: Bool) -> CGPath {
        if round { return CGPath(ellipseIn: r, transform: nil) }
        let k = min(r.width, r.height) * 0.18
        return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
    }

    private static func drawMagnifier(_ object: AnnotationObject, in ctx: CGContext, base: CGImage) {
        let S = object.magSourceRect, Lr = object.magLoupeRect
        let round = object.style.magRound
        let c = CGPoint(x: S.midX, y: S.midY), L = CGPoint(x: Lr.midX, y: Lr.midY)
        let color = object.style.color
        let lw = max(2, object.style.lineWidth * 0.7)
        let dx = L.x - c.x, dy = L.y - c.y
        let dist = max(hypot(dx, dy), 0.001)
        let dir = CGPoint(x: dx / dist, y: dy / dist)

        // Distance from a shape's centre to its edge along `d`.
        func reach(_ r: CGRect, _ d: CGPoint) -> CGFloat {
            let a = max(r.width / 2, 1), b = max(r.height / 2, 1)
            if round { return 1 / sqrt((d.x / a) * (d.x / a) + (d.y / b) * (d.y / b)) }
            return min(a / max(abs(d.x), 0.000001), b / max(abs(d.y), 0.000001))
        }
        // Outline point whose tangent is parallel to the link, on the side given by `n`.
        func support(_ r: CGRect, _ n: CGPoint) -> CGPoint {
            let a = max(r.width / 2, 1), b = max(r.height / 2, 1)
            if round {
                let h = max(sqrt(a * a * n.x * n.x + b * b * n.y * n.y), 0.000001)
                return CGPoint(x: r.midX + a * a * n.x / h, y: r.midY + b * b * n.y / h)
            }
            let k = min(r.width, r.height) * 0.18 * 0.29
            let sx: CGFloat = n.x >= 0 ? 1 : -1, sy: CGFloat = n.y >= 0 ? 1 : -1
            return CGPoint(x: r.midX + sx * (a - k), y: r.midY + sy * (b - k))
        }

        // Two lines join the enlarged area to its loupe (only while they are apart).
        if dist > reach(S, dir) + reach(Lr, dir) + 2 {
            let n = CGPoint(x: -dir.y, y: dir.x)
            ctx.saveGState()
            ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(lw * 0.8)
            ctx.setLineCap(.round)
            for sign: CGFloat in [1, -1] {
                let nn = CGPoint(x: n.x * sign, y: n.y * sign)
                ctx.move(to: support(S, nn))
                ctx.addLine(to: support(Lr, nn))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Outline around the area being enlarged.
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.addPath(magPath(S, round: round))
        ctx.strokePath()

        // Loupe: shadow, the enlarged picture clipped to its shape, then the outline.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(magPath(Lr, round: round))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(magPath(Lr, round: round))
        ctx.clip()
        let z = max(object.style.magnify, 1.2)
        ctx.translateBy(x: L.x, y: L.y)
        ctx.scaleBy(x: z, y: z)
        ctx.translateBy(x: -c.x, y: -c.y)
        ctx.interpolationQuality = .high
        drawImage(ctx, base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        ctx.restoreGState()

        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.addPath(magPath(Lr, round: round))
        ctx.strokePath()
    }

    // MARK: - Arrows

    /// Point and tangent on the quadratic curve tail > control > tip.
    private static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> (p: CGPoint, d: CGPoint) {
        let u = 1 - t
        let p = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
        var d = CGPoint(x: 2 * u * (c.x - a.x) + 2 * t * (b.x - c.x), y: 2 * u * (c.y - a.y) + 2 * t * (b.y - c.y))
        let l = hypot(d.x, d.y)
        if l < 0.0001 { d = CGPoint(x: b.x - a.x, y: b.y - a.y) }
        let n = max(hypot(d.x, d.y), 0.0001)
        return (p, CGPoint(x: d.x / n, y: d.y / n))
    }

    /// Any arrow style, bent through the middle handle.
    private static func drawCurvedArrow(_ ctx: CGContext, from tail: CGPoint, control: CGPoint, to tip: CGPoint,
                                        style: AnnotationStyle) {
        let length = hypot(tip.x - tail.x, tip.y - tail.y)
        guard length > 2 else { return }
        let w = style.lineWidth
        let tipDir = quad(tail, control, tip, 1).d
        let tailDir = quad(tail, control, tip, 0).d       // pointing from the tail into the curve

        func perp(_ d: CGPoint) -> CGPoint { CGPoint(x: -d.y, y: d.x) }
        func at(_ p: CGPoint, _ d: CGPoint, _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            let n = perp(d)
            return CGPoint(x: p.x + d.x * along + n.x * across, y: p.y + d.y * along + n.y * across)
        }
        func head(at p: CGPoint, dir d: CGPoint, length hl: CGFloat) {
            ctx.move(to: p)
            ctx.addLine(to: at(p, d, -hl, hl * 0.5))
            ctx.addLine(to: at(p, d, -hl, -hl * 0.5))
            ctx.closePath()
            ctx.fillPath()
        }

        switch style.arrowStyle {
        case 0: // tapered
            let tHead = min(max(20, w * 6), length * 0.6)
            let tHalf = tHead * 0.62
            let baseTip = at(tip, tipDir, -tHead, 0)
            let bodyHalf = max(1.5, w * 0.9)
            let steps = 28
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let q = quad(tail, control, baseTip, t)
                let half = w * 0.15 + (bodyHalf - w * 0.15) * t
                left.append(at(q.p, q.d, 0, half))
                right.append(at(q.p, q.d, 0, -half))
            }
            ctx.move(to: left[0])
            for p in left.dropFirst() { ctx.addLine(to: p) }
            ctx.addLine(to: at(baseTip, tipDir, 0, tHalf))
            ctx.addLine(to: tip)
            ctx.addLine(to: at(baseTip, tipDir, 0, -tHalf))
            for p in right.reversed() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.fillPath()

        case 1: // open chevron
            let hl = min(max(14, w * 4.5), length * 0.6)
            ctx.move(to: tail)
            ctx.addQuadCurve(to: tip, control: control)
            ctx.move(to: at(tip, tipDir, -hl, hl * 0.5))
            ctx.addLine(to: tip)
            ctx.addLine(to: at(tip, tipDir, -hl, -hl * 0.5))
            ctx.strokePath()

        case 3: // double-ended
            let hl = min(max(14, w * 4.5), length * 0.4)
            let a = at(tail, tailDir, hl * 0.9, 0)
            let b = at(tip, tipDir, -hl * 0.9, 0)
            ctx.move(to: a)
            ctx.addQuadCurve(to: b, control: control)
            ctx.strokePath()
            head(at: tip, dir: tipDir, length: hl)
            head(at: tail, dir: CGPoint(x: -tailDir.x, y: -tailDir.y), length: hl)

        default: // classic and the old Curved style
            let hl = min(max(14, w * 4.5), length * 0.6)
            let base = at(tip, tipDir, -hl * 0.85, 0)
            ctx.move(to: tail)
            ctx.addQuadCurve(to: base, control: control)
            ctx.strokePath()
            head(at: tip, dir: tipDir, length: hl)
        }
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
