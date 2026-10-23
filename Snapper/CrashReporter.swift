import AppKit
import SwiftUI

/// Opt-in anonymous crash and error reports.
///
/// Crashes and a few failures (recording, GIF export, updates) are written as small JSON reports to
/// ~/Library/Logs/Snapper/Reports on this Mac. They are only sent when Settings > General > Privacy >
/// "Send anonymous crash and error reports" is on (off by default). A report holds the Snapper and macOS
/// versions, the Mac model, what failed and, for a crash, the call stack. Never captures, file names,
/// window titles or anything typed; paths inside the home folder are shortened to "~".
/// Settings > View What's Sent shows every report, waiting or sent.
enum CrashReporter {
    struct Report: Codable, Identifiable {
        var id: String
        var kind: String          // "crash" or "error"
        var time: String
        var app: String
        var macOS: String
        var model: String
        var arch: String
        var summary: String
        var details: String
    }

    /// The settings toggle. Off unless the person turns it on.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "sendCrashReports") }

    /// Where reports go: the "reportURL" default when set (defaults write com.example.snapper reportURL …),
    /// otherwise SnapperReportURL from Info.plist (set in build.sh).
    static var endpoint: URL? {
        let s = UserDefaults.standard.string(forKey: "reportURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "SnapperReportURL") as? String ?? ""
        return s.isEmpty ? nil : URL(string: s)
    }

    private static let queue = DispatchQueue(label: "Snapper.CrashReporter")
    private static let keep = 20
    private static let lastRunKey = "reportLastRunVersion"

    static let folder: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Snapper/Reports", isDirectory: true)
    private static var pendingDir: URL { folder.appendingPathComponent("pending", isDirectory: true) }
    private static var sentDir: URL { folder.appendingPathComponent("sent", isDirectory: true) }
    /// Written by the crash handlers; turned into a report at the next launch.
    private static var crashFile: URL { folder.appendingPathComponent("last-crash.txt") }

    // MARK: Start

    /// At launch: turn a crash from the last run into a report, arm the crash handlers, send what is waiting.
    static func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sentDir, withIntermediateDirectories: true)

        if let text = try? String(contentsOf: crashFile, encoding: .utf8), !text.isEmpty {
            let when = (try? fm.attributesOfItem(atPath: crashFile.path)[.modificationDate] as? Date) ?? Date()
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            // The crash happened in the previous run, which may have been an older version.
            save(make(kind: "crash", summary: lines.first ?? "Crash", details: lines.dropFirst().joined(separator: "\n"),
                      time: when, app: UserDefaults.standard.string(forKey: lastRunKey)))
        }
        UserDefaults.standard.set(appVersion, forKey: lastRunKey)
        armCrashHandlers()

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { sendPending() }
    }

    /// Records a failure worth knowing about. `context` says what was being done, e.g. "Recording".
    static func record(_ context: String, error: Error) {
        let e = error as NSError
        var details = "\(e.domain) \(e.code)"
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { details += "\nUnderlying: \(under.domain) \(under.code)" }
        record(context, message: e.localizedDescription, details: details)
    }

    static func record(_ context: String, message: String, details: String = "") {
        save(make(kind: "error", summary: "\(context): \(message)", details: details, time: Date(), app: nil))
        DispatchQueue.main.async { sendPending() }
    }

    // MARK: Reports

    private static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Shortens paths in the home folder to "~" so a report never carries the account name.
    private static func scrub(_ s: String) -> String {
        let home = NSHomeDirectory()
        var out = s.replacingOccurrences(of: home, with: "~")
        out = out.replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
        return String(out.prefix(16_000))
    }

    private static func make(kind: String, summary: String, details: String, time: Date, app: String?) -> Report {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Report(id: UUID().uuidString, kind: kind, time: ISO8601DateFormatter().string(from: time),
                      app: app ?? appVersion, macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                      model: sysctl("hw.model"), arch: arch,
                      summary: scrub(summary), details: scrub(details))
    }

    /// What a report from this Mac looks like, for View What's Sent when there are none yet.
    static func example() -> Report {
        make(kind: "error", summary: "Recording: The operation couldn’t be completed.",
             details: "com.apple.ScreenCaptureKit.SCStreamErrorDomain -3801", time: Date(), app: nil)
    }

    static func json(_ report: Report) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func save(_ report: Report) {
        queue.async {
            guard let data = try? JSONEncoder().encode(report) else { return }
            try? data.write(to: pendingDir.appendingPathComponent("\(report.id).json"))
            trim(pendingDir)
        }
    }

    private static func files(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "json" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    /// Keeps only the newest reports in a folder.
    private static func trim(_ dir: URL) {
        let all = files(in: dir)
        for f in all.dropLast(keep) { try? FileManager.default.removeItem(at: f) }
    }

    private static func load(_ dir: URL) -> [Report] {
        files(in: dir).compactMap { try? JSONDecoder().decode(Report.self, from: Data(contentsOf: $0)) }
    }

    /// Reports for View What's Sent, newest first.
    static func all() -> (pending: [Report], sent: [Report]) {
        queue.sync { (Array(load(pendingDir).reversed()), Array(load(sentDir).reversed())) }
    }

    static func deleteAll() {
        queue.sync {
            for dir in [pendingDir, sentDir] {
                for f in files(in: dir) { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    // MARK: Sending

    private static var sending = false

    /// Sends waiting reports, oldest first, when reporting is on. A report that was sent moves to "sent".
    static func sendPending() {
        guard enabled, !sending, let url = endpoint else { return }
        sending = true
        Task.detached {
            let waiting = queue.sync { files(in: pendingDir) }
            for file in waiting.prefix(10) {
                guard let body = try? Data(contentsOf: file) else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Snapper/\(appVersion)", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 20
                request.httpBody = body
                guard let result = try? await URLSession.shared.data(for: request),
                      let http = result.1 as? HTTPURLResponse else { break }
                if (200..<300).contains(http.statusCode) || http.statusCode == 400 || http.statusCode == 413 {
                    // Sent, or refused for good: either way it should not be retried.
                    queue.sync {
                        let dest = sentDir.appendingPathComponent(file.lastPathComponent)
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.moveItem(at: file, to: dest)
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
                        trim(sentDir)
                    }
                } else {
                    break
                }
            }
            await MainActor.run { sending = false }
        }
    }

    // MARK: Crash handlers

    private static func armCrashHandlers() {
        crashFD = open(crashFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        _ = frames  // allocate now, never inside a signal handler
        NSSetUncaughtExceptionHandler { exception in
            var text = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
            text += exception.callStackSymbols.joined(separator: "\n")
            if crashFD >= 0 {
                _ = text.withCString { write(crashFD, $0, strlen($0)) }
            }
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }
}

// Signal handling may only touch memory that already exists, so these live outside the enum.
private var crashFD: Int32 = -1
private let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

private func crashSignalHandler(_ sig: Int32) {
    if crashFD >= 0 {
        let name: StaticString
        switch sig {
        case SIGSEGV: name = "Crash: SIGSEGV (bad memory access)\n"
        case SIGBUS: name = "Crash: SIGBUS (bad memory access)\n"
        case SIGILL: name = "Crash: SIGILL (Swift runtime trap)\n"
        case SIGABRT: name = "Crash: SIGABRT (abort)\n"
        case SIGFPE: name = "Crash: SIGFPE (arithmetic error)\n"
        case SIGTRAP: name = "Crash: SIGTRAP (Swift runtime trap)\n"
        default: name = "Crash: signal\n"
        }
        _ = write(crashFD, name.utf8Start, name.utf8CodeUnitCount)
        let count = backtrace(frames, 128)
        backtrace_symbols_fd(frames, count, crashFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// Settings > General > Privacy > View What's Sent.
struct ReportsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pending: [CrashReporter.Report] = []
    @State private var sent: [CrashReporter.Report] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crash and error reports").font(.title3.bold())
            Text("This is everything Snapper sends, exactly as sent. Reports stay on this Mac and are only sent while "
                 + "“Send anonymous crash and error reports” is on. They never include your captures, file names or anything you type.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if pending.isEmpty && sent.isEmpty {
                        Text("No reports yet. A report from this Mac would look like this:").font(.headline)
                        card(CrashReporter.example(), status: "Example")
                    }
                    ForEach(pending) { card($0, status: CrashReporter.enabled ? "Waiting to send" : "Not sent (reporting is off)") }
                    ForEach(sent) { card($0, status: "Sent") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([CrashReporter.folder]) }
                Button("Delete All") { CrashReporter.deleteAll(); reload() }
                    .disabled(pending.isEmpty && sent.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        (pending, sent) = CrashReporter.all()
    }

    private func card(_ r: CrashReporter.Report, status: String) -> some View {
        GroupBox {
            Text(CrashReporter.json(r))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(r.kind == "crash" ? "Crash" : "Error").bold()
                Text(status).foregroundColor(.secondary)
            }
        }
    }
}
