import AppKit
import CoreGraphics

enum AnnotationKind: String, Codable {
    case arrow, rectangle, ellipse, line, pencil, text, pixelate, blur, number, callout
    case highlighter, spotlight, image, magnifier
}

enum AnnotationTool: String, CaseIterable {
    case select, crop, arrow, rectangle, ellipse, line, pencil, highlighter, text, number, callout, spotlight, magnifier, pixelate, blur

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .crop: return "crop"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "square"
        case .ellipse: return "circle"
        case .magnifier: return "plus.magnifyingglass"
        case .line: return "line.diagonal"
        case .pencil: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop"
        case .number: return "number.circle"
        case .callout: return "text.bubble"
        case .spotlight: return "flashlight.on.fill"
        }
    }

    var title: String {
        switch self {
        case .number: return "Counter"
        case .rectangle: return "Shape"
        default: return rawValue.capitalized
        }
    }

    /// Single-key shortcut.
    var key: String {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return ""
        case .magnifier: return "m"
        case .line: return "l"
        case .pencil: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .pixelate: return "x"
        case .blur: return "b"
        case .number: return "n"
        case .callout: return ""
        case .spotlight: return "s"
        }
    }

    var objectKind: AnnotationKind? {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .pencil: return .pencil
        case .highlighter: return .highlighter
        case .text: return .text
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .number: return .number
        case .callout: return .callout
        case .spotlight: return .spotlight
        case .magnifier: return .magnifier
        case .select, .crop: return nil
        }
    }
}

struct AnnotationStyle: Codable, Equatable {
    var colorHex: String = "#FF3B30"
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = 28
    var arrowStyle: Int = 0     // 0 tapered, 1 open, 2 classic filled, 3 double-ended, 4 curved
    var textStyle: Int = 0      // 0 plain, 1 bold, 2 outlined, 3 highlight, 4 boxed, 5 dark pill, 6 handwritten
    var filled: Bool = false    // derived from shapeStyle (kept for older project files)
    var shapeStyle: Int = 0 { didSet { filled = shapeStyle >= 2 } }   // 0 rounded outline, 1 sharp outline, 2 tinted, 3 solid
    var ellipse: Bool = false   // Shape tool: ellipse instead of rectangle
    var magnify: CGFloat = 2.5  // magnifier zoom
    var magRound: Bool = true   // magnifier: round loupe (true) or rounded box
    var smartShapes: Bool = true  // pen: turn clean strokes into shapes
    var bubble: Bool = true     // text tool: speech-bubble box (true) or plain text (false)
    var effectMode: Int = 0     // blur: 0 smooth, 1 secure.  spotlight: 0 rectangle, 1 ellipse

    var color: NSColor { NSColor(hex: colorHex) ?? .systemRed }

    static let arrowStyleNames = ["Tapered", "Open", "Classic", "Double", "Curved"]
    static let textStyleNames = ["Plain", "Bold", "Outlined", "Highlight", "Boxed", "Dark pill", "Handwritten"]
    static let blurModeNames = ["Smooth", "Secure"]
    static let spotlightShapeNames = ["Rectangle", "Ellipse"]

    init() {}

    enum CodingKeys: String, CodingKey {
        case colorHex, lineWidth, fontSize, arrowStyle, textStyle, filled, effectMode, bubble, shapeStyle, ellipse, magnify, smartShapes, magRound
    }

    // Tolerant decoding: files from older versions miss newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FF3B30"
        lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 4
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 28
        arrowStyle = try c.decodeIfPresent(Int.self, forKey: .arrowStyle) ?? 0
        textStyle = try c.decodeIfPresent(Int.self, forKey: .textStyle) ?? 0
        filled = try c.decodeIfPresent(Bool.self, forKey: .filled) ?? false
        effectMode = try c.decodeIfPresent(Int.self, forKey: .effectMode) ?? 0
        bubble = try c.decodeIfPresent(Bool.self, forKey: .bubble) ?? true
        shapeStyle = try c.decodeIfPresent(Int.self, forKey: .shapeStyle) ?? (filled ? 3 : 0)
        ellipse = try c.decodeIfPresent(Bool.self, forKey: .ellipse) ?? false
        magnify = try c.decodeIfPresent(CGFloat.self, forKey: .magnify) ?? 2.5
        smartShapes = try c.decodeIfPresent(Bool.self, forKey: .smartShapes) ?? true
        magRound = try c.decodeIfPresent(Bool.self, forKey: .magRound) ?? true
    }
}

struct AnnotationObject: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    var start: CGPoint = .zero         // image pixel space, top-left origin
    var end: CGPoint = .zero
    var points: [CGPoint] = []         // pencil / highlighter path; curved arrow: [control point]
    var text: String = ""
    var style = AnnotationStyle()
    var z: Int = 0
    var rotation: CGFloat = 0          // degrees, about the object's centre
    var thickness: CGFloat = 0         // highlighter stroke width (0 = derived from style)
    var imageData: Data? = nil         // PNG for combined images

    init(kind: AnnotationKind, start: CGPoint = .zero, end: CGPoint = .zero, points: [CGPoint] = [],
         text: String = "", style: AnnotationStyle = AnnotationStyle(), z: Int = 0) {
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        self.text = text
        self.style = style
        self.z = z
    }

    var isFreehand: Bool { kind == .pencil || kind == .highlighter }
    /// An arrow is curved once its middle handle has been moved (or when it came from the old Curved style).
    var isCurvedArrow: Bool { kind == .arrow && (!points.isEmpty || style.arrowStyle == 4) }

    // Magnifier: start/end are corners of the area being enlarged (any width and height), `points[0]` is the
    // centre of the loupe (a default spot beside the area until it is moved). The loupe is the area scaled by `magnify`.
    var magSourceRect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: max(abs(end.x - start.x), 8), height: max(abs(end.y - start.y), 8))
    }
    var magLoupeSize: CGSize {
        let r = magSourceRect, z = max(style.magnify, 1.2)
        return CGSize(width: r.width * z, height: r.height * z)
    }
    var magLoupeCenter: CGPoint {
        if let c = points.first { return c }
        let s = magSourceRect, l = magLoupeSize
        return CGPoint(x: s.midX + s.width / 2 + l.width / 2 + 16,
                       y: s.midY - (s.height / 2 + l.height / 2 + 16) * 0.35)
    }
    var magLoupeRect: CGRect {
        let l = magLoupeSize, c = magLoupeCenter
        return CGRect(x: c.x - l.width / 2, y: c.y - l.height / 2, width: l.width, height: l.height)
    }

    /// Whether a point lies on the loupe itself.
    func magLoupeContains(_ p: CGPoint, slack: CGFloat) -> Bool {
        let l = magLoupeRect.insetBy(dx: -slack, dy: -slack)
        guard style.magRound else { return l.contains(p) }
        let lx = (p.x - l.midX) / max(l.width / 2, 1), ly = (p.y - l.midY) / max(l.height / 2, 1)
        return hypot(lx, ly) <= 1
    }

    /// The rectangle whose corner and edge handles resize the object.
    var editRect: CGRect { kind == .magnifier ? magSourceRect : rect }

    /// Rect-like kinds can be resized from their corners.
    var isBoxShaped: Bool {
        switch kind {
        case .rectangle, .ellipse, .pixelate, .blur, .spotlight, .image: return true
        default: return false
        }
    }

    var highlighterWidth: CGFloat { thickness > 0 ? thickness : max(style.lineWidth * 4, 12) }

    /// Middle handle of an arrow: where it was dragged to, the middle of the line, or (old Curved style) a default bend.
    var curveControl: CGPoint {
        if let c = points.first { return c }
        if style.arrowStyle != 4 { return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
        let mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2
        let dx = end.x - start.x, dy = end.y - start.y
        let len = max(hypot(dx, dy), 1)
        let bend = len * 0.25
        return CGPoint(x: mx + (dy / len) * bend, y: my - (dx / len) * bend)
    }

    /// Normalised rect spanned by start/end (or by points for freehand).
    var rect: CGRect {
        if isFreehand, let first = points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if kind == .text || kind == .callout {
            let size = AnnotationRenderer.textSize(for: self)
            return CGRect(origin: start, size: size)
        }
        if kind == .magnifier {
            return magSourceRect.union(magLoupeRect)
        }
        if kind == .number {
            let d = AnnotationRenderer.numberDiameter(for: style)
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        }
        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                       width: abs(end.x - start.x), height: abs(end.y - start.y))
        if isCurvedArrow {
            let c = curveControl
            return r.union(CGRect(x: c.x, y: c.y, width: 0, height: 0))
        }
        return r
    }

    mutating func translate(by d: CGVector) {
        start = CGPoint(x: start.x + d.dx, y: start.y + d.dy)
        end = CGPoint(x: end.x + d.dx, y: end.y + d.dy)
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    /// Kinds that can be rotated with the angle slider.
    var supportsRotation: Bool {
        switch kind {
        case .pixelate, .blur, .number, .callout, .spotlight, .magnifier: return false
        default: return true
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        var p = point
        if rotation != 0, supportsRotation {
            // Undo the rotation about the centre so the test runs in the object's own frame.
            let r = rect
            let c = CGPoint(x: r.midX, y: r.midY)
            let a = -rotation * .pi / 180
            let dx = p.x - c.x, dy = p.y - c.y
            p = CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
        }
        switch kind {
        case .line:
            return Self.distance(from: p, toSegment: start, end) <= tolerance + style.lineWidth / 2
        case .arrow:
            if isCurvedArrow {
                let c = curveControl
                var prev = start
                for i in 1...24 {
                    let t = CGFloat(i) / 24
                    let q = Self.quadPoint(start, c, end, t)
                    if Self.distance(from: p, toSegment: prev, q) <= tolerance + style.lineWidth / 2 { return true }
                    prev = q
                }
                return false
            }
            return Self.distance(from: p, toSegment: start, end) <= tolerance + style.lineWidth / 2
        case .pencil, .highlighter:
            let width = kind == .highlighter ? highlighterWidth : style.lineWidth
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= tolerance + width / 2 }
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Self.distance(from: p, toSegment: points[i - 1], points[i]) <= tolerance + width / 2 {
                return true
            }
            return false
        case .rectangle, .ellipse:
            let r = rect
            if style.filled { return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .spotlight:
            // Only the outline selects, so clicks inside the bright area reach what's underneath.
            let r = rect
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .text, .pixelate, .blur, .number, .image:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .callout:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
                || hypot(p.x - end.x, p.y - end.y) <= tolerance * 1.5
        case .magnifier:
            // Anywhere on the loupe, or on the outline around the enlarged area.
            if magLoupeContains(p, slack: tolerance) { return true }
            let s = magSourceRect
            let t = tolerance + style.lineWidth / 2
            if style.magRound {
                let sx = (p.x - s.midX) / max(s.width / 2, 1), sy = (p.y - s.midY) / max(s.height / 2, 1)
                return abs(hypot(sx, sy) - 1) * min(s.width, s.height) / 2 <= t
            }
            let outer = s.insetBy(dx: -t, dy: -t), inner = s.insetBy(dx: t, dy: t)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        }
    }

    static func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        if lengthSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Ramer-Douglas-Peucker simplification, used to smooth freehand strokes.
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxDist: CGFloat = 0
        var index = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(from: pts[i], toSegment: pts[0], pts[pts.count - 1])
            if d > maxDist { maxDist = d; index = i }
        }
        if maxDist > epsilon {
            let left = simplify(Array(pts[0...index]), epsilon: epsilon)
            let right = simplify(Array(pts[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [pts[0], pts[pts.count - 1]]
    }
}

extension AnnotationObject {
    enum CodingKeys: String, CodingKey {
        case id, kind, start, end, points, text, style, z, rotation, thickness, imageData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(AnnotationKind.self, forKey: .kind)
        start = try c.decodeIfPresent(CGPoint.self, forKey: .start) ?? .zero
        end = try c.decodeIfPresent(CGPoint.self, forKey: .end) ?? .zero
        points = try c.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        style = try c.decodeIfPresent(AnnotationStyle.self, forKey: .style) ?? AnnotationStyle()
        z = try c.decodeIfPresent(Int.self, forKey: .z) ?? 0
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        thickness = try c.decodeIfPresent(CGFloat.self, forKey: .thickness) ?? 0
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }
}

/// Versioned, human-readable project file (`.snapper`).
struct SnapperProject: Codable {
    static let currentVersion = 2

    var version: Int = SnapperProject.currentVersion
    var imagePNG: Data
    var objects: [AnnotationObject]
    var cropRect: CGRect?
    var background: String? = nil              // v1: preset name (still read)
    var backgroundSettings: BackgroundSettings? = nil

    init(imagePNG: Data, objects: [AnnotationObject], cropRect: CGRect?, backgroundSettings: BackgroundSettings?) {
        self.imagePNG = imagePNG
        self.objects = objects
        self.cropRect = cropRect
        self.backgroundSettings = backgroundSettings
    }

    enum CodingKeys: String, CodingKey {
        case version, imagePNG, objects, cropRect, background, backgroundSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        imagePNG = try c.decode(Data.self, forKey: .imagePNG)
        objects = try c.decodeIfPresent([AnnotationObject].self, forKey: .objects) ?? []
        cropRect = try c.decodeIfPresent(CGRect.self, forKey: .cropRect)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        backgroundSettings = try c.decodeIfPresent(BackgroundSettings.self, forKey: .backgroundSettings)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SnapperProject {
        let project = try JSONDecoder().decode(SnapperProject.self, from: data)
        guard project.version <= currentVersion else {
            throw NSError(domain: "Snapper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This project was made by a newer version of Snapper."])
        }
        return project
    }

    /// Background to use when opening: v2 settings, else the v1 preset name.
    var resolvedBackground: BackgroundSettings {
        if let s = backgroundSettings { return s }
        var s = BackgroundSettings.off
        if let name = background, let i = BackgroundCatalog.builtIn.firstIndex(where: { $0.name == name }) {
            s.fill = .builtIn(i)
        }
        return s
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}
