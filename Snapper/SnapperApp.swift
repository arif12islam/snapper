import SwiftUI
import AppKit
import Combine
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Entry point. Snapper is a regular AppKit app (so it has a real menu bar and windows that behave like
/// any other app's) that lives in the menu bar and shows a Dock icon only while a window is open.
@main
enum SnapperMain {
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.run()
    }
}

/// Menu bar icon: a black template glyph, so macOS draws it dark or light to match the menu bar.
/// Falls back to an SF Symbol if the bundled PNG is missing.
enum MenuBarIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapper") ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()
}

/// Decodes images off the main thread.
enum ImageLoader {
    static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 16384
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
        }.value
    }
}

/// Keeps the app in the Dock and the menu bar active exactly while an app-style window (editor, settings,
/// history, video editor, About) is open; otherwise Snapper is a menu bar item only.
@MainActor
enum AppPresence {
    private static var windows: Set<ObjectIdentifier> = []

    static func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if !windows.contains(id) {
            windows.insert(id)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in
                Task { @MainActor in
                    windows.remove(id)
                    update(activate: false)
                }
            }
        }
        update(activate: true)
    }

    private static func update(activate: Bool) {
        let policy: NSApplication.ActivationPolicy = windows.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        if policy == .regular && activate { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// App-style Settings window (normal window, Dock icon and menu bar while open).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private let window: NSWindow

    static func show(tab: String? = nil) {
        if let tab { SettingsRouter.shared.tab = tab }
        if shared == nil { shared = SettingsWindowController() }
        guard let c = shared else { return }
        AppPresence.track(c.window)
        c.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Snapper Settings"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu(title: "Snapper")
    private var cancellables = Set<AnyCancellable>()

    /// Double-clicking a .snapper project in Finder, or a snapper:// link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == "snapper" {
                URLCommands.handle(url)
            } else if url.pathExtension.lowercased() == "snapper" {
                AnnotateWindowController.openProject(at: url)
            } else if ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(url.pathExtension.lowercased()) {
                URLCommands.annotate(file: url)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = Brand.appIcon

        installMenus()
        installStatusItem()

        // Menus show the current shortcuts: rebuild them whenever a shortcut changes.
        HotkeyStore.shared.$combos
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.installMenus() }
            .store(in: &cancellables)

        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // Global shortcuts come from HotkeyStore (editable in Settings > Shortcuts).
        HotkeyManager.shared.register()

        HistoryStore.shared.purgeOld()
        LaunchAtLogin.syncPreference()

        RecordingSession.offerRecovery()
        Updater.checkInBackground()
        WelcomePanel.showIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menus

    private func installMenus() {
        NSApp.mainMenu = MenuFactory.mainMenu(delegate: self)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarIcon.image
        item.button?.setAccessibilityLabel("Snapper")
        statusMenu.delegate = self
        item.menu = statusMenu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            MenuFactory.fillStatusMenu(menu, delegate: self)
        } else if menu.title == "Recent Captures" {
            MenuFactory.fillRecent(menu)
        }
    }
}

/// snapper:// automation API (Shortcuts, Raycast, Alfred, scripts).
@MainActor
enum URLCommands {
    static let commands: [String] = [
        "all-in-one", "capture-area", "capture-window", "capture-fullscreen", "capture-previous-area",
        "self-timer", "scrolling-capture", "capture-text", "pin-area", "record-screen", "record-area",
        "record-window", "record-gif", "stop-recording", "restore", "toggle-overlays", "history",
        "open-annotate", "open-settings"
    ]

    static func handle(_ url: URL) {
        let c = CaptureCoordinator.shared
        let command = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch command {
        case "all-in-one": c.captureAllInOne()
        case "capture-area": c.captureArea()
        case "capture-window": c.captureWindow()
        case "capture-fullscreen":
            if query.contains(where: { $0.name == "timer" }) { c.captureFullscreenTimer() } else { c.captureFullscreen() }
        case "capture-previous-area": c.capturePreviousArea()
        case "self-timer": c.captureSelfTimer()
        case "scrolling-capture":
            c.captureScrolling(horizontal: query.contains { $0.name == "horizontal" && $0.value != "0" })
        case "capture-text": c.captureText()
        case "pin-area": c.capturePinArea()
        case "record-screen": RecordingSession.shared.toggleFullscreen()
        case "record-area": RecordingSession.shared.start(area: true)
        case "record-window": RecordingSession.shared.startWindow()
        case "record-gif": RecordingSession.shared.start(area: true, gif: true)
        case "stop-recording": RecordingSession.shared.stop()
        case "restore": c.restoreLast()
        case "toggle-overlays": QuickAccessPanel.toggleHidden()
        case "history": HistoryWindowController.show()
        case "open-annotate":
            if let path = query.first(where: { $0.name == "filepath" })?.value {
                annotate(file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            } else if let last = c.lastResult {
                AnnotateWindowController.open(image: last.image)
            }
        case "open-settings":
            SettingsWindowController.show()
        default:
            NSSound.beep()
        }
    }

    static func annotate(file url: URL) {
        if url.pathExtension.lowercased() == "snapper" {
            AnnotateWindowController.openProject(at: url)
            return
        }
        // Decode off the main thread so big files don't freeze the app; EXIF rotation is applied.
        Task {
            let image = await ImageLoader.load(url)
            if let image { AnnotateWindowController.open(image: image) } else { NSSound.beep() }
        }
    }
}


// MARK: - Menus

/// A menu item that runs a closure and shows its shortcut from the user's own Shortcuts settings.
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void
    var enabledWhen: (() -> Bool)?

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() {
        let h = handler
        Task { @MainActor in h() }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { enabledWhen?() ?? true }
}

extension KeyCombo {
    /// The key as NSMenuItem wants it (nil when it has no menu equivalent).
    var menuKeyEquivalent: String? {
        if key.count == 1 { return key.lowercased() }
        func scalar(_ v: Int) -> String? { UnicodeScalar(UInt32(v)).map { String(Character($0)) } }
        switch key {
        case "Space": return " "
        case "↩": return "\r"
        case "⇥": return "\t"
        case "←": return scalar(NSLeftArrowFunctionKey)
        case "→": return scalar(NSRightArrowFunctionKey)
        case "↑": return scalar(NSUpArrowFunctionKey)
        case "↓": return scalar(NSDownArrowFunctionKey)
        default:
            if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...20).contains(n) {
                return scalar(NSF1FunctionKey + n - 1)
            }
            return nil
        }
    }
}

@MainActor
enum MenuFactory {
    // MARK: Building blocks

    static func action(_ title: String, symbol: String? = nil, icons: Bool = false, hotkey: HotkeyAction? = nil,
                       key: String = "", mods: NSEvent.ModifierFlags = [.command],
                       enabled: (() -> Bool)? = nil,
                       _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ActionItem(title: title, handler: run)
        item.enabledWhen = enabled
        if icons, let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        if let hotkey, let combo = HotkeyStore.shared.combo(for: hotkey), let ke = combo.menuKeyEquivalent {
            item.keyEquivalent = ke
            item.keyEquivalentModifierMask = combo.flags
        } else if !key.isEmpty {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        return item
    }

    /// A menu item that goes through the responder chain (standard Edit, Window… commands).
    static func standard(_ title: String, _ selector: Selector, key: String = "",
                         mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = mods }
        return item
    }

    /// Item that the focused editor window handles by identifier (disabled when no editor is open).
    static func command(_ title: String, _ id: String, key: String = "",
                        mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = standard(title, Selector(("snapperCommand:")), key: key, mods: mods)
        item.representedObject = id
        return item
    }

    static func submenu(_ title: String, symbol: String? = nil, icons: Bool = false, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if icons, let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        let menu = NSMenu(title: title)
        for i in items { menu.addItem(i) }
        item.submenu = menu
        return item
    }

    private static func fill(_ menu: NSMenu, _ items: [NSMenuItem]) {
        for i in items { menu.addItem(i) }
    }

    // MARK: Capture and recording items (shared by the menu bar item and the File menu)

    static func screenshotItems(icons: Bool) -> [NSMenuItem] {
        let c = CaptureCoordinator.shared
        return [
            action("All-In-One", symbol: "square.dashed.inset.filled", icons: icons, hotkey: .allInOne) { c.captureAllInOne() },
            .separator(),
            action("Capture Screen", symbol: "display", icons: icons, hotkey: .captureFullscreen) { c.captureFullscreen() },
            action("Capture Area", symbol: "rectangle.dashed", icons: icons, hotkey: .captureArea) { c.captureArea() },
            action("Capture Window", symbol: "macwindow", icons: icons, hotkey: .captureWindow) { c.captureWindow() },
            action("Capture Previous Area", symbol: "clock.arrow.circlepath", icons: icons, hotkey: .capturePrevious) { c.capturePreviousArea() },
            submenu("Scrolling Capture", symbol: "chevron.down.2", icons: icons, items: [
                action("Vertical", hotkey: .scrolling) { c.captureScrolling(horizontal: false) },
                action("Horizontal") { c.captureScrolling(horizontal: true) }
            ]),
            submenu("Self-Timer", symbol: "timer", icons: icons, items: [
                action("Area", hotkey: .selfTimer) { c.captureSelfTimer() },
                action("Full Screen") { c.captureFullscreenTimer() }
            ]),
            action("Recognize Text/QR", symbol: "text.viewfinder", icons: icons, hotkey: .captureText) { c.captureText() },
            action("Pin Area to Screen", symbol: "pin", icons: icons, hotkey: .pinArea) { c.capturePinArea() }
        ]
    }

    static func recordItems(icons: Bool, includeStop: Bool) -> [NSMenuItem] {
        let r = RecordingSession.shared
        var items: [NSMenuItem] = [
            action("Record Screen", symbol: "record.circle", icons: icons, hotkey: .recordScreen) { r.toggleFullscreen() },
            action("Record Area", symbol: "rectangle.dashed.badge.record", icons: icons, hotkey: .recordArea) { r.start(area: true) },
            action("Record Window", symbol: "macwindow.badge.plus", icons: icons, hotkey: .recordWindow) { r.startWindow() },
            action("Record GIF", symbol: "photo.stack", icons: icons, hotkey: .recordGIF) { r.start(area: true, gif: true) }
        ]
        if includeStop {
            items.append(action("Stop Recording", symbol: "stop.circle", icons: icons, enabled: { RecordingSession.shared.isRecording }) { r.stop() })
        }
        return items
    }

    static func recentItems() -> [NSMenuItem] {
        let entries = HistoryStore.shared.recent(limit: 12)
        if entries.isEmpty {
            let none = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return [none]
        }
        return entries.map { entry in
            action(entry.label) { HistoryStore.shared.restore(entry) }
        }
    }

    static func fillRecent(_ menu: NSMenu) {
        menu.removeAllItems()
        fill(menu, recentItems())
    }

    private static func recentSubmenu(icons: Bool, delegate: NSMenuDelegate) -> NSMenuItem {
        let item = submenu("Recent Captures", symbol: "clock.arrow.circlepath", icons: icons, items: recentItems())
        item.submenu?.delegate = delegate
        return item
    }

    // MARK: Menu bar item

    static func fillStatusMenu(_ menu: NSMenu, delegate: NSMenuDelegate) {
        menu.removeAllItems()
        if Updater.available != nil {
            let up = action(Updater.menuTitle, symbol: "arrow.triangle.2.circlepath", icons: true) { Updater.menuAction() }
            menu.addItem(up)
            menu.addItem(.separator())
        }
        if RecordingSession.shared.isRecording {
            let stop = action("Stop Recording", symbol: "stop.circle.fill", icons: true) { RecordingSession.shared.stop() }
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        fill(menu, screenshotItems(icons: true))
        menu.addItem(.separator())
        fill(menu, recordItems(icons: true, includeStop: false))
        menu.addItem(.separator())
        menu.addItem(action("Capture History…", symbol: "clock", icons: true, hotkey: .history) { HistoryWindowController.show() })
        menu.addItem(recentSubmenu(icons: true, delegate: delegate))
        menu.addItem(action("Restore Recently Closed", symbol: "arrow.uturn.backward.circle", icons: true, hotkey: .restore) {
            CaptureCoordinator.shared.restoreLast()
        })
        menu.addItem(action(QuickAccessPanel.overlaysHidden ? "Show Overlays" : "Hide Overlays", symbol: "eye.slash", icons: true,
                            hotkey: .toggleOverlays) { QuickAccessPanel.toggleHidden() })
        menu.addItem(.separator())
        menu.addItem(action("Open Image…", symbol: "photo", icons: true) { openImageForAnnotate() })
        menu.addItem(action("Open Project…", symbol: "folder", icons: true) { AnnotateWindowController.openProjectPanel() })
        if PinPanel.count > 0 {
            menu.addItem(submenu("Pins", symbol: "pin", icons: true, items: [
                action("Unlock All Pins") { PinPanel.unlockAll() },
                action("Close All Pins") { PinPanel.closeAll() }
            ]))
        }
        menu.addItem(.separator())
        let login = action("Launch at Startup") {
            let on = !LaunchAtLogin.isEnabled
            LaunchAtLogin.apply(on)
            UserDefaults.standard.set(LaunchAtLogin.isEnabled, forKey: "launchAtLogin")
        }
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Settings…", symbol: "gearshape", icons: true, key: ",") { SettingsWindowController.show() })
        menu.addItem(action(Updater.menuTitle, symbol: "arrow.triangle.2.circlepath", icons: true) { Updater.menuAction() })
        menu.addItem(action("About Snapper", symbol: "info.circle", icons: true) { AboutWindow.show() })
        menu.addItem(standard("Quit Snapper", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    // MARK: Main menu (Snapper, File, Edit, Draw, Zoom, Capture, Help)

    static func mainMenu(delegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu(title: "Main")

        func top(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for i in items { menu.addItem(i) }
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        // Snapper
        _ = top(Brand.name, [
            action("About Snapper") { AboutWindow.show() },
            .separator(),
            action("Settings…", key: ",") { SettingsWindowController.show() },
            action("Check for Updates…") { Updater.menuAction() },
            .separator(),
            standard("Hide Snapper", #selector(NSApplication.hide(_:)), key: "h"),
            standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", mods: [.command, .option]),
            standard("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            standard("Quit Snapper", #selector(NSApplication.terminate(_:)), key: "q")
        ])

        // File
        _ = top("File", [
            command("Copy Image", "copy", key: "c", mods: [.command, .shift]),
            command("Save Image", "save", key: "s"),
            command("Save Image As…", "saveAs", key: "s", mods: [.command, .shift]),
            command("Save Project…", "saveProject"),
            command("Upload Image", "upload", key: "e"),
            command("Pin to Screen", "pin", key: "p"),
            command("Print…", "print", key: "p", mods: [.command, .shift]),
            .separator(),
            action("Open File…", key: "o", mods: [.command, .shift]) { openImageForAnnotate() },
            action("Open From Clipboard", key: "v", mods: [.command, .shift]) { openFromClipboard() },
            action("Open Project…") { AnnotateWindowController.openProjectPanel() },
            recentSubmenu(icons: false, delegate: delegate),
            .separator(),
            standard("Close", #selector(NSWindow.performClose(_:)), key: "w")
        ])

        // Edit
        _ = top("Edit", [
            standard("Undo", Selector(("undo:")), key: "z"),
            standard("Redo", Selector(("redo:")), key: "z", mods: [.command, .shift]),
            .separator(),
            standard("Copy", Selector(("copy:")), key: "c"),
            standard("Paste", Selector(("paste:")), key: "v"),
            standard("Delete", Selector(("delete:"))),
            .separator(),
            command("Add Image…", "addImage"),
            command("Rotate Left", "rotateLeft"),
            command("Rotate Right", "rotateRight"),
            command("Flip Horizontal", "flipH"),
            command("Flip Vertical", "flipV")
        ])

        // Draw
        var drawItems: [NSMenuItem] = AnnotationTool.allCases.filter { $0 != .callout && $0 != .ellipse }.map { t in
            let i = command(t.title, "tool:" + t.rawValue)
            i.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
            return i
        }
        drawItems.append(.separator())
        drawItems.append(command("Background…", "background"))
        _ = top("Draw", drawItems)

        // Zoom
        _ = top("Zoom", [
            standard("Zoom In", Selector(("snapperZoomIn:")), key: "+"),
            standard("Zoom Out", Selector(("snapperZoomOut:")), key: "-"),
            standard("Actual Size", Selector(("snapperActualSize:")), key: "1"),
            standard("Zoom to Fit", Selector(("snapperFit:")), key: "0"),
            .separator(),
            standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", mods: [.command, .control])
        ])

        // Capture
        var captureItems: [NSMenuItem] = [action("All-In-One", hotkey: .allInOne) { CaptureCoordinator.shared.captureAllInOne() }]
        captureItems.append(contentsOf: Array(screenshotItems(icons: false).dropFirst(2)))
        captureItems.append(NSMenuItem.separator())
        captureItems.append(submenu("Record", items: recordItems(icons: false, includeStop: true)))
        captureItems.append(NSMenuItem.separator())
        captureItems.append(action("Capture History…", hotkey: .history) { HistoryWindowController.show() })
        captureItems.append(action("Restore Recently Closed", hotkey: .restore) { CaptureCoordinator.shared.restoreLast() })
        captureItems.append(action("Hide / Show Overlays", hotkey: .toggleOverlays) { QuickAccessPanel.toggleHidden() })
        captureItems.append(action("Close All Overlays") { QuickAccessPanel.closeAll() })
        captureItems.append(NSMenuItem.separator())
        captureItems.append(action("Unlock All Pins") { PinPanel.unlockAll() })
        captureItems.append(action("Close All Pins") { PinPanel.closeAll() })
        captureItems.append(action("Open Save Folder") { NSWorkspace.shared.open(AppSettings.saveFolder) })
        _ = top("Capture", captureItems)
        NSApp.windowsMenu = nil

        // Help
        let help = top("Help", [
            action("Keyboard Shortcuts…") { SettingsWindowController.show(tab: "shortcuts") },
            action("Welcome") {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                WelcomePanel.showIfNeeded()
            },
            .separator(),
            builtBy()
        ])
        NSApp.helpMenu = help

        return main
    }

    private static func builtBy() -> NSMenuItem {
        let item = NSMenuItem(title: Brand.credit, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @MainActor
    static func openFromClipboard() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            AnnotateWindowController.open(image: cg)
        } else {
            Toast.show("No image on the clipboard")
        }
    }

    @MainActor
    static func openImageForAnnotate() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { URLCommands.annotate(file: url) }
    }
}
