import AppKit
import SwiftUI
import CoreGraphics

/// Three-step first-run guide: what Snapper does, the Screen Recording permission, and the shortcuts.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var step = 0
    @Published var hasPermission = CGPreflightScreenCaptureAccess()
    let lastStep = 2
}

@MainActor
final class WelcomePanel: NSObject, NSWindowDelegate {
    private static var current: WelcomePanel?

    private let panel: NSPanel
    private let model = WelcomeModel()
    private var observer: NSObjectProtocol?
    private var poll: Timer?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        if let existing = current {
            existing.show()
            return
        }
        let welcome = WelcomePanel()
        current = welcome
        welcome.show()
    }

    /// Opens the guide at the permission step, whether or not first-run onboarding was finished.
    static func showPermissionStep() {
        let welcome: WelcomePanel
        if let existing = current {
            welcome = existing
        } else {
            welcome = WelcomePanel()
            current = welcome
        }
        welcome.model.step = 1
        welcome.model.hasPermission = CGPreflightScreenCaptureAccess()
        welcome.show()
    }

    private override init() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                        styleMask: [.titled, .closable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.center()
        self.panel = p
        super.init()

        p.delegate = self
        let hosting = NSHostingView(rootView: WelcomeView(model: model, onDone: { [weak self] in self?.dismiss() }))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        p.contentView = hosting

        // Check once a second while the guide is open, so the step turns green the moment access is granted.
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = CGPreflightScreenCaptureAccess()
                if self.model.hasPermission != granted { self.model.hasPermission = granted }
            }
        }

        // Coming back from System Settings: re-check the permission.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.hasPermission = CGPreflightScreenCaptureAccess()
            }
        }
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        poll?.invalidate()
        poll = nil
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        panel.orderOut(nil)
        Self.current = nil
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}

// MARK: - Views

private struct WelcomeView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @ObservedObject var model: WelcomeModel
    let onDone: () -> Void

    private var accent: Color { Color(nsColor: Brand.accent) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case 0: intro
                case 1: permission
                default: ready
                }
            }
            .id(model.step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 28)

            footer
        }
        .frame(width: 520, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }

    // MARK: Steps

    private var intro: some View {
        VStack(spacing: 14) {
            Image(nsImage: Brand.appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Text("Welcome to \(Brand.name)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(Brand.tagline)
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 18) {
                feature("viewfinder", "Capture",
                        "Grab an area, a window, the whole screen or a scrolling page. Pull text out of any image.")
                feature("pencil.tip.crop.circle", "Annotate",
                        "Arrows, shapes, text, a magnifier, blur and backgrounds, all editable until you export.")
                feature("record.circle", "Record and edit",
                        "Record the screen or a GIF, trim it, add smart zoom, and pin shots to your screen.")
            }
            .padding(.top, 14)
            .padding(.horizontal, 52)
        }
    }

    private var permission: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(accent.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: model.hasPermission ? "checkmark.shield.fill" : "rectangle.dashed.badge.record")
                    .font(.system(size: 40))
                    .foregroundColor(model.hasPermission ? .green : accent)
            }
            Text(model.hasPermission ? "Screen recording is on" : "Allow screen recording")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("macOS asks apps for permission before they can see the screen. "
                 + "Snapper only looks when you capture or record, and nothing leaves your Mac.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 56)

            if model.hasPermission {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .padding(.top, 6)
            } else {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .padding(.top, 6)
                Text("Turn on Snapper under Screen & System Audio Recording, then quit and reopen Snapper.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 64)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.system(size: 38))
                .foregroundColor(accent)
            Text("You're all set")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Snapper lives in your menu bar. Click its icon for every command, or use a shortcut.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 56)

            VStack(spacing: 0) {
                let actions: [HotkeyAction] = [.allInOne, .captureArea, .captureWindow, .captureFullscreen, .recordScreen, .captureText]
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        if let combo = HotkeyStore.shared.combo(for: action) {
                            Keycaps(text: combo.display)
                        } else {
                            Text("Not set").foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    if index < actions.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .padding(.horizontal, 48)
            .padding(.top, 6)

            Toggle("Open Snapper when I log in", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .padding(.horizontal, 62)
                .padding(.top, 4)
                .onChange(of: launchAtLogin) { _, on in
                    LaunchAtLogin.apply(on)
                    LaunchAtLogin.syncPreference()
                }

            Text("Change any shortcut in Settings, Shortcuts. Esc cancels a capture.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.step > 0 {
                Button("Back") { model.step -= 1 }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .leading)
            } else {
                Color.clear.frame(width: 90, height: 1)
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(0...model.lastStep, id: \.self) { i in
                    Circle()
                        .fill(i == model.step ? accent : Color.primary.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(primaryTitle) {
                if model.step >= model.lastStep { onDone() } else { model.step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var primaryTitle: String {
        switch model.step {
        case 0: return "Continue"
        case 1: return model.hasPermission ? "Continue" : "Skip for now"
        default: return "Start capturing"
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundColor(accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A shortcut drawn as little keys.
private struct Keycaps: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            }
        }
    }
}
