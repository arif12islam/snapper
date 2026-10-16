import AppKit
import AVKit
import AVFoundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import QuartzCore

/// Editor state shown in the sidebar.
final class VideoEditModel: ObservableObject {
    @Published var settings = VideoEditSettings() {
        didSet { if oldValue != settings { onChange?() } }
    }
    @Published var hasCursorLog = false
    @Published var cursorHidden = false
    @Published var busy = false
    @Published var duration: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var showAllBackgrounds = false
    var onChange: (() -> Void)?
    var onExportMP4: (() -> Void)?
    var onExportGIF: (() -> Void)?
    var onResetTrim: (() -> Void)?

    var isTrimmed: Bool { duration > 0 && (trimStart > 0.05 || abs(trimEnd - duration) > 0.05) }
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
    private let surface = PlayerSurface()
    private let timeline = TrimTimelineView()
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var playStateObservation: NSKeyValueObservation?
    private let url: URL
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
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
        c.window.makeFirstResponder(c.timeline)
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

        // Left column: the video on a dark stage, with the filmstrip timeline underneath.
        if isGIF {
            let still = NSImageView(image: NSImage(contentsOf: url) ?? NSImage())
            still.animates = true
            still.imageScaling = .scaleProportionallyUpOrDown
            surface.showStill(still)
        } else {
            let p = AVPlayer(url: url)
            player = p
            surface.playerLayer.player = p
            if let item = p.currentItem {
                itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    let message = item.error?.localizedDescription ?? "unknown error"
                    Task { @MainActor [weak self] in self?.setStatus("This file can't be played: \(message)") }
                }
            }
            playStateObservation = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
                let playing = p.timeControlStatus != .paused
                Task { @MainActor [weak self] in self?.surface.setPlaying(playing) }
            }
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, t.seconds.isFinite else { return }
                    self.timeline.playhead = t.seconds
                }
            }
            surface.onClick = { [weak self] in self?.togglePlay() }
            timeline.onToggle = { [weak self] in self?.togglePlay() }
            timeline.onScrubBegin = { [weak self] in self?.player?.pause() }
            timeline.onSeek = { [weak self] t in self?.seek(to: t) }
            timeline.onTrim = { [weak self] start, end in self?.trimChanged(start: start, end: end) }
            model.onResetTrim = { [weak self] in self?.resetTrim() }
            model.onExportMP4 = { [weak self] in self?.exportMP4() }
            model.onExportGIF = { [weak self] in self?.exportGIF() }

            let asset = AVURLAsset(url: url)
            Task { [weak self] in
                let d = (try? await asset.load(.duration).seconds) ?? 0
                guard let self, d.isFinite, d > 0 else { return }
                self.timeline.configure(duration: d)
                self.model.duration = d
                self.model.trimStart = 0
                self.model.trimEnd = d
                self.timeline.loadThumbnails(asset: asset)
            }
        }
        timeline.isHidden = isGIF

        let column = NSView()
        for v in [surface, timeline] {
            v.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(v)
        }
        let timelineHeight = timeline.heightAnchor.constraint(equalToConstant: isGIF ? 0 : 124)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: column.topAnchor, constant: 20),
            surface.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 20),
            surface.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -20),
            surface.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -6),
            timeline.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 4),
            timeline.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -4),
            timeline.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -4),
            timelineHeight
        ])
        column.setContentHuggingPriority(.init(1), for: .horizontal)
        column.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // File actions on the left, status on the right. Trim and Export live in the sidebar.
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyFile))
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(reveal))
        let uploadButton = NSButton(title: "Upload", target: self, action: #selector(upload))
        copyButton.toolTip = "Copy the video file (with your edits) to paste into Finder, Mail, Slack"
        uploadButton.toolTip = "Upload and copy the link (\u{2325}-click for password and expiry)"
        for b in [copyButton, revealButton, uploadButton] { b.bezelStyle = .rounded }
        actionButtons = [copyButton, revealButton, uploadButton]

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
        let bar = NSStackView(views: [copyButton, revealButton, uploadButton, spacer, status, progress, cancelButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let sidebar = NSHostingView(rootView: VideoEditSidebar(model: model))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 296).isActive = true
        sidebar.isHidden = isGIF

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.isHidden = isGIF

        let middle = NSStackView(views: [column, divider, sidebar])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.alignment = .top

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        // Plain constraints rather than a vertical stack: the stack let the editor area collapse to a sliver.
        let root = NSView()
        for v in [middle, rule, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        window.contentView = root
        window.initialFirstResponder = timeline
        NSLayoutConstraint.activate([
            middle.topAnchor.constraint(equalTo: root.topAnchor),
            middle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            middle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            middle.bottomAnchor.constraint(equalTo: rule.topAnchor),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.topAnchor.constraint(equalTo: middle.topAnchor),
            column.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            divider.topAnchor.constraint(equalTo: middle.topAnchor),
            divider.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: middle.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: middle.bottomAnchor)
        ])
    }

    func windowWillClose(_ notification: Notification) {
        exportBox?.session.cancelExport()
        gifTask?.cancel()
        exportTimer?.invalidate()
        rebuildWork?.cancel()
        itemObservation = nil
        playStateObservation = nil
        if let o = timeObserver { player?.removeTimeObserver(o); timeObserver = nil }
        player?.pause()
        surface.playerLayer.player = nil
        player = nil
        Self.controllers[ObjectIdentifier(self)] = nil
    }

    // MARK: - State

    private func setStatus(_ text: String) { status.stringValue = text }

    private func setBusy(_ busy: Bool, message: String = "") {
        isBusy = busy
        model.busy = busy
        for b in actionButtons { b.isEnabled = !busy }
        timeline.isLocked = busy
        progress.isHidden = !busy
        progress.doubleValue = 0
        cancelButton.isHidden = !busy
        if busy || !message.isEmpty { status.stringValue = message }
    }

    // MARK: - Live preview

    private func scheduleRebuild() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor [weak self] in await self?.rebuild() } }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Builds the preview composition for the current settings (the newest request wins).
    private func rebuild() async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        guard let item = player?.currentItem else { return }
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

    // MARK: - Playback and trim

    private func togglePlay() {
        guard let p = player else { return }
        if p.timeControlStatus != .paused {
            p.pause()
        } else {
            let t = p.currentTime().seconds
            let start = model.trimStart, end = model.trimEnd > 0 ? model.trimEnd : model.duration
            if t < start - 0.01 || t >= end - 0.05 { seek(to: start) }
            p.play()
        }
        window.makeFirstResponder(timeline)
    }

    private func seek(to seconds: Double) {
        timeline.playhead = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The handles moved: remember the range, and keep playback inside it.
    private func trimChanged(start: Double, end: Double) {
        model.trimStart = start
        model.trimEnd = end
        let whole = start < 0.05 && abs(end - model.duration) < 0.05
        let item = player?.currentItem
        if whole {
            trimRange = nil
            item?.reversePlaybackEndTime = .invalid
            item?.forwardPlaybackEndTime = .invalid
        } else {
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    end: CMTime(seconds: end, preferredTimescale: 600))
            trimRange = range
            item?.reversePlaybackEndTime = range.start
            item?.forwardPlaybackEndTime = range.end
        }
    }

    private func resetTrim() {
        timeline.resetTrim()
        trimChanged(start: 0, end: model.duration)
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
            Task { @MainActor [weak self] in self?.progress.doubleValue = p }
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

    private let navy = Color(red: 0.106, green: 0.106, blue: 0.302)
    private let swatch: CGFloat = 24
    private let featured = 5          // built-in backgrounds shown before "more"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                trimSection
                Divider()
                backgroundSection
                frameSection
                zoomSection
                if model.cursorHidden { cursorSection }
                if model.settings != VideoEditSettings() {
                    Button { model.settings = VideoEditSettings() } label: {
                        Label("Reset edits", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }
            }
            .padding(16)
        }
        .disabled(model.busy)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Trim and export

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Trim") {
                if model.isTrimmed {
                    iconButton("arrow.counterclockwise", help: "Reset trim") { model.onResetTrim?() }
                }
            }
            HStack(spacing: 0) {
                timeCell("START", model.trimStart)
                Divider().frame(height: 26)
                timeCell("END", model.trimEnd)
                Divider().frame(height: 26)
                timeCell("LENGTH", max(0, model.trimEnd - model.trimStart))
            }
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))

            HStack(spacing: 8) {
                Button { model.onExportMP4?() } label: {
                    Label("MP4", systemImage: "film")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(navy))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Export as MP4")
                Button { model.onExportGIF?() } label: {
                    Label("GIF", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Export as GIF")
            }
        }
    }

    private func timeCell(_ title: String, _ seconds: Double) -> some View {
        let m = Int(max(0, seconds)) / 60
        let text = String(format: "%02d:%04.1f", m, max(0, seconds) - Double(m * 60))
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundColor(.secondary)
            Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    // MARK: Background

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Background") { EmptyView() }
            let catalog = BackgroundCatalog.builtIn.count
            let shown = model.showAllBackgrounds ? catalog : min(featured, catalog)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(swatch), spacing: 7), count: 8), alignment: .leading, spacing: 7) {
                swatchButton(.none, help: "No background")
                swatchButton(.wallpaper, help: "Desktop wallpaper")
                ForEach(0..<shown, id: \.self) { i in swatchButton(.builtIn(i), help: BackgroundCatalog.builtIn[i].name) }
                if catalog > featured {
                    Button { model.showAllBackgrounds.toggle() } label: {
                        Image(systemName: model.showAllBackgrounds ? "chevron.up" : "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: swatch, height: swatch)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.showAllBackgrounds ? "Fewer" : "More backgrounds")
                }
            }
            if !model.settings.background.isNone {
                VStack(spacing: 6) {
                    iconSlider("rectangle.inset.filled", help: "Padding", value: bind(\.background.padding), range: 0...0.3)
                    iconSlider("rectangle.roundedtop", help: "Corners", value: bind(\.background.cornerRadius), range: 0...60)
                    iconSlider("shadow", help: "Shadow", value: bind(\.background.shadow), range: 0...1)
                }
            }
        }
    }

    private func swatchButton(_ fill: BackgroundSettings.Fill, help: String) -> some View {
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
            Group {
                if fill == .none {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18))
                        Image(systemName: "circle.slash").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                } else {
                    Image(nsImage: BackgroundMaker.thumbnail(fill, size: CGSize(width: swatch * 2, height: swatch * 2)))
                        .resizable()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .frame(width: swatch, height: swatch)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2).padding(-3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Frame

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Frame") {
                Text(label(model.settings.format)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(VideoEditSettings.Format.allCases, id: \.self) { f in
                    let on = model.settings.format == f
                    Button { model.settings.format = f } label: {
                        AspectArt(ratio: f.aspect.ratio)
                            .frame(width: 26, height: 20)
                            .foregroundColor(on ? .accentColor : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(on ? Color.accentColor.opacity(0.12) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(f.rawValue)
                }
            }
        }
    }

    private func label(_ f: VideoEditSettings.Format) -> String {
        f == .original ? "Original" : (f.rawValue.split(separator: " ").last.map(String.init) ?? f.rawValue)
    }

    // MARK: Smart zoom and cursor

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Smart zoom") {
                Toggle("", isOn: Binding(get: { model.settings.smartZoom }, set: { model.settings.smartZoom = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!model.hasCursorLog)
            }
            .help(model.hasCursorLog ? "Zoom in on clicks and follow the cursor"
                                     : "Needs a recording made with Snapper, which logs clicks while recording")
            if model.settings.smartZoom {
                VStack(spacing: 6) {
                    iconSlider("plus.magnifyingglass", help: "Zoom",
                               value: Binding(get: { model.settings.zoomLevel }, set: { model.settings.zoomLevel = $0 }), range: 1.25...3.5)
                    iconSlider("wind", help: "Motion blur",
                               value: Binding(get: { model.settings.motionBlur }, set: { model.settings.motionBlur = $0 }), range: 0...1)
                }
            }
        }
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Cursor") { EmptyView() }
            iconSlider("cursorarrow", help: "Cursor size",
                       value: Binding(get: { model.settings.cursorScale }, set: { model.settings.cursorScale = $0 }), range: 0.75...3)
            iconToggle("scribble.variable", "Smooth movement",
                       isOn: Binding(get: { model.settings.smoothCursor }, set: { model.settings.smoothCursor = $0 }))
            iconToggle("cursorarrow.click.2", "Click effects",
                       isOn: Binding(get: { model.settings.clickEffects }, set: { model.settings.clickEffects = $0 }))
        }
    }

    // MARK: Building blocks

    private func header<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            Spacer()
            accessory()
        }
        .frame(height: 18)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconSlider(_ symbol: String, help: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 18)
            Slider(value: value, in: range).controlSize(.small)
        }
        .help(help)
    }

    private func iconToggle(_ symbol: String, _ title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    private func bind(_ kp: WritableKeyPath<VideoEditSettings, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(model.settings[keyPath: kp]) },
                set: { var s = model.settings; s[keyPath: kp] = CGFloat($0); model.settings = s })
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


// MARK: - Player stage

/// Dark rounded stage that shows the video (or an animated GIF). Click to play or pause.
@MainActor
final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    var onClick: (() -> Void)?
    private let glyph = NSImageView()
    private var still: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x15 / 255, green: 0x15 / 255, blue: 0x3d / 255, alpha: 1).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)

        let config = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        glyph.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Play")?.withSymbolConfiguration(config)
        glyph.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    func showStill(_ view: NSView) {
        still?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: glyph)
        still = view
        glyph.isHidden = true
    }

    func setPlaying(_ playing: Bool) {
        glyph.isHidden = playing || still != nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Filmstrip timeline

/// Thumbnails of the video with yellow trim handles, a red playhead and time labels underneath.
@MainActor
final class TrimTimelineView: NSView {
    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    var onToggle: (() -> Void)?
    var onScrubBegin: (() -> Void)?
    var isLocked = false

    private(set) var duration: Double = 0
    private(set) var start: Double = 0 { didSet { window?.invalidateCursorRects(for: self) } }
    private(set) var end: Double = 0 { didSet { window?.invalidateCursorRects(for: self) } }
    var playhead: Double = 0 { didSet { if oldValue != playhead { needsDisplay = true } } }

    private var thumbs: [CGImage?] = []
    private var asset: AVAsset?
    private var thumbTask: Task<Void, Never>?
    private var thumbWidth: CGFloat = 0
    private var drag: Drag = .none

    private enum Drag { case none, start, end, playhead }

    private let pad: CGFloat = 16
    private let handleW: CGFloat = 14
    private let yellow = NSColor(srgbRed: 1.0, green: 0.79, blue: 0.24, alpha: 1)
    private let red = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func configure(duration: Double) {
        self.duration = duration
        start = 0
        end = duration
        needsDisplay = true
    }

    func resetTrim() {
        start = 0
        end = duration
        needsDisplay = true
    }

    private var track: NSRect {
        NSRect(x: pad, y: 24, width: max(40, bounds.width - pad * 2), height: max(24, bounds.height - 24 - 34))
    }

    private func x(_ t: Double) -> CGFloat {
        guard duration > 0 else { return track.minX }
        return track.minX + CGFloat(t / duration) * track.width
    }

    private func time(_ x: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        return Double(min(max((x - track.minX) / track.width, 0), 1)) * duration
    }

    // MARK: Thumbnails

    func loadThumbnails(asset: AVAsset) {
        self.asset = asset
        regenerateThumbnails()
    }

    override func layout() {
        super.layout()
        if asset != nil, abs(bounds.width - thumbWidth) > 60 { regenerateThumbnails() }
    }

    private func regenerateThumbnails() {
        guard let asset, duration > 0, bounds.width > 100 else { return }
        thumbWidth = bounds.width
        thumbTask?.cancel()
        let tileH = track.height
        let count = max(4, Int((track.width / (tileH * 1.6)).rounded(.up)))
        let scale = window?.backingScaleFactor ?? 2
        let total = duration
        thumbs = Array(repeating: nil, count: count)
        needsDisplay = true

        thumbTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: tileH * 2.4 * scale, height: tileH * scale)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = CMTime(seconds: total * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                guard let image = try? await generator.image(at: t).image else { continue }
                if Task.isCancelled { return }
                guard let self else { return }
                if i < self.thumbs.count { self.thumbs[i] = image; self.needsDisplay = true }
            }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let tr = track
        let xs = x(start), xe = x(end)

        // Filmstrip
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tr, xRadius: 9, yRadius: 9).addClip()
        NSColor.controlBackgroundColor.setFill()
        tr.fill()
        if !thumbs.isEmpty {
            let tw = tr.width / CGFloat(thumbs.count)
            for (i, image) in thumbs.enumerated() {
                let r = NSRect(x: tr.minX + CGFloat(i) * tw, y: tr.minY, width: tw, height: tr.height)
                guard let cg = image else { continue }
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                let targetAspect = r.width / r.height, imageAspect = iw / ih
                var src = NSRect(x: 0, y: 0, width: iw, height: ih)
                if imageAspect > targetAspect {
                    let w = ih * targetAspect
                    src.origin.x = (iw - w) / 2
                    src.size.width = w
                } else {
                    let h = iw / targetAspect
                    src.origin.y = (ih - h) / 2
                    src.size.height = h
                }
                NSImage(cgImage: cg, size: NSSize(width: iw, height: ih))
                    .draw(in: r, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                if i < thumbs.count - 1 {
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    NSRect(x: r.maxX - 0.75, y: r.minY, width: 1.5, height: r.height).fill()
                }
            }
        }
        // Everything outside the kept range is washed out.
        NSColor.windowBackgroundColor.withAlphaComponent(0.78).setFill()
        NSRect(x: tr.minX, y: tr.minY, width: max(0, xs - tr.minX), height: tr.height).fill()
        NSRect(x: xe, y: tr.minY, width: max(0, tr.maxX - xe), height: tr.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Yellow frame with thicker side handles
        let outer = NSRect(x: xs - handleW, y: tr.minY - 5, width: (xe - xs) + handleW * 2, height: tr.height + 10)
        let inner = NSRect(x: xs, y: tr.minY, width: max(0, xe - xs), height: tr.height)
        let frame = NSBezierPath(roundedRect: outer, xRadius: 10, yRadius: 10)
        frame.append(NSBezierPath(roundedRect: inner, xRadius: 3, yRadius: 3))
        frame.windingRule = .evenOdd
        yellow.setFill()
        frame.fill()
        NSColor.black.withAlphaComponent(0.25).setFill()
        for gx in [xs - handleW / 2, xe + handleW / 2] {
            NSBezierPath(roundedRect: NSRect(x: gx - 1, y: tr.midY - 9, width: 2, height: 18), xRadius: 1, yRadius: 1).fill()
        }

        // Playhead
        let px = x(min(max(playhead, 0), duration))
        red.setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 1.5, y: 10, width: 3, height: tr.maxY + 12 - 10), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(ovalIn: NSRect(x: px - 8, y: 4, width: 16, height: 16)).fill()

        drawLabels(tr)
    }

    private func drawLabels(_ tr: NSRect) {
        guard duration > 0 else { return }
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let limit = max(2, Int(tr.width / 90))
        let step = steps.first(where: { duration / $0 <= Double(limit) }) ?? 3600
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        var t = 0.0
        while t <= duration + 0.001 {
            let label = String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) as NSString
            let size = label.size(withAttributes: attrs)
            let lx = t == 0 ? tr.minX : min(max(x(t) - size.width / 2, 0), bounds.width - size.width)
            label.draw(at: NSPoint(x: lx, y: tr.maxY + 14), withAttributes: attrs)
            t += step
        }
    }

    // MARK: Mouse and keys

    override func resetCursorRects() {
        guard duration > 0 else { return }
        let tr = track
        addCursorRect(NSRect(x: x(start) - handleW, y: tr.minY - 5, width: handleW, height: tr.height + 10), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: x(end), y: tr.minY - 5, width: handleW, height: tr.height + 10), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !isLocked, duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let tr = track
        let xs = x(start), xe = x(end)
        let onHandleRow = p.y >= tr.minY - 10 && p.y <= tr.maxY + 10
        let nearStart = onHandleRow && p.x >= xs - 22 && p.x <= xs + 2
        let nearEnd = onHandleRow && p.x >= xe - 2 && p.x <= xe + 22
        if nearStart && nearEnd {
            drag = abs(p.x - xs) <= abs(p.x - xe) ? .start : .end
        } else if nearStart {
            drag = .start
        } else if nearEnd {
            drag = .end
        } else {
            drag = .playhead
            onScrubBegin?()
        }
        apply(p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != .none else { return }
        apply(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { drag = .none }

    private func apply(_ px: CGFloat) {
        let t = time(px)
        let minLength = min(0.2, duration)
        switch drag {
        case .start:
            start = min(max(0, t), end - minLength)
            onTrim?(start, end)
            onSeek?(start)
        case .end:
            end = max(min(duration, t), start + minLength)
            onTrim?(start, end)
            onSeek?(end)
        case .playhead:
            onSeek?(t)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onToggle?()
        case 123: onSeek?(max(0, playhead - 1.0 / 30))
        case 124: onSeek?(min(duration, playhead + 1.0 / 30))
        default: super.keyDown(with: event)
        }
    }
}
