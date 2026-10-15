import AppKit
import AVKit
import AVFoundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Editor state shown in the sidebar.
final class VideoEditModel: ObservableObject {
    @Published var settings = VideoEditSettings() {
        didSet { if oldValue != settings { onChange?() } }
    }
    @Published var hasCursorLog = false
    @Published var cursorHidden = false
    @Published var busy = false
    var onChange: (() -> Void)?
}

/// Window shown after a recording: playback, editor (background, format, smart zoom, cursor effects,
/// motion blur), trim, export to MP4 or GIF, copy, reveal and upload.
///
/// Edits are non-destructive: the original file is never changed. Trim, background, zoom and cursor settings
/// apply to every export, and Copy / Upload use the edited video as well.
@MainActor
final class VideoWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [ObjectIdentifier: VideoWindowController] = [:]

    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let url: URL
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let trimPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let exportPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var actionButtons: [NSButton] = []
    private let model = VideoEditModel()
    private var log: CursorLog?
    private var rebuildWork: DispatchWorkItem?
    private var rebuildGeneration = 0
    private var currentComposition: AVVideoComposition?
    private var trimRange: CMTimeRange?
    private var exportBox: ExportBox?
    private var exportTimer: Timer?
    private var gifTask: Task<Void, Never>?
    private var itemObservation: NSKeyValueObservation?
    private var isBusy = false
    private let isGIF: Bool

    static func open(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.show("The file was moved or deleted")
            return
        }
        // One editor per file.
        if let existing = controllers.values.first(where: { $0.url == url }) {
            AppPresence.track(existing.window)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let c = VideoWindowController(url: url)
        controllers[ObjectIdentifier(c)] = c
        c.window.center()
        AppPresence.track(c.window)
        c.window.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        self.url = url
        isGIF = url.pathExtension.lowercased() == "gif"
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.subtitle = Brand.name
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 480)
        window.tabbingMode = .disallowed
        super.init()
        window.delegate = self

        log = CursorLog.load(for: url)
        model.hasCursorLog = !(log?.isEmpty ?? true)
        model.cursorHidden = log?.cursorHidden ?? false
        model.onChange = { [weak self] in self?.scheduleRebuild() }

        let player = AVPlayer(url: url)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        if let item = player.currentItem {
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "unknown error"
                Task { @MainActor in self?.setStatus("This file can't be played: \(message)") }
            }
        }

        // Left: file actions. Right: status and Export.
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyFile))
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(reveal))
        let uploadButton = NSButton(title: "Upload", target: self, action: #selector(upload))
        copyButton.toolTip = "Copy the video file (with your edits) to paste into Finder, Mail, Slack"
        uploadButton.toolTip = "Upload and copy the link (⌥-click for password and expiry)"
        for b in [copyButton, revealButton, uploadButton] { b.bezelStyle = .rounded }
        actionButtons = [copyButton, revealButton, uploadButton]

        trimPopup.addItem(withTitle: "Trim")
        trimPopup.addItem(withTitle: "Trim…")
        trimPopup.lastItem?.target = self
        trimPopup.lastItem?.action = #selector(trim)
        trimPopup.addItem(withTitle: "Reset Trim")
        trimPopup.lastItem?.target = self
        trimPopup.lastItem?.action = #selector(resetTrim)
        trimPopup.bezelStyle = .rounded
        trimPopup.toolTip = "Cut the start and end. Exports use the trimmed range."

        exportPopup.addItem(withTitle: "Export")
        exportPopup.addItem(withTitle: "MP4…")
        exportPopup.lastItem?.target = self
        exportPopup.lastItem?.action = #selector(exportMP4)
        exportPopup.addItem(withTitle: "GIF…")
        exportPopup.lastItem?.target = self
        exportPopup.lastItem?.action = #selector(exportGIF)
        exportPopup.bezelStyle = .rounded
        if isGIF {
            trimPopup.isEnabled = false
            exportPopup.isEnabled = false
        }

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelWork)
        cancelButton.isHidden = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 140).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [trimPopup, copyButton, revealButton, uploadButton, spacer,
                                      status, progress, cancelButton, exportPopup])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let sidebar = NSHostingView(rootView: VideoEditSidebar(model: model))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sidebar.isHidden = isGIF

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.isHidden = isGIF

        let middle = NSStackView(views: [playerView, divider, sidebar])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.alignment = .top
        playerView.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [middle, rule, bar])
        root.orientation = .vertical
        root.spacing = 0
        middle.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            middle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            middle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: middle.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            divider.topAnchor.constraint(equalTo: middle.topAnchor),
            divider.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: middle.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
    }

    func windowWillClose(_ notification: Notification) {
        exportBox?.session.cancelExport()
        gifTask?.cancel()
        exportTimer?.invalidate()
        rebuildWork?.cancel()
        itemObservation = nil
        playerView.player?.pause()
        playerView.player = nil
        Self.controllers[ObjectIdentifier(self)] = nil
    }

    // MARK: - State

    private func setStatus(_ text: String) { status.stringValue = text }

    private func setBusy(_ busy: Bool, message: String = "") {
        isBusy = busy
        model.busy = busy
        for b in actionButtons { b.isEnabled = !busy }
        if !isGIF {
            trimPopup.isEnabled = !busy
            exportPopup.isEnabled = !busy
        }
        progress.isHidden = !busy
        progress.doubleValue = 0
        cancelButton.isHidden = !busy
        if busy || !message.isEmpty { status.stringValue = message }
    }

    private func updateTrimStatus() {
        guard let r = trimRange else { setStatus(""); return }
        func fmt(_ t: CMTime) -> String {
            let s = max(0, Int(t.seconds.rounded()))
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        setStatus("Trimmed \(fmt(r.start)) to \(fmt(r.end)). Exports use this range.")
    }

    // MARK: - Live preview

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in await self?.rebuild() } }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Builds the preview composition for the current settings (the newest request wins).
    private func rebuild() async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        guard let item = playerView.player?.currentItem else { return }
        let settings = model.settings
        if settings.isIdentity && !(model.cursorHidden && model.hasCursorLog) {
            item.videoComposition = nil
            currentComposition = nil
            return
        }
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let composer = VideoComposer(settings: settings, sourceSize: size, log: log)
            let comp = try await composer.makeComposition(for: asset)
            guard generation == rebuildGeneration else { return }
            item.videoComposition = comp
            currentComposition = comp
        } catch {
            if generation == rebuildGeneration { setStatus("Preview failed: \(error.localizedDescription)") }
        }
    }

    /// Makes sure the composition matches the sidebar right now (used before exporting).
    private func rebuildNow() async {
        rebuildWork?.cancel()
        rebuildWork = nil
        await rebuild()
    }

    // MARK: - Trim

    @objc private func trim() {
        guard !isBusy else { return }
        guard playerView.canBeginTrimming else {
            setStatus("This video can't be trimmed.")
            return
        }
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in
                guard let self, result == .okButton, let item = self.playerView.player?.currentItem else { return }
                let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
                let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
                let range = CMTimeRange(start: start, end: end)
                guard range.duration.seconds > 0.1 else { return }
                let whole = abs(range.duration.seconds - item.duration.seconds) < 0.05
                self.trimRange = whole ? nil : range
                self.updateTrimStatus()
            }
        }
    }

    @objc private func resetTrim() {
        trimRange = nil
        if let item = playerView.player?.currentItem {
            item.reversePlaybackEndTime = .invalid
            item.forwardPlaybackEndTime = .invalid
        }
        setStatus("")
    }

    // MARK: - Export

    private var hasEdits: Bool {
        currentComposition != nil || trimRange != nil
    }

    /// Exports the edited video as MP4. Returns false when it failed or was cancelled.
    private func runMP4Export(to dest: URL, message: String) async -> Bool {
        setBusy(true, message: message)
        await rebuildNow()
        let asset = AVURLAsset(url: url)
        // Re-encode when there are edits (precise trim, effects); otherwise copy the streams as they are.
        let preset = hasEdits ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            setBusy(false, message: "Could not start the export.")
            return false
        }
        try? FileManager.default.removeItem(at: dest)
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        if let comp = currentComposition { session.videoComposition = comp }
        if let range = trimRange { session.timeRange = range }
        let box = ExportBox(session)
        exportBox = box
        exportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            let p = Double(box.session.progress)
            Task { @MainActor in self?.progress.doubleValue = p }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        exportTimer?.invalidate()
        exportTimer = nil
        exportBox = nil
        switch box.session.status {
        case .completed:
            setBusy(false)
            return true
        case .cancelled:
            try? FileManager.default.removeItem(at: dest)
            setBusy(false, message: "Cancelled.")
            return false
        default:
            let reason = box.session.error?.localizedDescription ?? "unknown error"
            try? FileManager.default.removeItem(at: dest)
            setBusy(false, message: "Export failed: \(reason)")
            return false
        }
    }

    @objc private func exportMP4() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = url.deletingLastPathComponent()
        let suffix = model.settings.format == .original ? "edited" : model.settings.format.rawValue.components(separatedBy: " ").first!.lowercased()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (\(suffix)).mp4"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            if await runMP4Export(to: dest, message: "Exporting…") {
                setStatus("Saved \(dest.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    @objc private func exportGIF() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".gif"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let source = url
        let range = trimRange
        gifTask = Task {
            setBusy(true, message: "Exporting GIF…")
            await rebuildNow()
            let comp = currentComposition
            let error = await GIFExporter.export(video: source, to: dest, composition: comp, timeRange: range) { fraction in
                Task { @MainActor in self.progress.doubleValue = fraction }
            }
            gifTask = nil
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: dest)
                setBusy(false, message: "Cancelled.")
            } else if let error {
                try? FileManager.default.removeItem(at: dest)
                setBusy(false, message: "GIF export failed: \(error.localizedDescription)")
            } else {
                setBusy(false, message: "Saved \(dest.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    @objc private func cancelWork() {
        exportBox?.session.cancelExport()
        gifTask?.cancel()
    }

    // MARK: - Share

    /// The file to copy or upload: the original, or a fresh export when there are edits.
    private func deliverableURL(message: String) async -> URL? {
        await rebuildNow()
        guard hasEdits, !isGIF else { return url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapper/Share", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (edited).mp4")
        return await runMP4Export(to: dest, message: message) ? dest : nil
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyFile() {
        guard !isBusy else { return }
        Task {
            guard let file = await deliverableURL(message: "Preparing…") else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([file as NSURL])
            setStatus("Copied. Paste into Finder, Mail, Slack…")
        }
    }

    @objc private func upload() {
        guard !isBusy else { return }
        var options = UploadOptions.defaults
        if NSEvent.modifierFlags.contains(.option) {
            guard let chosen = UploadOptions.ask() else { return }
            options = chosen
        }
        let type = isGIF ? "image/gif" : "video/mp4"
        Task {
            guard let file = await deliverableURL(message: "Preparing upload…") else { return }
            setStatus("Uploading…")
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: file) }.value
                let link = try await Uploader.upload(data: data, fileName: file.lastPathComponent, contentType: type, options: options)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link.absoluteString, forType: .string)
                setStatus("Link copied: \(link.absoluteString)")
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }
}

private final class ExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
}

// MARK: - Sidebar

private struct VideoEditSidebar: View {
    @ObservedObject var model: VideoEditModel

    private let swatchColumns = Array(repeating: GridItem(.fixed(38), spacing: 5), count: 6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Background") {
                    LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 5) {
                        swatch(.none)
                        ForEach(0..<BackgroundCatalog.builtIn.count, id: \.self) { i in swatch(.builtIn(i)) }
                        swatch(.wallpaper)
                    }
                    labeled("Padding") {
                        Slider(value: bind(\.background.padding, 0...0.3), in: 0...0.3)
                    }
                    labeled("Corners") {
                        Slider(value: bind(\.background.cornerRadius, 0...60), in: 0...60)
                    }
                    labeled("Shadow") {
                        Slider(value: bind(\.background.shadow, 0...1), in: 0...1)
                    }
                }

                section("Format") {
                    Picker("", selection: Binding(get: { model.settings.format }, set: { model.settings.format = $0 })) {
                        ForEach(VideoEditSettings.Format.allCases, id: \.self) { f in Text(f.rawValue).tag(f) }
                    }
                    .labelsHidden()
                    Text("For TikTok, Reels and Shorts use Vertical; YouTube uses Landscape.")
                        .font(.caption).foregroundColor(.secondary)
                }

                section("Smart zoom") {
                    Toggle("Zoom in on clicks, follow the cursor", isOn: Binding(get: { model.settings.smartZoom },
                                                                                 set: { model.settings.smartZoom = $0 }))
                        .disabled(!model.hasCursorLog)
                    labeled("Zoom") {
                        Slider(value: Binding(get: { model.settings.zoomLevel }, set: { model.settings.zoomLevel = $0 }),
                               in: 1.25...3.5)
                    }
                    .disabled(!model.settings.smartZoom)
                    labeled("Motion blur") {
                        Slider(value: Binding(get: { model.settings.motionBlur }, set: { model.settings.motionBlur = $0 }),
                               in: 0...1)
                    }
                    .disabled(!model.settings.smartZoom)
                    if !model.hasCursorLog {
                        Text("Needs a recording made with this version of Snapper (it logs clicks while recording).")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                section("Cursor") {
                    if model.cursorHidden {
                        Toggle("Smooth movement", isOn: Binding(get: { model.settings.smoothCursor },
                                                                set: { model.settings.smoothCursor = $0 }))
                        labeled("Size") {
                            Slider(value: Binding(get: { model.settings.cursorScale }, set: { model.settings.cursorScale = $0 }),
                                   in: 0.75...3)
                        }
                        Toggle("Click effects", isOn: Binding(get: { model.settings.clickEffects },
                                                              set: { model.settings.clickEffects = $0 }))
                    } else {
                        Text("Turn on \u{201C}Editable cursor\u{201D} in Settings > Recording to smooth the cursor, resize it and add click effects after recording.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Button("Reset Edits") { model.settings = VideoEditSettings() }
                    .controlSize(.small)
                    .disabled(model.settings == VideoEditSettings())
            }
            .padding(14)
        }
        .disabled(model.busy)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func bind(_ kp: WritableKeyPath<VideoEditSettings, CGFloat>, _ range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { Double(model.settings[keyPath: kp]) },
                set: { var s = model.settings; s[keyPath: kp] = CGFloat($0); model.settings = s })
    }

    private func swatch(_ fill: BackgroundSettings.Fill) -> some View {
        let selected = model.settings.background.fill == fill
        return Button(action: {
            var s = model.settings
            if s.background.isNone, fill != .none {
                s.background = BackgroundSettings.starter
                s.background.padding = 0.06
            }
            s.background.fill = fill
            model.settings = s
        }) {
            Image(nsImage: BackgroundMaker.thumbnail(fill, size: CGSize(width: 38, height: 26)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5).padding(-2))
        }
        .buttonStyle(.plain)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.callout).foregroundColor(.secondary).frame(width: 78, alignment: .leading)
            content()
        }
    }
}

// MARK: - GIF

enum GIFExporter {
    /// Samples the video and writes an animated GIF. `composition` applies the editor's effects.
    static func export(video: URL, to destination: URL, composition: AVVideoComposition? = nil,
                       timeRange: CMTimeRange? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async -> Error? {
        let asset = AVURLAsset(url: video)
        do {
            let total = try await asset.load(.duration).seconds
            let startSeconds = timeRange?.start.seconds ?? 0
            let duration = timeRange?.duration.seconds ?? total
            guard duration > 0 else { throw NSError(domain: "Snapper", code: 20, userInfo: [NSLocalizedDescriptionKey: "The video is empty."]) }
            let quality = AppSettings.recordQuality
            let baseFPS: Double = [8, 12, 15][min(max(quality, 0), 2)]
            let fps: Double = duration > 30 ? min(baseFPS, 6) : (duration > 12 ? min(baseFPS, 10) : baseFPS)
            let maxSide: CGFloat = [480, 720, 960][min(max(quality, 0), 2)]
            let count = max(1, Int(duration * fps))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSide, height: maxSide)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

            guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw NSError(domain: "Snapper", code: 21, userInfo: [NSLocalizedDescriptionKey: "Could not create the GIF file."])
            }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary

            for i in 0..<count {
                try Task.checkCancellation()
                let time = CMTime(seconds: startSeconds + Double(i) / fps, preferredTimescale: 600)
                let image = try await generator.image(at: time).image
                CGImageDestinationAddImage(dest, image, frameProps)
                progress(Double(i + 1) / Double(count))
            }
            guard CGImageDestinationFinalize(dest) else {
                throw NSError(domain: "Snapper", code: 22, userInfo: [NSLocalizedDescriptionKey: "Could not finish the GIF."])
            }
            return nil
        } catch {
            return error
        }
    }
}
