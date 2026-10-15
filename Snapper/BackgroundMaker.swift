import AppKit
import ImageIO
import CoreGraphics

// MARK: - Settings

/// Everything the Background tool can change. Stored in projects, presets and UserDefaults.
struct BackgroundSettings: Codable, Equatable {
    enum Fill: Codable, Equatable {
        case none
        case builtIn(Int)          // index into BackgroundCatalog.builtIn
        case color(String)         // hex
        case image(String)         // file name in BackgroundCatalog.customDirectory
        case wallpaper             // current desktop picture
    }

    enum Aspect: String, Codable, CaseIterable {
        case auto = "Auto", square = "1:1", fourThree = "4:3", threeTwo = "3:2",
             sixteenNine = "16:9", sixteenTen = "16:10", nineSixteen = "9:16", fourFive = "4:5"

        /// width / height, nil = follow the content.
        var ratio: CGFloat? {
            switch self {
            case .auto: return nil
            case .square: return 1
            case .fourThree: return 4.0 / 3.0
            case .threeTwo: return 3.0 / 2.0
            case .sixteenNine: return 16.0 / 9.0
            case .sixteenTen: return 16.0 / 10.0
            case .nineSixteen: return 9.0 / 16.0
            case .fourFive: return 4.0 / 5.0
            }
        }
    }

    var fill: Fill = .none
    var padding: CGFloat = 0.08        // fraction of the content's shorter side
    var cornerRadius: CGFloat = 12     // image pixels
    var shadow: CGFloat = 0.6          // 0...1
    var alignment: Int = 4             // 0...8, row-major 3x3 grid, 4 = centre
    var aspect: Aspect = .auto
    var autoBalance: Bool = false

    var isNone: Bool { fill == .none }

    static let off = BackgroundSettings()
    static let starter: BackgroundSettings = {
        var s = BackgroundSettings()
        s.fill = .builtIn(0)
        return s
    }()

    init() {}

    enum CodingKeys: String, CodingKey { case fill, padding, cornerRadius, shadow, alignment, aspect, autoBalance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = (try? c.decodeIfPresent(Fill.self, forKey: .fill)) ?? BackgroundSettings.Fill.none
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 0.08
        cornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 12
        shadow = try c.decodeIfPresent(CGFloat.self, forKey: .shadow) ?? 0.6
        alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? 4
        aspect = (try? c.decodeIfPresent(Aspect.self, forKey: .aspect)) ?? .auto
        autoBalance = try c.decodeIfPresent(Bool.self, forKey: .autoBalance) ?? false
    }

    // MARK: Persistence

    private static func load(_ key: String) -> BackgroundSettings? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BackgroundSettings.self, from: data)
    }

    private static func save(_ s: BackgroundSettings, key: String) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Last background used in the annotate editor.
    static var lastUsed: BackgroundSettings {
        get { load("annotateBackgroundSettings") ?? .off }
        set { save(newValue, key: "annotateBackgroundSettings") }
    }

    /// Background added to window captures ("Window capture: with background").
    static var windowCapture: BackgroundSettings {
        get {
            if let s = load("windowCaptureBackground") { return s }
            var s = BackgroundSettings()
            s.fill = .wallpaper
            s.padding = 0.06
            s.cornerRadius = 0          // the window keeps its own rounded corners
            return s
        }
        set { save(newValue, key: "windowCaptureBackground") }
    }
}

/// Named, saved backgrounds ("Save and reuse presets").
struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: BackgroundSettings

    static var all: [BackgroundPreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "backgroundPresets"),
                  let list = try? JSONDecoder().decode([BackgroundPreset].self, from: data) else { return [] }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "backgroundPresets") }
        }
    }
}

// MARK: - Catalog

enum BackgroundCatalog {
    struct Item {
        let name: String
        let colors: [String]   // 1 colour = solid, 2+ = diagonal gradient
    }

    /// 20 built-in backgrounds: 14 gradients and 6 solid colours.
    static let builtIn: [Item] = [
        Item(name: "Ocean", colors: ["#2193B0", "#6DD5ED"]),
        Item(name: "Sunset", colors: ["#FF512F", "#F09819"]),
        Item(name: "Violet", colors: ["#5B247A", "#1BCEDF"]),
        Item(name: "Mint", colors: ["#11998E", "#38EF7D"]),
        Item(name: "Rose", colors: ["#EE9CA7", "#FFDDE1"]),
        Item(name: "Peach", colors: ["#FFB88C", "#DE6262"]),
        Item(name: "Lagoon", colors: ["#43C6AC", "#191654"]),
        Item(name: "Aurora", colors: ["#00C9FF", "#92FE9D"]),
        Item(name: "Citrus", colors: ["#F7971E", "#FFD200"]),
        Item(name: "Berry", colors: ["#8E2DE2", "#4A00E0"]),
        Item(name: "Midnight", colors: ["#0F2027", "#203A43", "#2C5364"]),
        Item(name: "Sky", colors: ["#A1C4FD", "#C2E9FB"]),
        Item(name: "Graphite", colors: ["#232526", "#414345"]),
        Item(name: "Paper", colors: ["#F5F7FA", "#C3CFE2"]),
        Item(name: "White", colors: ["#FFFFFF"]),
        Item(name: "Light Gray", colors: ["#E9E9EB"]),
        Item(name: "Sand", colors: ["#EFE6D8"]),
        Item(name: "Blue", colors: ["#3A6FF7"]),
        Item(name: "Charcoal", colors: ["#2B2B2E"]),
        Item(name: "Black", colors: ["#000000"])
    ]

    static var customDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snapper/Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File names of the user's own background images.
    static var customImages: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: customDirectory.path)) ?? []
        return files.filter { ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }

    /// Copies an image into the backgrounds folder and returns its file name.
    static func importImage(from url: URL) -> String? {
        let name = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        let dest = customDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            cacheLock.lock(); imageCache[name] = nil; cacheLock.unlock()
            return name
        } catch {
            return nil
        }
    }

    static func removeImage(_ name: String) {
        try? FileManager.default.removeItem(at: customDirectory.appendingPathComponent(name))
        cacheLock.lock(); imageCache[name] = nil; cacheLock.unlock()
    }

    private static var imageCache: [String: CGImage] = [:]
    private static let cacheLock = NSLock()

    private static func cachedImage(_ name: String) -> CGImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return imageCache[name]
    }

    static func cgImage(named name: String) -> CGImage? {
        if let c = cachedImage(name) { return c }
        let url = customDirectory.appendingPathComponent(name)
        guard let img = decode(url) else { return nil }
        cacheLock.lock()
        imageCache[name] = img
        cacheLock.unlock()
        return img
    }

    /// Decodes at screen-useful size (4K at most, EXIF rotation applied), fully, so drawing never waits on a decoder.
    static func decode(_ url: URL, maxPixel: Int = 4096) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Runs `done` on the main thread once the image behind `fill` is decoded (decoding happens off the main
    /// thread, so choosing a big picture or the wallpaper doesn't freeze the editor).
    static func prepare(_ fill: BackgroundSettings.Fill, done: @escaping () -> Void) {
        switch fill {
        case .image(let name):
            if cachedImage(name) != nil { done(); return }
        case .wallpaper:
            if cachedWallpaper() != nil { done(); return }
        default:
            done()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            switch fill {
            case .image(let name): _ = cgImage(named: name)
            case .wallpaper: _ = wallpaper()
            default: break
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    private static var wallpaperCache: (url: URL, image: CGImage)?

    private static func cachedWallpaper() -> (url: URL, image: CGImage)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return wallpaperCache
    }

    static func wallpaper() -> CGImage? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let c = cachedWallpaper(), c.url == url { return c.image }
        var target = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // Dynamic wallpapers can point at a folder; use its first image.
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.first(where: { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }) else { return nil }
            target = first
        }
        guard let img = decode(target) else { return nil }
        cacheLock.lock()
        wallpaperCache = (url, img)
        cacheLock.unlock()
        return img
    }
}

// MARK: - Rendering

enum BackgroundMaker {
    struct Layout {
        let canvasSize: CGSize      // whole output, image pixels
        let contentRect: CGRect     // where the screenshot goes, top-left origin
    }

    static func paddingPixels(_ s: BackgroundSettings, contentSize: CGSize) -> CGFloat {
        (min(contentSize.width, contentSize.height) * max(0, s.padding)).rounded()
    }

    /// Where the content sits inside the output for the given settings.
    static func layout(_ s: BackgroundSettings, contentSize: CGSize) -> Layout {
        let w = contentSize.width, h = contentSize.height
        let pad = paddingPixels(s, contentSize: contentSize)
        var cw = w + pad * 2, ch = h + pad * 2
        if let ratio = s.aspect.ratio {
            if cw / ch < ratio { cw = (ch * ratio).rounded() } else { ch = (cw / ratio).rounded() }
        }
        let col = CGFloat(s.alignment % 3), row = CGFloat(s.alignment / 3)
        let freeX = max(0, cw - w - pad * 2), freeY = max(0, ch - h - pad * 2)
        let x = pad + freeX * col / 2
        let y = pad + freeY * row / 2
        return Layout(canvasSize: CGSize(width: cw, height: ch),
                      contentRect: CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h))
    }

    static func radius(_ s: BackgroundSettings, contentSize: CGSize) -> CGFloat {
        min(max(0, s.cornerRadius), min(contentSize.width, contentSize.height) / 2)
    }

    /// Shadow blur, downward offset and opacity, in image pixels.
    static func shadowParams(_ s: BackgroundSettings, contentSize: CGSize) -> (blur: CGFloat, offset: CGFloat, alpha: CGFloat) {
        let base = max(10, min(contentSize.width, contentSize.height) * 0.05)
        let k = max(0, min(1, s.shadow))
        return (base * 1.6 * k, base * 0.35 * k, 0.5 * k)
    }

    /// Paints the background fill into `rect`. `flipped` = top-left origin context.
    static func drawFill(_ s: BackgroundSettings, in ctx: CGContext, rect: CGRect, flipped: Bool) {
        ctx.saveGState()
        ctx.clip(to: rect)
        switch s.fill {
        case .none:
            break
        case .builtIn(let i):
            let item = BackgroundCatalog.builtIn[min(max(i, 0), BackgroundCatalog.builtIn.count - 1)]
            drawColors(item.colors, in: ctx, rect: rect, flipped: flipped)
        case .color(let hex):
            ctx.setFillColor((NSColor(hex: hex) ?? .white).cgColor)
            ctx.fill(rect)
        case .image(let name):
            if let img = BackgroundCatalog.cgImage(named: name) {
                drawAspectFill(img, in: ctx, rect: rect, flipped: flipped)
            } else {
                ctx.setFillColor(NSColor.gray.cgColor)
                ctx.fill(rect)
            }
        case .wallpaper:
            if let img = BackgroundCatalog.wallpaper() {
                drawAspectFill(img, in: ctx, rect: rect, flipped: flipped)
            } else {
                drawColors(BackgroundCatalog.builtIn[0].colors, in: ctx, rect: rect, flipped: flipped)
            }
        }
        ctx.restoreGState()
    }

    static func drawColors(_ hexes: [String], in ctx: CGContext, rect: CGRect, flipped: Bool) {
        let colors = hexes.compactMap { NSColor(hex: $0)?.cgColor }
        if colors.count == 1 {
            ctx.setFillColor(colors[0])
            ctx.fill(rect)
            return
        }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: nil) else { return }
        let start = flipped ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY)
        let end = flipped ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY)
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static var reducedCache: (source: CGImage, width: Int, image: CGImage)?

    /// A smaller copy for drawing into a small area (previews), so a 4K backdrop isn't resampled on every repaint.
    private static func reduced(_ img: CGImage, forPixelWidth width: CGFloat) -> CGImage {
        let target = Int(ceil(width))
        guard target > 0, target * 2 <= img.width else { return img }
        if let r = reducedCache, r.source === img, abs(r.width - target) <= max(16, target / 6) { return r.image }
        let h = max(1, Int((Double(target) * Double(img.height) / Double(img.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: target, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: target, height: h))
        guard let out = ctx.makeImage() else { return img }
        reducedCache = (img, target, out)
        return out
    }

    private static func drawAspectFill(_ source: CGImage, in ctx: CGContext, rect: CGRect, flipped: Bool) {
        let scale0 = max(rect.width / CGFloat(source.width), rect.height / CGFloat(source.height))
        let deviceScale = max(abs(ctx.ctm.a), 0.01)
        let img = reduced(source, forPixelWidth: CGFloat(source.width) * scale0 * deviceScale)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let scale = max(rect.width / iw, rect.height / ih)
        let w = iw * scale, h = ih * scale
        let target = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        ctx.interpolationQuality = .high
        if flipped {
            ctx.saveGState()
            ctx.translateBy(x: target.minX, y: target.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        } else {
            ctx.draw(img, in: target)
        }
    }

    // MARK: Auto Balance

    /// Insets of uniform-coloured margins around the content (image pixels, top/left/bottom/right),
    /// so the padding around the "real" content looks even.
    static func balancedInsets(_ image: CGImage) -> NSEdgeInsets {
        let w = image.width, h = image.height
        guard w > 8, h > 8,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return NSEdgeInsetsZero }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // Bitmap rows run top to bottom in memory.
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        let ref = pixel(0, 0)
        func same(_ p: (Int, Int, Int)) -> Bool { abs(p.0 - ref.0) + abs(p.1 - ref.1) + abs(p.2 - ref.2) < 24 }
        func rowUniform(_ y: Int) -> Bool { stride(from: 0, to: w, by: max(1, w / 400)).allSatisfy { same(pixel($0, y)) } }
        func colUniform(_ x: Int) -> Bool { stride(from: 0, to: h, by: max(1, h / 400)).allSatisfy { same(pixel(x, $0)) } }

        var top = 0; while top < h / 2 - 1, rowUniform(top) { top += 1 }
        var bottom = 0; while bottom < h / 2 - 1, rowUniform(h - 1 - bottom) { bottom += 1 }
        var left = 0; while left < w / 2 - 1, colUniform(left) { left += 1 }
        var right = 0; while right < w / 2 - 1, colUniform(w - 1 - right) { right += 1 }
        // Nothing but margin: leave it alone.
        if top + bottom >= h - 4 || left + right >= w - 4 { return NSEdgeInsetsZero }
        // Keep a little breathing room so content isn't cut flush.
        let keep = 4
        return NSEdgeInsets(top: CGFloat(max(0, top - keep)), left: CGFloat(max(0, left - keep)),
                            bottom: CGFloat(max(0, bottom - keep)), right: CGFloat(max(0, right - keep)))
    }

    // MARK: Export

    static func apply(_ s: BackgroundSettings, to input: CGImage) -> CGImage {
        guard !s.isNone else { return input }
        var image = input
        if s.autoBalance {
            let i = balancedInsets(input)
            let r = CGRect(x: i.left, y: i.top, width: CGFloat(input.width) - i.left - i.right,
                           height: CGFloat(input.height) - i.top - i.bottom).integral
            if r.width > 4, r.height > 4, let c = input.cropping(to: r) { image = c }
        }
        let size = CGSize(width: image.width, height: image.height)
        let lay = layout(s, contentSize: size)
        let outW = Int(lay.canvasSize.width), outH = Int(lay.canvasSize.height)
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return input }

        // Work top-left origin, like the canvas.
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: 1, y: -1)
        let full = CGRect(x: 0, y: 0, width: outW, height: outH)
        drawFill(s, in: ctx, rect: full, flipped: true)
        drawContent(image, settings: s, in: ctx, rect: lay.contentRect, scale: 1)
        return ctx.makeImage() ?? input
    }

    /// Shadow + rounded content. `rect` and `scale` are in the context's units (scale = units per image pixel).
    /// Context must be flipped (top-left origin).
    static func drawContent(_ image: CGImage, settings s: BackgroundSettings, in ctx: CGContext, rect: CGRect, scale: CGFloat) {
        let contentSize = CGSize(width: rect.width / scale, height: rect.height / scale)
        let r = radius(s, contentSize: contentSize) * scale
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        let sh = shadowParams(s, contentSize: contentSize)
        if sh.alpha > 0 {
            ctx.saveGState()
            // Shadow offsets are in device space (y up), so negative = downward.
            ctx.setShadow(offset: CGSize(width: 0, height: -sh.offset * scale), blur: sh.blur * scale,
                          color: NSColor.black.withAlphaComponent(sh.alpha).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        AnnotationRenderer.drawImage(ctx, image, in: rect)
        ctx.restoreGState()
    }

    // MARK: Thumbnails

    static func thumbnail(_ fill: BackgroundSettings.Fill, size: CGSize = CGSize(width: 44, height: 30)) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if fill == .none {
                NSColor.textBackgroundColor.setFill()
                rect.fill()
                NSColor.systemRed.withAlphaComponent(0.8).setStroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 5))
                slash.line(to: NSPoint(x: rect.maxX - 6, y: rect.minY + 5))
                slash.lineWidth = 1.5
                slash.stroke()
            } else {
                var s = BackgroundSettings()
                s.fill = fill
                drawFill(s, in: ctx, rect: rect, flipped: true)
            }
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.separatorColor.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            return true
        }
    }
}
