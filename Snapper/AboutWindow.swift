import AppKit
import SwiftUI

/// "About Snapper": icon, name, version, tagline.
@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {
    private static var shared: AboutWindow?
    private let window: NSWindow

    static func show() {
        if shared == nil { shared = AboutWindow() }
        if let w = shared?.window { AppPresence.track(w) }
        shared?.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        let host = NSHostingView(rootView: AboutView())
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 380)
        let effect = NSVisualEffectView(frame: host.frame)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        window.contentView = effect
        window.center()
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: Brand.appIcon)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            Text(Brand.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(Brand.tagline)
                .foregroundColor(.secondary)
            Text(Brand.version)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(Brand.credit)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: Brand.accent))
            Spacer().frame(height: 6)
            HStack(spacing: 10) {
                Button("Settings…") {
                    SettingsWindowController.show()
                }
                Button("Capture History") {
                    Task { @MainActor in HistoryWindowController.show() }
                }
            }
            .controlSize(.regular)
        }
        .padding(28)
        .frame(width: 340, height: 380)
        .tint(Color(nsColor: Brand.accent))
    }
}
