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
    @AppStorage("updateSource") var updateSource = ""

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
                TextField("Update source", text: $updateSource, prompt: Text("owner/repo or a feed URL"))
                HStack {
                    Text("Version \(Updater.currentVersion)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Check Now") { Updater.menuAction() }
                }
                Text("A GitHub repository (its latest release) or a URL that returns {\"version\", \"url\"}. The download is a .zip or .dmg containing Snapper.app.")
                    .font(.caption).foregroundColor(.secondary)
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
                Picker("Keep captures for", selection: $retentionDays) {
                    Text("1 day").tag(1.0)
                    Text("3 days").tag(3.0)
                    Text("1 week").tag(7.0)
                    Text("1 month").tag(30.0)
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
                Text("Turn freezing off to capture menus, videos and other moving content as they are when you release.")
                    .font(.caption).foregroundColor(.secondary)
                Picker("Self-timer", selection: $selfTimerSeconds) {
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            }
            Section("Window capture") {
                Picker("Style", selection: $windowCaptureStyle) {
                    Text("With background").tag(0)
                    Text("Transparent with shadow").tag(1)
                    Text("Transparent without shadow").tag(2)
                }
                if windowCaptureStyle == 0 {
                    Picker("Background", selection: Binding(get: { fillTag }, set: { setFill($0) })) {
                        Text("Desktop wallpaper").tag(-1)
                        Text("Plain white").tag(-2)
                        Text("Plain black").tag(-3)
                        ForEach(0..<BackgroundCatalog.builtIn.count, id: \.self) { i in
                            Text(BackgroundCatalog.builtIn[i].name).tag(i)
                        }
                    }
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
                Picker("Position", selection: $qaPosition) {
                    Text("Bottom right").tag(0)
                    Text("Bottom left").tag(1)
                    Text("Top right").tag(2)
                    Text("Top left").tag(3)
                }
                Picker("Size", selection: $qaSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                }
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
                Picker("Quality", selection: $recordQuality) {
                    Text("Low (small files)").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                Picker("Frame rate", selection: $recordFPS) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Resolution", selection: $recordResolution) {
                    Text("Native (Retina)").tag(0)
                    Text("Up to 1080p").tag(1)
                    Text("Up to 720p").tag(2)
                }
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
                Picker("Style", selection: $clickStyle) {
                    Text("Outline").tag(0)
                    Text("Filled").tag(1)
                }
                Toggle("Animate", isOn: $clickAnimate)
            }
            .disabled(!showClicks)
            Section("Keystrokes") {
                Toggle("Show keystrokes (asks for Input Monitoring)", isOn: $showKeystrokes)
                Picker("Position", selection: $keysPosition) {
                    Text("Bottom centre").tag(0)
                    Text("Bottom left").tag(1)
                    Text("Bottom right").tag(2)
                    Text("Top centre").tag(3)
                }
                Picker("Size", selection: $keysSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                }
                Picker("Style", selection: $keysStyle) {
                    Text("Dark").tag(0)
                    Text("Light").tag(1)
                }
                Toggle("Only keyboard shortcuts (⌘, ⌥, ⌃ combinations)", isOn: $keysOnlyShortcuts)
            }
            Section("Camera") {
                Toggle("Show camera", isOn: $showCamera)
                Picker("Position", selection: $cameraPosition) {
                    Text("Bottom left").tag(0)
                    Text("Bottom right").tag(1)
                    Text("Top left").tag(2)
                    Text("Top right").tag(3)
                }
                Picker("Size", selection: $cameraSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                }
                Picker("Shape", selection: $cameraShape) {
                    Text("Circle").tag(0)
                    Text("Rounded rectangle").tag(1)
                }
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
                Picker("Links expire", selection: $uploadExpiryHours) {
                    Text("Never").tag(0)
                    Text("After 1 hour").tag(1)
                    Text("After 1 day").tag(24)
                    Text("After 1 week").tag(168)
                    Text("After 30 days").tag(720)
                }
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
