import AppKit
import SwiftUI
import CoreGraphics

@MainActor
final class WelcomePanel: NSObject, NSWindowDelegate {
    private static var current: WelcomePanel?

    private let panel: NSPanel
    private let hostingView: NSHostingView<WelcomeView>
    private var observer: NSObjectProtocol?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
        let welcome = WelcomePanel()
        current = welcome
        welcome.show()
    }

    private override init() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 600),
                        styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        p.title = "Welcome to Snapper"
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.center()

        // Placeholder first: no `self` before super.init().
        let hosting = NSHostingView(rootView: WelcomeView(hasPermission: false, onDone: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 600)
        p.contentView = hosting

        self.panel = p
        self.hostingView = hosting
        super.init()

        p.delegate = self
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        hostingView.rootView = WelcomeView(
            hasPermission: CGPreflightScreenCaptureAccess(),
            onDone: { [weak self] in self?.dismiss() }
        )
    }

    private func dismiss() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        panel.orderOut(nil)
        Self.current = nil
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}

private struct WelcomeView: View {
    let hasPermission: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: Brand.appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)

            Text("Welcome to \(Brand.name)").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(Brand.tagline)
                .foregroundColor(.secondary)

            GroupBox("Screen Recording permission") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: hasPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(hasPermission ? .green : .orange)
                        Text(hasPermission ? "Permission granted" : "Snapper needs Screen Recording access")
                        Spacer()
                    }
                    if !hasPermission {
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Text("After enabling Snapper, quit and reopen it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Keyboard shortcuts") {
                VStack(spacing: 6) {
                    ForEach([HotkeyAction.allInOne, .captureArea, .captureWindow, .captureFullscreen,
                             .recordScreen, .captureText], id: \.self) { action in
                        shortcutRow(action.title, HotkeyStore.shared.combo(for: action)?.display ?? "None")
                    }
                    shortcutRow("Cancel", "Esc")
                }
                .padding(4)
            }

            Spacer(minLength: 0)

            Text("You can change every shortcut in Settings > Shortcuts.")
                .font(.caption).foregroundColor(.secondary)

            Button("Start capturing", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: Brand.accent))
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 460, height: 600)
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(keys).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
        }
    }
}
