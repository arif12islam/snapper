import AppKit
import CoreGraphics
import Vision

/// Interactive annotation canvas. Flipped so view space is top-left origin, like image space.
final class AnnotateCanvas: NSView, NSTextFieldDelegate {
    private(set) var baseImage: CGImage
    typealias Snapshot = (objects: [AnnotationObject], crop: CGRect?, image: CGImage)
    private(set) var objects: [AnnotationObject] = []
    private(set) var cropRect: CGRect?
    private(set) var selectedID: UUID? {
        didSet { if oldValue != selectedID { notifySelection() } }
    }

    /// Kind of the selected annotation, if any.
    var selectedKind: AnnotationKind? {
        guard let id = selectedID else { return nil }
        return objects.first { $0.id == id }?.kind
    }

    var selectedObject: AnnotationObject? {
        guard let id = selectedID else { return nil }
        return objects.first { $0.id == id }
    }

    /// The Text tool draws a speech bubble (callout) unless Plain is chosen.
    private var effectiveTool: AnnotationTool { tool == .text && style.bubble ? .callout : tool }

    var tool: AnnotationTool = .arrow {
        didSet {
            if tool != .select { selectedID = nil }
            if tool != .crop { pendingCrop = nil; cropDrag = nil }
            commitTextEditing()
            // Entering or leaving Crop switches between the whole picture and the cropped result.
            if (oldValue == .crop) != (tool == .crop), cropRect != nil || !background.isNone { fitView() }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            onChange?()
        }
    }
    var style = AnnotationStyle() {
        didSet {
            // Style edits apply to the selected object, if any.
            if let id = selectedID, let i = objects.firstIndex(where: { $0.id == id }), objects[i].style != style {
                if styleUndoID != id { pushUndo(); styleUndoID = id }
                objects[i].style = style
                needsDisplay = true
            }
        }
    }

    /// Crop tool aspect ratio (width / height); nil = free.
    var cropAspect: CGFloat?

    /// Background shown live on the canvas and applied on export.
    var background: BackgroundSettings = .off {
        didSet { if oldValue != background { balanceCache = nil; fitView() } }
    }

    var onChange: (() -> Void)?
    var onSelectionStyle: ((AnnotationStyle) -> Void)?
    var onCopyShortcut: (() -> Void)?
    var onSaveShortcut: (() -> Void)?
    var onSelectionRotation: ((CGFloat?) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var rotatingID: UUID?
    private var styleUndoID: UUID?

    private var dragStart: CGPoint?
    private var working: AnnotationObject?
    private var movingLast: CGPoint?
    private var movingLoupe = false             // dragging a magnifier's loupe only (not the whole object)
    private var didPushMoveUndo = false
    private var pendingCrop: CGRect?
    private var nextZ = 1

    private enum Handle: Equatable { case corner(Int), edge(Int), rotate, start, end, control, tip, loupe }
    private var activeHandle: Handle?
    private var lastSmart: (id: UUID, time: Date)?
    private var interacting = false              // a drawing tool is active but the drag moves an existing object
    private var hoverCursor: NSCursor?
    private var handleAnchor: CGPoint = .zero

    private enum CropDrag { case new, corner(CGPoint), move(CGPoint) }
    private var cropDrag: CropDrag?

    private var textField: NSTextField?
    private var editingID: UUID?

    private var balanceCache: (key: CGRect, insets: NSEdgeInsets)?
    /// Display-sized copy of the picture, so each redraw blits a small bitmap instead of rescaling a 5K one.
    private var scaledBase: (source: CGImage, width: Int, image: CGImage)?

    private func displayBase(forPixelWidth target: Int) -> CGImage? {
        guard target > 0, target < baseImage.width else { return nil }       // at or above 1:1, draw the original
        if let c = scaledBase, c.source === baseImage, abs(c.width - target) <= max(8, target / 8) { return c.image }
        let h = max(1, Int((Double(target) * Double(baseImage.height) / Double(baseImage.width)).rounded()))
        guard let ctx = CGContext(data: nil, width: target, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: target, height: h))
        guard let img = ctx.makeImage() else { return nil }
        scaledBase = (baseImage, target, img)
        return img
    }

    /// Redraws only the area around an object that is being drawn or moved (image-space rects).
    private func invalidate(_ rects: [CGRect], pad: CGFloat) {
        var u = CGRect.null
        for r in rects where !r.isNull { u = u.union(r) }
        guard !u.isNull else { needsDisplay = true; return }
        setNeedsDisplay(viewRect(u).insetBy(dx: -(pad * fitScale + 24), dy: -(pad * fitScale + 24)))
    }

    init(image: CGImage, objects: [AnnotationObject] = [], cropRect: CGRect? = nil) {
        self.baseImage = image
        self.objects = objects
        self.cropRect = cropRect
        self.nextZ = (objects.map { $0.z }.max() ?? 0) + 1
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var imageSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }

    // MARK: - Geometry

    /// Zoom relative to "fit to window" (1 = fit). Pan is the presentation centre's offset from the view centre.
    private(set) var zoom: CGFloat = 1
    private var pan: CGPoint = .zero

    private var showsBackground: Bool { tool != .crop && !background.isNone }

    /// Part of the image that ends up in the export (image space). While the Crop tool is
    /// active the whole image is shown so the crop can be adjusted.
    var contentRect: CGRect {
        let full = CGRect(origin: .zero, size: imageSize)
        guard tool != .crop else { return full }
        guard let c = cropRect else { return objectsExtent }
        let r = c.integral.intersection(full)
        return (r.isNull || r.width < 2 || r.height < 2) ? full : r
    }

    /// The picture plus anything drawn outside it: the frame grows to hold annotations that go past the edge.
    private var objectsExtent: CGRect {
        guard extendCanvas else { return CGRect(origin: .zero, size: imageSize) }
        var all = objects
        if let w = working { all.append(w) }
        return AnnotationRenderer.canvasRect(imageSize: imageSize, objects: all)
    }

    /// Off by default: annotations stay inside the picture. When on, the frame (and the export) grows to hold them.
    var extendCanvas = false {
        didSet {
            guard extendCanvas != oldValue else { return }
            fitView()
            onChange?()
        }
    }

    /// Colour of the added area: transparent (checkerboard) or white.
    var extendFillWhite = false { didSet { needsDisplay = true } }

    /// Layout is held still while the mouse is down, so the view does not rescale under the pointer mid-drag.
    private var frozenContent: CGRect?

    /// Auto Balance: uniform margins trimmed from the content (relative to `contentRect`).
    private func balanceInsets() -> NSEdgeInsets {
        let key = contentRect
        if let c = balanceCache, c.key == key { return c.insets }
        if !CGRect(origin: .zero, size: imageSize).contains(key) { return NSEdgeInsetsZero }
        var insets = NSEdgeInsetsZero
        if let region = baseImage.cropping(to: key.integral) { insets = BackgroundMaker.balancedInsets(region) }
        balanceCache = (key, insets)
        return insets
    }

    /// What is shown framed by the background (image space).
    private var shownRect: CGRect {
        let c = frozenContent ?? contentRect
        guard showsBackground, background.autoBalance else { return c }
        let i = balanceInsets()
        let r = CGRect(x: c.minX + i.left, y: c.minY + i.top,
                       width: c.width - i.left - i.right, height: c.height - i.top - i.bottom)
        return (r.width > 4 && r.height > 4) ? r : c
    }

    /// Everything that is drawn: the visible part of the image plus the backdrop (image space).
    private var presentationRect: CGRect {
        let v = shownRect
        guard showsBackground else { return v }
        let lay = BackgroundMaker.layout(background, contentSize: v.size)
        return CGRect(x: v.minX - lay.contentRect.minX, y: v.minY - lay.contentRect.minY,
                      width: lay.canvasSize.width, height: lay.canvasSize.height)
    }

    /// Space kept clear for the floating glass bars (top = style bar, bottom = tools bar).
    var contentInsets = NSEdgeInsets(top: 56, left: 0, bottom: 60, right: 0) {
        didSet { needsDisplay = true }
    }

    private var availableSize: CGSize {
        CGSize(width: max(bounds.width - contentInsets.left - contentInsets.right, 10),
               height: max(bounds.height - contentInsets.top - contentInsets.bottom, 10))
    }

    private var baseFit: CGFloat {
        let margin: CGFloat = 24
        let p = presentationRect
        let a = availableSize
        let w = max(a.width - margin * 2, 10), h = max(a.height - margin * 2, 10)
        return min(w / max(p.width, 1), h / max(p.height, 1), 2)
    }

    /// Points of view per image pixel.
    private var fitScale: CGFloat { baseFit * zoom }

    /// View position of image (0,0) when centred with no pan.
    private func baseOrigin(scale s: CGFloat) -> CGPoint {
        let p = presentationRect
        let a = availableSize
        return CGPoint(x: contentInsets.left + (a.width - p.width * s) / 2 - p.minX * s,
                       y: contentInsets.top + (a.height - p.height * s) / 2 - p.minY * s)
    }

    private var imageFrame: CGRect {
        let s = fitScale
        let o = baseOrigin(scale: s)
        return CGRect(x: o.x + pan.x, y: o.y + pan.y, width: imageSize.width * s, height: imageSize.height * s)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let f = imageFrame, s = fitScale
        return CGRect(x: f.minX + r.minX * s, y: f.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func clampPan() {
        let s = fitScale
        let p = presentationRect
        let w = p.width * s, h = p.height * s
        // Free canvas: the picture can be pushed almost out of view in any direction.
        let maxX = max((w + bounds.width) / 2 - 120, 0)
        let maxY = max((h + bounds.height) / 2 - 120, 0)
        pan.x = min(max(pan.x, -maxX), maxX)
        pan.y = min(max(pan.y, -maxY), maxY)
    }

    /// Zooms while keeping the image point under `anchor` (view coordinates) fixed.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil, live useLive: Bool = false) {
        commitTextEditing()
        if useLive { beginLive() }
        let q = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let ip = toImage(q)
        zoom = min(max(newZoom, 0.2), 32)
        let s = fitScale
        let o = baseOrigin(scale: s)
        pan.x = q.x - ip.x * s - o.x
        pan.y = q.y - ip.y * s - o.y
        clampPan()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onZoomChange?(zoom)
    }

    func zoomIn() { setZoom(zoom * 1.25) }
    func zoomOut() { setZoom(zoom / 1.25) }

    func fitView() {
        commitTextEditing()
        zoom = 1
        pan = .zero
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onZoomChange?(zoom)
    }

    /// 100%: one image pixel per view point.
    func actualSize() { setZoom(1 / max(baseFit, 0.0001)) }

    /// Current zoom as a percentage of the real image size.
    var zoomPercent: Int { Int((fitScale * 100).rounded()) }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let f = imageFrame, s = fitScale
        return CGPoint(x: (p.x - f.minX) / s, y: (p.y - f.minY) / s)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = imageFrame, s = fitScale
        return CGPoint(x: f.minX + p.x * s, y: f.minY + p.y * s)
    }

    /// With Extend Canvas on (and no crop) annotations can go anywhere and the frame grows to hold them; otherwise
    /// they stay inside the picture.
    private func clampToImage(_ p: CGPoint) -> CGPoint {
        guard cropRect != nil || !extendCanvas else { return p }
        let c = contentRect
        return CGPoint(x: min(max(p.x, c.minX), c.maxX), y: min(max(p.y, c.minY), c.maxY))
    }

    // MARK: - Live zoom / pan snapshot

    private var live: (image: CGImage, origin: CGPoint, scale: CGFloat)?
    private var liveWork: DispatchWorkItem?

    /// Renders the current view once into a bitmap; zoom and pan then just move that bitmap until the gesture
    /// settles (about 0.14 s after the last event), which keeps pinch and scroll smooth with backgrounds and shadows.
    private func beginLive() {
        if live == nil {
            // Large windows get a lighter snapshot while the gesture runs; it is redrawn crisp right after.
            let backing = window?.backingScaleFactor ?? 2
            let scale: CGFloat = bounds.width * bounds.height * backing * backing > 4_500_000 ? max(1, backing * 0.6) : backing
            let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSColor.underPageBackgroundColor.setFill()
            bounds.fill()
            drawContent(ctx)
            NSGraphicsContext.restoreGraphicsState()
            guard let img = ctx.makeImage() else { return }
            live = (img, imageFrame.origin, fitScale)
        }
        liveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endLive() }
        liveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func endLive() {
        liveWork?.cancel()
        liveWork = nil
        guard live != nil else { return }
        live = nil
        needsDisplay = true
    }

    // MARK: - Undo / redo

    private func pushUndo() {
        endLive()
        rotatingID = nil
        undoStack.append((objects, cropRect, baseImage))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange?()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        commitTextEditing()
        redoStack.append((objects, cropRect, baseImage))
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((objects, cropRect, baseImage))
        restore(next)
    }

    private func restore(_ snap: Snapshot) {
        rotatingID = nil
        styleUndoID = nil
        objects = snap.objects
        let cropChanged = snap.crop != cropRect
        cropRect = snap.crop
        if snap.image !== baseImage {
            baseImage = snap.image
            AnnotationRenderer.clearCache()
            balanceCache = nil
            fitView()
        } else if cropChanged, tool != .crop {
            fitView()
        }
        if let id = selectedID, !objects.contains(where: { $0.id == id }) { selectedID = nil }
        notifySelection()
        needsDisplay = true
        onChange?()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        objects.removeAll { $0.id == id }
        selectedID = nil
        needsDisplay = true
    }

    func clearCrop() {
        guard cropRect != nil else { return }
        pushUndo()
        cropRect = nil
        pendingCrop = nil
        if tool != .crop { fitView() }
        needsDisplay = true
        onChange?()
    }

    func exportImage() -> CGImage? {
        commitTextEditing()
        return AnnotationRenderer.exportImage(base: baseImage, objects: objects, cropRect: cropRect, expand: extendCanvas, whiteFill: extendFillWhite)
    }

    /// Exactly what the canvas shows: annotations, crop, Auto Balance and background.
    func finalImage() -> CGImage? {
        guard var image = exportImage() else { return nil }
        guard !background.isNone else { return image }
        if background.autoBalance {
            let i = balanceInsetsForExport()
            let r = CGRect(x: i.left, y: i.top, width: CGFloat(image.width) - i.left - i.right,
                           height: CGFloat(image.height) - i.top - i.bottom).integral
            if r.width > 4, r.height > 4, let c = image.cropping(to: r) { image = c }
        }
        var s = background
        s.autoBalance = false
        return BackgroundMaker.apply(s, to: image)
    }

    /// Balance insets for the crop as exported (independent of the active tool).
    private func balanceInsetsForExport() -> NSEdgeInsets {
        let full = CGRect(origin: .zero, size: imageSize)
        var key = full
        if cropRect == nil, objectsExtent != full { return NSEdgeInsetsZero }
        if let c = cropRect {
            let r = c.integral.intersection(full)
            if !r.isNull, r.width >= 2, r.height >= 2 { key = r }
        }
        if let c = balanceCache, c.key == key { return c.insets }
        guard let region = baseImage.cropping(to: key.integral) else { return NSEdgeInsetsZero }
        return BackgroundMaker.balancedInsets(region)
    }

    func makeProject() -> SnapperProject? {
        commitTextEditing()
        let rep = NSBitmapImageRep(cgImage: baseImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return SnapperProject(imagePNG: png, objects: objects, cropRect: cropRect,
                              backgroundSettings: background.isNone ? nil : background)
    }

    // MARK: - Whole-picture transforms (rotate, flip, resize)

    private static func normalized(_ degrees: CGFloat) -> CGFloat {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    private static func newContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Rotates a CGImage by 90 degrees.
    private static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = newContext(width: h, height: w) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = newContext(width: w, height: h) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Applies a point mapping to every annotation and the crop. Boxes keep their size and move by centre.
    private func remap(_ map: (CGPoint) -> CGPoint, rotationDelta: CGFloat, mirror: Bool) {
        objects = objects.map { o in
            var n = o
            switch o.kind {
            case .text, .callout, .image:
                let r = o.rect
                let c = map(CGPoint(x: r.midX, y: r.midY))
                if o.kind == .image {
                    n.start = CGPoint(x: c.x - r.width / 2, y: c.y - r.height / 2)
                    n.end = CGPoint(x: c.x + r.width / 2, y: c.y + r.height / 2)
                } else {
                    n.start = CGPoint(x: c.x - r.width / 2, y: c.y - r.height / 2)
                }
                if o.kind == .callout { n.end = map(o.end) }
                if o.kind != .callout {
                    n.rotation = Self.normalized((mirror ? -o.rotation : o.rotation) + rotationDelta)
                }
            case .number:
                n.start = map(o.start)
            default:
                n.start = map(o.start)
                n.end = map(o.end)
                n.points = o.points.map(map)
                if mirror { n.rotation = -o.rotation }
            }
            return n
        }
        if let c = cropRect {
            let a = map(CGPoint(x: c.minX, y: c.minY)), b = map(CGPoint(x: c.maxX, y: c.maxY))
            cropRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }

    private func replaceBase(_ image: CGImage) {
        baseImage = image
        scaledBase = nil
        AnnotationRenderer.clearCache()
        balanceCache = nil
        fitView()
        onChange?()
    }

    /// Rotates the picture and carries every annotation (and the crop) along with it.
    func rotateImage(clockwise: Bool) {
        commitTextEditing()
        guard let rotated = Self.rotate(baseImage, clockwise: clockwise) else { return }
        pushUndo()
        let w = CGFloat(baseImage.width), h = CGFloat(baseImage.height)
        remap({ p in clockwise ? CGPoint(x: h - p.y, y: p.x) : CGPoint(x: p.y, y: w - p.x) },
              rotationDelta: clockwise ? 90 : -90, mirror: false)
        replaceBase(rotated)
    }

    func flipImage(horizontal: Bool) {
        commitTextEditing()
        guard let flipped = Self.flip(baseImage, horizontal: horizontal) else { return }
        pushUndo()
        let w = CGFloat(baseImage.width), h = CGFloat(baseImage.height)
        remap({ p in horizontal ? CGPoint(x: w - p.x, y: p.y) : CGPoint(x: p.x, y: h - p.y) },
              rotationDelta: 0, mirror: true)
        replaceBase(flipped)
    }

    /// Scales the picture to `size` pixels; annotations scale with it.
    func resizeImage(to size: CGSize) {
        commitTextEditing()
        let nw = max(1, Int(size.width.rounded())), nh = max(1, Int(size.height.rounded()))
        guard nw != baseImage.width || nh != baseImage.height,
              let ctx = Self.newContext(width: nw, height: nh) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let resized = ctx.makeImage() else { return }
        pushUndo()
        let sx = CGFloat(nw) / CGFloat(baseImage.width), sy = CGFloat(nh) / CGFloat(baseImage.height)
        let k = (sx + sy) / 2
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
        objects = objects.map { o in
            var n = o
            n.start = map(o.start)
            n.end = map(o.end)
            n.points = o.points.map(map)
            n.style.lineWidth = max(1, o.style.lineWidth * k)
            n.style.fontSize = max(6, o.style.fontSize * k)
            n.thickness = o.thickness * k
            return n
        }
        if let c = cropRect {
            cropRect = CGRect(x: c.minX * sx, y: c.minY * sy, width: c.width * sx, height: c.height * sy)
        }
        replaceBase(resized)
    }

    // MARK: - Combine images

    /// Adds another picture as a movable layer. `point` is in image space (nil = centre).
    func addImage(_ image: CGImage, at point: CGPoint? = nil) {
        commitTextEditing()
        // Encoding a large picture takes a moment: do it off the main thread so the editor stays responsive.
        Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { CaptureEngine.pngData(image) }.value
            guard let self, let png else { return }
            self.placeImage(image, png: png, at: point)
        }
    }

    private func placeImage(_ image: CGImage, png: Data, at point: CGPoint?) {
        let c = contentRect
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min(1, c.width * 0.6 / iw, c.height * 0.6 / ih)
        let w = iw * scale, h = ih * scale
        let centre = point ?? CGPoint(x: c.midX, y: c.midY)
        var obj = AnnotationObject(kind: .image,
                                   start: CGPoint(x: centre.x - w / 2, y: centre.y - h / 2),
                                   end: CGPoint(x: centre.x + w / 2, y: centre.y + h / 2),
                                   z: nextZ)
        obj.imageData = png
        AnnotationRenderer.prime(obj.id, image: image)
        nextZ += 1
        pushUndo()
        objects.append(obj)
        tool = .select
        selectedID = obj.id
        needsDisplay = true
        onChange?()
    }

    private static func cgImage(from pasteboard: NSPasteboard) -> CGImage? {
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func pasteImage() -> Bool {
        guard let img = Self.cgImage(from: .general) else { return false }
        addImage(img)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NSImage.canInit(with: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let img = Self.cgImage(from: sender.draggingPasteboard) else { return false }
        let p = clampToImage(toImage(convert(sender.draggingLocation, from: nil)))
        addImage(img, at: p)
        return true
    }

    // MARK: - Rotation of one annotation

    /// Angle of the selected object, or nil when nothing rotatable is selected.
    var selectedRotation: CGFloat? {
        guard let o = selectedObject, o.supportsRotation else { return nil }
        return o.rotation
    }

    func setSelectedRotation(_ degrees: CGFloat) {
        guard let id = selectedID, let i = objects.firstIndex(where: { $0.id == id }),
              objects[i].supportsRotation else { return }
        if rotatingID != id {          // one undo step per slider drag
            pushUndo()
            rotatingID = id
        }
        objects[i].rotation = Self.normalized(degrees)
        needsDisplay = true
    }

    private func notifySelection() {
        styleUndoID = nil
        onSelectionRotation?(selectedRotation)
    }

    // MARK: - Handles

    private func handles(for o: AnnotationObject) -> [(Handle, CGPoint)] {
        switch o.kind {
        case .line:
            return [(.start, o.start), (.end, o.end)]
        case .arrow:
            // Start, middle (drag to bend, double-click to straighten) and end.
            return [(.start, o.start), (.control, o.curveControl), (.end, o.end)]
        case .callout:
            return [(.tip, o.end)]
        case .magnifier:
            let r = o.magSourceRect
            return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY)),
                    (.edge(0), CGPoint(x: r.midX, y: r.minY)), (.edge(1), CGPoint(x: r.maxX, y: r.midY)),
                    (.edge(2), CGPoint(x: r.midX, y: r.maxY)), (.edge(3), CGPoint(x: r.minX, y: r.midY)),
                    (.loupe, CGPoint(x: o.magLoupeRect.maxX, y: o.magLoupeRect.midY))]
        default:
            var list: [(Handle, CGPoint)] = []
            let r = o.rect
            if o.isBoxShaped, o.rotation == 0 {
                list = [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                        (.corner(2), CGPoint(x: r.maxX, y: r.maxY)), (.corner(3), CGPoint(x: r.minX, y: r.maxY))]
                if o.kind != .image {
                    list += [(.edge(0), CGPoint(x: r.midX, y: r.minY)), (.edge(1), CGPoint(x: r.maxX, y: r.midY)),
                             (.edge(2), CGPoint(x: r.midX, y: r.maxY)), (.edge(3), CGPoint(x: r.minX, y: r.midY))]
                }
            }
            if o.kind == .rectangle || o.kind == .ellipse || o.kind == .image || o.kind == .text || o.kind == .pencil {
                // Rotate handle above the box; it turns with the object.
                let reach = r.height / 2 + 28 / max(fitScale, 0.05)
                let a = o.rotation * .pi / 180
                list.append((.rotate, CGPoint(x: r.midX + reach * sin(a), y: r.midY - reach * cos(a))))
            }
            return list
        }
    }

    private func handleHit(at p: CGPoint) -> Handle? {
        guard let o = selectedObject else { return nil }
        let r = 8 / max(fitScale, 0.05)
        for (h, q) in handles(for: o) where hypot(p.x - q.x, p.y - q.y) <= r { return h }
        return nil
    }

    private func dragHandle(_ handle: Handle, to p: CGPoint, constrain: Bool) {
        guard let id = selectedID, let i = objects.firstIndex(where: { $0.id == id }) else { return }
        var o = objects[i]
        switch handle {
        case .start: o.start = p
        case .end: o.end = p
        case .tip: o.end = p
        case .control: o.points = [p]
        case .loupe:
            // The handle on the loupe's edge sets its size: the left edge stays, the zoom follows the width.
            let s = o.magSourceRect, l = o.magLoupeRect
            let z = min(max((p.x - l.minX) / max(s.width, 1), 1.2), 12)
            o.style.magnify = z
            o.points = [CGPoint(x: l.minX + s.width * z / 2, y: l.midY)]
        case .rotate:
            let r = o.rect
            var deg = atan2(p.y - r.midY, p.x - r.midX) * 180 / .pi + 90
            if constrain { deg = (deg / 15).rounded() * 15 }
            o.rotation = Self.normalized(deg)
        case .edge(let side):
            let r = o.editRect
            var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
            switch side {
            case 0: minY = p.y
            case 1: maxX = p.x
            case 2: maxY = p.y
            default: minX = p.x
            }
            o.start = CGPoint(x: minX, y: minY)
            o.end = CGPoint(x: maxX, y: maxY)
        case .corner:
            var q = p
            let a = handleAnchor
            if o.kind == .image || constrain {
                // Keep the proportions (always for pictures, with Shift for shapes).
                let r = objects[i].editRect
                let aspect = max(r.width, 1) / max(r.height, 1)
                let dx = q.x - a.x, dy = q.y - a.y
                let w = max(abs(dx), abs(dy) * aspect)
                q = CGPoint(x: a.x + (dx < 0 ? -w : w), y: a.y + (dy < 0 ? -w / aspect : w / aspect))
            }
            o.start = a
            o.end = q
        }
        objects[i] = o
    }

    // MARK: - Mouse

    override func resetCursorRects() {
        let c = viewRect(contentRect).intersection(bounds)
        addCursorRect(c, cursor: hoverCursor ?? (tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverCursor(nil)
    }

    /// Pointer over an object: open hand (it can be dragged). Over a handle of the selection: pointing hand.
    private func updateHover(_ event: NSEvent) {
        guard tool != .crop, event.type != .leftMouseDragged else { setHoverCursor(nil); return }
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let optionHeld = event.modifierFlags.contains(.option)
        let canGrab = tool == .select || (tool != .pencil && tool != .highlighter && !optionHeld)
        var c: NSCursor?
        if canGrab {
            if handleHit(at: raw) != nil {
                c = .pointingHand
            } else if hitObject(at: clampToImage(raw)) != nil {
                c = .openHand
            }
        }
        setHoverCursor(c)
    }

    private func setHoverCursor(_ c: NSCursor?) {
        guard c !== hoverCursor else { return }
        hoverCursor = c
        window?.invalidateCursorRects(for: self)
    }

    /// Tools that still let you grab objects: hover turns the pointer into a hand and a drag moves what is under it.
    /// Hold Option to draw over an existing object instead.
    private func canInteract(_ event: NSEvent) -> Bool {
        tool != .select && tool != .crop && tool != .pencil && tool != .highlighter
            && !event.modifierFlags.contains(.option)
    }

    /// Select tool behaviour: grab a handle of the selected object, or select and start moving the object under
    /// the pointer. Returns true when something was grabbed.
    private func selectInteraction(_ event: NSEvent, raw: CGPoint, p: CGPoint) -> Bool {
        if let h = handleHit(at: raw), let o = selectedObject {
            if h == .control, o.kind == .arrow, event.clickCount == 2 {
                // Double-click the middle handle to straighten the arrow.
                pushUndo()
                if let i = objects.firstIndex(where: { $0.id == o.id }) { objects[i].points = [] }
                onChange?()
                needsDisplay = true
                return true
            }
            activeHandle = h
            didPushMoveUndo = false
            if case .corner(let i) = h {
                let r = o.editRect
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                               CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
                handleAnchor = corners[(i + 2) % 4]
            }
            return true
        }
        let hit = hitObject(at: p)
        selectedID = hit?.id
        movingLoupe = false
        if let hit {
            movingLast = p
            movingLoupe = hit.kind == .magnifier && hit.magLoupeContains(p, slack: 0)
            didPushMoveUndo = false
            onSelectionStyle?(hit.style)
            NSCursor.closedHand.set()
            if (hit.kind == .text || hit.kind == .callout), event.clickCount == 2 { beginTextEditing(id: hit.id) }
        }
        notifySelection()
        needsDisplay = true
        return hit != nil
    }

    override func mouseDown(with event: NSEvent) {
        endLive()
        window?.makeFirstResponder(self)
        commitTextEditing()
        frozenContent = contentRect
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let p = clampToImage(raw)
        dragStart = p
        activeHandle = nil

        interacting = false
        if canInteract(event), selectInteraction(event, raw: raw, p: p) {
            // A drawing tool is active, but the click landed on an existing object (or one of its handles).
            interacting = true
            return
        }

        if tool != .select, tool != .crop, selectedID != nil {
            selectedID = nil
            notifySelection()
            needsDisplay = true
        }

        switch effectiveTool {
        case .select:
            _ = selectInteraction(event, raw: raw, p: p)

        case .crop:
            beginCropDrag(at: raw)

        case .text:
            let obj = AnnotationObject(kind: .text, start: p, end: p, text: "", style: style, z: nextZ)
            nextZ += 1
            pushUndo()
            objects.append(obj)
            selectedID = obj.id
            beginTextEditing(id: obj.id)

        case .number:
            let used = objects.filter { $0.kind == .number }.compactMap { Int($0.text) }
            let marker = AnnotationObject(kind: .number, start: p, end: p, text: String((used.max() ?? 0) + 1),
                                          style: style, z: nextZ)
            nextZ += 1
            pushUndo()
            objects.append(marker)

        case .callout:
            // Press on the thing to point at, drag to where the text box should go.
            working = AnnotationObject(kind: .callout, start: p, end: p, style: style, z: nextZ)

        case .pencil, .highlighter:
            working = AnnotationObject(kind: tool == .pencil ? .pencil : .highlighter,
                                       start: p, end: p, points: [p], style: style, z: nextZ)

        default:
            guard var kind = tool.objectKind else { return }
            if tool == .rectangle && style.ellipse { kind = .ellipse }
            working = AnnotationObject(kind: kind, start: p, end: p, style: style, z: nextZ)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let p = clampToImage(raw)
        let shift = event.modifierFlags.contains(.shift)
        // Area to repaint: the object before and after this step (spotlight dims everything, so repaint all).
        var dirty: [CGRect] = []
        var pad: CGFloat = 8
        var full = false
        func note(_ o: AnnotationObject?) {
            guard let o else { return }
            if o.kind == .spotlight || o.kind == .callout || o.kind == .magnifier || o.rotation != 0 { full = true }
            dirty.append(o.rect)
            pad = max(pad, o.kind == .highlighter ? o.highlighterWidth : o.style.lineWidth * 3)
        }
        switch interacting ? AnnotationTool.select : effectiveTool {
        case .select:
            note(selectedObject)
            if let h = activeHandle {
                if h == .rotate { full = true }
                if !didPushMoveUndo { pushUndo(); didPushMoveUndo = true }
                dragHandle(h, to: p, constrain: shift)
                note(selectedObject)
                break
            }
            guard let id = selectedID, let last = movingLast,
                  let i = objects.firstIndex(where: { $0.id == id }) else { return }
            if !didPushMoveUndo { pushUndo(); didPushMoveUndo = true }
            if movingLoupe, objects[i].kind == .magnifier {
                let c = objects[i].magLoupeCenter
                objects[i].points = [CGPoint(x: c.x + p.x - last.x, y: c.y + p.y - last.y)]
            } else {
                objects[i].translate(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            }
            movingLast = p
            note(objects[i])
        case .crop:
            updateCropDrag(to: raw, shift: shift)
            full = true
        case .callout:
            working?.start = p
            full = true
        case .pencil, .highlighter:
            note(working)
            if shift, let first = working?.points.first {
                // Shift draws a straight stroke.
                working?.points = [first, p]
            } else {
                working?.points.append(p)
            }
            working?.end = p
            note(working)
        default:
            note(working)
            var end = p
            if shift, let w = working {
                end = constrained(from: w.start, to: p, kind: w.kind)
            }
            working?.end = end
            note(working)
        }
        let imageBounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: -pad, dy: -pad)
        let inside = dirty.allSatisfy { imageBounds.contains($0) }
        if full || dirty.isEmpty || !inside { needsDisplay = true } else { invalidate(dirty, pad: pad) }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil; movingLast = nil; movingLoupe = false; frozenContent = nil; activeHandle = nil; interacting = false; needsDisplay = true
            if hoverCursor != nil || tool == .select { NSCursor.openHand.set() }
            updateHover(event)
        }

        if tool == .crop {
            endCropDrag()
            return
        }
        if (tool == .select || interacting), activeHandle != nil {
            onChange?()
            return
        }

        guard var w = working else { return }
        working = nil
        if w.kind == .callout {
            if hypot(w.start.x - w.end.x, w.start.y - w.end.y) < 12 {
                w.start = clampToImage(CGPoint(x: w.end.x + 60, y: w.end.y + 50))
            }
            pushUndo()
            objects.append(w)
            nextZ += 1
            selectedID = w.id
            beginTextEditing(id: w.id)
            return
        }
        if w.kind == .magnifier, abs(w.end.x - w.start.x) < 14 || abs(w.end.y - w.start.y) < 14 {
            // A plain click makes a default-sized loupe around the point.
            let c = w.start
            w.start = CGPoint(x: c.x - 44, y: c.y - 30)
            w.end = CGPoint(x: c.x + 44, y: c.y + 30)
        }
        if w.kind == .pencil, w.style.smartShapes, absorbArrowHead(w) { return }
        if w.kind == .pencil, w.style.smartShapes, let shape = ShapeRecognizer.recognize(w.points) {
            // Keep the drawing as one undo step and the clean shape as the next, so undo can bring it back.
            var drawn = w
            drawn.points = AnnotationObject.simplify(w.points, epsilon: 0.8)
            pushUndo()
            objects.append(drawn)
            var made = AnnotationObject(kind: .line, z: drawn.z)
            made.style = w.style
            made.style.shapeStyle = 0
            made.style.ellipse = false
            let name: String
            switch shape {
            case .line(let a, let b):
                made.kind = .line; made.start = a; made.end = b; name = "line"
            case .arrow(let a, let b):
                made.kind = .arrow; made.start = a; made.end = b; name = "arrow"
            case .rectangle(let r):
                made.kind = .rectangle
                made.start = CGPoint(x: r.minX, y: r.minY); made.end = CGPoint(x: r.maxX, y: r.maxY); name = "rectangle"
            case .ellipse(let r):
                made.kind = .ellipse
                made.start = CGPoint(x: r.minX, y: r.minY); made.end = CGPoint(x: r.maxX, y: r.maxY); name = "ellipse"
            }
            pushUndo()
            if let i = objects.firstIndex(where: { $0.id == drawn.id }) { objects[i] = made } else { objects.append(made) }
            nextZ += 1
            selectedID = made.id
            lastSmart = (made.id, Date())
            notifySelection()
            Toast.show("Snapped to \(name). Undo keeps your drawing")
            return
        }
        if w.kind == .pencil {
            w.points = AnnotationObject.simplify(w.points, epsilon: 0.8)
        }
        if w.kind == .highlighter {
            w.points = AnnotationObject.simplify(w.points, epsilon: 1.2)
            snapHighlighterToText(&w)
        }
        let tiny = hypot(w.end.x - w.start.x, w.end.y - w.start.y) < 3 && !w.isFreehand
        if tiny { return }
        pushUndo()
        objects.append(w)
        nextZ += 1
        // Keep the new object selected so its box, handles and rotate control are right there.
        selectedID = w.isFreehand ? nil : w.id
        notifySelection()
    }

    /// Drawing the head of an arrow with the pen: a short stroke at the end of a line just made turns it into an arrow.
    private func absorbArrowHead(_ w: AnnotationObject) -> Bool {
        guard let last = lastSmart, Date().timeIntervalSince(last.time) < 3,
              let i = objects.firstIndex(where: { $0.id == last.id }),
              objects[i].kind == .line || objects[i].kind == .arrow else { return false }
        var o = objects[i]
        guard let tip = ShapeRecognizer.arrowHeadEnd(stroke: w.points, lineStart: o.start, lineEnd: o.end) else { return false }
        if o.kind == .line {
            pushUndo()
            if tip == o.start { o.start = o.end; o.end = tip }
            o.kind = .arrow
            objects[i] = o
            selectedID = o.id
            notifySelection()
        }
        lastSmart = (o.id, Date())    // a second barb is absorbed too
        needsDisplay = true
        return true
    }

    private func constrained(from s: CGPoint, to p: CGPoint, kind: AnnotationKind) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch kind {
        case .rectangle, .ellipse, .pixelate, .blur, .spotlight, .magnifier:
            let m = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -m : m), y: s.y + (dy < 0 ? -m : m))
        default:
            // Snap lines and arrows to 45 degree steps.
            let angle = atan2(dy, dx)
            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(snapped) * len, y: s.y + sin(snapped) * len)
        }
    }

    private func hitObject(at p: CGPoint) -> AnnotationObject? {
        let tolerance = 8 / max(fitScale, 0.05)
        for object in objects.sorted(by: { $0.z > $1.z }) where object.hitTest(p, tolerance: tolerance) {
            return object
        }
        return nil
    }

    // MARK: - Highlighter: smart text size

    /// A roughly horizontal stroke over a line of text becomes a straight band exactly as tall as that line.
    private func snapHighlighterToText(_ o: inout AnnotationObject) {
        let r = o.rect
        guard r.width > 12, r.height < max(r.width * 0.35, 6) else { return }
        let full = CGRect(origin: .zero, size: imageSize)
        let region = CGRect(x: r.minX - 12, y: r.minY - 48, width: r.width + 24, height: r.height + 96)
            .integral.intersection(full)
        guard !region.isNull, region.width > 8, region.height > 8, let crop = baseImage.cropping(to: region) else { return }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        let midY = r.midY
        var best: CGRect?
        for obs in request.results ?? [] {
            let b = obs.boundingBox     // normalised, bottom-left origin within the crop
            let box = CGRect(x: region.minX + b.minX * region.width,
                             y: region.minY + (1 - b.maxY) * region.height,
                             width: b.width * region.width, height: b.height * region.height)
            guard box.minX < r.maxX, box.maxX > r.minX else { continue }
            let d = abs(box.midY - midY)
            guard d < box.height else { continue }
            if let current = best, abs(current.midY - midY) <= d { continue }
            best = box
        }
        guard let line = best else { return }
        o.thickness = line.height * 1.2
        o.points = [CGPoint(x: r.minX, y: line.midY), CGPoint(x: r.maxX, y: line.midY)]
        o.start = o.points[0]
        o.end = o.points[1]
    }

    // MARK: - Crop

    private var snapDistance: CGFloat { 10 / max(fitScale, 0.05) }

    /// Snaps a point to the picture's edges and centre lines.
    private func snapped(_ p: CGPoint) -> CGPoint {
        let t = snapDistance
        var q = p
        for x in [0, imageSize.width / 2, imageSize.width] where abs(p.x - x) < t { q.x = x }
        for y in [0, imageSize.height / 2, imageSize.height] where abs(p.y - y) < t { q.y = y }
        return CGPoint(x: min(max(q.x, 0), imageSize.width), y: min(max(q.y, 0), imageSize.height))
    }

    private func beginCropDrag(at raw: CGPoint) {
        let p = snapped(raw)
        if let c = pendingCrop ?? cropRect {
            let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
                           CGPoint(x: c.maxX, y: c.maxY), CGPoint(x: c.minX, y: c.maxY)]
            let r = 10 / max(fitScale, 0.05)
            if let i = corners.firstIndex(where: { hypot($0.x - raw.x, $0.y - raw.y) <= r }) {
                cropDrag = .corner(corners[(i + 2) % 4])
                pendingCrop = c
                return
            }
            if c.contains(raw) {
                cropDrag = .move(CGPoint(x: raw.x - c.minX, y: raw.y - c.minY))
                pendingCrop = c
                return
            }
        }
        cropDrag = .new
        dragStart = p
        pendingCrop = CGRect(origin: p, size: .zero)
    }

    private func rectFrom(anchor a: CGPoint, to p: CGPoint, aspect: CGFloat?) -> CGRect {
        var q = p
        if let aspect, aspect > 0 {
            let dx = q.x - a.x, dy = q.y - a.y
            let w = max(abs(dx), abs(dy) * aspect)
            q = CGPoint(x: a.x + (dx < 0 ? -w : w), y: a.y + (dy < 0 ? -w / aspect : w / aspect))
        }
        let r = CGRect(x: min(a.x, q.x), y: min(a.y, q.y), width: abs(q.x - a.x), height: abs(q.y - a.y))
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    private func updateCropDrag(to raw: CGPoint, shift: Bool) {
        let p = snapped(raw)
        let aspect = cropAspect ?? (shift ? 1 : nil)
        switch cropDrag {
        case .new:
            if let s = dragStart { pendingCrop = rectFrom(anchor: s, to: p, aspect: aspect) }
        case .corner(let anchor):
            pendingCrop = rectFrom(anchor: anchor, to: p, aspect: aspect)
        case .move(let offset):
            guard let c = pendingCrop else { return }
            var x = raw.x - offset.x, y = raw.y - offset.y
            x = min(max(x, 0), imageSize.width - c.width)
            y = min(max(y, 0), imageSize.height - c.height)
            let moved = CGRect(x: x, y: y, width: c.width, height: c.height)
            let s = snapped(moved.origin)
            pendingCrop = CGRect(origin: CGPoint(x: min(s.x, imageSize.width - c.width), y: min(s.y, imageSize.height - c.height)),
                                 size: c.size)
        case nil:
            break
        }
    }

    private func endCropDrag() {
        defer { cropDrag = nil }
        guard let c = pendingCrop, !c.isNull, c.width >= 8, c.height >= 8 else {
            pendingCrop = nil
            return
        }
        if c != cropRect {
            pushUndo()
            cropRect = c
            onChange?()
        }
        pendingCrop = nil
    }

    /// Applies an aspect ratio to the current crop (or a centred one).
    func applyCropAspect(_ aspect: CGFloat?) {
        cropAspect = aspect
        guard let aspect else { return }
        let full = CGRect(origin: .zero, size: imageSize)
        let base = cropRect ?? full
        var w = base.width, h = base.width / aspect
        if h > base.height { h = base.height; w = h * aspect }
        let r = CGRect(x: base.midX - w / 2, y: base.midY - h / 2, width: w, height: h).intersection(full)
        pushUndo()
        cropRect = r
        needsDisplay = true
        onChange?()
    }

    // MARK: - Zoom and pan gestures

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification * 1.2), anchor: convert(event.locationInWindow, from: nil), live: true)
    }

    /// Two-finger twist turns the selected annotation.
    override func rotate(with event: NSEvent) {
        guard let id = selectedID, let i = objects.firstIndex(where: { $0.id == id }), objects[i].supportsRotation else { return }
        if event.phase == .began { pushUndo() }
        objects[i].rotation = Self.normalized(objects[i].rotation - CGFloat(event.rotation))
        onSelectionRotation?(selectedRotation)
        if event.phase == .ended { onChange?() }
        needsDisplay = true
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(zoom - 1) > 0.01 { fitView() } else { actualSize() }
    }

    override func scrollWheel(with event: NSEvent) {
        // A mouse wheel zooms around the pointer; two-finger scrolling pans (pinch, or hold ⌘ / ⌥, to zoom).
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || !event.hasPreciseScrollingDeltas {
            let factor = exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.016 : 0.09))
            setZoom(zoom * factor, anchor: convert(event.locationInWindow, from: nil), live: true)
        } else {
            commitTextEditing()
            beginLive()
            pan.x += event.scrollingDeltaX
            pan.y += event.scrollingDeltaY
            clampPan()
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // This is a menu-bar app with no Edit menu, so handle the standard shortcuts here.
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) { redo() } else { undo() }
            return
        }
        if flags.contains(.command), let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "=", "+": zoomIn(); return
            case "-": zoomOut(); return
            case "0": fitView(); return
            case "1": actualSize(); return
            case "c": onCopyShortcut?(); return
            case "s": onSaveShortcut?(); return
            case "v": if pasteImage() { return }
            default: break
            }
        }
        // Return or Enter finishes cropping and shows the result.
        if tool == .crop, event.keyCode == 36 || event.keyCode == 76 { tool = .select; return }
        // Arrow keys nudge the selection (Shift = 10 px).
        if let arrow = [123: CGVector(dx: -1, dy: 0), 124: CGVector(dx: 1, dy: 0),
                        125: CGVector(dx: 0, dy: 1), 126: CGVector(dx: 0, dy: -1)][Int(event.keyCode)],
           let id = selectedID, let i = objects.firstIndex(where: { $0.id == id }) {
            let k: CGFloat = flags.contains(.shift) ? 10 : 1
            pushUndo()
            objects[i].translate(by: CGVector(dx: arrow.dx * k, dy: arrow.dy * k))
            needsDisplay = true
            return
        }
        if flags.isEmpty || flags == .shift {
            if event.keyCode == 51 || event.keyCode == 117 { deleteSelected(); return }   // delete / forward delete
            if event.keyCode == 53 {
                if tool == .crop { pendingCrop = nil; tool = .select; return }
                selectedID = nil
                needsDisplay = true
                return
            }
            if let ch = event.charactersIgnoringModifiers?.lowercased(),
               let match = AnnotationTool.allCases.first(where: { $0.key == ch }) {
                tool = match
                return
            }
        }
        super.keyDown(with: event)
    }

    // MARK: - Text editing

    private func beginTextEditing(id: UUID) {
        guard let obj = objects.first(where: { $0.id == id }) else { return }
        editingID = id
        let s = fitScale
        let origin = toView(obj.start)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y,
                                              width: max(160, obj.rect.width * s + 40),
                                              height: obj.style.fontSize * s * 1.5 + 8))
        field.stringValue = obj.text
        field.font = NSFont.systemFont(ofSize: max(obj.style.fontSize * s, 10), weight: .medium)
        if obj.kind == .callout {
            field.font = NSFont.systemFont(ofSize: max(obj.style.fontSize * s, 10), weight: .semibold)
            field.textColor = .white
            field.backgroundColor = obj.style.color
        } else {
            field.textColor = obj.style.color
            field.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        }
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .exterior
        field.placeholderString = "Type text, press Return"
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let id = editingID, let i = objects.firstIndex(where: { $0.id == id }),
              let field = textField else { return }
        objects[i].text = field.stringValue
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            commitTextEditing()
            return true
        }
        return false
    }

    func commitTextEditing() {
        guard let field = textField, let id = editingID else { return }
        let value = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        textField = nil
        editingID = nil
        if let i = objects.firstIndex(where: { $0.id == id }) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                objects.remove(at: i)
                if selectedID == id { selectedID = nil }
            } else {
                objects[i].text = value
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
        onChange?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let f = imageFrame, s = fitScale
        let hiddenText = editingID

        if let l = live {
            // While pinching or scrolling, move a bitmap of the last full render (cheap) and redraw crisply
            // once the gesture settles.
            let k = s / l.scale
            let rect = CGRect(x: f.minX - l.origin.x * k, y: f.minY - l.origin.y * k,
                              width: bounds.width * k, height: bounds.height * k)
            ctx.interpolationQuality = .medium
            AnnotationRenderer.drawImage(ctx, l.image, in: rect)
        } else {
            drawContent(ctx)
        }

        // Handles in view space, so they stay the same size at any zoom.
        if tool != .crop, let obj = selectedObject, obj.id != hiddenText {
            for (h, p) in handles(for: obj) {
                if h == .rotate {
                    // Tether from the top of the box to the rotate handle.
                    let r = obj.rect
                    let a = obj.rotation * .pi / 180
                    let half = r.height / 2
                    let top = CGPoint(x: r.midX + half * sin(a), y: r.midY - half * cos(a))
                    let t = toView(top), v = toView(p)
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.move(to: t)
                    ctx.addLine(to: v)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                drawHandle(at: toView(p), in: ctx)
            }
            if activeHandle == .rotate, let rp = handles(for: obj).first(where: { $0.0 == .rotate })?.1 {
                drawPill("\(Int(obj.rotation.rounded()))°", near: toView(rp))
            }
        }

        if tool == .crop { drawCropOverlay(ctx, frame: f, scale: s) }
    }

    /// Everything except handles and the crop overlay: backdrop, picture and annotations.
    private func drawContent(_ ctx: CGContext) {
        let f = imageFrame, s = fitScale
        let visible = shownRect
        let cv = viewRect(visible)
        let clipPath: CGPath

        if showsBackground {
            // Backdrop exactly as the export draws it, scaled to the view.
            let backdrop = viewRect(presentationRect)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(backdrop)
            ctx.restoreGState()
            BackgroundMaker.drawFill(background, in: ctx, rect: backdrop, flipped: true)

            let radius = BackgroundMaker.radius(background, contentSize: visible.size) * s
            clipPath = CGPath(roundedRect: cv, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let sh = BackgroundMaker.shadowParams(background, contentSize: visible.size)
            if sh.alpha > 0 {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -sh.offset * s), blur: sh.blur * s,
                              color: NSColor.black.withAlphaComponent(sh.alpha).cgColor)
                ctx.addPath(clipPath)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            if visible != CGRect(origin: .zero, size: imageSize) {
                ctx.saveGState()
                ctx.addPath(clipPath)
                ctx.clip()
                drawChecker(ctx, in: cv, white: extendFillWhite)
                ctx.restoreGState()
            }
        } else {
            let canvasView = viewRect(contentRect)
            clipPath = CGPath(rect: canvasView, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(canvasView)
            ctx.restoreGState()
            if contentRect != CGRect(origin: .zero, size: imageSize) { drawChecker(ctx, in: canvasView, white: extendFillWhite) }
        }

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.translateBy(x: f.minX, y: f.minY)
        ctx.scaleBy(x: s, y: s)
        ctx.interpolationQuality = .high

        var all = objects
        if let w = working { all.append(w) }
        // Hide text that is currently being edited in the field overlay.
        let hiddenText = editingID
        let drawList = all.filter { $0.id != hiddenText || $0.kind == .callout }
        let pixelWidth = Int((f.width * (window?.backingScaleFactor ?? 2)).rounded())
        if let small = displayBase(forPixelWidth: pixelWidth) {
            AnnotationRenderer.drawImage(ctx, small, in: CGRect(origin: .zero, size: imageSize))
        } else {
            AnnotationRenderer.drawImage(ctx, baseImage, in: CGRect(origin: .zero, size: imageSize))
        }
        AnnotationRenderer.render(into: ctx, base: baseImage, objects: drawList, imageSize: imageSize, drawBase: false)

        // Selection outline
        if let obj = selectedObject, obj.id != hiddenText {
            let base = obj.rect
            let r = base.insetBy(dx: -6 / s, dy: -6 / s)
            ctx.saveGState()
            if obj.rotation != 0, obj.supportsRotation {
                // The box turns with the object.
                ctx.translateBy(x: base.midX, y: base.midY)
                ctx.rotate(by: obj.rotation * .pi / 180)
                ctx.translateBy(x: -base.midX, y: -base.midY)
            }
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / s)
            ctx.setLineDash(phase: 0, lengths: [5 / s, 4 / s])
            ctx.stroke(r)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Transparent-looking backdrop for the part of the canvas that has no picture.
    private func drawChecker(_ ctx: CGContext, in rect: CGRect, white: Bool) {
        if white {
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
            return
        }
        let r = rect.intersection(bounds.insetBy(dx: -20, dy: -20))
        guard !r.isNull else { return }
        let t: CGFloat = 10
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
        ctx.fill(r)
        ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        let i0 = Int(floor((r.minX - rect.minX) / t)), i1 = Int(ceil((r.maxX - rect.minX) / t))
        let j0 = Int(floor((r.minY - rect.minY) / t)), j1 = Int(ceil((r.maxY - rect.minY) / t))
        for j in j0..<max(j1, j0) {
            for i in i0..<max(i1, i0) where (i + j) & 1 == 1 {
                ctx.fill(CGRect(x: rect.minX + CGFloat(i) * t, y: rect.minY + CGFloat(j) * t, width: t, height: t))
            }
        }
        ctx.restoreGState()
    }

    /// Small dark label next to a point (used for the rotation angle).
    private func drawPill(_ text: String, near p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pill = CGRect(x: p.x + 14, y: p.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        str.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 3))
    }

    private func drawHandle(at p: CGPoint, in ctx: CGContext) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: r)
    }

    private func drawCropOverlay(_ ctx: CGContext, frame f: CGRect, scale s: CGFloat) {
        guard let r = pendingCrop ?? cropRect else { return }
        let vr = viewRect(r)
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(f)
        path.addRect(vr)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(pendingCrop != nil ? 0.5 : 0.6).cgColor)
        ctx.fillPath(using: .evenOdd)
        // Rule-of-thirds guides
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        for k in 1...2 {
            let x = vr.minX + vr.width * CGFloat(k) / 3, y = vr.minY + vr.height * CGFloat(k) / 3
            ctx.move(to: CGPoint(x: x, y: vr.minY)); ctx.addLine(to: CGPoint(x: x, y: vr.maxY))
            ctx.move(to: CGPoint(x: vr.minX, y: y)); ctx.addLine(to: CGPoint(x: vr.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(vr)
        ctx.restoreGState()
        for p in [CGPoint(x: vr.minX, y: vr.minY), CGPoint(x: vr.maxX, y: vr.minY),
                  CGPoint(x: vr.maxX, y: vr.maxY), CGPoint(x: vr.minX, y: vr.maxY)] {
            drawHandle(at: p, in: ctx)
        }

        let label = "\(Int(r.width)) × \(Int(r.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        let pill = CGRect(x: vr.minX, y: max(vr.minY - size.height - 10, 2), width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        str.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3))
    }

    override func setFrameSize(_ newSize: NSSize) {
        endLive()
        super.setFrameSize(newSize)
        clampPan()
        window?.invalidateCursorRects(for: self)
    }
}
