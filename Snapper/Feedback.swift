import AppKit
import SwiftUI
import ApplicationServices

/// "Send Feedback": a short note plus optional diagnostics (versions, permissions and the tail of Snapper's logs),
/// delivered as a prefilled email to the Snapper inbox. Nothing is sent without the person pressing Send in Mail.
enum Feedback {
    static let address = "snapper@bykorp.com"

    private static var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// The diagnostics text: app and system versions, permission states and recent log lines.
    static func diagnostics() -> String {
        var lines: [String] = []
        lines.append("Snapper \(versionText)")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Mac \(sysctl("hw.model") ?? "unknown"), \(sysctl("machdep.cpu.brand_string") ?? "unknown CPU")")
        lines.append("Screen Recording: \(CGPreflightScreenCaptureAccess() ? "on" : "off")")
        lines.append("Accessibility: \(AXIsProcessTrusted() ? "on" : "off")")
        lines.append("Displays: \(NSScreen.screens.count)")
        lines.append("Language: \(Locale.preferredLanguages.first ?? "unknown")")
        lines.append("")
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Snapper", isDirectory: true)
        let logs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for log in logs.filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            lines.append("===== \(log.lastPathComponent) (last 200 lines) =====")
            if let text = try? String(contentsOf: log, encoding: .utf8) {
                lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: false).suffix(200).map(String.init))
            } else {
                lines.append("(could not be read)")
            }
            lines.append("")
        }
        if logs.isEmpty { lines.append("No logs yet.") }
        return lines.joined(separator: "\n")
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Writes diagnostics.txt into a fresh folder and zips it. Returns the zip, or nil if that failed.
    private static func makeDiagnosticsZip() -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SnapperFeedback-\(UUID().uuidString)", isDirectory: true)
        let folder = dir.appendingPathComponent("Snapper diagnostics", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try diagnostics().write(to: folder.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        } catch { return nil }
        let zip = dir.appendingPathComponent("Snapper diagnostics.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 && fm.fileExists(atPath: zip.path) ? zip : nil
    }

    /// Opens a prefilled email in the person's mail app. Falls back to a mailto link and Finder if there is none.
    @MainActor
    static func send(message: String, includeDiagnostics: Bool) {
        let subject = "Snapper \(versionText) feedback"
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var items: [Any] = [body.isEmpty ? "(write your feedback here)" : body]
        var zip: URL?
        if includeDiagnostics {
            zip = makeDiagnosticsZip()
            if let zip { items.append(zip) }
        }

        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [address]
            service.subject = subject
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                return
            }
        }
        // No mail account set up: open a plain mailto and show the attachment so it can be added by hand.
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = address
        comps.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        if let zip { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
        Toast.show(zip == nil ? "Opening your mail app…" : "Attach the highlighted file to the email.", seconds: 5)
    }
}

@MainActor
final class FeedbackWindow: NSObject, NSWindowDelegate {
    private static var shared: FeedbackWindow?
    private let window: NSWindow

    static func show() {
        if shared == nil { shared = FeedbackWindow() }
        if let w = shared?.window { AppPresence.present(w) }
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Send Feedback"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        let host = NSHostingView(rootView: FeedbackView(onClose: { [weak self] in self?.window.close() }))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 360)
        window.contentView = host
        window.center()
    }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct FeedbackView: View {
    let onClose: () -> Void
    @State private var message = ""
    @State private var includeDiagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What happened, or what would you change?")
                .font(.system(size: 15, weight: .semibold))
            TextEditor(text: $message)
                .font(.system(size: 13))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            Toggle("Include diagnostics", isOn: $includeDiagnostics)
                .help("App and macOS versions, permission states and the last lines of Snapper's logs. No screenshots or recordings.")
            Text("Opens an email to \(Feedback.address) that you review and send yourself.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Write Email") {
                    Feedback.send(message: message, includeDiagnostics: includeDiagnostics)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440, height: 360)
        .tint(Color(nsColor: Brand.accent))
    }
}
