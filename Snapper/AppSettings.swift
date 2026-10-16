import AppKit

/// Typed UserDefaults accessors. Defaults here must match the @AppStorage defaults in SettingsView.
enum AppSettings {
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) as? Bool ?? def }
    private static func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) as? Int ?? def }
    private static func double(_ key: String, _ def: Double) -> Double { d.object(forKey: key) as? Double ?? def }
    private static func string(_ key: String, _ def: String) -> String { d.string(forKey: key) ?? def }

    // MARK: General / after capture
    static var saveFolderPath: String { string("saveFolderPath", "") }
    static var saveFolder: URL {
        let p = saveFolderPath
        if !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
    static var showQuickAccess: Bool { bool("showQuickAccess", true) }
    static var copyAfterCapture: Bool { bool("copyAfterCapture", false) }
    static var saveAfterCapture: Bool { bool("saveAfterCapture", false) }
    static var playSound: Bool { bool("playSound", true) }
    static var fileNameTemplate: String { string("fileNameTemplate", "Snapper {date} at {time}") }
    static var retentionDays: Double { double("retentionDays", 7) }

    // MARK: Capture
    static var hideDesktopIcons: Bool { bool("hideDesktopIcons", true) }
    static var showCrosshair: Bool { bool("showCrosshair", true) }
    static var showMagnifier: Bool { bool("showMagnifier", true) }
    static var freezeScreen: Bool { bool("freezeScreen", true) }
    static var selfTimerSeconds: Int { int("selfTimerSeconds", 5) }
    /// 0 = with background, 1 = transparent with shadow, 2 = transparent without shadow.
    static var windowCaptureStyle: Int { int("windowCaptureStyle", 1) }

    // MARK: Quick Access
    static var autoClosePanel: Bool { bool("autoClosePanel", false) }
    static var autoCloseSeconds: Double { double("autoCloseSeconds", 8) }
    /// 0 bottom-right, 1 bottom-left, 2 top-right, 3 top-left.
    static var qaPosition: Int { int("qaPosition", 0) }
    /// 0 small, 1 medium, 2 large.
    static var qaSize: Int { int("qaSize", 1) }
    static var closeAfterCopy: Bool { bool("closeAfterCopy", true) }
    static var closeAfterSave: Bool { bool("closeAfterSave", true) }
    static var closeAfterDrag: Bool { bool("closeAfterDrag", true) }

    // MARK: Recording
    static var recordMic: Bool { bool("recordMic", false) }
    static var recordSystemAudio: Bool { bool("recordSystemAudio", true) }
    static var showClicks: Bool { bool("showClicks", true) }
    static var showKeystrokes: Bool { bool("showKeystrokes", false) }
    static var showCamera: Bool { bool("showCamera", false) }
    static var countdownSeconds: Int { int("countdownSeconds", 3) }
    static var recordFPS: Int { int("recordFPS", 30) }
    /// 0 low, 1 medium, 2 high.
    static var recordQuality: Int { int("recordQuality", 1) }
    /// 0 native, 1 at most 1080p, 2 at most 720p.
    static var recordResolution: Int { int("recordResolution", 1) }
    static var recordShowCursor: Bool { bool("recordShowCursor", true) }
    /// Record without the cursor and draw it in the video editor (smooth cursor, cursor size, click effects).
    static var editableCursor: Bool { bool("editableCursor", false) }
    static var recordDoNotDisturb: Bool { Features.doNotDisturb && bool("recordDoNotDisturb", false) }
    static var recordHideDesktopIcons: Bool { bool("recordHideDesktopIcons", false) }

    static var clickColor: String { string("clickColor", "#FFCC00") }
    static var clickSize: Double { double("clickSize", 64) }
    /// 0 outline, 1 filled.
    static var clickStyle: Int { int("clickStyle", 0) }
    static var clickAnimate: Bool { bool("clickAnimate", true) }

    /// 0 bottom centre, 1 bottom left, 2 bottom right, 3 top centre.
    static var keysPosition: Int { int("keysPosition", 0) }
    /// 0 small, 1 medium, 2 large.
    static var keysSize: Int { int("keysSize", 1) }
    /// 0 dark, 1 light.
    static var keysStyle: Int { int("keysStyle", 0) }
    static var keysOnlyShortcuts: Bool { bool("keysOnlyShortcuts", false) }

    /// 0 bottom left, 1 bottom right, 2 top left, 3 top right.
    static var cameraPosition: Int { int("cameraPosition", 0) }
    /// 0 small, 1 medium, 2 large.
    static var cameraSize: Int { int("cameraSize", 1) }
    /// 0 circle, 1 rounded rectangle.
    static var cameraShape: Int { int("cameraShape", 0) }

    // MARK: Cloud
    static var uploadEndpoint: String { string("uploadEndpoint", "") }
    static var uploadToken: String { string("uploadToken", "") }
    /// Hours until a link expires; 0 = never.
    static var uploadExpiryHours: Int { int("uploadExpiryHours", 0) }
}
