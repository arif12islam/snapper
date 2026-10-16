import AppKit
import Vision
import CoreML

enum OCR {
    struct Output {
        var text: String
        var codes: [String]
        var error: String? = nil
    }

    private static let queue = DispatchQueue(label: "snapper.ocr", qos: .userInitiated, attributes: .concurrent)

    /// Loads the text model once at launch, so the first real capture does not pay for it.
    static func warmUp() {
        queue.async {
            let size = CGSize(width: 320, height: 64)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gc
            NSString(string: "Snapper reads text 0123").draw(at: NSPoint(x: 12, y: 20), withAttributes: [
                .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            if let img = ctx.makeImage() { _ = read(img, languages: ["en-US"], detect: false) }
        }
    }

    /// Recognises text and QR/barcodes at the same time. Text uses a fixed language list (language detection is
    /// slow and was the usual cause of empty results) and only falls back to detection when nothing was found.
    static func analyze(_ image: CGImage) async -> Output {
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let lock = NSLock()
            var lines: [String] = []
            var codes: [String] = []
            var failure: String?

            group.enter()
            queue.async {
                let prepared = prepare(image)
                var result = read(prepared, languages: languages(), detect: false)
                if result.lines.isEmpty, result.error == nil { result = read(prepared, languages: [], detect: true) }
                lock.lock(); lines = result.lines; failure = result.error; lock.unlock()
                group.leave()
            }
            group.enter()
            queue.async {
                let found = detectCodes(image)
                lock.lock(); codes = found; lock.unlock()
                group.leave()
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                lock.lock()
                let out = Output(text: lines.joined(separator: "\n"), codes: codes, error: lines.isEmpty && codes.isEmpty ? failure : nil)
                lock.unlock()
                continuation.resume(returning: out)
            }
        }
    }

    // MARK: Text

    /// One recognition attempt per strategy, stopping at the first that works. The default path runs on the
    /// Neural Engine; when that cannot start (CRImageReaderError, "could not create inference context") the
    /// same request runs on the CPU, and as a last resort in fast mode.
    private static func read(_ image: CGImage, languages: [String], detect: Bool) -> (lines: [String], error: String?) {
        let attempts: [(level: VNRequestTextRecognitionLevel, cpu: Bool)] = [(.accurate, false), (.accurate, true), (.fast, true)]
        var lastError: String?
        for attempt in attempts {
            let started = Date()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = attempt.level
            // Screenshots are full of code, URLs and names, which "correction" tends to mangle, and it is slower.
            request.usesLanguageCorrection = false
            if detect {
                request.automaticallyDetectsLanguage = true
            } else if !languages.isEmpty, attempt.level == .accurate {
                request.recognitionLanguages = languages
            }
            if attempt.cpu, let cpu = MLComputeDevice.allComputeDevices.first(where: {
                if case .cpu = $0 { return true } else { return false }
            }) {
                request.setComputeDevice(cpu, for: .main)
            }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                log("ok \(attempt.level == .fast ? "fast" : "accurate")\(attempt.cpu ? " cpu" : "") \(image.width)x\(image.height) in \(ms(started)) ms")
                return (readingOrder(request.results ?? []), nil)
            } catch {
                let e = error as NSError
                lastError = "\(e.domain) \(e.code)"
                log("fail \(attempt.level == .fast ? "fast" : "accurate")\(attempt.cpu ? " cpu" : "") \(image.width)x\(image.height) in \(ms(started)) ms: \(e.domain) \(e.code) \(e.userInfo)")
            }
        }
        return ([], lastError)
    }

    private static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    /// ~/Library/Logs/Snapper/ocr.log, so a failure can be diagnosed.
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Snapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ocr.log")
    }()

    private static func log(_ line: String) {
        NSLog("Snapper OCR: \(line)")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// English first, plus the user's own languages when Vision supports them.
    private static func languages() -> [String] {
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate,
                            revision: VNRecognizeTextRequestRevision3)) ?? []
        var chosen = ["en-US"]
        for preferred in Locale.preferredLanguages {
            let base = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if let match = supported.first(where: { $0 == preferred }) ?? supported.first(where: { $0.hasPrefix(base) }),
               !chosen.contains(match) {
                chosen.append(match)
            }
        }
        return Array(chosen.prefix(4))
    }

    /// Rows top to bottom, left to right inside a row. Grouping into rows first keeps the ordering consistent,
    /// which a plain "close enough" comparison cannot guarantee.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [String] {
        let items = observations.compactMap { o -> (box: CGRect, text: String)? in
            guard let t = o.topCandidates(1).first?.string, !t.isEmpty else { return nil }
            return (o.boundingBox, t)
        }.sorted { $0.box.midY > $1.box.midY }

        var rows: [[(box: CGRect, text: String)]] = []
        for item in items {
            if let last = rows.last, let first = last.first,
               abs(first.box.midY - item.box.midY) < max(first.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }

    /// Always redraws the capture into a plain 8-bit sRGB bitmap on white. Captures arrive in all sorts of pixel
    /// formats and colour spaces, and Vision's reader rejects some of them. Huge ones are scaled down (Vision does
    /// not need more than about 2600 px), tiny ones up to 2x.
    private static func prepare(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height), smallest = min(image.width, image.height)
        var k = 1.0
        if longest > 2600 { k = 2600.0 / Double(longest) }
        else if smallest < 160 { k = min(2.0, 320.0 / Double(max(smallest, 1))) }
        let w = max(2, Int(Double(image.width) * k)), h = max(2, Int(Double(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Codes

    private static func detectCodes(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            NSLog("Snapper OCR (codes): \(error)")
            return []
        }
        return (request.results ?? []).compactMap { $0.payloadStringValue }
    }
}
