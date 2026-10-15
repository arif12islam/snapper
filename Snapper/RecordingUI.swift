import AppKit
@preconcurrency import AVFoundation

// MARK: - Countdown

@MainActor
enum CountdownOverlay {
    /// Shows 3-2-1 as a small glass circle centred on `screen`, then returns.
    static func run(seconds: Int, on screen: NSScreen) async {
        guard seconds > 0 else { return }
        let size = NSSize(width: 84, height: 84)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size.height - 54) / 2, width: size.width, height: 54)
        content.addSubview(label)

        let window = Glass.panel(size: size, cornerRadius: 42, level: .screenSaver, dark: true, content: content)
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        window.orderFrontRegardless()

        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        window.orderOut(nil)
    }
}

// MARK: - Controls (hidden from the recording)

/// Glass capsule: logo, pulsing dot, timer, mic level, pause and stop.
@MainActor
final class RecordingControls: NSObject {
    private let panel: NSPanel
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let dot = NSView()
    private let pauseButton = NSButton()
    private let meter = NSLevelIndicator()
    private var timer: Timer?
    private var elapsed: TimeInterval = 0
    private var lastTick = Date()
    private(set) var isPaused = false

    var onStop: (() -> Void)?
    var onPauseToggle: ((Bool) -> Void)?
    var onTick: ((TimeInterval, Bool) -> Void)?

    var windowNumber: Int { panel.windowNumber }

    init(screen: NSScreen, showMeter: Bool) {
        let size = NSSize(width: showMeter ? 240 : 176, height: 38)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let vf = screen.visibleFrame
        panel = Glass.panel(size: size, cornerRadius: 19, level: .screenSaver, dark: true, content: content)
        super.init()
        panel.isMovableByWindowBackground = true
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 24))

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        dot.toolTip = "Snapper is recording"
        dot.frame = NSRect(x: 16, y: 14.5, width: 9, height: 9)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textColor = .labelColor
        timeLabel.frame = NSRect(x: 32, y: 9, width: 52, height: 20)

        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        pauseButton.isBordered = false
        pauseButton.contentTintColor = .labelColor
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.frame = NSRect(x: 88, y: 5, width: 28, height: 28)
        pauseButton.toolTip = "Pause / resume"

        let stop = NSButton()
        stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop")
        stop.isBordered = false
        stop.contentTintColor = .systemRed
        stop.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        stop.target = self
        stop.action = #selector(stopTapped)
        stop.frame = NSRect(x: size.width - 44, y: 3, width: 36, height: 32)
        stop.title = ""
        stop.toolTip = "Stop recording"

        content.addSubview(dot)
        content.addSubview(timeLabel)
        content.addSubview(pauseButton)
        content.addSubview(stop)

        if showMeter {
            meter.levelIndicatorStyle = .continuousCapacity
            meter.minValue = 0
            meter.maxValue = 1
            meter.warningValue = 0.8
            meter.criticalValue = 0.95
            meter.frame = NSRect(x: 122, y: 13, width: 60, height: 12)
            meter.toolTip = "Microphone level"
            content.addSubview(meter)
        }
    }

    func show() {
        panel.orderFrontRegardless()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer?.tolerance = 0.1
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    func setLevel(_ level: Float) { meter.doubleValue = Double(level) }

    private func tick() {
        let now = Date()
        if !isPaused { elapsed += now.timeIntervalSince(lastTick) }
        lastTick = now
        let total = Int(elapsed)
        timeLabel.stringValue = String(format: "%02d:%02d", total / 60, total % 60)
        dot.layer?.opacity = isPaused ? 0.3 : (Int(elapsed * 2) % 2 == 0 ? 1 : 0.45)
        onTick?(elapsed, isPaused)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        lastTick = Date()
        pauseButton.image = NSImage(systemSymbolName: isPaused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: isPaused ? "Resume" : "Pause")
        onPauseToggle?(isPaused)
    }

    @objc private func stopTapped() { onStop?() }
}

// MARK: - Recording time in the menu bar

@MainActor
final class RecordingStatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onStop: (() -> Void)?

    override init() {
        super.init()
        item.button?.title = "● 00:00"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.contentTintColor = .systemRed
        item.button?.toolTip = "Recording. Click to stop."
        item.button?.target = self
        item.button?.action = #selector(clicked)
    }

    func update(elapsed: TimeInterval, paused: Bool) {
        let total = Int(elapsed)
        item.button?.title = (paused ? "❚❚ " : "● ") + String(format: "%02d:%02d", total / 60, total % 60)
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() { onStop?() }
}

// MARK: - Click highlights and keystroke display (appear in the recording)

@MainActor
final class InputOverlays: NSObject {
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private let showClicks: Bool
    private let showKeys: Bool
    private let screen: NSScreen
    private var keyPanel: NSPanel?
    private var keyLabel: NSTextField?
    private var typed = ""
    private var hideWork: DispatchWorkItem?

    // Settings (Settings > Recording)
    private let clickColor = NSColor(hex: AppSettings.clickColor) ?? .systemYellow
    private let clickSize = CGFloat(AppSettings.clickSize)
    private let clickFilled = AppSettings.clickStyle == 1
    private let clickAnimate = AppSettings.clickAnimate
    private let keysPosition = AppSettings.keysPosition
    private let keysScale: CGFloat = [0.75, 1.0, 1.35][min(max(AppSettings.keysSize, 0), 2)]
    private let keysLight = AppSettings.keysStyle == 1
    private let onlyShortcuts = AppSettings.keysOnlyShortcuts

    init(screen: NSScreen, showClicks: Bool, showKeys: Bool) {
        self.screen = screen
        self.showClicks = showClicks
        self.showKeys = showKeys
        super.init()
    }

    func start() {
        if showClicks {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let p = NSEvent.mouseLocation
                Task { @MainActor [weak self] in self?.ripple(at: p) }
            }
        }
        if showKeys {
            // Needs the Input Monitoring permission; macOS asks the first time.
            let only = onlyShortcuts
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let text = Self.describe(event, onlyShortcuts: only) else { return }
                Task { @MainActor [weak self] in self?.show(keys: text) }
            }
        }
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        mouseMonitor = nil
        keyMonitor = nil
        hideWork?.cancel()
        keyPanel?.orderOut(nil)
        keyPanel = nil
    }

    private func ripple(at point: CGPoint) {
        let size = clickSize
        let window = NSWindow(contentRect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        view.wantsLayer = true
        view.layer?.backgroundColor = clickColor.withAlphaComponent(clickFilled ? 0.55 : 0.18).cgColor
        view.layer?.borderColor = clickColor.cgColor
        view.layer?.borderWidth = clickFilled ? 0 : 3
        view.layer?.cornerRadius = size / 2
        window.contentView = view
        window.orderFrontRegardless()
        if clickAnimate, let layer = view.layer {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 1.0
            grow.duration = 0.35
            layer.add(grow, forKey: "grow")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = clickAnimate ? 0.5 : 0.25
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in window.orderOut(nil) }
        })
    }

    private func show(keys: String) {
        typed += keys
        if typed.count > 28 { typed = String(typed.suffix(28)) }
        if keyPanel == nil {
            let size = NSSize(width: 420 * keysScale, height: 56 * keysScale)
            let vf = screen.visibleFrame
            let x: CGFloat
            switch keysPosition {
            case 1: x = vf.minX + 32
            case 2: x = vf.maxX - size.width - 32
            default: x = vf.midX - size.width / 2
            }
            let y = keysPosition == 3 ? vf.maxY - size.height - 48 : vf.minY + 96
            let p = NSPanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let bg = NSView(frame: NSRect(origin: .zero, size: size))
            bg.wantsLayer = true
            bg.layer?.backgroundColor = (keysLight ? NSColor.white.withAlphaComponent(0.9)
                                                   : NSColor.black.withAlphaComponent(0.75)).cgColor
            bg.layer?.cornerRadius = 14 * keysScale
            if keysLight {
                bg.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
                bg.layer?.borderWidth = 1
            }
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 26 * keysScale, weight: .semibold)
            label.textColor = keysLight ? .black : .white
            label.alignment = .center
            label.frame = NSRect(x: 8, y: 10 * keysScale, width: size.width - 16, height: 36 * keysScale)
            bg.addSubview(label)
            p.contentView = bg
            keyPanel = p
            keyLabel = label
        }
        keyLabel?.stringValue = typed
        keyPanel?.alphaValue = 1
        keyPanel?.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.typed = ""
                self?.keyPanel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// nil = don't show (plain typing when "only shortcuts" is on).
    private nonisolated static func describe(_ event: NSEvent, onlyShortcuts: Bool) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var prefix = ""
        if flags.contains(.control) { prefix += "⌃" }
        if flags.contains(.option) { prefix += "⌥" }
        if flags.contains(.shift) { prefix += "⇧" }
        if flags.contains(.command) { prefix += "⌘" }
        let isShortcut = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        if onlyShortcuts && !isShortcut { return nil }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋", 117: "⌦",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 76: "↩"]
        if let s = special[event.keyCode] { return prefix + s + (prefix.isEmpty ? "" : " ") }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        if prefix.isEmpty { return event.characters ?? chars }
        return prefix + chars + " "
    }
}

// MARK: - Camera bubble (appears in the recording)

/// Position, size and shape come from Settings > Recording. Double-click toggles fullscreen camera.
@MainActor
final class CameraBubble: NSObject {
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var preview: AVCaptureVideoPreviewLayer?
    private var smallFrame: NSRect = .zero
    private var isFullscreen = false
    private weak var screen: NSScreen?

    func show(on screen: NSScreen) async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted, let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        self.screen = screen

        let side: CGFloat = [130, 180, 260][min(max(AppSettings.cameraSize, 0), 2)]
        let rounded = AppSettings.cameraShape == 1
        let size = NSSize(width: rounded ? side * 4 / 3 : side, height: side)
        let vf = screen.visibleFrame
        let m: CGFloat = 24
        let origin: NSPoint
        switch AppSettings.cameraPosition {
        case 1: origin = NSPoint(x: vf.maxX - size.width - m, y: vf.minY + m)
        case 2: origin = NSPoint(x: vf.minX + m, y: vf.maxY - size.height - m)
        case 3: origin = NSPoint(x: vf.maxX - size.width - m, y: vf.maxY - size.height - m)
        default: origin = NSPoint(x: vf.minX + m, y: vf.minY + m)
        }
        smallFrame = NSRect(origin: origin, size: size)

        let p = CameraPanel(contentRect: smallFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onDoubleClick = { [weak self] in self?.toggleFullscreen() }

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        view.layer?.cornerRadius = rounded ? 18 : side / 2
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.cgColor
        view.layer?.borderWidth = 3
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.videoGravity = .resizeAspectFill
        preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))   // mirror like a mirror
        view.layer?.addSublayer(preview)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
        self.preview = preview
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    /// Fullscreen camera mode: the camera fills the screen (e.g. for an intro), double-click again to shrink.
    private func toggleFullscreen() {
        guard let panel, let screen else { return }
        isFullscreen.toggle()
        let target = isFullscreen ? screen.frame : smallFrame
        panel.contentView?.layer?.cornerRadius = isFullscreen ? 0 : (AppSettings.cameraShape == 1 ? 18 : smallFrame.height / 2)
        panel.contentView?.layer?.borderWidth = isFullscreen ? 0 : 3
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s?.stopRunning() }
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class CameraPanel: NSPanel {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
