import AppKit
import ScreenCaptureKit
import ApplicationServices

/// Pixel data used for overlap matching.
private struct Luma {
    var data: [UInt8]
    var w: Int
    var h: Int

    init(_ image: CGImage) {
        w = image.width
        h = image.height
        data = [UInt8](repeating: 0, count: w * h)
        let (width, height) = (w, h)
        data.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private init(data: [UInt8], w: Int, h: Int) { self.data = data; self.w = w; self.h = h }

    func transposed() -> Luma {
        var out = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeBufferPointer { src in
            for y in 0..<h { for x in 0..<w { out[x * h + y] = src[y * w + x] } }
        }
        return Luma(data: out, w: h, h: w)
    }
}

/// Floating "capturing…" HUD with a Stop button. It belongs to this app, so it is excluded from the capture.
@MainActor
private final class ScrollHUD: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "Capturing")
    private(set) var stopRequested = false

    init(screen: NSScreen) {
        let size = NSSize(width: 236, height: 36)
        let vf = screen.visibleFrame
        panel = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 16,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        label.frame = NSRect(x: 16, y: 9, width: 150, height: 18)
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.frame = NSRect(x: 170, y: 5, width: 58, height: 26)
        content.addSubview(label)
        content.addSubview(stop)
        panel.hasShadow = true
        panel.contentView = Glass.surface(content, cornerRadius: 18, dark: true)
        panel.orderFrontRegardless()
    }

    @objc private func stop() { stopRequested = true }

    func update(frames: Int, length: Int) {
        label.stringValue = "Capturing  \(frames) frames"
    }

    func close() { panel.orderOut(nil) }
}

@MainActor
enum ScrollCapture {
    static let maxLength = 20_000   // pixels, along the scroll axis

    /// Runs a scrolling capture of `rect` (global Cocoa points) on `display`.
    /// Returns the stitched image, or nil if nothing useful could be captured.
    static func run(rect: CGRect, display: SCDisplay, screen: NSScreen,
                    firstFrame: CGImage, horizontal: Bool) async -> CGImage? {
        guard ensureEventPostingAllowed() else { return nil }

        let hud = ScrollHUD(screen: screen)
        defer { hud.close() }

        // Cursor goes to the middle of the region so the wheel events hit the right view.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: rect.midX, y: mainHeight - rect.midY)
        let originalCursor = CGEvent(source: nil)?.location ?? center
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        defer { CGWarpMouseCursorPosition(originalCursor) }

        var parts: [CGImage] = [firstFrame]
        var previous = firstFrame
        var total = horizontal ? firstFrame.width : firstFrame.height
        var failures = 0
        let scrollPoints = Int32((horizontal ? rect.width : rect.height) * 0.4)
        var truncated = false

        for _ in 0..<80 {
            if hud.stopRequested { break }
            postScroll(points: scrollPoints, horizontal: horizontal)
            try? await Task.sleep(nanoseconds: 450_000_000)

            guard let full = try? await CaptureEngine.captureDisplay(display, excludeOwnWindows: true),
                  let frame = CaptureEngine.cropDisplayImage(full, display: display, screen: screen, rect: rect),
                  frame.width == previous.width, frame.height == previous.height else {
                failures += 1
                if failures >= 2 { break }
                continue
            }

            guard let shift = overlapShift(previous: previous, next: frame, horizontal: horizontal) else {
                break   // reached the end, or the content could not be matched
            }
            let slice: CGRect = horizontal
                ? CGRect(x: frame.width - shift, y: 0, width: shift, height: frame.height)
                : CGRect(x: 0, y: frame.height - shift, width: frame.width, height: shift)
            guard let piece = frame.cropping(to: slice) else { break }
            parts.append(piece)
            total += shift
            previous = frame
            hud.update(frames: parts.count, length: total)

            if total >= maxLength { truncated = true; break }
        }

        if truncated {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Capture stopped at \(maxLength) px"
            alert.informativeText = "Very long captures use a lot of memory, so Snapper stopped here. The image so far was kept."
            alert.runModal()
        }
        guard parts.count > 1 else { return nil }
        return stitch(parts, horizontal: horizontal)
    }

    // MARK: - Event posting

    private static func ensureEventPostingAllowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed for scrolling capture"
        alert.informativeText = "Snapper scrolls the page for you by sending scroll events. Enable Snapper in System Settings > Privacy & Security > Accessibility, then try again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    private static func postScroll(points: Int32, horizontal: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Negative wheel1 scrolls down; negative wheel2 scrolls right.
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: horizontal ? 0 : -points,
                            wheel2: horizontal ? -points : 0,
                            wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Overlap matching

    /// How many pixels the content moved between the two frames, or nil if the frames are
    /// identical (end of content) or cannot be matched confidently.
    private static func overlapShift(previous: CGImage, next: CGImage, horizontal: Bool) -> Int? {
        var a = Luma(previous)
        var b = Luma(next)
        if horizontal { a = a.transposed(); b = b.transposed() }
        let w = a.w, h = a.h
        guard w == b.w, h == b.h, h >= 40 else { return nil }

        let colStep = max(1, w / 160)
        let samplesPerRow = (w + colStep - 1) / colStep

        return a.data.withUnsafeBufferPointer { pa -> Int? in
            b.data.withUnsafeBufferPointer { pb -> Int? in
                // 1. Identical frames mean we hit the end of the content.
                var diffSum = 0, diffCount = 0
                var y = 0
                while y < h {
                    var x = 0
                    while x < w {
                        diffSum += abs(Int(pa[y * w + x]) - Int(pb[y * w + x]))
                        diffCount += 1
                        x += colStep
                    }
                    y += 3
                }
                if Double(diffSum) / Double(max(diffCount, 1)) < 0.4 { return nil }

                // 2. Find where a strip from the next frame appears in the previous one.
                //    The strip starts below the top quarter so sticky headers don't confuse it.
                let strip = max(16, min(64, h / 5))
                let stripStart = h / 4
                guard stripStart + strip < h else { return nil }
                let maxP = h - strip
                guard maxP > stripStart + 1 else { return nil }

                var bestP = -1
                var bestErr = Int.max
                for p in (stripStart + 1)...maxP {
                    var err = 0
                    var r = 0
                    while r < strip {
                        let rowA = (p + r) * w
                        let rowB = (stripStart + r) * w
                        var x = 0
                        while x < w {
                            err += abs(Int(pa[rowA + x]) - Int(pb[rowB + x]))
                            x += colStep
                        }
                        if err >= bestErr { break }
                        r += 2
                    }
                    if err < bestErr { bestErr = err; bestP = p }
                }
                guard bestP > 0 else { return nil }
                let rowsSampled = (strip + 1) / 2
                let meanErr = Double(bestErr) / Double(max(rowsSampled * samplesPerRow, 1))
                guard meanErr < 8 else { return nil }
                return bestP - stripStart
            }
        }
    }

    // MARK: - Stitching

    private static func stitch(_ parts: [CGImage], horizontal: Bool) -> CGImage? {
        guard let first = parts.first else { return nil }
        let width = horizontal ? parts.reduce(0) { $0 + $1.width } : first.width
        let height = horizontal ? first.height : parts.reduce(0) { $0 + $1.height }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        var offset = 0
        for part in parts {
            if horizontal {
                ctx.draw(part, in: CGRect(x: offset, y: 0, width: part.width, height: part.height))
                offset += part.width
            } else {
                // CGContext origin is bottom-left; stack from the top.
                ctx.draw(part, in: CGRect(x: 0, y: height - offset - part.height, width: part.width, height: part.height))
                offset += part.height
            }
        }
        return ctx.makeImage()
    }
}
