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
final class VideoWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
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
    private var toolbarItems: [NSToolbarItem] = []
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let model = VideoEditModel()
    private var log: CursorLog?
    private var rebuildWork: DispatchWorkItem?
    private var rebuildGeneration = 0
    private var currentComposition: AVVideoComposition?
    private var naturalVideoSize: CGSize?
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
            AppPresence.present(existing.window)
            return
        }
        let c = VideoWindowController(url: url)
        controllers[ObjectIdentifier(c)] = c
        c.window.center()
        AppPresence.present(c.window, focus: c.timeline)
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
                Task { @MainActor [weak self] in
                    self?.surface.setPlaying(playing)
                    self?.playButton.image = Self.symbol(playing ? "pause.fill" : "play.fill")
                }
            }
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, t.seconds.isFinite else { return }
                    self.timeline.playhead = t.seconds
                    self.updateTimeLabel(t.seconds)
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
                self.updateTimeLabel(0)
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: size).applying(transform)
                    self.surface.videoSize = CGSize(width: abs(r.width), height: abs(r.height))
                }
            }
        }
        timeline.isHidden = isGIF

        // Transport: play / pause and time on the left; export progress on the right while busy.
        playButton.isBordered = false
        playButton.image = Self.symbol("play.fill")
        playButton.contentTintColor = .labelColor
        playButton.target = self
        playButton.action = #selector(togglePlayAction)
        playButton.toolTip = "Play or pause (space)"
        playButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        timeLabel.textColor = .labelColor

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelWork)
        cancelButton.isHidden = true
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 120).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transport = NSStackView(views: [playButton, timeLabel, spacer, status, progress, cancelButton])
        transport.orientation = .horizontal
        transport.spacing = 8
        transport.isHidden = isGIF

        let column = NSView()
        for v in [surface, transport, timeline] {
            v.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(v)
        }
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: column.topAnchor, constant: 20),
            surface.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 24),
            surface.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -24),
            transport.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 12),
            transport.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: -3),
            transport.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: isGIF ? 0 : 22),
            timeline.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 6),
            timeline.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 12),
            timeline.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -12),
            timeline.heightAnchor.constraint(equalToConstant: isGIF ? 0 : 92),
            timeline.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -14)
        ])
        column.setContentHuggingPriority(.init(1), for: .horizontal)
        column.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let sidebar = NSHostingView(rootView: VideoEditSidebar(model: model))
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sidebar.isHidden = isGIF

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = isGIF

        // The editor fills the window; file actions live in the toolbar.
        let root = NSView()
        for v in [column, divider, sidebar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        window.contentView = root
        window.initialFirstResponder = timeline
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: isGIF ? root.trailingAnchor : divider.leadingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        let toolbar = NSToolbar(identifier: "snapper.video")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    // MARK: - Toolbar

    private enum ToolbarID {
        static let copy = NSToolbarItem.Identifier("snapper.video.copy")
        static let reveal = NSToolbarItem.Identifier("snapper.video.reveal")
        static let upload = NSToolbarItem.Identifier("snapper.video.upload")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.copy, ToolbarID.reveal] + (Features.cloudUpload ? [ToolbarID.upload] : [])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ToolbarID.copy:
            item.label = "Copy"
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
            item.action = #selector(copyFile)
            item.toolTip = "Copy the video, with your edits, to paste anywhere"
        case ToolbarID.reveal:
            item.label = "Show in Finder"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show in Finder")
            item.action = #selector(reveal)
            item.toolTip = "Show in Finder"
        case ToolbarID.upload:
            item.label = "Upload"
            item.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: "Upload")
            item.action = #selector(upload)
            item.toolTip = "Upload and copy the link (\u{2325}-click for password and expiry)"
        default:
            return nil
        }
        item.target = self
        item.isBordered = true
        item.autovalidates = false
        toolbarItems.append(item)
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    }

    private func updateTimeLabel(_ t: Double) {
        func fmt(_ v: Double) -> String {
            let v = max(0, v), m = Int(v) / 60
            return String(format: "%02d:%04.1f", m, v - Double(m * 60))
        }
        timeLabel.stringValue = "\(fmt(t))  /  \(fmt(model.duration))"
    }

    @objc private func togglePlayAction() { togglePlay() }

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
        for item in toolbarItems { item.isEnabled = !busy }
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
            if let natural = naturalVideoSize { surface.videoSize = natural }
            return
        }
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
            let size = try await track.load(.naturalSize)
            let composer = VideoComposer(settings: settings, sourceSize: size, log: log)
            let comp = try await composer.makeComposition(for: asset)
            guard generation == rebuildGeneration else { return }
            if naturalVideoSize == nil { naturalVideoSize = surface.videoSize }
            item.videoComposition = comp
            currentComposition = comp
            surface.videoSize = comp.renderSize
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
        .tint(.brand)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(navy))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Export as MP4")
                Button { model.onExportGIF?() } label: {
                    Label("GIF", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .bold))
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
            Text(title).font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundColor(.secondary)
            Text(text).font(.system(size: 16, weight: .bold, design: .rounded)).monospacedDigit()
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
                .strokeBorder(selected ? Color.brand : Color.clear, lineWidth: 2.5).padding(-3))
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
                            .foregroundColor(on ? .white : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(on ? Color.brand : Color.primary.opacity(0.05)))
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
            Text(title).font(.system(size: 13, weight: .bold))
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

/// The video, fitted to its own aspect ratio with rounded corners and a soft shadow, floating on the window
/// background (no letterbox slab). Click to play or pause.
@MainActor
final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    var onClick: (() -> Void)?
    /// Pixel size of what is shown (the edited composition when there is one), for the fit.
    var videoSize: CGSize = .zero { didSet { needsLayout = true } }

    private let shadowLayer = CALayer()
    private let glyph = NSView()
    private var still: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        layer?.addSublayer(shadowLayer)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.cornerRadius = 8
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        layer?.addSublayer(playerLayer)

        // Paused: a small dark disc with a play glyph, centred on the video.
        glyph.wantsLayer = true
        glyph.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        glyph.layer?.cornerRadius = 26
        glyph.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)) ?? NSImage())
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        glyph.addSubview(icon)
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 52),
            glyph.heightAnchor.constraint(equalToConstant: 52),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.centerXAnchor.constraint(equalTo: glyph.centerXAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: glyph.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fitted: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let k = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = (videoSize.width * k).rounded(), h = (videoSize.height * k).rounded()
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }

    override func layout() {
        super.layout()
        let r = fitted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = r
        shadowLayer.frame = r
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: 8, cornerHeight: 8, transform: nil)
        CATransaction.commit()
        still?.frame = r
    }

    func showStill(_ view: NSView) {
        still?.removeFromSuperview()
        if let image = (view as? NSImageView)?.image { videoSize = image.size }
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.frame = fitted
        addSubview(view, positioned: .below, relativeTo: glyph)
        still = view
        glyph.isHidden = true
    }

    func setPlaying(_ playing: Bool) {
        glyph.isHidden = playing || still != nil
    }

    override func mouseDown(with event: NSEvent) {
        if fitted.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
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

    private let pad: CGFloat = 12
    private let handleW: CGFloat = 10
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
        NSRect(x: pad, y: 16, width: max(40, bounds.width - pad * 2), height: max(24, bounds.height - 16 - 26))
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
        NSBezierPath(roundedRect: tr, xRadius: 6, yRadius: 6).addClip()
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
                    NSColor.black.withAlphaComponent(0.25).setFill()
                    NSRect(x: r.maxX - 0.5, y: r.minY, width: 1, height: r.height).fill()
                }
            }
        }
        // Everything outside the kept range is washed out.
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        NSRect(x: tr.minX, y: tr.minY, width: max(0, xs - tr.minX), height: tr.height).fill()
        NSRect(x: xe, y: tr.minY, width: max(0, tr.maxX - xe), height: tr.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        // Trim frame: quiet grey while the whole clip is kept, yellow once it is trimmed or being dragged.
        let trimmed = start > 0.01 || end < duration - 0.01 || drag == .start || drag == .end
        let outer = NSRect(x: xs - handleW, y: tr.minY - 3, width: (xe - xs) + handleW * 2, height: tr.height + 6)
        let inner = NSRect(x: xs, y: tr.minY, width: max(0, xe - xs), height: tr.height)
        let frame = NSBezierPath(roundedRect: outer, xRadius: 7, yRadius: 7)
        frame.append(NSBezierPath(roundedRect: inner, xRadius: 2, yRadius: 2))
        frame.windingRule = .evenOdd
        (trimmed ? yellow : NSColor.tertiaryLabelColor).setFill()
        frame.fill()
        (trimmed ? NSColor.black.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.8)).setFill()
        for gx in [xs - handleW / 2, xe + handleW / 2] {
            NSBezierPath(roundedRect: NSRect(x: gx - 0.75, y: tr.midY - 6, width: 1.5, height: 12), xRadius: 0.75, yRadius: 0.75).fill()
        }

        // Playhead: a thin red line with a small knob, outlined so it reads over any frame.
        let px = x(min(max(playhead, 0), duration))
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 2, y: 8, width: 4, height: tr.maxY + 4 - 8), xRadius: 2, yRadius: 2).fill()
        NSBezierPath(ovalIn: NSRect(x: px - 6, y: 2, width: 12, height: 12)).fill()
        red.setFill()
        NSBezierPath(roundedRect: NSRect(x: px - 1, y: 8, width: 2, height: tr.maxY + 4 - 8), xRadius: 1, yRadius: 1).fill()
        NSBezierPath(ovalIn: NSRect(x: px - 5, y: 3, width: 10, height: 10)).fill()

        drawLabels(tr)
    }

    private func drawLabels(_ tr: NSRect) {
        guard duration > 0 else { return }
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]
        let limit = max(2, Int(tr.width / 90))
        let step = steps.first(where: { duration / $0 <= Double(limit) }) ?? 3600
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        var t = 0.0
        while t <= duration + 0.001 {
            let label = String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) as NSString
            let size = label.size(withAttributes: attrs)
            let lx = t == 0 ? tr.minX : min(max(x(t) - size.width / 2, 0), bounds.width - size.width)
            label.draw(at: NSPoint(x: lx, y: tr.maxY + 8), withAttributes: attrs)
            t += step
        }
    }

    // MARK: Mouse and keys

    override func resetCursorRects() {
        guard duration > 0 else { return }
        let tr = track
        addCursorRect(NSRect(x: x(start) - handleW, y: tr.minY - 3, width: handleW, height: tr.height + 6), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: x(end), y: tr.minY - 3, width: handleW, height: tr.height + 6), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !isLocked, duration > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let tr = track
        let xs = x(start), xe = x(end)
        let onHandleRow = p.y >= tr.minY - 10 && p.y <= tr.maxY + 10
        let nearStart = onHandleRow && p.x >= xs - 18 && p.x <= xs + 3
        let nearEnd = onHandleRow && p.x >= xe - 3 && p.x <= xe + 18
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

    override func mouseUp(with event: NSEvent) { drag = .none; needsDisplay = true }

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
