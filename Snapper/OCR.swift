import AppKit
import Vision

enum OCR {
    struct Output {
        var text: String
        var codes: [String]
        var error: String? = nil
    }

    /// Recognises text (automatic language detection) and QR/barcodes. Each request runs on its own, so a failure
    /// in one never hides the result of the other, and text falls back from accurate to fast mode.
    static func analyze(_ image: CGImage) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errors: [String] = []
                let source = upscaledIfSmall(image)

                func recognize(_ level: VNRequestTextRecognitionLevel, detectLanguage: Bool) -> [VNRecognizedTextObservation] {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = level
                    request.usesLanguageCorrection = level == .accurate
                    if detectLanguage {
                        request.automaticallyDetectsLanguage = true
                    } else {
                        request.recognitionLanguages = ["en-US"]
                    }
                    do {
                        try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
                        return request.results ?? []
                    } catch {
                        errors.append(error.localizedDescription)
                        NSLog("Snapper OCR: \(error)")
                        return []
                    }
                }

                var observations = recognize(.accurate, detectLanguage: true)
                if observations.isEmpty { observations = recognize(.accurate, detectLanguage: false) }
                if observations.isEmpty { observations = recognize(.fast, detectLanguage: false) }

                // Keep reading order: top to bottom, then left to right.
                observations.sort {
                    let a = $0.boundingBox, b = $1.boundingBox
                    if abs(a.midY - b.midY) > 0.01 { return a.midY > b.midY }
                    return a.minX < b.minX
                }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }

                var codes: [String] = []
                let codeRequest = VNDetectBarcodesRequest()
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([codeRequest])
                    codes = (codeRequest.results ?? []).compactMap { $0.payloadStringValue }
                } catch {
                    NSLog("Snapper OCR (codes): \(error)")
                }

                continuation.resume(returning: Output(text: lines.joined(separator: "\n"), codes: codes,
                                                      error: errors.first))
            }
        }
    }

    /// Small crops read much better at 2x.
    private static func upscaledIfSmall(_ image: CGImage) -> CGImage {
        let smallest = min(image.width, image.height)
        guard smallest < 700 else { return image }
        let k = min(3.0, 1400.0 / Double(max(smallest, 1)))
        let w = Int(Double(image.width) * k), h = Int(Double(image.height) * k)
        guard k > 1.2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

/// Small transient message near the bottom of a screen: a plain glass capsule.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String, on screen: NSScreen? = nil, seconds: Double = 2.2) {
        current?.orderOut(nil)
        guard let target = screen ?? NSScreen.main else { return }
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let textWidth = ceil(NSAttributedString(string: message, attributes: [.font: font]).size().width)
        let size = NSSize(width: min(textWidth + 32, target.frame.width - 80), height: 30)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: (size.height - 16) / 2, width: size.width - 32, height: 16)
        content.addSubview(label)

        let vf = target.visibleFrame
        let panel = Glass.panel(size: size, cornerRadius: size.height / 2, level: .screenSaver, dark: true, content: content)
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 48))
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    if current === panel { current = nil }
                }
            })
        }
    }
}
