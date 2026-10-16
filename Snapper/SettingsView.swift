import SwiftUI
import AppKit

/// Settings window: tabs for General, Capture, Quick Access, Recording, Cloud and Shortcuts.
/// Defaults must match AppSettings.
/// Which Settings tab is showing (so Help > Keyboard Shortcuts can jump straight to Shortcuts).
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab = "general"
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    private let tabs: [(id: String, title: String, symbol: String)] = [
        ("general", "General", "gearshape"),
        ("capture", "Capture", "camera.viewfinder"),
        ("quickaccess", "Quick Access", "rectangle.on.rectangle"),
        ("recording", "Recording", "record.circle"),
        ("cloud", "Cloud", "icloud"),
        ("shortcuts", "Shortcuts", "keyboard")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.id) { t in
                    Button { router.tab = t.id } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.symbol).font(.system(size: 15, weight: .regular))
                            Text(t.title).font(.system(size: 10.5, weight: router.tab == t.id ? .semibold : .regular))
                        }
                        .frame(width: 78, height: 44)
                        .foregroundColor(router.tab == t.id ? Color(nsColor: Brand.accent) : .secondary)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(router.tab == t.id ? Color.primary.opacity(0.08) : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
            Divider()
            Group {
                switch router.tab {
                case "capture": CaptureSettings()
                case "quickaccess": QuickAccessSettings()
                case "recording": RecordingSettings()
                case "cloud": CloudSettings()
                case "shortcuts": ShortcutSettings()
                default: GeneralSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 640)
        .tint(Color(nsColor: Brand.accent))
    }
}

private struct GeneralSettings: View {
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("playSound") var playSound = true
    @AppStorage("showQuickAccess") var showQuickAccess = true
    @AppStorage("copyAfterCapture") var copyAfterCapture = false
    @AppStorage("saveAfterCapture") var saveAfterCapture = false
    @AppStorage("saveFolderPath") var saveFolderPath = ""
    @AppStorage("fileNameTemplate") var fileNameTemplate = "Snapper {date} at {time}"
    @AppStorage("retentionDays") var retentionDays = 30.0
    @AppStorage("autoUpdateCheck") var autoUpdateCheck = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: Brand.appIcon)
                        .resizable()
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Brand.name).font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(Brand.tagline).foregroundColor(.secondary)
                        Text(Brand.version).font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.apply(newValue) }
                Toggle("Play a sound when capturing", isOn: $playSound)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdateCheck)
                HStack {
                    Text("Version \(Updater.currentVersion)").foregroundColor(.secondary)
                    Spacer()
                    Button("Check Now") { Updater.menuAction() }
                }
            }
            Section("After capture") {
                Toggle("Show Quick Access overlay", isOn: $showQuickAccess)
                Toggle("Copy to clipboard", isOn: $copyAfterCapture)
                Toggle("Save to the save folder", isOn: $saveAfterCapture)
            }
            Section("Saving") {
                LabeledContent("Save folder") {
                    HStack {
                        Text(AppSettings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                TextField("File name", text: $fileNameTemplate)
                    .help("Tokens: {date} {time} {kind} {width} {height} {counter}")
            }
            Section("History") {
                LabeledContent("Keep captures for") {
                    Segments(selection: $retentionDays, items: [
                        (1.0, "Day", nil), (3.0, "3 days", nil), (7.0, "Week", nil), (30.0, "Month", nil)
                    ])
                }
                Button("Open History…") { Task { @MainActor in HistoryWindowController.show() } }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.saveFolder
        if panel.runModal() == .OK, let url = panel.url { saveFolderPath = url.path }
    }
}

private struct CaptureSettings: View {
    @AppStorage("hideDesktopIcons") var hideDesktopIcons = true
    @AppStorage("showCrosshair") var showCrosshair = true
    @AppStorage("showMagnifier") var showMagnifier = true
    @AppStorage("freezeScreen") var freezeScreen = true
    @AppStorage("selfTimerSeconds") var selfTimerSeconds = 5
    @AppStorage("windowCaptureStyle") var windowCaptureStyle = 1
    @ObservedObject private var model = WindowBackgroundModel.shared
    private var windowBackground: BackgroundSettings {
        get { model.settings }
        nonmutating set { model.settings = newValue }
    }

    var body: some View {
        Form {
            Section("Area capture") {
                Toggle("Show crosshair", isOn: $showCrosshair)
                Toggle("Show magnifier", isOn: $showMagnifier)
                Toggle("Freeze the screen while selecting", isOn: $freezeScreen)
                    .help("Turn freezing off to capture menus, videos and other moving content as they are when you release.")
                LabeledContent("Self-timer") {
                    Segments(selection: $selfTimerSeconds, items: [(3, "3 s", nil), (5, "5 s", nil), (10, "10 s", nil)])
                }
            }
            Section("Window capture") {
                LabeledContent("Style") {
                    PreviewPicker(selection: $windowCaptureStyle, items: [
                        Choice(0, "On a background") { WindowStyleArt(style: 0) },
                        Choice(1, "Transparent with shadow") { WindowStyleArt(style: 1) },
                        Choice(2, "Transparent, no shadow") { WindowStyleArt(style: 2) }
                    ], size: CGSize(width: 52, height: 36))
                }
                if windowCaptureStyle == 0 {
                    LabeledContent("Background") {
                        HStack(spacing: 6) {
                            swatch(-1, .wallpaper, "Desktop wallpaper")
                            swatch(-2, .color("#FFFFFF"), "White")
                            swatch(-3, .color("#000000"), "Black")
                            ForEach(0..<min(4, BackgroundCatalog.builtIn.count), id: \.self) { i in
                                swatch(i, .builtIn(i), BackgroundCatalog.builtIn[i].name)
                            }
                        }
                    }
                    LabeledContent("Padding") {
                        Slider(value: Binding(get: { Double(windowBackground.padding) },
                                              set: { windowBackground.padding = CGFloat($0); save() }), in: 0...0.25)
                            .controlSize(.small)
                            .frame(width: 180)
                    }
                }
            }
            Section("General") {
                Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ tag: Int, _ fill: BackgroundSettings.Fill, _ help: String) -> some View {
        let on = fillTag == tag
        return Button { setFill(tag) } label: {
            Image(nsImage: BackgroundMaker.thumbnail(fill, size: CGSize(width: 44, height: 44)))
                .resizable()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 2).padding(-3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var fillTag: Int {
        switch windowBackground.fill {
        case .wallpaper: return -1
        case .color(let hex): return hex == "#000000" ? -3 : -2
        case .builtIn(let i): return i
        default: return -1
        }
    }

    private func setFill(_ tag: Int) {
        switch tag {
        case -1: windowBackground.fill = .wallpaper
        case -2: windowBackground.fill = .color("#FFFFFF")
        case -3: windowBackground.fill = .color("#000000")
        default: windowBackground.fill = .builtIn(tag)
        }
        save()
    }

    private func save() { BackgroundSettings.windowCapture = windowBackground }
}

private struct QuickAccessSettings: View {
    @AppStorage("qaPosition") var qaPosition = 0
    @AppStorage("qaSize") var qaSize = 1
    @AppStorage("autoClosePanel") var autoClosePanel = true
    @AppStorage("autoCloseSeconds") var autoCloseSeconds = 8.0
    @AppStorage("closeAfterCopy") var closeAfterCopy = true
    @AppStorage("closeAfterSave") var closeAfterSave = true
    @AppStorage("closeAfterDrag") var closeAfterDrag = true

    var body: some View {
        Form {
            Section("Overlay") {
                LabeledContent("Position") {
                    PositionPad(selection: $qaPosition, slots: [
                        (3, .topLeading, "Top left"), (2, .topTrailing, "Top right"),
                        (1, .bottomLeading, "Bottom left"), (0, .bottomTrailing, "Bottom right")
                    ])
                }
                .help("Swipe the overlay towards the edge to dismiss it, away from the edge to save.")
                LabeledContent("Size") {
                    Segments(selection: $qaSize, items: [(0, "S", nil), (1, "M", nil), (2, "L", nil)])
                }
            }
            Section("Closing") {
                Toggle("Close automatically", isOn: $autoClosePanel)
                Stepper(value: $autoCloseSeconds, in: 2...60, step: 1) {
                    LabeledContent("After", value: "\(Int(autoCloseSeconds)) s")
                }
                .disabled(!autoClosePanel)
                Toggle("Close after copying", isOn: $closeAfterCopy)
                Toggle("Close after saving", isOn: $closeAfterSave)
                Toggle("Close after dragging out", isOn: $closeAfterDrag)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingSettings: View {
    @AppStorage("recordMic") var recordMic = false
    @AppStorage("recordSystemAudio") var recordSystemAudio = true
    @AppStorage("countdownSeconds") var countdownSeconds = 3
    @AppStorage("recordFPS") var recordFPS = 30
    @AppStorage("recordQuality") var recordQuality = 1
    @AppStorage("recordResolution") var recordResolution = 0
    @AppStorage("recordShowCursor") var recordShowCursor = true
    @AppStorage("editableCursor") var editableCursor = false
    @AppStorage("recordDoNotDisturb") var recordDoNotDisturb = false
    @AppStorage("recordHideDesktopIcons") var recordHideDesktopIcons = false
    @AppStorage("showClicks") var showClicks = true
    @AppStorage("clickColor") var clickColor = "#FFCC00"
    @AppStorage("clickSize") var clickSize = 64.0
    @AppStorage("clickStyle") var clickStyle = 0
    @AppStorage("clickAnimate") var clickAnimate = true
    @AppStorage("showKeystrokes") var showKeystrokes = false
    @AppStorage("keysPosition") var keysPosition = 0
    @AppStorage("keysSize") var keysSize = 1
    @AppStorage("keysStyle") var keysStyle = 0
    @AppStorage("keysOnlyShortcuts") var keysOnlyShortcuts = false
    @AppStorage("showCamera") var showCamera = false
    @AppStorage("cameraPosition") var cameraPosition = 0
    @AppStorage("cameraSize") var cameraSize = 1
    @AppStorage("cameraShape") var cameraShape = 0

    var body: some View {
        Form {
            Section("Video") {
                LabeledContent("Quality") {
                    Segments(selection: $recordQuality, items: [(0, "Low", nil), (1, "Medium", nil), (2, "High", nil)])
                }
                LabeledContent("Frame rate") {
                    Segments(selection: $recordFPS, items: [(15, "15", nil), (30, "30", nil), (60, "60", nil)])
                }
                LabeledContent("Resolution") {
                    Segments(selection: $recordResolution, items: [(0, "Retina", nil), (1, "1080p", nil), (2, "720p", nil)])
                }
                Stepper(value: $countdownSeconds, in: 0...10) {
                    LabeledContent("Countdown", value: countdownSeconds == 0 ? "Off" : "\(countdownSeconds) s")
                }
            }
            Section("Audio") {
                Toggle("Record microphone", isOn: $recordMic)
                Toggle("Record computer audio", isOn: $recordSystemAudio)
            }
            Section("Cursor") {
                Toggle("Show cursor", isOn: $recordShowCursor)
                Toggle("Editable cursor", isOn: $editableCursor)
                    .help("Records without the cursor and draws it in the video editor, where you can smooth it, resize it and add click effects.")
            }
            Section("While recording") {
                Toggle("Turn on Do Not Disturb", isOn: $recordDoNotDisturb)
                if recordDoNotDisturb {
                    Text("Create two shortcuts in the Shortcuts app: \u{201C}\(FocusMode.onShortcut)\u{201D} (Set Focus: Do Not Disturb, On) and \u{201C}\(FocusMode.offShortcut)\u{201D} (Turn Off). macOS doesn't let apps change Focus directly.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Toggle("Hide desktop icons", isOn: $recordHideDesktopIcons)
            }
            Section("Clicks") {
                Toggle("Highlight clicks", isOn: $showClicks)
                ColorPicker("Color", selection: Binding(get: { Color(nsColor: NSColor(hex: clickColor) ?? .systemYellow) },
                                                        set: { clickColor = NSColor($0).hexString }), supportsOpacity: false)
                LabeledContent("Size") { Slider(value: $clickSize, in: 32...120).controlSize(.small).frame(width: 180) }
                LabeledContent("Style") {
                    PreviewPicker(selection: $clickStyle, items: [
                        Choice(0, "Outline") { ClickArt(filled: false) },
                        Choice(1, "Filled") { ClickArt(filled: true) }
                    ])
                }
                Toggle("Animate", isOn: $clickAnimate)
            }
            .disabled(!showClicks)
            Section("Keystrokes") {
                Toggle("Show keystrokes", isOn: $showKeystrokes)
                    .help("Asks for Input Monitoring the first time")
                LabeledContent("Position") {
                    PositionPad(selection: $keysPosition, slots: [
                        (3, .top, "Top"), (1, .bottomLeading, "Bottom left"),
                        (0, .bottom, "Bottom"), (2, .bottomTrailing, "Bottom right")
                    ], block: CGSize(width: 14, height: 5))
                }
                LabeledContent("Size") {
                    Segments(selection: $keysSize, items: [(0, "S", nil), (1, "M", nil), (2, "L", nil)])
                }
                LabeledContent("Style") {
                    PreviewPicker(selection: $keysStyle, items: [
                        Choice(0, "Dark") { KeycapArt(scale: 1, dark: true) },
                        Choice(1, "Light") { KeycapArt(scale: 1, dark: false) }
                    ])
                }
                Toggle("Only shortcuts", isOn: $keysOnlyShortcuts)
                    .help("Show only ⌘, ⌥ and ⌃ combinations, not plain typing")
            }
            Section("Camera") {
                Toggle("Show camera", isOn: $showCamera)
                LabeledContent("Position") {
                    PositionPad(selection: $cameraPosition, slots: [
                        (2, .topLeading, "Top left"), (3, .topTrailing, "Top right"),
                        (0, .bottomLeading, "Bottom left"), (1, .bottomTrailing, "Bottom right")
                    ], block: CGSize(width: 10, height: 10), round: cameraShape == 0)
                }
                .help("You can also drag the camera while recording. Double-click it for fullscreen.")
                LabeledContent("Size") {
                    Segments(selection: $cameraSize, items: [(0, "S", nil), (1, "M", nil), (2, "L", nil)])
                }
                LabeledContent("Shape") {
                    Segments(selection: $cameraShape, items: [(0, "Circle", "circle"), (1, "Rounded", "app")])
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CloudSettings: View {
    @AppStorage("uploadEndpoint") var uploadEndpoint = ""
    @AppStorage("uploadToken") var uploadToken = ""
    @AppStorage("uploadExpiryHours") var uploadExpiryHours = 0

    var body: some View {
        Form {
            Section("Server") {
                TextField("Upload URL", text: $uploadEndpoint)
                SecureField("Access token (optional)", text: $uploadToken)
                    .help("Snapper sends the file with an HTTP PUT. The bundled server (server/server.js) adds password links, expiry, self-destructing links and comments.")
            }
            Section("Links") {
                LabeledContent("Links expire") {
                    Segments(selection: $uploadExpiryHours, items: [
                        (0, "Never", nil), (1, "1 h", nil), (24, "1 day", nil), (168, "1 week", nil), (720, "30 days", nil)
                    ])
                }
                .help("\u{2325}-click Upload to set a password, a different expiry, or delete-after-first-view for one upload.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var store = HotkeyStore.shared
    private let sections = ["Screenshots", "Recording", "Overlays and history"]

    var body: some View {
        Form {
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(HotkeyAction.allCases.filter { $0.section == section }) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(action.title)
                                Spacer()
                                ShortcutRecorder(action: action)
                                    .frame(width: 132, height: 24)
                                Button {
                                    store.set(nil, for: action)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Clear")
                                .opacity(store.combo(for: action) == nil ? 0 : 1)
                            }
                            if store.unavailable.contains(action) {
                                Text("Another app already uses this shortcut, so macOS didn't give it to Snapper.")
                                    .font(.caption).foregroundColor(.red)
                            } else if let msg = store.messages[action] {
                                Text(msg).font(.caption).foregroundColor(.orange)
                            }
                        }
                    }
                }
            }
            Section {
                HStack {
                    Button("Restore Defaults") { store.resetToDefaults() }
                    Spacer()
                    Button("Open Keyboard Shortcuts…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Click a field and press the keys. Esc cancels, Delete clears.")
                    .font(.caption).foregroundColor(.secondary)
                    .help("Shortcuts need ⌘, ⌃ or ⌥ (function keys work alone). To use ⌘⇧3, ⌘⇧4 or ⌘⇧5, turn the macOS screenshot shortcuts off first.")
            }
            Section("Quick Access overlay (pointer over it)") {
                LabeledContent("Copy · Save · Save As", value: "⌘C · ⌘S · ⇧⌘S")
                LabeledContent("Annotate · Pin · Text · Upload", value: "⌘E · ⌘P · ⌘T · ⌘U")
                LabeledContent("Close", value: "Esc or ⌘W")
            }
            Section("URL scheme") {
                Text("Automate Snapper from Shortcuts, Raycast or scripts with snapper:// links, e.g. snapper://capture-area. See the README for the full list.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Window-capture background being edited in Settings (ObservableObject instead of @State, which needs Xcode's macro plugins).
final class WindowBackgroundModel: ObservableObject {
    static let shared = WindowBackgroundModel()
    @Published var settings = BackgroundSettings.windowCapture
}
