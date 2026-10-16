import AppKit
import Combine
import ImageIO

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        let date: Date
        let kind: String           // area, window, fullscreen, scrolling, recording, gif
        let width: Int
        let height: Int
        let file: String           // PNG in the history folder (the thumbnail for videos)
        var path: String? = nil    // videos: the movie / GIF on disk

        var isVideo: Bool { path != nil }

        var label: String {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return "\(kind.capitalized) • \(f.string(from: date)) • \(width)×\(height)"
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", screenshots = "Screenshots", windows = "Windows", scrolling = "Scrolling", recordings = "Recordings"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .screenshots: return "camera.viewfinder"
            case .windows: return "macwindow"
            case .scrolling: return "scroll"
            case .recordings: return "record.circle"
            }
        }

        func matches(_ e: Entry) -> Bool {
            switch self {
            case .all: return true
            case .screenshots: return e.kind == "area" || e.kind == "fullscreen"
            case .windows: return e.kind == "window"
            case .scrolling: return e.kind == "scrolling"
            case .recordings: return e.isVideo
            }
        }
    }

    @Published private(set) var entries: [Entry] = []

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private let thumbCache = NSCache<NSString, NSImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Snapper/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadIndex()
    }

    func add(_ result: CaptureResult) {
        guard let data = result.pngData else { return }
        let file = "\(result.id.uuidString).png"
        let url = directory.appendingPathComponent(file)
        // Write off the main thread; the entry is listed right away.
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url) }
        let entry = Entry(id: result.id, date: result.date, kind: result.kind.rawValue,
                          width: result.image.width, height: result.image.height, file: file)
        insert(entry)
    }

    /// Records a finished recording or GIF (the file stays where it was saved).
    func addVideo(url: URL, thumbnail: CGImage?, kind: String) {
        let id = UUID()
        let file = "\(id.uuidString).png"
        if let thumbnail, let data = CaptureEngine.pngData(thumbnail) {
            try? data.write(to: directory.appendingPathComponent(file))
        }
        let entry = Entry(id: id, date: Date(), kind: kind, width: thumbnail?.width ?? 0, height: thumbnail?.height ?? 0,
                          file: file, path: url.path)
        insert(entry)
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        saveIndex()
        purgeOld()
    }

    func recent(limit: Int = 20) -> [Entry] {
        Array(entries.prefix(limit))
    }

    func fileURL(for entry: Entry) -> URL {
        directory.appendingPathComponent(entry.file)
    }

    func nsImage(for entry: Entry) -> NSImage? {
        NSImage(contentsOf: fileURL(for: entry))
    }

    /// Small, cached thumbnail (decoded at reduced size, so big captures stay cheap).
    func thumbnail(for entry: Entry, maxPixel: Int = 360) -> NSImage? {
        let key = entry.file as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(fileURL(for: entry) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache.setObject(img, forKey: key)
        return img
    }

    @MainActor
    func restore(_ entry: Entry) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        if let path = entry.path {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Toast.show("The file was moved or deleted")
                return
            }
            QuickAccessPanel.showVideo(url: url, screen: screen)
            return
        }
        guard let image = nsImage(for: entry),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let kind = CaptureResult.Kind(rawValue: entry.kind) ?? .area
        let result = CaptureResult(image: cg, kind: kind, screen: screen, areaRect: nil, displayID: nil)
        QuickAccessPanel.show(for: result)
    }

    @MainActor
    func annotate(_ entry: Entry) {
        if let path = entry.path {
            VideoWindowController.open(url: URL(fileURLWithPath: path))
            return
        }
        guard let image = nsImage(for: entry),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        AnnotateWindowController.open(image: cg)
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: fileURL(for: entry))
        thumbCache.removeObject(forKey: entry.file as NSString)
        entries.removeAll { $0.id == entry.id }
        saveIndex()
    }

    func deleteAll() {
        for e in entries { try? FileManager.default.removeItem(at: fileURL(for: e)) }
        thumbCache.removeAllObjects()
        entries.removeAll()
        saveIndex()
    }

    func purgeOld() {
        let cutoff = Date().addingTimeInterval(-AppSettings.retentionDays * 86_400)
        let expired = entries.filter { $0.date < cutoff }
        guard !expired.isEmpty else { return }
        for entry in expired {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file))
        }
        entries.removeAll { $0.date < cutoff }
        saveIndex()
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    private let ioQueue = DispatchQueue(label: "com.example.snapper.history", qos: .utility)

    private func saveIndex() {
        let snapshot = entries
        let url = indexURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
