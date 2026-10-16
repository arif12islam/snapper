import AppKit
import ScreenCaptureKit
import CoreGraphics

struct CaptureResult: Identifiable {
    enum Kind: String, Codable { case area, window, fullscreen, scrolling }

    var id = UUID()
    let image: CGImage
    let kind: Kind
    var date = Date()
    let screen: NSScreen
    var areaRect: CGRect?              // global Cocoa coords; for "previous area"
    var displayID: CGDirectDisplayID?
    var png: Data? = nil               // encoded once, shared by history, Quick Access, copy and save

    /// PNG bytes (the cached copy when there is one).
    var pngData: Data? { png ?? CaptureEngine.pngData(image) }
}

enum CaptureError: Error {
    case noDisplay
    case captureFailed
}

enum CaptureEngine {
    static func displays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.displays
    }

    /// Captures a display at native pixel resolution (points x backing scale).
    static func captureDisplay(_ display: SCDisplay, excludeOwnWindows: Bool = false) async throws -> CGImage {
        var excluded: [SCWindow] = []
        if excludeOwnWindows {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let pid = ProcessInfo.processInfo.processIdentifier
            excluded = content.windows.filter { $0.owningApplication?.processID == pid }
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let scale = screen(for: display)?.backingScaleFactor ?? 2
        config.width = Int((CGFloat(display.width) * scale).rounded())
        config.height = Int((CGFloat(display.height) * scale).rounded())
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
    }

    /// `rect` is in global Cocoa points (bottom-left origin). The image is top-left origin pixels.
    static func cropDisplayImage(_ image: CGImage, display: SCDisplay,
                                 screen: NSScreen, rect: CGRect) -> CGImage? {
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        // Derive scale from the actual image so it is correct on Retina and non-Retina.
        let scaleX = CGFloat(image.width) / frame.width
        let scaleY = CGFloat(image.height) / frame.height

        let px = (rect.minX - frame.minX) * scaleX
        let pyFromTop = (frame.maxY - rect.maxY) * scaleY
        let cropRect = CGRect(x: px, y: pyFromTop,
                              width: rect.width * scaleX,
                              height: rect.height * scaleY).integral
        guard cropRect.width >= 2, cropRect.height >= 2 else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = cropRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else { return nil }
        return image.cropping(to: clamped)
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private init() {}

    private var isCapturing = false
    private(set) var lastResult: CaptureResult?
    private var lastArea: (rect: CGRect, displayID: CGDirectDisplayID)?
    private var iconsWereVisible = true
    private var iconsHidden = false

    func captureArea() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.present { result in
                self.endCapture()
                if let result { self.finish(result) }
            }
        }
    }

    /// One shortcut for everything: select an area, then pick screenshot, recording, GIF, scrolling, OCR, pin or timer.
    func captureAllInOne() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.presentAllInOne { result, action in
                guard let result else { self.endCapture(); return }
                switch action {
                case .screenshot:
                    self.endCapture()
                    self.finish(result)
                case .text:
                    self.endCapture()
                    self.recognizeText(in: result)
                case .pin:
                    self.endCapture()
                    PinPanel.pin(result.image, near: result.screen)
                case .scrolling:
                    self.runScrolling(selected: result, horizontal: false)
                case .timer:
                    self.runTimer(selected: result)
                case .record, .gif:
                    self.endCapture()
                    if let rect = result.areaRect, let id = result.displayID {
                        RecordingSession.shared.startRecording(rect: rect, screen: result.screen, displayID: id,
                                                               gif: action == .gif)
                    }
                }
            }
        }
    }

    /// Select an area, count down, then capture it (menus, hover states…).
    func captureSelfTimer() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.present { result in
                guard let result else { self.endCapture(); return }
                self.runTimer(selected: result)
            }
        }
    }

    /// Fullscreen capture after the self-timer countdown.
    func captureFullscreenTimer() {
        guard beginCapture() else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
              let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            endCapture()
            return
        }
        Task {
            await settleIfNeeded()
            await CountdownOverlay.run(seconds: AppSettings.selfTimerSeconds, on: screen)
            try? await Task.sleep(nanoseconds: 250_000_000)
            defer { endCapture() }
            guard let displays = try? await CaptureEngine.displays(),
                  let display = displays.first(where: { $0.displayID == id }),
                  let image = try? await CaptureEngine.captureDisplay(display) else { return }
            finish(CaptureResult(image: image, kind: .fullscreen, screen: screen, areaRect: nil, displayID: id))
            FlashOverlay.flash(on: screen)
        }
    }

    private func runTimer(selected: CaptureResult) {
        guard let rect = selected.areaRect, let id = selected.displayID else { endCapture(); return }
        Task {
            await CountdownOverlay.run(seconds: AppSettings.selfTimerSeconds, on: selected.screen)
            try? await Task.sleep(nanoseconds: 250_000_000)
            defer { endCapture() }
            guard let displays = try? await CaptureEngine.displays(),
                  let display = displays.first(where: { $0.displayID == id }),
                  let image = try? await CaptureEngine.captureDisplay(display),
                  let cropped = CaptureEngine.cropDisplayImage(image, display: display, screen: selected.screen, rect: rect)
            else { return }
            finish(CaptureResult(image: cropped, kind: .area, screen: selected.screen, areaRect: rect, displayID: id))
            FlashOverlay.flash(on: selected.screen)
        }
    }

    /// Select an area, recognise its text and QR codes, and put the result on the clipboard.
    func captureText() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.present { result in
                self.endCapture()
                if let result { self.recognizeText(in: result) }
            }
        }
    }

    private func recognizeText(in result: CaptureResult) {
        Task {
            Toast.show("Reading text…", on: result.screen, seconds: 10)
            let output = await OCR.analyze(result.image)
            let combined = ([output.text] + output.codes).filter { !$0.isEmpty }.joined(separator: "\n")
            if combined.isEmpty {
                if let error = output.error {
                    Toast.show("Text recognition failed: \(error)", on: result.screen, seconds: 4)
                } else {
                    Toast.show("No text found", on: result.screen)
                }
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(combined, forType: .string)
                let what = output.codes.isEmpty ? "\(output.text.count) characters" : "text and \(output.codes.count) code(s)"
                Toast.show("Copied \(what)", on: result.screen)
            }
        }
    }

    /// Area capture whose result floats on screen as a pin instead of opening Quick Access.
    func capturePinArea() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.present { result in
                self.endCapture()
                if let result { PinPanel.pin(result.image, near: result.screen) }
            }
        }
    }

    /// Select a region, then scroll it automatically and stitch the frames together.
    func captureScrolling(horizontal: Bool) {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            AreaCaptureOverlay.present { selected in
                guard let selected else { self.endCapture(); return }
                self.runScrolling(selected: selected, horizontal: horizontal)
            }
        }
    }

    private func runScrolling(selected: CaptureResult, horizontal: Bool) {
        guard let rect = selected.areaRect, let displayID = selected.displayID else {
            endCapture()
            return
        }
        Task {
            defer { self.endCapture() }
            guard let displays = try? await CaptureEngine.displays(),
                  let display = displays.first(where: { $0.displayID == displayID }) else { return }
            let stitched = await ScrollCapture.run(rect: rect, display: display, screen: selected.screen,
                                                   firstFrame: selected.image, horizontal: horizontal)
            if let stitched {
                let result = CaptureResult(image: stitched, kind: .scrolling, screen: selected.screen,
                                           areaRect: nil, displayID: displayID)
                self.finish(result)
            } else {
                // Nothing scrolled (or scrolling was not allowed): keep the plain selection.
                self.finish(selected)
            }
        }
    }

    func captureWindow() {
        guard beginCapture() else { return }
        Task {
            await settleIfNeeded()
            WindowPickerOverlay.present { result in
                self.endCapture()
                if let result { self.finish(result) }
            }
        }
    }

    func captureFullscreen() {
        guard beginCapture() else { return }
        Task {
            defer { endCapture() }
            await settleIfNeeded()
            do {
                let displays = try await CaptureEngine.displays()
                let mouse = NSEvent.mouseLocation
                let underMouse = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
                var chosen: SCDisplay?
                if let underMouse {
                    chosen = displays.first { CaptureEngine.screen(for: $0) == underMouse }
                }
                guard let display = chosen ?? displays.first,
                      let screen = CaptureEngine.screen(for: display) else { return }
                let image = try await CaptureEngine.captureDisplay(display)
                let result = CaptureResult(image: image, kind: .fullscreen, screen: screen,
                                           areaRect: nil, displayID: display.displayID)
                finish(result)
                FlashOverlay.flash(on: screen)
            } catch {
                NSSound.beep()
            }
        }
    }

    func capturePreviousArea() {
        guard let last = lastArea, beginCapture() else { return }
        Task {
            defer { endCapture() }
            await settleIfNeeded()
            do {
                let displays = try await CaptureEngine.displays()
                guard let display = displays.first(where: { $0.displayID == last.displayID }),
                      let screen = CaptureEngine.screen(for: display) else { return }
                let image = try await CaptureEngine.captureDisplay(display)
                guard let cropped = CaptureEngine.cropDisplayImage(image, display: display,
                                                                   screen: screen, rect: last.rect) else { return }
                let result = CaptureResult(image: cropped, kind: .area, screen: screen,
                                           areaRect: last.rect, displayID: display.displayID)
                finish(result)
                FlashOverlay.flash(on: screen)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Re-opens the most recently closed overlay (or the last capture).
    func restoreLast() {
        if !QuickAccessPanel.restoreRecentlyClosed(), let result = lastResult {
            QuickAccessPanel.show(for: result)
        }
    }

    // MARK: - Private

    private func beginCapture() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        iconsHidden = false
        if AppSettings.hideDesktopIcons {
            iconsWereVisible = DesktopIconManager.areVisible()
            if iconsWereVisible {
                DesktopIconManager.setVisible(false)
                iconsHidden = true
            }
        }
        return true
    }

    private func endCapture() {
        if iconsHidden {
            DesktopIconManager.setVisible(true)
            iconsHidden = false
        }
        isCapturing = false
    }

    /// The icon cover window needs one frame on screen before we grab pixels.
    private func settleIfNeeded() async {
        if iconsHidden {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static let shutter: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop")
    }()

    func finish(_ input: CaptureResult) {
        if AppSettings.playSound { Self.shutter?.play() }
        lastResult = input
        if input.kind == .area, let rect = input.areaRect, let id = input.displayID {
            lastArea = (rect, id)
        }
        // Encode the PNG once, off the main thread; history, Quick Access, copy and save all share it.
        let image = input.image
        Task {
            let data = await Task.detached(priority: .userInitiated) { CaptureEngine.pngData(image) }.value
            var result = input
            result.png = data
            self.lastResult = result
            self.deliver(result)
        }
    }

    private func deliver(_ result: CaptureResult) {
        HistoryStore.shared.add(result)
        if AppSettings.copyAfterCapture, let data = result.png {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
        }
        if AppSettings.saveAfterCapture, let data = result.png {
            let folder = AppSettings.saveFolder
            let name = FileNamer.name(kind: result.kind.rawValue.capitalized, width: result.image.width,
                                      height: result.image.height, date: result.date)
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: folder.appendingPathComponent(name))
            }
        }
        if AppSettings.showQuickAccess {
            QuickAccessPanel.show(for: result)
        } else if AppSettings.copyAfterCapture {
            Toast.show("Copied to clipboard", on: result.screen, seconds: 1.4)
        }
    }
}
