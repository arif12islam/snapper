import AppKit
import ImageIO
import AVFoundation
import ScreenCaptureKit

@MainActor
final class RecordingSession {
    static let shared = RecordingSession()
    private init() {}

    private(set) var isRecording = false
    private var starting = false
    private var engine: RecorderEngine?
    private var controls: RecordingControls?
    private var overlays: InputOverlays?
    private var camera: CameraBubble?
    private var statusItem: RecordingStatusItem?
    private var cursor: CursorRecorder?
    private var recordingURL: URL?
    private var makeGIF = false
    private var screen: NSScreen?
    private var iconsHidden = false
    private var focusOn = false

    // MARK: - Public

    func toggleFullscreen() {
        if isRecording { stop() } else { start(area: false) }
    }

    /// Records the display under the mouse, or a selected area.
    func start(area: Bool, gif: Bool = false) {
        guard canStart() else { return }
        starting = true
        if area {
            AreaCaptureOverlay.present { [weak self] result in
                guard let self else { return }
                guard let result, let rect = result.areaRect, let displayID = result.displayID else {
                    self.starting = false
                    return
                }
                Task { await self.beginDisplay(screen: result.screen, displayID: displayID, rect: rect, gif: gif) }
            }
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let screen, let id = Self.displayID(of: screen) else {
                starting = false
                return
            }
            Task { await beginDisplay(screen: screen, displayID: id, rect: screen.frame, gif: gif) }
        }
    }

    /// Records an area chosen elsewhere (all-in-one mode).
    func startRecording(rect: CGRect, screen: NSScreen, displayID: CGDirectDisplayID, gif: Bool) {
        guard canStart() else { return }
        starting = true
        Task { await beginDisplay(screen: screen, displayID: displayID, rect: rect, gif: gif) }
    }

    /// Records a single window (it can move and be covered; only that window is recorded).
    func startWindow(gif: Bool = false) {
        guard canStart() else { return }
        starting = true
        WindowPickerOverlay.pick { [weak self] picked, screen in
            guard let self else { return }
            guard let picked, let screen else { self.starting = false; return }
            Task { await self.beginWindow(picked, screen: screen, gif: gif) }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        let url = recordingURL
        if let url { cursor?.finish(for: url) }
        teardownUI()
        restoreEnvironment()
        guard let engine else { return }
        self.engine = nil
        let gif = makeGIF
        let screen = self.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let fileURL = url
        Task {
            let (url, error) = await engine.stop()
            Self.clearManifest()
            if let url {
                await self.finished(url: url, gif: gif, screen: screen)
                return
            }
            guard let error else { return }
            Self.logFailure(error)
            // If finishing fails, keep whatever part of the file still plays.
            if let fileURL, await Self.isPlayable(fileURL) {
                Toast.show("Recording saved, but it ended early", on: screen, seconds: 3)
                await self.finished(url: fileURL, gif: gif, screen: screen)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "The recording couldn\u{2019}t be finished"
            alert.informativeText = Self.describe(error) + "\n\nDetails are in ~/Library/Logs/Snapper/recording.log"
            alert.runModal()
        }
    }

    /// Domain, code, message and the underlying error, which is where AVFoundation puts the real reason.
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        var text = "\(e.localizedDescription) (\(e.domain) \(e.code))"
        if let reason = e.localizedFailureReason { text += "\n\(reason)" }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "\nUnderlying: \(under.localizedDescription) (\(under.domain) \(under.code))"
        }
        return text
    }

    private static func logFailure(_ error: Error) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Snapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("recording.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(describe(error).replacingOccurrences(of: "\n", with: " | ")) \((error as NSError).userInfo)\n"
        NSLog("Snapper recording: \(line)")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: log)
        }
    }

    private static func isPlayable(_ url: URL) async -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 10_000 else { return false }
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration), duration.seconds > 0.3 else { return false }
        return true
    }

    // MARK: - Start

    private func canStart() -> Bool {
        guard !isRecording, !starting else { return false }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            return false
        }
        return true
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func options() async -> RecordingOptions {
        var options = RecordingOptions()
        options.systemAudio = AppSettings.recordSystemAudio
        options.fps = AppSettings.recordFPS
        options.quality = AppSettings.recordQuality
        options.showsCursor = AppSettings.recordShowCursor && !AppSettings.editableCursor
        options.mic = AppSettings.recordMic
        if options.mic {
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok {
                options.mic = false
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Microphone access is off"
                alert.informativeText = "Recording will continue without the microphone. You can allow it in System Settings > Privacy & Security > Microphone."
                alert.runModal()
            }
        }
        return options
    }

    /// Output pixel size: native, or capped at 1080p / 720p (Settings > Recording > Resolution). Always even.
    private static func outputSize(points: CGSize, scale: CGFloat) -> (Int, Int) {
        var w = points.width * scale, h = points.height * scale
        let caps: [(CGFloat, CGFloat)?] = [nil, (1920, 1080), (1280, 720)]
        if let cap = caps[min(max(AppSettings.recordResolution, 0), 2)] {
            let k = min(1, cap.0 / max(w, h), cap.1 / max(min(w, h), 1))
            w *= k
            h *= k
        }
        func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
        return (even(w), even(h))
    }

    private func prepareEnvironment() async {
        if AppSettings.recordHideDesktopIcons, DesktopIconManager.areVisible() {
            DesktopIconManager.setVisible(false)
            iconsHidden = true
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if AppSettings.recordDoNotDisturb {
            focusOn = FocusMode.set(true)
        }
    }

    private func restoreEnvironment() {
        if iconsHidden {
            DesktopIconManager.setVisible(true)
            iconsHidden = false
        }
        if focusOn {
            _ = FocusMode.set(false)
            focusOn = false
        }
    }

    private func showUI(on screen: NSScreen, mic: Bool) async -> RecordingControls {
        let controls = RecordingControls(screen: screen, showMeter: mic)
        controls.onStop = { [weak self] in self?.stop() }
        controls.onPauseToggle = { [weak self] paused in
            if paused { self?.engine?.pause() } else { self?.engine?.resume() }
            self?.cursor?.setPaused(paused)
        }
        controls.onTick = { [weak self] elapsed, paused in self?.statusItem?.update(elapsed: elapsed, paused: paused) }
        controls.show()
        self.controls = controls

        let item = RecordingStatusItem()
        item.onStop = { [weak self] in self?.stop() }
        statusItem = item

        if AppSettings.showCamera {
            let bubble = CameraBubble()
            await bubble.show(on: screen)
            camera = bubble
        }
        let overlays = InputOverlays(screen: screen, showClicks: AppSettings.showClicks, showKeys: AppSettings.showKeystrokes)
        overlays.start()
        self.overlays = overlays

        // Let the controls window register with the window server so it can be excluded.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return controls
    }

    private func beginDisplay(screen: NSScreen, displayID: CGDirectDisplayID, rect: CGRect, gif: Bool) async {
        defer { starting = false }
        let options = await options()
        guard let displays = try? await CaptureEngine.displays(),
              let display = displays.first(where: { $0.displayID == displayID }) else { return }

        await prepareEnvironment()
        await CountdownOverlay.run(seconds: AppSettings.countdownSeconds, on: screen)
        let controls = await showUI(on: screen, mic: options.mic)

        // Display-local rect in points with a top-left origin.
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: screen.frame.maxY - rect.maxY,
                           width: rect.width, height: rect.height)
        let sourceRect = local.intersection(CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height))
        guard !sourceRect.isNull, sourceRect.width >= 16, sourceRect.height >= 16 else {
            teardownUI()
            restoreEnvironment()
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let excluded = content.windows.filter { $0.windowID == CGWindowID(controls.windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let (w, h) = Self.outputSize(points: sourceRect.size, scale: screen.backingScaleFactor)
            await run(filter: filter, width: w, height: h, sourceRect: sourceRect, region: rect,
                      screen: screen, options: options, gif: gif)
        } catch {
            fail(error)
        }
    }

    private func beginWindow(_ picked: WindowPickerOverlay.PickedWindow, screen: NSScreen, gif: Bool) async {
        defer { starting = false }
        let options = await options()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == picked.windowID }) else {
                throw NSError(domain: "Snapper", code: 30, userInfo: [NSLocalizedDescriptionKey: "That window can't be recorded."])
            }
            await prepareEnvironment()
            await CountdownOverlay.run(seconds: AppSettings.countdownSeconds, on: screen)
            _ = await showUI(on: screen, mic: options.mic)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let (w, h) = Self.outputSize(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
            await run(filter: filter, width: w, height: h, sourceRect: nil, region: picked.frame,
                      screen: screen, options: options, gif: gif)
        } catch {
            fail(error)
        }
    }

    private func run(filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect?, region: CGRect,
                     screen: NSScreen, options: RecordingOptions, gif: Bool) async {
        let url = Self.newRecordingURL()
        let engine = RecorderEngine()
        engine.onLevel = { [weak self] level in self?.controls?.setLevel(level) }
        engine.onFailure = { [weak self] _ in self?.stop() }
        self.engine = engine
        self.recordingURL = url
        self.makeGIF = gif
        self.screen = screen
        isRecording = true
        do {
            Self.writeManifest(url: url)
            try await engine.start(filter: filter, width: width, height: height, sourceRect: sourceRect,
                                   url: url, options: options)
            let recorder = CursorRecorder(region: region, cursorHidden: AppSettings.editableCursor)
            recorder.begin()
            cursor = recorder
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        isRecording = false
        engine = nil
        teardownUI()
        restoreEnvironment()
        Self.clearManifest()
        Self.logFailure(error)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "The recording couldn\u{2019}t start"
        alert.informativeText = Self.describe(error)
        alert.runModal()
    }

    private func teardownUI() {
        controls?.close()
        overlays?.stop()
        camera?.hide()
        statusItem?.remove()
        controls = nil
        overlays = nil
        camera = nil
        statusItem = nil
        cursor = nil
    }

    // MARK: - Finish

    private func finished(url: URL, gif: Bool, screen: NSScreen) async {
        if gif {
            let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
            Toast.show("Making GIF…", on: screen, seconds: 30)
            let error = await GIFExporter.export(video: url, to: gifURL, progress: { _ in })
            if let error {
                Toast.show("GIF failed: \(error.localizedDescription)", on: screen, seconds: 5)
                await present(url, kind: "recording", screen: screen)
                return
            }
            Toast.show("GIF ready", on: screen, seconds: 1.2)
            try? FileManager.default.removeItem(at: url)
            await present(gifURL, kind: "gif", screen: screen)
        } else {
            await present(url, kind: "recording", screen: screen)
        }
    }

    private func present(_ url: URL, kind: String, screen: NSScreen) async {
        var thumb: CGImage?
        if kind == "gif" {
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) { thumb = CGImageSourceCreateImageAtIndex(src, 0, nil) }
        } else {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            thumb = try? await gen.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        }
        HistoryStore.shared.addVideo(url: url, thumbnail: thumb, kind: kind)
        if AppSettings.showQuickAccess {
            QuickAccessPanel.showVideo(url: url, screen: screen)
        } else if kind == "recording" {
            VideoWindowController.open(url: url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Files and crash recovery

    private static func newRecordingURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = movies.appendingPathComponent("Snapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(f.string(from: Date())).mp4")
    }

    private static var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snapper/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active.json")
    }

    private static func writeManifest(url: URL) {
        let info: [String: String] = ["path": url.path, "started": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    private static func clearManifest() {
        try? FileManager.default.removeItem(at: manifestURL)
    }

    /// Called at launch: if the last recording never finished, offer to open what was saved.
    static func offerRecovery() {
        guard let data = try? Data(contentsOf: manifestURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let path = info["path"] else { return }
        defer { clearManifest() }
        let url = URL(fileURLWithPath: path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard FileManager.default.fileExists(atPath: path), size > 0 else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "A recording didn't finish"
        alert.informativeText = "Snapper quit unexpectedly while recording. The part that was saved is in \(url.lastPathComponent). It is stored in segments, so most of it should play."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: VideoWindowController.open(url: url)
        case .alertSecondButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
        default: break
        }
    }
}

/// Do Not Disturb while recording. macOS has no public API for Focus, so this runs two Shortcuts the user
/// creates once: "Snapper Focus On" (Set Focus: Do Not Disturb, On) and "Snapper Focus Off".
enum FocusMode {
    static let onShortcut = "Snapper Focus On"
    static let offShortcut = "Snapper Focus Off"

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        let tool = "/usr/bin/shortcuts"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["run", on ? onShortcut : offShortcut]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
