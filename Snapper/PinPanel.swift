import AppKit
import QuartzCore

/// A floating, always-on-top copy of an image with rounded corners.
///
/// - Pinch on the trackpad to zoom into the picture (around the pointer); drag to pan while zoomed.
/// - Swipe up / down with two fingers to change opacity; the mouse wheel zooms; ⌘-scroll or ⌘+ / ⌘− resizes the
///   pin; drag an edge to resize.
/// - Double-click resets the zoom (or toggles 100 % size). Arrow keys move it precisely.
/// - Right-click for the menu. "Lock" makes it click-through.
/// The picture is a GPU layer, so zooming and moving cost almost nothing.
@MainActor
final class PinPanel: NSObject {
    private static var pins: [ObjectIdentifier: PinPanel] = [:]

    fileprivate let panel: PinWindow
    private let image: CGImage
    private let pinView: PinView
    private let naturalSize: NSSize      // 100% size in points

    static func pin(_ image: CGImage, near screen: NSScreen? = nil) {
        let p = PinPanel(image: image, screen: screen ?? NSScreen.main ?? NSScreen.screens[0])
        pins[ObjectIdentifier(p)] = p
        p.panel.orderFrontRegardless()
        p.panel.invalidateShadow()
    }

    private init(image: CGImage, screen: NSScreen) {
        self.image = image
        let backing = screen.backingScaleFactor
        let natural = NSSize(width: CGFloat(image.width) / backing, height: CGFloat(image.height) / backing)
        var size = natural
        let maxSize = NSSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = NSSize(width: max(60, size.width * fit), height: max(40, size.height * fit))

        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2 + CGFloat(Self.pins.count % 6) * 24,
                             y: vf.midY - size.height / 2 - CGFloat(Self.pins.count % 6) * 24)
        let win = PinWindow(contentRect: NSRect(origin: origin, size: size))
        win.contentAspectRatio = natural
        win.minSize = NSSize(width: 60, height: 60 * natural.height / max(natural.width, 1))
        let view = PinView(frame: NSRect(origin: .zero, size: size), image: image)
        self.panel = win
        self.pinView = view
        self.naturalSize = natural
        super.init()

        win.contentView = view
        view.owner = self
    }

    // MARK: - Actions (called from the view)

    fileprivate func adjustOpacity(by delta: CGFloat) {
        panel.alphaValue = min(1, max(0.1, panel.alphaValue + delta))
        pinView.flash("\(Int((panel.alphaValue * 100).rounded()))% opacity")
    }

    fileprivate func setOpacity(_ value: CGFloat) { panel.alphaValue = value }

    /// Resizes the window around its centre, keeping the aspect ratio.
    fileprivate func scale(by factor: CGFloat) {
        let f = panel.frame
        let w = min(max(f.width * factor, 60), naturalSize.width * 4)
        let h = w * naturalSize.height / max(naturalSize.width, 1)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        panel.invalidateShadow()
        pinView.flash("\(Int((w / naturalSize.width * 100).rounded()))%")
    }

    fileprivate func setSize(_ percent: CGFloat) {
        let f = panel.frame
        let w = naturalSize.width * percent / 100, h = naturalSize.height * percent / 100
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
        panel.invalidateShadow()
    }

    fileprivate var isNaturalSize: Bool { abs(panel.frame.width - naturalSize.width) < 1 }

    fileprivate func nudge(dx: CGFloat, dy: CGFloat) {
        var f = panel.frame
        f.origin.x += dx
        f.origin.y += dy
        panel.setFrame(f, display: true)
    }

    fileprivate func toggleLock() {
        panel.ignoresMouseEvents.toggle()
        if panel.ignoresMouseEvents {
            Toast.show("Pin locked: clicks pass through. Unlock from the menu bar.", seconds: 2.4)
        }
    }

    fileprivate func copyImage() {
        guard let data = CaptureEngine.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        pinView.flash("Copied")
    }

    fileprivate func saveImage() {
        guard let data = CaptureEngine.pngData(image) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.directoryURL = AppSettings.saveFolder
        sp.nameFieldStringValue = "Snapper Pin.png"
        if sp.runModal() == .OK, let url = sp.url { try? data.write(to: url) }
    }

    fileprivate func annotate() {
        AnnotateWindowController.open(image: image)
        closePin()
    }

    fileprivate func closePin() {
        panel.orderOut(nil)
        Self.pins[ObjectIdentifier(self)] = nil
    }

    /// Unlocks every pin (used from the menu bar, since locked pins are click-through).
    static func unlockAll() {
        for pin in pins.values { pin.panel.ignoresMouseEvents = false }
    }

    static func closeAll() {
        for pin in Array(pins.values) { pin.closePin() }
    }

    static var count: Int { pins.count }
}

fileprivate final class PinWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

/// Rounded, layer-backed pin content. Zoom and pan move a GPU layer; nothing is redrawn on the CPU.
fileprivate final class PinView: NSView {
    weak var owner: PinPanel?
    private let imageLayer = CALayer()
    private let hudLayer = CATextLayer()
    private let closeButton = NSButton()
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero            // image layer origin relative to the view (<= 0)
    private var hudWork: DispatchWorkItem?
    private static let corner: CGFloat = 12

    init(frame: NSRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.cornerRadius = Self.corner
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        layer.backgroundColor = NSColor.black.cgColor

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        layer.addSublayer(imageLayer)

        hudLayer.fontSize = 11
        hudLayer.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        hudLayer.foregroundColor = NSColor.white.cgColor
        hudLayer.backgroundColor = Brand.navy.withAlphaComponent(0.82).cgColor
        hudLayer.cornerRadius = 9
        hudLayer.alignmentMode = .center
        hudLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        hudLayer.opacity = 0
        layer.addSublayer(hudLayer)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close pin")
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close (Esc)"
        closeButton.alphaValue = 0
        addSubview(closeButton)
        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { zoom <= 1.001 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; closeButton.animator().alphaValue = 1 }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; closeButton.animator().alphaValue = 0 }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        clampOffset()
        layoutLayers()
        window?.invalidateShadow()
    }

    private func clampOffset() {
        let w = bounds.width * zoom, h = bounds.height * zoom
        offset.x = min(0, max(bounds.width - w, offset.x))
        offset.y = min(0, max(bounds.height - h, offset.y))
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: offset.x, y: offset.y, width: bounds.width * zoom, height: bounds.height * zoom)
        let hudSize = CGSize(width: 96, height: 18)
        hudLayer.frame = CGRect(x: bounds.midX - hudSize.width / 2, y: 8, width: hudSize.width, height: hudSize.height)
        CATransaction.commit()
        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
    }

    /// Short label at the bottom (zoom level, opacity…).
    func flash(_ text: String) {
        hudLayer.string = text
        hudLayer.opacity = 1
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hudLayer.opacity = 0 }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    // MARK: Zoom and pan

    private func setZoom(_ z: CGFloat, around p: CGPoint) {
        let newZoom = min(max(z, 1), 16)
        let imgPoint = CGPoint(x: (p.x - offset.x) / zoom, y: (p.y - offset.y) / zoom)
        zoom = newZoom
        offset = CGPoint(x: p.x - imgPoint.x * zoom, y: p.y - imgPoint.y * zoom)
        clampOffset()
        layoutLayers()
        flash(zoom <= 1.001 ? "Fit" : "Zoom \(Int((zoom * 100).rounded()))%")
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setZoom(zoom > 1.001 ? 1 : 2.5, around: p)
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) {
            let d = event.scrollingDeltaY * (precise ? 0.01 : 0.06)
            owner?.scale(by: 1 + d)
            return
        }
        if event.modifierFlags.contains(.option) {
            owner?.adjustOpacity(by: event.scrollingDeltaY * (precise ? 0.004 : 0.03))
            return
        }
        // Two-finger swipe up / down changes opacity (pinch zooms). A mouse wheel zooms around the pointer.
        if precise {
            if zoom > 1.001, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                offset.x += event.scrollingDeltaX
                clampOffset()
                layoutLayers()
                return
            }
            guard event.scrollingDeltaY != 0 else { return }
            owner?.adjustOpacity(by: event.scrollingDeltaY * 0.004)
        } else {
            setZoom(zoom * exp(event.scrollingDeltaY * 0.08), around: convert(event.locationInWindow, from: nil))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            if zoom > 1.001 {
                setZoom(1, around: convert(event.locationInWindow, from: nil))
            } else if let owner {
                owner.setSize(owner.isNaturalSize ? 50 : 100)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoom > 1.001 else { super.mouseDragged(with: event); return }
        // While zoomed, dragging pans the picture instead of moving the window.
        offset.x += event.deltaX
        offset.y -= event.deltaY
        clampOffset()
        layoutLayers()
    }

    @objc private func closeTapped() { owner?.closePin() }

    // MARK: Menu and keys

    override func rightMouseDown(with event: NSEvent) {
        guard let owner else { return }
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        item("Copy") { owner.copyImage() }
        item("Save…") { owner.saveImage() }
        item("Annotate") { owner.annotate() }
        menu.addItem(.separator())
        item("Reset Zoom") { [weak self] in
            guard let self else { return }
            self.setZoom(1, around: CGPoint(x: self.bounds.midX, y: self.bounds.midY))
        }
        for pct in [50, 100, 200] {
            item("Size \(pct)%") { owner.setSize(CGFloat(pct)) }
        }
        menu.addItem(.separator())
        for pct in [100, 75, 50, 25] {
            item("Opacity \(pct)%") { owner.setOpacity(CGFloat(pct) / 100) }
        }
        menu.addItem(.separator())
        item("Lock (click-through)") { owner.toggleLock() }
        menu.addItem(.separator())
        item("Close") { owner.closePin() }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        let k: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let cmd = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53: owner?.closePin()
        case 123: owner?.nudge(dx: -k, dy: 0)
        case 124: owner?.nudge(dx: k, dy: 0)
        case 125: owner?.nudge(dx: 0, dy: -k)
        case 126: owner?.nudge(dx: 0, dy: k)
        default:
            if cmd, let ch = event.charactersIgnoringModifiers {
                switch ch {
                case "=", "+": owner?.scale(by: 1.15); return
                case "-": owner?.scale(by: 1 / 1.15); return
                case "0": owner?.setSize(100); return
                case "c": owner?.copyImage(); return
                case "w": owner?.closePin(); return
                default: break
                }
            }
            super.keyDown(with: event)
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
