import AppKit
import Carbon
import SwiftUI

// MARK: - Key combos

/// A global shortcut: virtual key code + Cocoa modifier flags, with a display string captured when recorded.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt              // NSEvent.ModifierFlags raw value (command/shift/option/control only)
    var key: String                  // printable key, e.g. "A", "5", "Space", "F5"

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    /// "⌃⇧A" in Apple's modifier order.
    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    /// SwiftUI shortcut for menus (nil when the key has no single-character equivalent).
    var menuShortcut: KeyboardShortcut? {
        guard key.count == 1, let ch = key.lowercased().first else { return nil }
        var m: SwiftUI.EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: m)
    }

    static func make(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ key: String) -> KeyCombo {
        KeyCombo(keyCode: UInt32(keyCode), modifiers: flags.intersection(relevant).rawValue, key: key)
    }

    private static let specialKeys: [UInt16: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool { (specialKeys[keyCode] ?? "").hasPrefix("F") }

    static func keyName(for event: NSEvent) -> String {
        if let s = specialKeys[event.keyCode] { return s }
        let ch = (event.charactersIgnoringModifiers ?? "").uppercased()
        return ch.isEmpty ? "#\(event.keyCode)" : ch
    }
}

// MARK: - Actions

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case allInOne, captureArea, captureWindow, captureFullscreen, capturePrevious, scrolling, selfTimer,
         captureText, pinArea, recordScreen, recordArea, recordWindow, recordGIF, restore, toggleOverlays, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: return "All-in-one"
        case .captureArea: return "Capture area"
        case .captureWindow: return "Capture window"
        case .captureFullscreen: return "Capture screen"
        case .capturePrevious: return "Capture previous area"
        case .scrolling: return "Scrolling capture"
        case .selfTimer: return "Self-timer"
        case .captureText: return "Recognize text / QR"
        case .pinArea: return "Pin area to screen"
        case .recordScreen: return "Record screen (start / stop)"
        case .recordArea: return "Record area"
        case .recordWindow: return "Record window"
        case .recordGIF: return "Record GIF"
        case .restore: return "Restore recently closed"
        case .toggleOverlays: return "Hide / show overlays"
        case .history: return "Capture history"
        }
    }

    var section: String {
        switch self {
        case .allInOne, .captureArea, .captureWindow, .captureFullscreen, .capturePrevious, .scrolling,
             .selfTimer, .captureText, .pinArea: return "Screenshots"
        case .recordScreen, .recordArea, .recordWindow, .recordGIF: return "Recording"
        case .restore, .toggleOverlays, .history: return "Overlays and history"
        }
    }

    var defaultCombo: KeyCombo? {
        let cs: NSEvent.ModifierFlags = [.control, .shift]
        switch self {
        case .allInOne: return .make(kVK_ANSI_X, cs, "X")
        case .captureArea: return .make(kVK_ANSI_A, cs, "A")
        case .captureWindow: return .make(kVK_ANSI_W, cs, "W")
        case .captureFullscreen: return .make(kVK_ANSI_F, cs, "F")
        case .captureText: return .make(kVK_ANSI_T, cs, "T")
        case .recordScreen: return .make(kVK_ANSI_R, cs, "R")
        case .restore: return .make(kVK_ANSI_Z, cs, "Z")
        case .toggleOverlays: return .make(kVK_ANSI_H, cs, "H")
        default: return nil
        }
    }

    @MainActor
    func perform() {
        let c = CaptureCoordinator.shared
        switch self {
        case .allInOne: c.captureAllInOne()
        case .captureArea: c.captureArea()
        case .captureWindow: c.captureWindow()
        case .captureFullscreen: c.captureFullscreen()
        case .capturePrevious: c.capturePreviousArea()
        case .scrolling: c.captureScrolling(horizontal: false)
        case .selfTimer: c.captureSelfTimer()
        case .captureText: c.captureText()
        case .pinArea: c.capturePinArea()
        case .recordScreen: RecordingSession.shared.toggleFullscreen()
        case .recordArea: RecordingSession.shared.start(area: true)
        case .recordWindow: RecordingSession.shared.startWindow()
        case .recordGIF: RecordingSession.shared.start(area: true, gif: true)
        case .restore: c.restoreLast()
        case .toggleOverlays: QuickAccessPanel.toggleHidden()
        case .history: HistoryWindowController.show()
        }
    }
}

// MARK: - Store (persistence + validation)

final class HotkeyStore: ObservableObject {
    static let shared = HotkeyStore()

    @Published private(set) var combos: [HotkeyAction: KeyCombo] = [:]
    /// Shortcuts macOS refused to register (another app already owns them).
    @Published var unavailable: Set<HotkeyAction> = []
    /// Last message per action shown under its recorder (problem or advice).
    @Published var messages: [HotkeyAction: String] = [:]

    private let key = "globalHotkeys"

    private init() {
        load()
    }

    func combo(for action: HotkeyAction) -> KeyCombo? { combos[action] }

    private func load() {
        var result: [HotkeyAction: KeyCombo] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for action in HotkeyAction.allCases {
                if let entry = saved[action.rawValue] {
                    if let combo = entry { result[action] = combo }      // explicit nil = cleared by the user
                } else if let d = action.defaultCombo {
                    result[action] = d
                }
            }
        } else {
            for action in HotkeyAction.allCases { if let d = action.defaultCombo { result[action] = d } }
        }
        combos = result
    }

    private func save() {
        var out: [String: KeyCombo?] = [:]
        for action in HotkeyAction.allCases { out[action.rawValue] = combos[action] }
        if let data = try? JSONEncoder().encode(out) { UserDefaults.standard.set(data, forKey: key) }
    }

    enum Verdict {
        case ok
        case warning(String)       // accepted, with advice
        case rejected(String)      // not accepted
    }

    /// Checks a shortcut against the rules, Snapper's other shortcuts and macOS's own shortcuts.
    func validate(_ combo: KeyCombo, for action: HotkeyAction) -> Verdict {
        let f = combo.flags
        let hasPrimary = f.contains(.command) || f.contains(.control) || f.contains(.option)
        if !hasPrimary && !KeyCombo.isFunctionKey(UInt16(combo.keyCode)) {
            return .rejected("Use at least one of ⌘, ⌃ or ⌥, so it doesn't fire while you type.")
        }
        if let other = combos.first(where: { $0.key != action && $0.value.keyCode == combo.keyCode && $0.value.flags == f })?.key {
            return .rejected("Already used for \u{201C}\(other.title)\u{201D}.")
        }
        if let reserved = SystemShortcuts.reserved(combo) {
            return .rejected("\(combo.display) is \(reserved) in macOS and most apps.")
        }
        if let system = SystemShortcuts.enabledConflict(combo) {
            if system.isScreenshot {
                return .warning("macOS uses \(combo.display) for \u{201C}\(system.name)\u{201D}. Turn it off in System Settings > Keyboard > Keyboard Shortcuts > Screenshots so Snapper gets it.")
            }
            return .rejected("macOS uses \(combo.display) for \u{201C}\(system.name)\u{201D}. Pick another, or turn that one off in System Settings > Keyboard > Keyboard Shortcuts.")
        }
        return .ok
    }

    /// Sets (or clears, with nil) a shortcut. Returns the verdict; rejected shortcuts are not stored.
    @discardableResult
    func set(_ combo: KeyCombo?, for action: HotkeyAction) -> Verdict {
        guard let combo else {
            combos[action] = nil
            messages[action] = nil
            save()
            HotkeyManager.shared.register()
            return .ok
        }
        let verdict = validate(combo, for: action)
        switch verdict {
        case .rejected(let msg):
            messages[action] = msg
            return verdict
        case .warning(let msg):
            messages[action] = msg
        case .ok:
            messages[action] = nil
        }
        combos[action] = combo
        save()
        HotkeyManager.shared.register()
        return verdict
    }

    func resetToDefaults() {
        var result: [HotkeyAction: KeyCombo] = [:]
        for action in HotkeyAction.allCases { if let d = action.defaultCombo { result[action] = d } }
        combos = result
        messages = [:]
        save()
        HotkeyManager.shared.register()
    }
}

// MARK: - macOS shortcuts

enum SystemShortcuts {
    struct Hit {
        let name: String
        let isScreenshot: Bool
    }

    private static let cmd = NSEvent.ModifierFlags.command.rawValue
    private static let shift = NSEvent.ModifierFlags.shift.rawValue
    private static let opt = NSEvent.ModifierFlags.option.rawValue
    private static let ctrl = NSEvent.ModifierFlags.control.rawValue

    /// macOS symbolic hotkeys that are on by default: id -> (key code, modifiers, name).
    private static let defaults: [Int: (Int, UInt, String)] = [
        28: (20, cmd | shift, "Save picture of screen as a file"),
        29: (20, ctrl | cmd | shift, "Copy picture of screen to the clipboard"),
        30: (21, cmd | shift, "Save picture of selected area as a file"),
        31: (21, ctrl | cmd | shift, "Copy picture of selected area to the clipboard"),
        184: (23, cmd | shift, "Screenshot and recording options"),
        64: (49, cmd, "Show Spotlight search"),
        65: (49, cmd | opt, "Show Finder search window"),
        60: (49, ctrl, "Select the previous input source"),
        61: (49, ctrl | opt, "Select next source in Input menu"),
        32: (126, ctrl, "Mission Control"),
        33: (125, ctrl, "Application windows"),
        79: (123, ctrl, "Move left a space"),
        81: (124, ctrl, "Move right a space"),
        36: (103, 0, "Show Desktop"),
        52: (2, cmd | opt, "Turn Dock hiding on/off"),
        118: (18, ctrl, "Switch to Desktop 1"),
        119: (19, ctrl, "Switch to Desktop 2"),
        120: (20, ctrl, "Switch to Desktop 3"),
        162: (96, ctrl | opt | cmd, "Turn VoiceOver on or off"),
        15: (46, cmd | opt, "Minimize all windows")
    ]
    private static let screenshotIDs: Set<Int> = [28, 29, 30, 31, 184]

    /// The user's current symbolic hotkeys (includes changes made in System Settings).
    private typealias Entry = (enabled: Bool, keyCode: Int, mods: UInt)

    private static func current() -> [Int: Entry] {
        var result: [Int: Entry] = [:]
        for (id, d) in defaults { result[id] = (enabled: true, keyCode: d.0, mods: d.1) }
        guard let dict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return result }
        for (k, v) in dict {
            guard let id = Int(k), let entry = v as? [String: Any] else { continue }
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) ?? 1 != 0)
            guard let value = entry["value"] as? [String: Any], let params = value["parameters"] as? [Int], params.count >= 3
            else {
                if var existing = result[id] { existing.enabled = enabled; result[id] = existing }
                continue
            }
            result[id] = (enabled: enabled, keyCode: params[1], mods: UInt(params[2]))
        }
        return result
    }

    static func enabledConflict(_ combo: KeyCombo) -> Hit? {
        let mask = KeyCombo.relevant.rawValue
        for (id, entry) in current() where entry.enabled {
            guard entry.keyCode == Int(combo.keyCode), entry.mods & mask == combo.modifiers & mask else { continue }
            let name = defaults[id]?.2 ?? "a system shortcut"
            return Hit(name: name, isScreenshot: screenshotIDs.contains(id))
        }
        return nil
    }

    /// Shortcuts no app should take over.
    static func reserved(_ combo: KeyCombo) -> String? {
        let f = combo.flags
        let k = Int(combo.keyCode)
        if f == [.command] {
            let names: [Int: String] = [
                kVK_ANSI_C: "Copy", kVK_ANSI_V: "Paste", kVK_ANSI_X: "Cut", kVK_ANSI_Z: "Undo", kVK_ANSI_A: "Select All",
                kVK_ANSI_S: "Save", kVK_ANSI_Q: "Quit", kVK_ANSI_W: "Close", kVK_ANSI_H: "Hide", kVK_ANSI_M: "Minimize",
                kVK_ANSI_N: "New", kVK_ANSI_O: "Open", kVK_ANSI_P: "Print", kVK_ANSI_T: "New Tab", kVK_ANSI_F: "Find",
                kVK_Tab: "the app switcher", kVK_ANSI_Comma: "Settings", kVK_ANSI_Grave: "window cycling"
            ]
            if let n = names[k] { return n.hasPrefix("the") ? n : "\u{201C}\(n)\u{201D}" }
        }
        if f == [.command, .shift], k == kVK_ANSI_Z { return "\u{201C}Redo\u{201D}" }
        if f == [.command, .option], k == kVK_Escape { return "Force Quit" }
        if f == [.control, .command], k == kVK_ANSI_Q { return "Lock Screen" }
        if f == [.control, .command], k == kVK_ANSI_F { return "full screen" }
        if f == [.command, .shift], k == kVK_ANSI_Q { return "Log Out" }
        return nil
    }
}

// MARK: - Registration

/// Registers the user's shortcuts with Carbon (works without Accessibility permission).
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var suspended = false

    func register() {
        installHandler()
        unregisterAll()
        guard !suspended else { return }
        let store = HotkeyStore.shared
        var failed: Set<HotkeyAction> = []
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let combo = store.combo(for: action) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x534E5052), id: UInt32(index))  // 'SNPR'
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeyRefs.append(ref) } else { failed.insert(action) }
        }
        DispatchQueue.main.async { store.unavailable = failed }
    }

    /// While a shortcut is being recorded, global shortcuts must not fire.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        register()
    }

    private func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    fileprivate func handle(id: UInt32) {
        let all = HotkeyAction.allCases
        let index = Int(id)
        guard index >= 0, index < all.count else { return }
        let action = all[index]
        DispatchQueue.main.async {
            MainActor.assumeIsolated { action.perform() }
        }
    }
}

/// C callback: only forwards to the manager.
private func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, let userData else { return status }
    Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().handle(id: hotKeyID.id)
    return noErr
}

// MARK: - Recorder control

/// Click, then press the new shortcut. Esc cancels, Delete clears.
final class ShortcutRecorderView: NSView {
    var action: HotkeyAction = .captureArea
    private var recording = false {
        didSet { needsDisplay = true; recording ? HotkeyManager.shared.suspend() : HotkeyManager.shared.resume() }
    }
    private var heldFlags: NSEvent.ModifierFlags = []
    private var shake = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }

    override func mouseDown(with event: NSEvent) {
        if recording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        recording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        heldFlags = []
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        heldFlags = event.modifierFlags.intersection(KeyCombo.relevant)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(KeyCombo.relevant)
        if flags.isEmpty, event.keyCode == UInt16(kVK_Escape) { window?.makeFirstResponder(nil); return }
        if flags.isEmpty, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            HotkeyStore.shared.set(nil, for: action)
            window?.makeFirstResponder(nil)
            return
        }
        let combo = KeyCombo.make(Int(event.keyCode), flags, KeyCombo.keyName(for: event))
        switch HotkeyStore.shared.set(combo, for: action) {
        case .rejected:
            NSSound.beep()
            shakeField()
        default:
            window?.makeFirstResponder(nil)
        }
    }

    private func shakeField() {
        guard let layer = layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -6, 6, -4, 4, 0]
        anim.duration = 0.3
        layer.add(anim, forKey: "shake")
    }

    override func draw(_ dirtyRect: NSRect) {
        wantsLayer = true
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (recording ? Brand.accent.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? Brand.accent : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()

        let text: String
        let color: NSColor
        let store = HotkeyStore.shared
        if recording {
            var held = ""
            if heldFlags.contains(.control) { held += "⌃" }
            if heldFlags.contains(.option) { held += "⌥" }
            if heldFlags.contains(.shift) { held += "⇧" }
            if heldFlags.contains(.command) { held += "⌘" }
            text = held.isEmpty ? "Type shortcut…" : held
            color = .labelColor
        } else if let c = store.combo(for: action) {
            text = c.display
            color = store.unavailable.contains(action) ? .systemRed : .labelColor
        } else {
            text = "Record Shortcut"
            color = .secondaryLabelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: recording ? .medium : .regular), .foregroundColor: color
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let s = str.size()
        str.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
}

/// SwiftUI wrapper.
struct ShortcutRecorder: NSViewRepresentable {
    let action: HotkeyAction
    @ObservedObject var store = HotkeyStore.shared

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.action = action
        nsView.needsDisplay = true
    }
}
