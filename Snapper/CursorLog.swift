import AppKit

/// Pointer positions and clicks recorded alongside a video, used by the video editor for
/// smart zooms, smooth cursor movement and click effects.
/// Coordinates are normalised to the recorded area: 0...1, top-left origin. Times are seconds into the video.
struct CursorLog: Codable {
    var samples: [[Double]] = []     // [t, x, y]
    var clicks: [[Double]] = []      // [t, x, y]
    var cursorHidden = false         // true when the video was recorded without the cursor

    static func url(for video: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Snapper/CursorLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".json")
    }

    static func load(for video: URL) -> CursorLog? {
        guard let data = try? Data(contentsOf: url(for: video)) else { return nil }
        return try? JSONDecoder().decode(CursorLog.self, from: data)
    }

    func save(for video: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url(for: video), options: .atomic) }
    }

    var isEmpty: Bool { samples.isEmpty }

    // MARK: Queries (samples are sorted by time)

    private func index(before t: Double) -> Int {
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid][0] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Raw (linearly interpolated) position at time t.
    func position(at t: Double) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        let i = index(before: t)
        let a = samples[i]
        guard i + 1 < samples.count else { return CGPoint(x: a[1], y: a[2]) }
        let b = samples[i + 1]
        let span = max(b[0] - a[0], 0.0001)
        let k = min(max((t - a[0]) / span, 0), 1)
        return CGPoint(x: a[1] + (b[1] - a[1]) * k, y: a[2] + (b[2] - a[2]) * k)
    }

    /// Gaussian-weighted average around t: removes shaky motion.
    func smoothedPosition(at t: Double, window: Double) -> CGPoint? {
        guard window > 0.001 else { return position(at: t) }
        guard !samples.isEmpty else { return nil }
        var i = index(before: t - window)
        var sx = 0.0, sy = 0.0, sw = 0.0
        let sigma = window / 2
        while i < samples.count, samples[i][0] <= t + window {
            let d = samples[i][0] - t
            let w = exp(-(d * d) / (2 * sigma * sigma))
            sx += samples[i][1] * w
            sy += samples[i][2] * w
            sw += w
            i += 1
        }
        guard sw > 0 else { return position(at: t) }
        return CGPoint(x: sx / sw, y: sy / sw)
    }
}

/// Collects a CursorLog while recording.
@MainActor
final class CursorRecorder {
    private var log = CursorLog()
    private let region: CGRect           // global Cocoa coordinates
    private var start = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var timer: Timer?
    private var clickMonitor: Any?

    init(region: CGRect, cursorHidden: Bool) {
        self.region = region
        log.cursorHidden = cursorHidden
    }

    private var now: Double {
        Date().timeIntervalSince(start) - pausedTotal
    }

    private func normalised(_ p: CGPoint) -> (Double, Double) {
        (Double((p.x - region.minX) / max(region.width, 1)), Double((region.maxY - p.y) / max(region.height, 1)))
    }

    func begin() {
        start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        timer?.tolerance = 0.03
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor [weak self] in self?.click(at: p) }
        }
    }

    private func sample() {
        guard pausedAt == nil else { return }
        let (x, y) = normalised(NSEvent.mouseLocation)
        let n = log.samples.count
        if n >= 2, log.samples[n-1][1] == x, log.samples[n-1][2] == y, log.samples[n-2][1] == x, log.samples[n-2][2] == y {
            log.samples[n-1][0] = now   // still: extend the hold instead of storing more samples
            return
        }
        log.samples.append([now, x, y])
    }

    private func click(at p: CGPoint) {
        guard pausedAt == nil else { return }
        let (x, y) = normalised(p)
        log.clicks.append([now, x, y])
    }

    func setPaused(_ paused: Bool) {
        if paused {
            pausedAt = Date()
        } else if let at = pausedAt {
            pausedTotal += Date().timeIntervalSince(at)
            pausedAt = nil
        }
    }

    func finish(for video: URL) {
        timer?.invalidate()
        timer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        log.save(for: video)
    }
}
