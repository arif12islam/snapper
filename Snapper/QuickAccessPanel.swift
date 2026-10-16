import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Non-activating panel that can still take key presses once the pointer is over it,
/// so ⌘C / ⌘S / ⌘W / ⌘E / ⌘U / ⌘T / ⌘P work without stealing focus from the user's app.
/// Two-finger horizontal swipes are caught here: towards the screen edge closes, away saves.
private final class QuickAccessWindow: NSPanel {
    var shortcuts: [String: () -> Void] = [:]
    var onSwipe: ((CGFloat, Bool) -> Void)?                 // (finger dx so far, ended)
    var onMagnify: ((CGFloat, CGPoint) -> Void)?             // (factor, location in the window)
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onResetZoom: (() -> Void)?
    var cardIsZoomed: () -> Bool = { false }

    private enum ScrollMode { case swipe, zoom, pan }
    private var scrollMode: ScrollMode?
    private var swipeDX: CGFloat = 0

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased(), let handler = shortcuts[key] {
            handler()
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "s", let h = shortcuts["S"] {
            h()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        shortcuts["w"]?()      // Esc closes
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .magnify:
            onMagnify?(1 + event.magnification, event.locationInWindow)
            return
        case .smartMagnify:
            onResetZoom?()
            return
        case .scrollWheel:
            if handleScroll(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Mouse wheel and vertical two-finger scrolling zoom the picture, horizontal two-finger swipes dismiss or
    /// save the card, and while zoomed in, two-finger scrolling pans.
    private func handleScroll(_ event: NSEvent) -> Bool {
        let precise = event.hasPreciseScrollingDeltas
        if !precise {
            onMagnify?(exp(event.scrollingDeltaY * 0.08), event.locationInWindow)
            return true
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            scrollMode = nil
            swipeDX = 0
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if scrollMode == nil, dx != 0 || dy != 0 {
            if event.modifierFlags.contains(.option) {
                scrollMode = .zoom
            } else if cardIsZoomed() {
                scrollMode = .pan
            } else {
                scrollMode = abs(dx) > abs(dy) ? .swipe : .zoom
            }
        }
        guard let mode = scrollMode else { return true }
        switch mode {
        case .zoom:
            if dy != 0 { onMagnify?(exp(dy * 0.012), event.locationInWindow) }
        case .pan:
            onPan?(dx, dy)
        case .swipe:
            if event.momentumPhase != [] { return true }
            // Normalise to finger movement regardless of the "natural scrolling" setting.
            swipeDX += event.isDirectionInvertedFromDevice ? dx : -dx
            let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            onSwipe?(swipeDX, ended)
            if ended { swipeDX = 0 }
        }
        return true
    }
}

/// Zoom and pan of the picture inside the card (the card itself never changes size).
final class CardZoom: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var offset: CGSize = .zero

    var isZoomed: Bool { zoom > 1.001 }

    func apply(factor: CGFloat, at p: CGPoint, in size: CGSize) {
        let newZoom = min(max(zoom * factor, 1), 8)
        guard newZoom != zoom else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let k = newZoom / zoom
        let off = CGSize(width: (p.x - c.x) - ((p.x - c.x) - offset.width) * k,
                         height: (p.y - c.y) - ((p.y - c.y) - offset.height) * k)
        zoom = newZoom
        offset = Self.clamp(off, zoom: newZoom, size: size)
    }

    func pan(dx: CGFloat, dy: CGFloat, in size: CGSize) {
        offset = Self.clamp(CGSize(width: offset.width + dx, height: offset.height + dy), zoom: zoom, size: size)
    }

    func reset() {
        zoom = 1
        offset = .zero
    }

    private static func clamp(_ o: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let mx = (zoom - 1) * size.width / 2, my = (zoom - 1) * size.height / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}

@MainActor
final class QuickAccessPanel: NSObject {
    enum Item {
        case image(CaptureResult)
        case video(url: URL, screen: NSScreen, thumbnail: CGImage?, duration: Double)

        var screen: NSScreen {
            switch self {
            case .image(let r): return r.screen
            case .video(_, let s, _, _): return s
            }
        }
    }

    /// Visible overlays, oldest first (newest sits in the corner, older ones stack away from it).
    private static var stack: [QuickAccessPanel] = []
    private static var recentlyClosed: [Item] = []
    private(set) static var overlaysHidden = false
    private static let maxVisible = 5

    private let item: Item
    private let panel: QuickAccessWindow
    private var hosting: NSHostingView<QuickAccessView>?
    private let fileURL: URL           // temp PNG for images, the movie itself for videos
    private let pngData: Data?
    private let nsImage: NSImage
    private let kindLabel: String
    private let date: Date
    private let pixelSize: CGSize
    let cardSize: CGSize
    private let infoString: String
    private var hovering = false
    private let zoomModel = CardZoom()
    private var autoCloseWork: DispatchWorkItem?
    private var dragMonitor: Any?
    private var restingOrigin: CGPoint = .zero

    // MARK: - Public entry points

    static func show(for result: CaptureResult) {
        present(.image(result))
    }

    static func showVideo(url: URL, screen: NSScreen) {
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            let thumb = try? await generator.image(at: CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)).image
            present(.video(url: url, screen: screen, thumbnail: thumb, duration: duration))
        }
    }

    private static func present(_ item: Item) {
        if overlaysHidden { setHidden(false) }
        let p = QuickAccessPanel(item: item)
        stack.append(p)
        while stack.count > maxVisible { stack.first?.close(remember: true) }
        p.open()
        relayout(animated: true)
    }

    /// Re-opens the most recently closed overlay. Returns false when there is none.
    @discardableResult
    static func restoreRecentlyClosed() -> Bool {
        guard let item = recentlyClosed.popLast() else { return false }
        present(item)
        return true
    }

    static var hasRecentlyClosed: Bool { !recentlyClosed.isEmpty }

    /// "Temporarily hide overlays": out of the way for a screenshot or screen share, back with one click.
    static func setHidden(_ hidden: Bool) {
        overlaysHidden = hidden
        for p in stack {
            if hidden { p.cancelAutoClose(); p.panel.orderOut(nil) } else { p.panel.orderFrontRegardless(); p.scheduleAutoClose() }
        }
    }

    static func toggleHidden() { setHidden(!overlaysHidden) }

    static func closeAll() {
        for p in stack { p.close(remember: true) }
    }

    // MARK: - Layout

    private static var cornerIsRight: Bool { AppSettings.qaPosition == 0 || AppSettings.qaPosition == 2 }
    private static var cornerIsBottom: Bool { AppSettings.qaPosition == 0 || AppSettings.qaPosition == 1 }

    private static func relayout(animated: Bool) {
        let margin: CGFloat = 16, gap: CGFloat = 10
        var offsets: [ObjectIdentifier: CGFloat] = [:]       // per screen
        for p in stack.reversed() {
            let screen = p.item.screen
            let key = ObjectIdentifier(screen)
            let used = offsets[key] ?? 0
            let vf = screen.visibleFrame
            let size = p.cardSize
            let x = cornerIsRight ? vf.maxX - size.width - margin : vf.minX + margin
            let y = cornerIsBottom ? vf.minY + margin + used : vf.maxY - margin - used - size.height
            offsets[key] = used + size.height + gap
            let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            p.restingOrigin = frame.origin
            if animated, p.panel.isVisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    p.panel.animator().setFrame(frame, display: true)
                }
            } else {
                p.panel.setFrame(frame, display: true)
            }
        }
    }

    static func downsample(_ image: CGImage, maxPixel: Int) -> CGImage {
        let w = image.width, h = image.height
        let k = Double(maxPixel) / Double(max(w, h))
        guard k < 1 else { return image }
        let nw = max(1, Int(Double(w) * k)), nh = max(1, Int(Double(h) * k))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? image
    }

    /// Card size: the capture scaled to fit, multiplied by the size setting.
    private static func cardSize(for pixels: CGSize) -> CGSize {
        let k: CGFloat = [0.8, 1.0, 1.3][min(max(AppSettings.qaSize, 0), 2)]
        let maxW: CGFloat = 260 * k, maxH: CGFloat = 160 * k
        let minW: CGFloat = 240 * k, minH: CGFloat = 104 * k
        let scale = min(maxW / max(pixels.width, 1), maxH / max(pixels.height, 1), 1)
        return CGSize(width: max(pixels.width * scale, minW), height: max(pixels.height * scale, minH))
    }

    // MARK: - Init

    private init(item: Item) {
        self.item = item
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let pixels: CGSize
        let image: NSImage
        switch item {
        case .image(let result):
            let data = result.pngData ?? Data()
            pixels = CGSize(width: result.image.width, height: result.image.height)
            let name = FileNamer.name(kind: result.kind.rawValue.capitalized, width: Int(pixels.width),
                                      height: Int(pixels.height), date: result.date)
            // A per-capture folder keeps the real file name for drag and drop.
            let sub = dir.appendingPathComponent(result.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let url = sub.appendingPathComponent(name)
            try? data.write(to: url)
            fileURL = url
            pngData = data
            // Show a downsampled copy: the card is small, the capture may be 6K.
            let preview = Self.downsample(result.image, maxPixel: 720)
            image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
            kindLabel = result.kind.rawValue.capitalized
            date = result.date
            let kb = max(1, Int((Double(data.count) / 1024.0).rounded()))
            let size = kb >= 1024 ? String(format: "%.1f MB", Double(kb) / 1024) : "\(kb) KB"
            infoString = "\(Int(pixels.width)) × \(Int(pixels.height))  ·  \(size)"
        case .video(let url, _, let thumb, let duration):
            fileURL = url
            pngData = nil
            if let thumb {
                pixels = CGSize(width: thumb.width, height: thumb.height)
                image = NSImage(cgImage: thumb, size: NSSize(width: thumb.width, height: thumb.height))
            } else {
                pixels = CGSize(width: 320, height: 200)
                image = NSImage(systemSymbolName: "film", accessibilityDescription: nil) ?? NSImage()
            }
            kindLabel = url.pathExtension.lowercased() == "gif" ? "GIF" : "Recording"
            date = Date()
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mb = Double(bytes) / 1_048_576
            let secs = Int(duration.rounded())
            infoString = String(format: "%d:%02d  ·  %.1f MB", secs / 60, secs % 60, mb)
        }
        let card = Self.cardSize(for: pixels)
        self.pixelSize = pixels
        self.nsImage = image
        self.cardSize = card

        let p = QuickAccessWindow(contentRect: NSRect(origin: .zero, size: card),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = p

        super.init()

        p.shortcuts = [
            "c": { [weak self] in self?.copy() },
            "s": { [weak self] in self?.save(askLocation: false) },
            "S": { [weak self] in self?.save(askLocation: true) },
            "w": { [weak self] in self?.close(remember: true) },
            "e": { [weak self] in self?.edit() },
            "u": { [weak self] in self?.upload() },
            "t": { [weak self] in self?.copyText() },
            "p": { [weak self] in self?.pin() }
        ]
        p.onSwipe = { [weak self] dx, ended in self?.handleSwipe(dx: dx, ended: ended) }
        p.cardIsZoomed = { [weak self] in self?.zoomModel.isZoomed ?? false }
        p.onMagnify = { [weak self] factor, location in
            guard let self else { return }
            self.cancelAutoClose()
            // Window coordinates have their origin at the bottom left; the view works from the top left.
            let point = CGPoint(x: location.x, y: self.cardSize.height - location.y)
            self.zoomModel.apply(factor: factor, at: point, in: self.cardSize)
        }
        p.onPan = { [weak self] dx, dy in
            guard let self else { return }
            self.zoomModel.pan(dx: dx, dy: dy, in: self.cardSize)
        }
        p.onResetZoom = { [weak self] in self?.zoomModel.reset() }

        let host = NSHostingView(rootView: makeView())
        host.frame = NSRect(origin: .zero, size: card)
        host.autoresizingMask = [.width, .height]
        // One rounded, anti-aliased container clips everything (picture, dim layer, buttons) so the corners stay
        // clean when hovering. The window shadow follows its shape.
        let container = NSView(frame: NSRect(origin: .zero, size: card))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        container.addSubview(host)
        p.contentView = container
        hosting = host
        DispatchQueue.main.async { p.invalidateShadow() }
    }

    private var isVideo: Bool {
        if case .video = item { return true }
        return false
    }

    private func makeView() -> QuickAccessView {
        QuickAccessView(
            image: nsImage,
            size: cardSize,
            infoString: infoString,
            kindLabel: kindLabel,
            fileURL: fileURL,
            isVideo: isVideo,
            hovering: hovering,
            zoom: zoomModel,
            onSave: { [weak self] in
                let ask = NSEvent.modifierFlags.contains(.option)
                self?.save(askLocation: ask)
            },
            onCopy: { [weak self] in self?.copy() },
            onEdit: { [weak self] in self?.edit() },
            onPin: { [weak self] in self?.pin() },
            onText: { [weak self] in self?.copyText() },
            onUpload: { [weak self] in self?.upload() },
            onClose: { [weak self] in self?.close(remember: true) },
            onDragStart: { [weak self] in DispatchQueue.main.async { self?.dragStarted() } },
            onHoverChange: { [weak self] inside in
                DispatchQueue.main.async { self?.setHovering(inside) }
            }
        )
    }

    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            cancelAutoClose()
            panel.makeKey()           // enables the ⌘ shortcuts without activating the app
        } else {
            scheduleAutoClose()
        }
        hosting?.rootView = makeView()
        panel.invalidateShadow()
    }

    private func open() {
        panel.alphaValue = 0
        if !Self.overlaysHidden { panel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        scheduleAutoClose()
    }

    func close(remember: Bool) {
        cancelAutoClose()
        if let m = dragMonitor { NSEvent.removeMonitor(m); dragMonitor = nil }
        panel.orderOut(nil)
        if remember {
            Self.recentlyClosed.append(item)
            if Self.recentlyClosed.count > 10 { Self.recentlyClosed.removeFirst() }
        }
        if !isVideo {
            // Keep the temp file a little longer in case a drag is still being delivered.
            let dir = fileURL.deletingLastPathComponent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: dir) }
        }
        Self.stack.removeAll { $0 === self }
        Self.relayout(animated: true)
    }

    func cancelAutoClose() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
    }

    private func scheduleAutoClose() {
        cancelAutoClose()
        guard AppSettings.autoClosePanel, !hovering, !Self.overlaysHidden else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.close(remember: true) }
        }
        autoCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.autoCloseSeconds, execute: work)
    }

    // MARK: - Swipe

    private func handleSwipe(dx: CGFloat, ended: Bool) {
        let towardEdge = Self.cornerIsRight ? dx : -dx
        if ended {
            if towardEdge > 70 {
                slideAway(toEdge: true)
                close(remember: true)
            } else if towardEdge < -70 {
                save(askLocation: false)
                if !AppSettings.closeAfterSave { snapBack() }
            } else {
                snapBack()
            }
            return
        }
        cancelAutoClose()
        var f = panel.frame
        f.origin.x = restingOrigin.x + max(min(dx, 120), -120) * 0.8
        panel.setFrame(f, display: true)
        panel.alphaValue = max(0.3, 1 - abs(dx) / 240)
    }

    private func snapBack() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrameOrigin(restingOrigin)
            panel.animator().alphaValue = 1
        }
        if !hovering { scheduleAutoClose() }
    }

    private func slideAway(toEdge: Bool) {
        let target = CGPoint(x: restingOrigin.x + (Self.cornerIsRight ? 300 : -300), y: restingOrigin.y)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 0
        }
    }

    // MARK: - Drag out

    private func dragStarted() {
        cancelAutoClose()
        guard AppSettings.closeAfterDrag, dragMonitor == nil else { return }
        // Close once the drop has happened (the mouse button comes up somewhere else).
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let m = self.dragMonitor { NSEvent.removeMonitor(m); self.dragMonitor = nil }
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.close(remember: true)
            }
        }
    }

    // MARK: - Actions

    private var suggestedName: String {
        if isVideo { return fileURL.lastPathComponent }
        return FileNamer.name(kind: kindLabel, width: Int(pixelSize.width), height: Int(pixelSize.height), date: date)
    }

    /// Save: straight into the save folder (Settings), or ask where with ⌥ / ⇧⌘S.
    private func save(askLocation: Bool) {
        cancelAutoClose()
        var destination: URL?
        if askLocation {
            NSApp.activate(ignoringOtherApps: true)
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = isVideo ? [UTType(filenameExtension: fileURL.pathExtension) ?? .movie] : [.png]
            savePanel.directoryURL = AppSettings.saveFolder
            savePanel.nameFieldStringValue = suggestedName
            guard savePanel.runModal() == .OK, let url = savePanel.url else { scheduleAutoClose(); return }
            destination = url
        } else {
            let folder = AppSettings.saveFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = Self.uniqueURL(folder.appendingPathComponent(suggestedName))
        }
        guard let dest = destination else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: fileURL, to: dest)
            Toast.show("Saved to \(dest.deletingLastPathComponent().lastPathComponent)", on: item.screen, seconds: 1.4)
        } catch {
            Toast.show(error.localizedDescription, on: item.screen, seconds: 4)
        }
        if AppSettings.closeAfterSave { close(remember: true) } else { scheduleAutoClose() }
    }

    private static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let data = pngData {
            pb.setData(data, forType: .png)
        } else {
            pb.writeObjects([fileURL as NSURL])
        }
        Toast.show("Copied to clipboard", on: item.screen, seconds: 1.4)
        if AppSettings.closeAfterCopy { close(remember: true) } else { scheduleAutoClose() }
    }

    private func edit() {
        cancelAutoClose()
        switch item {
        case .image(let r):
            close(remember: true)
            AnnotateWindowController.open(image: r.image)
        case .video(let url, _, _, _):
            close(remember: true)
            VideoWindowController.open(url: url)
        }
    }

    private func pin() {
        guard case .image(let r) = item else { return }
        close(remember: true)
        PinPanel.pin(r.image, near: r.screen)
    }

    private func copyText() {
        guard case .image(let r) = item else { return }
        cancelAutoClose()
        let target = item.screen
        Task {
            Toast.show("Reading text…", on: target, seconds: 10)
            let output = await OCR.analyze(r.image)
            if !output.text.isEmpty || !output.codes.isEmpty {
                let combined = ([output.text] + output.codes).filter { !$0.isEmpty }.joined(separator: "\n")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(combined, forType: .string)
                let what = output.codes.isEmpty ? "\(output.text.count) characters" : "text and \(output.codes.count) code(s)"
                Toast.show("Copied \(what)", on: target)
            } else if let error = output.error {
                Toast.show("Couldn\u{2019}t read the text (\(error)). Details in ~/Library/Logs/Snapper/ocr.log", on: target, seconds: 6)
            } else {
                Toast.show("No text found", on: target)
            }
            scheduleAutoClose()
        }
    }

    /// Upload; ⌥-click asks for a password and expiry first.
    private func upload() {
        cancelAutoClose()
        let target = item.screen
        var options = UploadOptions.defaults
        if NSEvent.modifierFlags.contains(.option) {
            guard let chosen = UploadOptions.ask() else { scheduleAutoClose(); return }
            options = chosen
        }
        let name = suggestedName
        let type = isVideo ? (fileURL.pathExtension.lowercased() == "gif" ? "image/gif" : "video/mp4") : "image/png"
        let data = pngData ?? (try? Data(contentsOf: fileURL))
        guard let payload = data else { return }
        Toast.show("Uploading…", on: target, seconds: 60)
        Task {
            do {
                let link = try await Uploader.upload(data: payload, fileName: name, contentType: type, options: options)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link.absoluteString, forType: .string)
                Toast.show(options.password.isEmpty ? "Link copied" : "Link copied (password protected)", on: target)
            } catch {
                Toast.show(error.localizedDescription, on: target, seconds: 5)
            }
            scheduleAutoClose()
        }
    }
}

// MARK: - View

/// Compact card: just the capture. Hovering dims it and reveals a row of icon buttons.
/// State is passed in (no @State) and the panel swaps `rootView` when hover changes.
private struct QuickAccessView: View {
    let image: NSImage
    let size: CGSize
    let infoString: String
    let kindLabel: String
    let fileURL: URL
    let isVideo: Bool
    let hovering: Bool
    @ObservedObject var zoom: CardZoom
    let onSave: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onPin: () -> Void
    let onText: () -> Void
    let onUpload: () -> Void
    let onClose: () -> Void
    let onDragStart: () -> Void
    let onHoverChange: (Bool) -> Void

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: isVideo ? .fill : .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(zoom.zoom, anchor: .center)
                .offset(zoom.offset)
                .frame(width: size.width, height: size.height)
                .clipped()

            if isVideo && !hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 4)
            }

            if hovering {
                Color.black.opacity(0.38)
            }

            VStack(spacing: 0) {
                HStack {
                    if hovering {
                        roundButton("xmark", help: "Close (esc). Swipe towards the edge to dismiss", action: onClose)
                    }
                    Spacer()
                    if hovering { infoPill }
                }
                Spacer()
                if hovering {
                    actionBar
                } else {
                    HStack {
                        infoPill
                        Spacer()
                    }
                }
            }
            .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .onDrag {
            onDragStart()
            return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
        }
        .onHover { inside in onHoverChange(inside) }
        .environment(\.colorScheme, .dark)
    }

    private var infoPill: some View {
        Text("\(kindLabel)  ·  \(infoString)")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.5)))
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            iconButton("doc.on.doc", help: isVideo ? "Copy file (⌘C)" : "Copy (⌘C)", action: onCopy)
            iconButton("square.and.arrow.down", help: "Save to folder (⌘S). ⌥-click or ⇧⌘S: Save As", action: onSave)
            iconButton(isVideo ? "film" : "pencil.tip.crop.circle", help: isVideo ? "Edit video (⌘E)" : "Annotate (⌘E)", action: onEdit)
            if !isVideo {
                iconButton("pin", help: "Pin to screen (⌘P)", action: onPin)
                iconButton("text.viewfinder", help: "Copy text and QR codes (⌘T)", action: onText)
            }
            iconButton("icloud.and.arrow.up", help: "Upload and copy link (⌘U). ⌥-click for password and expiry", action: onUpload)
        }
        .padding(5)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 31, height: 31)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
