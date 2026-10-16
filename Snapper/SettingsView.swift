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
                            Image(systemName: t.symbol).font(.system(size: 17))
                            Text(t.title).font(.system(size: 11))
                        }
                        .frame(width: 84, height: 46)
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
                Text("Tokens: {date} {time} {kind} {width} {height} {counter}")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("History") {
                TilePicker(title: "Keep captures for", selection: $retentionDays, choices: [
                    Choice(1.0, "1 day") { DaysArt(days: 1) },
                    Choice(3.0, "3 days") { DaysArt(days: 3) },
                    Choice(7.0, "1 week") { DaysArt(days: 7) },
                    Choice(30.0, "1 month") { DaysArt(days: 30) }
                ])
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
                Text("Turn freezing off to capture menus, videos and other moving content as they are when you release.")
                    .font(.caption).foregroundColor(.secondary)
                TilePicker(title: "Self-timer", selection: $selfTimerSeconds, choices: [3, 5, 10].map { n in
                    Choice(n, "\(n) s") { TimerArt(seconds: n) }
                })
            }
            Section("Window capture") {
                TilePicker(title: "Style", selection: $windowCaptureStyle, choices: [
                    Choice(0, "Background") { WindowStyleArt(style: 0) },
                    Choice(1, "Shadow") { WindowStyleArt(style: 1) },
                    Choice(2, "Flat") { WindowStyleArt(style: 2) }
                ], tile: CGSize(width: 70, height: 48))
                if windowCaptureStyle == 0 {
                    TilePicker(title: "Background", selection: Binding(get: { fillTag }, set: { setFill($0) }),
                               choices: [
                                   Choice(-1, "Wallpaper") { swatch(.wallpaper) },
                                   Choice(-2, "White") { swatch(.color("#FFFFFF")) },
                                   Choice(-3, "Black") { swatch(.color("#000000")) }
                               ] + (0..<BackgroundCatalog.builtIn.count).map { i in
                                   Choice(i, BackgroundCatalog.builtIn[i].name) { swatch(.builtIn(i)) }
                               },
                               tile: CGSize(width: 52, height: 36), columns: 6)
                    HStack {
                        Text("Padding")
                        Slider(value: Binding(get: { Double(windowBackground.padding) },
                                              set: { windowBackground.padding = CGFloat($0); save() }), in: 0...0.25)
                    }
                }
            }
            Section("General") {
                Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
            }
        }
        .formStyle(.grouped)
    }

    private func swatch(_ fill: BackgroundSettings.Fill) -> some View {
        Image(nsImage: BackgroundMaker.thumbnail(fill, size: CGSize(width: 40, height: 28)))
            .resizable()
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
                TilePicker(title: "Position", selection: $qaPosition, choices: [
                    Choice(0, "Bottom right") { ScreenArt(at: .bottomTrailing) },
                    Choice(1, "Bottom left") { ScreenArt(at: .bottomLeading) },
                    Choice(2, "Top right") { ScreenArt(at: .topTrailing) },
                    Choice(3, "Top left") { ScreenArt(at: .topLeading) }
                ])
                TilePicker(title: "Size", selection: $qaSize, choices: [
                    Choice(0, "Small") { ScreenArt(block: CGSize(width: 8, height: 6)) },
                    Choice(1, "Medium") { ScreenArt(block: CGSize(width: 13, height: 9)) },
                    Choice(2, "Large") { ScreenArt(block: CGSize(width: 19, height: 13)) }
                ])
                Text("The overlay appears on the display you captured. Swipe it towards the edge to dismiss, away from the edge to save.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Closing") {
                Toggle("Close automatically", isOn: $autoClosePanel)
                Stepper(value: $autoCloseSeconds, in: 2...60, step: 1) {
                    Text("After \(Int(autoCloseSeconds)) seconds")
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
                TilePicker(title: "Quality", selection: $recordQuality, choices: [
                    Choice(0, "Small files") { BarsArt(n: 1) },
                    Choice(1, "Medium") { BarsArt(n: 2) },
                    Choice(2, "High") { BarsArt(n: 3) }
                ], tile: CGSize(width: 62, height: 40))
                TilePicker(title: "Frame rate", selection: $recordFPS, choices: [
                    Choice(15, "15 fps") { FramesArt(count: 3) },
                    Choice(30, "30 fps") { FramesArt(count: 5) },
                    Choice(60, "60 fps") { FramesArt(count: 9) }
                ], tile: CGSize(width: 62, height: 40))
                TilePicker(title: "Resolution", selection: $recordResolution, choices: [
                    Choice(0, "Retina") { ScreenArt(at: .center, block: CGSize(width: 30, height: 20)) },
                    Choice(1, "1080p") { ScreenArt(at: .center, block: CGSize(width: 20, height: 13)) },
                    Choice(2, "720p") { ScreenArt(at: .center, block: CGSize(width: 12, height: 8)) }
                ], tile: CGSize(width: 62, height: 40))
                Stepper(value: $countdownSeconds, in: 0...10) { Text("Countdown: \(countdownSeconds) s") }
            }
            Section("Audio") {
                Toggle("Record microphone", isOn: $recordMic)
                Toggle("Record computer audio", isOn: $recordSystemAudio)
            }
            Section("Cursor") {
                Toggle("Show cursor", isOn: $recordShowCursor)
                Toggle("Editable cursor", isOn: $editableCursor)
                Text("Records without the cursor and draws it in the video editor, where you can smooth it, resize it and add click effects.")
                    .font(.caption).foregroundColor(.secondary)
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
                HStack { Text("Size"); Slider(value: $clickSize, in: 32...120) }
                TilePicker(title: "Style", selection: $clickStyle, choices: [
                    Choice(0, "Outline") { ClickArt(filled: false) },
                    Choice(1, "Filled") { ClickArt(filled: true) }
                ])
                Toggle("Animate", isOn: $clickAnimate)
            }
            .disabled(!showClicks)
            Section("Keystrokes") {
                Toggle("Show keystrokes (asks for Input Monitoring)", isOn: $showKeystrokes)
                TilePicker(title: "Position", selection: $keysPosition, choices: [
                    Choice(0, "Bottom") { ScreenArt(at: .bottom, block: CGSize(width: 16, height: 5)) },
                    Choice(1, "Bottom left") { ScreenArt(at: .bottomLeading, block: CGSize(width: 16, height: 5)) },
                    Choice(2, "Bottom right") { ScreenArt(at: .bottomTrailing, block: CGSize(width: 16, height: 5)) },
                    Choice(3, "Top") { ScreenArt(at: .top, block: CGSize(width: 16, height: 5)) }
                ])
                TilePicker(title: "Size", selection: $keysSize, choices: [
                    Choice(0, "Small") { KeycapArt(scale: 0.8) },
                    Choice(1, "Medium") { KeycapArt(scale: 1.05) },
                    Choice(2, "Large") { KeycapArt(scale: 1.35) }
                ])
                TilePicker(title: "Style", selection: $keysStyle, choices: [
                    Choice(0, "Dark") { KeycapArt(scale: 1.1, dark: true) },
                    Choice(1, "Light") { KeycapArt(scale: 1.1, dark: false) }
                ])
                Toggle("Only keyboard shortcuts (⌘, ⌥, ⌃ combinations)", isOn: $keysOnlyShortcuts)
            }
            Section("Camera") {
                Toggle("Show camera", isOn: $showCamera)
                TilePicker(title: "Position", selection: $cameraPosition, choices: [
                    Choice(0, "Bottom left") { ScreenArt(at: .bottomLeading, block: CGSize(width: 10, height: 10), round: cameraShape == 0) },
                    Choice(1, "Bottom right") { ScreenArt(at: .bottomTrailing, block: CGSize(width: 10, height: 10), round: cameraShape == 0) },
                    Choice(2, "Top left") { ScreenArt(at: .topLeading, block: CGSize(width: 10, height: 10), round: cameraShape == 0) },
                    Choice(3, "Top right") { ScreenArt(at: .topTrailing, block: CGSize(width: 10, height: 10), round: cameraShape == 0) }
                ])
                TilePicker(title: "Size", selection: $cameraSize, choices: [
                    Choice(0, "Small") { ScreenArt(block: CGSize(width: 7, height: 7), round: cameraShape == 0) },
                    Choice(1, "Medium") { ScreenArt(block: CGSize(width: 11, height: 11), round: cameraShape == 0) },
                    Choice(2, "Large") { ScreenArt(block: CGSize(width: 16, height: 16), round: cameraShape == 0) }
                ])
                TilePicker(title: "Shape", selection: $cameraShape, choices: [
                    Choice(0, "Circle") { Circle().frame(width: 22, height: 22) },
                    Choice(1, "Rounded") { RoundedRectangle(cornerRadius: 6).frame(width: 28, height: 22) }
                ])
                Text("Drag the camera to move it. Double-click for fullscreen camera.")
                    .font(.caption).foregroundColor(.secondary)
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
                Text("Snapper sends the file with an HTTP PUT. The bundled server (server/server.js) adds password links, expiry, self-destructing links and comments.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Links") {
                TilePicker(title: "Links expire", selection: $uploadExpiryHours, choices: [
                    Choice(0, "Never") { SymbolArt(name: "infinity") },
                    Choice(1, "1 hour") { SymbolArt(name: "clock") },
                    Choice(24, "1 day") { DaysArt(days: 1) },
                    Choice(168, "1 week") { DaysArt(days: 7) },
                    Choice(720, "30 days") { DaysArt(days: 30) }
                ], tile: CGSize(width: 52, height: 38))
                Text("⌥-click Upload to set a password, a different expiry, or delete-after-first-view for one upload.")
                    .font(.caption).foregroundColor(.secondary)
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
                Text("Click a field and press the new keys. Esc cancels, Delete clears. Shortcuts need ⌘, ⌃ or ⌥ (function keys work alone). To use ⌘⇧3, ⌘⇧4 or ⌘⇧5, turn the macOS screenshot shortcuts off first.")
                    .font(.caption).foregroundColor(.secondary)
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
