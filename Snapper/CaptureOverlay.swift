import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Shared drawing helpers for the capture overlays.
enum OverlayDrawing {
    static func pillSize(_ text: String, fontSize: CGFloat = 12) -> CGSize {
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
        ])
        let s = str.size()
        return CGSize(width: ceil(s.width) + 20, height: ceil(s.height) + 10)
    }

    @discardableResult
    static func drawPill(_ text: String, at origin: CGPoint, fontSize: CGFloat = 12) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = pillSize(text, fontSize: fontSize)
        let rect = CGRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        str.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 5))
        return rect
    }

    static func drawHint(_ text: String, in bounds: CGRect) {
        let size = pillSize(text, fontSize: 13)
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 44 - size.height)
        drawPill(text, at: origin, fontSize: 13)
    }
}

/// What the user picked in all-in-one mode.
enum AllInOneAction {
    case screenshot, record, gif, scrolling, text, pin, timer
}

@MainActor
final class AreaCaptureOverlay {
    enum Mode { case standard, allInOne }

    private static var current: AreaCaptureOverlay?
    /// Last all-in-one selection, global Cocoa coordinates.
    private static var lastAllInOneRect: CGRect?

    private var windows: [OverlayWindow] = []
    private var frozen: [ObjectIdentifier: (image: CGImage, display: SCDisplay, screen: NSScreen)] = [:]
    private let mode: Mode
    private let completion: (CaptureResult?, AllInOneAction) -> Void
    private var finished = false
    fileprivate let freeze = AppSettings.freezeScreen
    private var toolbar: AllInOneToolbar?

    private init(mode: Mode, completion: @escaping (CaptureResult?, AllInOneAction) -> Void) {
        self.mode = mode
        self.completion = completion
    }

    /// Plain area selection.
    static func present(completion: @escaping (CaptureResult?) -> Void) {
        let overlay = AreaCaptureOverlay(mode: .standard) { result, _ in completion(result) }
        current = overlay
        overlay.start()
    }

    /// All-in-one: adjustable selection plus a toolbar to choose what to do with it.
    static func presentAllInOne(completion: @escaping (CaptureResult?, AllInOneAction) -> Void) {
        let overlay = AreaCaptureOverlay(mode: .allInOne, completion: completion)
        current = overlay
        overlay.start()
    }

    private func start() {
        Task {
            do {
                let displays = try await CaptureEngine.displays()
                for display in displays {
                    guard let screen = CaptureEngine.screen(for: display) else { continue }
                    let image = try await CaptureEngine.captureDisplay(display)
                    guard !finished else { return }
                    let window = OverlayWindow(screen: screen, frozenImage: image, controller: self,
                                               adjustable: mode == .allInOne)
                    windows.append(window)
                    frozen[ObjectIdentifier(window)] = (image, display, screen)
                }
                guard !finished else { return }
                guard !windows.isEmpty else { finish(nil, .screenshot); return }

                NSApp.activate(ignoringOtherApps: true)
                for window in windows { window.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                let keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows[0]
                keyWindow.makeKey()
                keyWindow.makeFirstResponder(keyWindow.selectionView)

                if mode == .allInOne, let last = Self.lastAllInOneRect,
                   let w = windows.first(where: { $0.frame.contains(CGPoint(x: last.midX, y: last.midY)) }) {
                    w.selectionView.preselect(global: last)
                    w.makeKey()
                    w.makeFirstResponder(w.selectionView)
                }
            } catch {
                finish(nil, .screenshot)
            }
        }
    }

    fileprivate func cancel() {
        finish(nil, .screenshot)
    }

    // MARK: All-in-one toolbar

    fileprivate func selectionChanged(_ global: CGRect?, in window: OverlayWindow) {
        guard mode == .allInOne else { return }
        guard let global, global.width >= 4, global.height >= 4 else {
            toolbar?.close()
            toolbar = nil
            return
        }
        if toolbar == nil {
            let bar = AllInOneToolbar()
            bar.onAction = { [weak self, weak window] action in
                guard let self, let window else { return }
                self.confirm(action: action, on: window)
            }
            bar.onSizeEntered = { [weak window] size in
                window?.selectionView.setSelectionSize(size)
            }
            bar.onCancel = { [weak self] in self?.cancel() }
            bar.onLockChanged = { [weak window] locked in window?.selectionView.lockAspect = locked }
            toolbar = bar
            window.addChildWindow(bar.panel, ordered: .above)
        }
        toolbar?.update(selection: global, screen: window.screen ?? NSScreen.main)
    }

    fileprivate func confirm(action: AllInOneAction, on window: OverlayWindow) {
        guard let global = window.selectionView.globalSelection else { return }
        Self.lastAllInOneRect = global
        didSelect(global, on: window, action: action)
    }

    // MARK: Result

    fileprivate func didSelect(_ rect: CGRect, on window: NSWindow, action: AllInOneAction = .screenshot) {
        guard let info = frozen[ObjectIdentifier(window)] else { finish(nil, action); return }
        let needsPixels = action == .screenshot || action == .text || action == .pin || action == .scrolling

        if freeze || !needsPixels {
            guard let cropped = CaptureEngine.cropDisplayImage(info.image, display: info.display,
                                                               screen: info.screen, rect: rect) else {
                finish(nil, action)
                return
            }
            finish(CaptureResult(image: cropped, kind: .area, screen: info.screen,
                                 areaRect: rect, displayID: info.display.displayID), action)
            return
        }
        // Live mode: hide the overlay, then grab fresh pixels (moving content is captured as it is now).
        toolbar?.close()
        for w in windows { w.orderOut(nil) }
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let fresh = try? await CaptureEngine.captureDisplay(info.display),
                  let cropped = CaptureEngine.cropDisplayImage(fresh, display: info.display,
                                                               screen: info.screen, rect: rect) else {
                finish(nil, action)
                return
            }
            finish(CaptureResult(image: cropped, kind: .area, screen: info.screen,
                                 areaRect: rect, displayID: info.display.displayID), action)
        }
    }

    private func finish(_ result: CaptureResult?, _ action: AllInOneAction) {
        guard !finished else { return }
        finished = true
        toolbar?.close()
        toolbar = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        frozen.removeAll()
        Self.current = nil
        completion(result, action)
    }
}

private final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, frozenImage: CGImage, controller: AreaCaptureOverlay, adjustable: Bool) {
        let view = SelectionView(screen: screen, frozenImage: frozenImage, controller: controller, adjustable: adjustable)
        self.selectionView = view
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        ignoresMouseEvents = false      // receive clicks even where the live (unfrozen) screen shows through
        contentView = view
        view.window_ = self
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let frozenImage: CGImage
    private let screen: NSScreen
    private weak var controller: AreaCaptureOverlay?
    weak var window_: OverlayWindow?
    private let adjustable: Bool
    private let showCrosshair = AppSettings.showCrosshair
    private let showMagnifier = AppSettings.showMagnifier

    /// Current selection in view coordinates.
    private var selection: CGRect?
    private var mousePoint: CGPoint?
    var lockAspect = false

    private enum Drag {
        case new(CGPoint)
        case move(CGPoint)                 // offset from selection origin
        case resize(edges: Edges, start: CGRect, mouse: CGPoint)
    }
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }
    private var drag: Drag?

    init(screen: NSScreen, frozenImage: CGImage, controller: AreaCaptureOverlay, adjustable: Bool) {
        self.screen = screen
        self.frozenImage = frozenImage
        self.controller = controller
        self.adjustable = adjustable
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        setUpLayers(freeze: controller.freeze)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var globalSelection: CGRect? {
        guard let s = selection else { return nil }
        return s.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    func preselect(global: CGRect) {
        let local = global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds)
        guard !local.isNull, local.width >= 4, local.height >= 4 else { return }
        selection = local
        notify()
        updateLayers()
    }

    func setSelectionSize(_ size: CGSize) {
        guard var s = selection else { return }
        s.size = CGSize(width: min(max(size.width, 4), bounds.width), height: min(max(size.height, 4), bounds.height))
        // Keep the top-left corner where it is (Cocoa: top = maxY).
        let top = selection?.maxY ?? s.maxY
        s.origin.y = top - s.height
        s.origin.x = min(s.origin.x, bounds.maxX - s.width)
        s.origin.y = max(s.origin.y, 0)
        selection = s
        notify()
        updateLayers()
    }

    private func notify() {
        guard let w = window_ else { return }
        controller?.selectionChanged(globalSelection, in: w)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if adjustable, let s = selection {
            addCursorRect(s.insetBy(dx: 8, dy: 8), cursor: .openHand)
        }
    }

    // MARK: Events

    private func edges(at p: CGPoint, of s: CGRect) -> Edges {
        let t: CGFloat = 8
        guard s.insetBy(dx: -t, dy: -t).contains(p) else { return [] }
        var e: Edges = []
        if abs(p.x - s.minX) <= t { e.insert(.left) }
        if abs(p.x - s.maxX) <= t { e.insert(.right) }
        if abs(p.y - s.minY) <= t { e.insert(.bottom) }
        if abs(p.y - s.maxY) <= t { e.insert(.top) }
        return e
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        if adjustable, let s = selection {
            let e = edges(at: p, of: s)
            if !e.isEmpty {
                drag = .resize(edges: e, start: s, mouse: p)
                return
            }
            if s.contains(p) {
                if event.clickCount == 2 {
                    if let w = window_ { controller?.confirm(action: .screenshot, on: w) }
                    return
                }
                drag = .move(CGPoint(x: p.x - s.minX, y: p.y - s.minY))
                return
            }
        }
        drag = .new(p)
        selection = CGRect(origin: p, size: .zero)
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePoint = p
        switch drag {
        case .new(let start):
            var r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if event.modifierFlags.contains(.shift) {
                let m = max(r.width, r.height)
                r = CGRect(x: p.x < start.x ? start.x - m : start.x, y: p.y < start.y ? start.y - m : start.y, width: m, height: m)
            }
            selection = r.intersection(bounds)
        case .move(let offset):
            guard let s = selection else { break }
            var o = CGPoint(x: p.x - offset.x, y: p.y - offset.y)
            o.x = min(max(o.x, 0), bounds.width - s.width)
            o.y = min(max(o.y, 0), bounds.height - s.height)
            selection = CGRect(origin: o, size: s.size)
        case .resize(let e, let start, let mouse):
            var r = start
            let dx = p.x - mouse.x, dy = p.y - mouse.y
            if e.contains(.left) { r.origin.x += dx; r.size.width -= dx }
            if e.contains(.right) { r.size.width += dx }
            if e.contains(.bottom) { r.origin.y += dy; r.size.height -= dy }
            if e.contains(.top) { r.size.height += dy }
            r = r.standardized
            if lockAspect, start.height > 0 {
                let ratio = start.width / start.height
                if e.contains(.left) || e.contains(.right) { r.size.height = r.width / ratio } else { r.size.width = r.height * ratio }
            }
            selection = r.intersection(bounds)
        case nil:
            break
        }
        notify()
        updateLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        mousePoint = convert(event.locationInWindow, from: nil)
        defer { drag = nil; window?.invalidateCursorRects(for: self) }
        guard let s = selection, s.width >= 4, s.height >= 4 else {
            selection = nil
            notify()
            if !adjustable { controller?.cancel() }
            updateLayers()
            return
        }
        if adjustable {
            notify()
            updateLayers()
        } else if let window {
            controller?.didSelect(s.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), on: window)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            controller?.cancel()
        case 36, 76:
            if adjustable, let w = window_ { controller?.confirm(action: .screenshot, on: w) }
        case 123, 124, 125, 126:
            guard adjustable, var s = selection else { return }
            let k: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: s.origin.x -= k
            case 124: s.origin.x += k
            case 125: s.origin.y -= k
            default: s.origin.y += k
            }
            s.origin.x = min(max(s.origin.x, 0), bounds.width - s.width)
            s.origin.y = min(max(s.origin.y, 0), bounds.height - s.height)
            selection = s
            notify()
            updateLayers()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Layers
    //
    // Everything is a Core Animation layer: the frozen screenshot, the dimming, crosshair, selection chrome
    // and the magnifier (the screenshot again, scaled 5x with nearest-neighbour filtering). Moving the mouse
    // only repositions layers on the GPU; nothing full-screen is redrawn on the CPU.

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let crossH = CALayer()
    private let crossV = CALayer()
    private let borderOuter = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let sizePill = PillLayer()
    private let hintPill = PillLayer()
    private let coordsPill = PillLayer()
    private let magContainer = CALayer()
    private let magImage = CALayer()
    private let reticle = CALayer()
    private let zoom: CGFloat = 6

    private func setUpLayers(freeze: Bool) {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let root = layer else { return }
        let scale = screen.backingScaleFactor
        // Live mode: a nearly transparent fill so the window still receives every click.
        root.backgroundColor = NSColor.black.withAlphaComponent(freeze ? 0 : 0.01).cgColor

        imageLayer.contents = frozenImage
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds
        imageLayer.isHidden = !freeze
        root.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        root.addSublayer(dimLayer)

        for l in [crossH, crossV] {
            l.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            l.isHidden = true
            root.addSublayer(l)
        }

        borderOuter.fillColor = nil
        borderOuter.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
        borderOuter.lineWidth = 1
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        border.lineWidth = 1.5
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
        handlesLayer.lineWidth = 1
        for l in [borderOuter, border, handlesLayer] { root.addSublayer(l) }

        magContainer.masksToBounds = true
        magContainer.cornerRadius = 60       // round loupe
        magContainer.shadowOpacity = 0
        magContainer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        magContainer.borderWidth = 1.5
        magContainer.backgroundColor = NSColor.black.cgColor
        magContainer.isHidden = true
        magImage.contents = frozenImage
        magImage.contentsGravity = .resize
        magImage.magnificationFilter = .nearest
        magContainer.addSublayer(magImage)
        reticle.borderColor = NSColor.systemRed.cgColor
        reticle.borderWidth = 1
        reticle.cornerRadius = 2.5
        magContainer.addSublayer(reticle)
        root.addSublayer(magContainer)

        for p in [sizePill, hintPill, coordsPill] {
            p.setScale(scale)
            root.addSublayer(p)
        }
        coordsPill.fontSize = 11
        hintPill.fontSize = 12
        updateLayers()
    }

    private var isNewDrag: Bool {
        if case .new = drag { return true }
        return false
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let sel = selection
        let path = CGMutablePath()
        path.addRect(bounds)
        if let s = sel { path.addRect(s) }
        dimLayer.path = path

        let drawing = drag != nil
        let choosing = sel == nil || (drawing && isNewDrag)

        // Crosshair
        if showCrosshair, let mp = mousePoint, choosing {
            crossH.isHidden = false
            crossV.isHidden = false
            // Short ticks around the pointer instead of lines across the whole screen.
            let arm: CGFloat = 13
            crossH.frame = CGRect(x: mp.x.rounded() - arm, y: mp.y.rounded() - 0.5, width: arm * 2, height: 1)
            crossV.frame = CGRect(x: mp.x.rounded() - 0.5, y: mp.y.rounded() - arm, width: 1, height: arm * 2)
        } else {
            crossH.isHidden = true
            crossV.isHidden = true
        }

        // Selection chrome
        if let s = sel, s.width > 0 || s.height > 0 {
            border.path = CGPath(rect: s, transform: nil)
            borderOuter.path = CGPath(rect: s.insetBy(dx: -1.5, dy: -1.5), transform: nil)
            border.isHidden = false
            borderOuter.isHidden = false
            let text = "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
            let size = sizePill.setText(text)
            var y = s.maxY + 8
            if y + size.height > bounds.maxY - 4 {
                y = s.minY - size.height - 8
                if y < 4 { y = s.maxY - size.height - 8 }
            }
            let x = min(max(s.minX, 4), bounds.maxX - size.width - 4)
            sizePill.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            sizePill.isHidden = false
            if adjustable && !drawing {
                let hp = CGMutablePath()
                for p in [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.midX, y: s.minY), CGPoint(x: s.maxX, y: s.minY),
                          CGPoint(x: s.maxX, y: s.midY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.midX, y: s.maxY),
                          CGPoint(x: s.minX, y: s.maxY), CGPoint(x: s.minX, y: s.midY)] {
                    hp.addEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                }
                handlesLayer.path = hp
                handlesLayer.isHidden = false
            } else {
                handlesLayer.isHidden = true
            }
        } else {
            border.isHidden = true
            borderOuter.isHidden = true
            handlesLayer.isHidden = true
            sizePill.isHidden = true
        }

        // Magnifier
        if showMagnifier, let mp = mousePoint, choosing {
            let size = CGSize(width: 120, height: 120)
            var origin = CGPoint(x: mp.x + 26, y: mp.y - 26 - size.height)
            origin.x = min(max(origin.x, 8), bounds.width - size.width - 8)
            origin.y = min(max(origin.y, 34), bounds.height - size.height - 8)
            magContainer.frame = CGRect(origin: origin, size: size)
            magImage.frame = CGRect(x: size.width / 2 - mp.x * zoom, y: size.height / 2 - mp.y * zoom,
                                    width: bounds.width * zoom, height: bounds.height * zoom)
            reticle.frame = CGRect(x: size.width / 2 - zoom / 2, y: size.height / 2 - zoom / 2, width: zoom, height: zoom)
            magContainer.isHidden = false
            let c = coordsPill.setText("\(Int(mp.x)), \(Int(bounds.height - mp.y))")
            coordsPill.frame = CGRect(x: origin.x, y: origin.y - c.height - 6, width: c.width, height: c.height)
            coordsPill.isHidden = false
        } else {
            magContainer.isHidden = true
            coordsPill.isHidden = true
        }

        // Hint
        let hs = hintPill.setText("Drag to select  ·  Esc to cancel")
        hintPill.frame = CGRect(x: bounds.midX - hs.width / 2, y: bounds.maxY - 44 - hs.height, width: hs.width, height: hs.height)
        hintPill.isHidden = sel != nil
    }
}

/// Rounded label (navy glass-like pill) as a layer: background + centred text.
private final class PillLayer: CALayer {
    private let text = CATextLayer()
    var fontSize: CGFloat = 12

    override init() {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        addSublayer(text)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setScale(_ s: CGFloat) {
        contentsScale = s
        text.contentsScale = s
    }

    /// Sets the text and returns the pill size.
    @discardableResult
    func setText(_ string: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        if (text.string as? String) != string {
            text.string = string
            text.font = font
            text.fontSize = fontSize
        }
        let t = NSAttributedString(string: string, attributes: [.font: font]).size()
        let size = CGSize(width: ceil(t.width) + 20, height: ceil(t.height) + 10)
        cornerRadius = size.height / 2
        text.frame = CGRect(x: 0, y: (size.height - ceil(t.height)) / 2 - 1, width: size.width, height: ceil(t.height) + 2)
        return size
    }
}

// MARK: - All-in-one toolbar

@MainActor
private final class AllInOneToolbar: NSObject, NSTextFieldDelegate {
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let panel: Panel
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let lockButton = NSButton()
    var onAction: ((AllInOneAction) -> Void)?
    var onSizeEntered: ((CGSize) -> Void)?
    var onLockChanged: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    private static let actions: [(AllInOneAction, String, String)] = [
        (.screenshot, "camera.viewfinder", "Capture screenshot (Return)"),
        (.record, "record.circle", "Record video"),
        (.gif, "photo.stack", "Record GIF"),
        (.scrolling, "chevron.down.2", "Scrolling capture"),
        (.text, "text.viewfinder", "Copy text (OCR)"),
        (.pin, "pin", "Pin to screen"),
        (.timer, "timer", "Self-timer")
    ]

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 38),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let bg = NSView(frame: panel.contentLayoutRect)
        bg.autoresizingMask = [.width, .height]

        var views: [NSView] = []
        for (i, entry) in Self.actions.enumerated() {
            let b = NSButton()
            b.image = NSImage(systemSymbolName: entry.1, accessibilityDescription: entry.2)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = .labelColor
            b.toolTip = entry.2
            b.tag = i
            b.target = self
            b.action = #selector(actionTapped(_:))
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            if entry.0 == .screenshot {
                // The default action (Return) is the one solid button.
                b.wantsLayer = true
                b.layer?.backgroundColor = Brand.accent.cgColor
                b.layer?.cornerRadius = 7
                b.layer?.cornerCurve = .continuous
                b.contentTintColor = .white
            }
            views.append(b)
        }
        let sep = NSBox()
        sep.boxType = .separator
        views.append(sep)

        for f in [widthField, heightField] {
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            f.alignment = .center
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 46).isActive = true
            f.bezelStyle = .roundedBezel
            f.controlSize = .small
        }
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        times.font = .systemFont(ofSize: 11)
        lockButton.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Lock aspect ratio")
        lockButton.setButtonType(.toggle)
        lockButton.isBordered = false
        lockButton.contentTintColor = .white
        lockButton.toolTip = "Lock aspect ratio"
        lockButton.target = self
        lockButton.action = #selector(lockTapped)
        views += [widthField, times, heightField, lockButton]

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bg.centerYAnchor)
        ])
        let fitting = stack.fittingSize
        let size = NSSize(width: max(fitting.width, 300), height: 38)
        bg.frame = NSRect(origin: .zero, size: size)
        panel.contentView = Glass.surface(bg, cornerRadius: 19, dark: true)
        panel.setContentSize(size)
    }

    func update(selection global: CGRect, screen: NSScreen?) {
        if panel.firstResponder !== widthField.currentEditor(), panel.firstResponder !== heightField.currentEditor() {
            widthField.stringValue = "\(Int(global.width.rounded()))"
            heightField.stringValue = "\(Int(global.height.rounded()))"
        }
        let size = panel.frame.size
        let vf = screen?.frame ?? global
        var origin = CGPoint(x: global.midX - size.width / 2, y: global.minY - size.height - 12)
        if origin.y < vf.minY + 8 { origin.y = global.maxY + 12 }              // no room below: go above
        if origin.y + size.height > vf.maxY - 8 { origin.y = global.minY + 12 } // no room either: inside
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < Self.actions.count else { return }
        onAction?(Self.actions[sender.tag].0)
    }

    @objc private func lockTapped() {
        let locked = lockButton.state == .on
        lockButton.image = NSImage(systemSymbolName: locked ? "lock" : "lock.open", accessibilityDescription: "Lock aspect ratio")
        onLockChanged?(locked)
    }

    @objc private func cancelTapped() { onCancel?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let w = Double(widthField.stringValue) ?? 0, h = Double(heightField.stringValue) ?? 0
            if w >= 4, h >= 4 { onSizeEntered?(CGSize(width: w, height: h)) }
            panel.parent?.makeKey()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
