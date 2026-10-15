import AppKit
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class WindowPickerOverlay {
    struct PickedWindow {
        let frame: CGRect       // global Cocoa coords
        let ownerName: String
        let windowID: CGWindowID
    }

    private static var current: WindowPickerOverlay?

    private var windows: [PickerWindow] = []
    private var frozen: [ObjectIdentifier: (image: CGImage, display: SCDisplay, screen: NSScreen)] = [:]
    private var pickable: [PickedWindow] = []
    private let completion: (CaptureResult?) -> Void
    private var finished = false

    fileprivate private(set) var hovered: PickedWindow?

    private init(completion: @escaping (CaptureResult?) -> Void) {
        self.completion = completion
    }

    static func present(completion: @escaping (CaptureResult?) -> Void) {
        let overlay = WindowPickerOverlay(completion: completion)
        current = overlay
        overlay.start()
    }

    /// Just choose a window (used to record a window); no capture is made.
    static func pick(completion: @escaping (PickedWindow?, NSScreen?) -> Void) {
        let overlay = WindowPickerOverlay(completion: { _ in })
        overlay.pickCompletion = completion
        current = overlay
        overlay.start()
    }

    private var pickCompletion: ((PickedWindow?, NSScreen?) -> Void)?

    private func start() {
        pickable = Self.fetchWindows()
        Task {
            do {
                let displays = try await CaptureEngine.displays()
                for display in displays {
                    guard let screen = CaptureEngine.screen(for: display) else { continue }
                    let image = try await CaptureEngine.captureDisplay(display)
                    guard !finished else { return }
                    let window = PickerWindow(screen: screen, frozenImage: image, controller: self)
                    windows.append(window)
                    frozen[ObjectIdentifier(window)] = (image, display, screen)
                }
                guard !finished else { return }
                guard !windows.isEmpty else { finish(nil); return }

                NSApp.activate(ignoringOtherApps: true)
                for window in windows { window.orderFrontRegardless() }
                let mouse = NSEvent.mouseLocation
                let keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows[0]
                keyWindow.makeKey()
                keyWindow.makeFirstResponder(keyWindow.pickerView)
                updateHover(at: mouse)
            } catch {
                finish(nil)
            }
        }
    }

    /// On-screen, normal-layer windows in front-to-back order, in global Cocoa coordinates.
    private static func fetchWindows() -> [PickedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        // CG window bounds are top-left origin relative to the primary display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0

        var result: [PickedWindow] = []
        for info in list {
            if let pid = info[kCGWindowOwnerPID as String] as? Int, pid == ownPID { continue }
            if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard b.width > 1, b.height > 1 else { continue }
            let cocoa = CGRect(x: b.minX, y: mainHeight - b.minY - b.height, width: b.width, height: b.height)
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "Window"
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            result.append(PickedWindow(frame: cocoa, ownerName: owner, windowID: CGWindowID(number)))
        }
        return result
    }

    fileprivate func updateHover(at point: CGPoint) {
        let hit = pickable.first { $0.frame.contains(point) }
        if hit?.frame != hovered?.frame {
            hovered = hit
            for window in windows { window.contentView?.needsDisplay = true }
        }
    }

    fileprivate func cancel() {
        finish(nil)
    }

    fileprivate func didPick(_ picked: PickedWindow, on window: NSWindow) {
        guard !finished, let info = frozen[ObjectIdentifier(window)] else { finish(nil); return }
        if let pickCompletion {
            self.pickCompletion = nil
            finish(nil)
            pickCompletion(picked, info.screen)
            return
        }
        // Hide our overlays, then grab a fresh frame so pixels are never stale.
        for w in windows { w.orderOut(nil) }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            // Preferred: capture the window by itself (transparent corners, optional shadow, optional background).
            if let image = await Self.captureSingleWindow(picked.windowID, scale: info.screen.backingScaleFactor) {
                finish(CaptureResult(image: image, kind: .window, screen: info.screen,
                                     areaRect: nil, displayID: info.display.displayID))
                return
            }
            // Fallback: crop the window's frame out of a fresh display frame.
            do {
                let image = try await CaptureEngine.captureDisplay(info.display)
                let rect = picked.frame.intersection(info.screen.frame)
                guard !rect.isNull,
                      let cropped = CaptureEngine.cropDisplayImage(image, display: info.display,
                                                                   screen: info.screen, rect: rect) else {
                    finish(nil)
                    return
                }
                let result = CaptureResult(image: cropped, kind: .window, screen: info.screen,
                                           areaRect: nil, displayID: info.display.displayID)
                finish(result)
            } catch {
                finish(nil)
            }
        }
    }

    /// Window capture styles (Settings > Capture): 0 = on a background, 1 = transparent with shadow,
    /// 2 = transparent without shadow.
    static func captureSingleWindow(_ windowID: CGWindowID, scale: CGFloat) async -> CGImage? {
        guard windowID != 0,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let style = AppSettings.windowCaptureStyle
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = style != 1
        let pxScale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        config.width = max(2, Int((rect.width * (pxScale > 0 ? pxScale : scale)).rounded()))
        config.height = max(2, Int((rect.height * (pxScale > 0 ? pxScale : scale)).rounded()))
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }
        if style == 0 {
            return BackgroundMaker.apply(BackgroundSettings.windowCapture, to: image)
        }
        return image
    }

    private func finish(_ result: CaptureResult?) {
        guard !finished else { return }
        finished = true
        if let pick = pickCompletion {          // cancelled while picking
            pickCompletion = nil
            pick(nil, nil)
        }
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        frozen.removeAll()
        Self.current = nil
        completion(result)
    }
}

private final class PickerWindow: NSWindow {
    let pickerView: PickerView

    init(screen: NSScreen, frozenImage: CGImage, controller: WindowPickerOverlay) {
        let view = PickerView(screen: screen, frozenImage: frozenImage, controller: controller)
        self.pickerView = view
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PickerView: NSView {
    private let frozenImage: CGImage
    private let screen: NSScreen
    private weak var controller: WindowPickerOverlay?

    init(screen: NSScreen, frozenImage: CGImage, controller: WindowPickerOverlay) {
        self.screen = screen
        self.frozenImage = frozenImage
        self.controller = controller
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.updateHover(at: NSEvent.mouseLocation)
        if let hovered = controller?.hovered, let window {
            controller?.didPick(hovered, on: window)
        } else {
            controller?.cancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(frozenImage, in: bounds)

        // Hovered window rect in this view's coordinates
        var hoverRect: CGRect?
        var ownerName = ""
        if let h = controller?.hovered {
            let local = h.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY).intersection(bounds)
            if !local.isNull, local.width > 0, local.height > 0 {
                hoverRect = local
                ownerName = h.ownerName
            }
        }

        // Dim everything except the hovered window
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds)
        if let r = hoverRect { path.addRect(r) }
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let r = hoverRect {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(r.insetBy(dx: 1.5, dy: 1.5))
            ctx.restoreGState()

            // Owner-name pill: above the window, flipping inside when near the top edge
            let size = OverlayDrawing.pillSize(ownerName)
            var y = r.maxY + 8
            if y + size.height > bounds.maxY - 4 {
                y = r.maxY - size.height - 12
            }
            let x = min(max(r.minX, 4), bounds.maxX - size.width - 4)
            OverlayDrawing.drawPill(ownerName, at: CGPoint(x: x, y: y))
        }

        OverlayDrawing.drawHint("Click a window to capture   •   Esc to cancel", in: bounds)
    }
}
