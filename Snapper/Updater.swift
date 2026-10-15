import AppKit

/// In-app updates. Snapper looks at a release feed, downloads the newer build, swaps itself in place and relaunches.
///
/// The feed is set in Settings > General > Updates. It can be a GitHub repository ("owner/repo", using its latest
/// release) or a URL returning JSON like {"version": "1.3", "url": "https://.../Snapper-1.3.zip", "notes": "..."}.
/// The download can be a .zip containing Snapper.app (`./build.sh --zip` makes one) or a .dmg.
@MainActor
enum Updater {
    struct Release {
        let version: String
        let notes: String
        let url: URL
    }

    private(set) static var available: Release?
    private static var busy = false
    private static let sourceKey = "updateSource"
    private static let lastCheckKey = "updateLastCheck"

    static var source: String {
        UserDefaults.standard.string(forKey: sourceKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Menu title for the update item.
    static var menuTitle: String {
        if busy { return "Updating…" }
        if let r = available { return "Update to Snapper \(r.version)" }
        return "Check for Updates…"
    }

    /// Menu action: install when one is known, otherwise look for one.
    static func menuAction() {
        if busy { return }
        if let r = available {
            Task { await install(r) }
        } else {
            Task { await check(userInitiated: true) }
        }
    }

    /// Quiet check at launch, at most twice a day, and only when a source is configured.
    static func checkInBackground() {
        guard !source.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 12 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: Checking

    private static func feedURL() -> URL? {
        let s = source
        if s.isEmpty { return nil }
        if s.lowercased().hasPrefix("http") { return URL(string: s) }
        return URL(string: "https://api.github.com/repos/\(s)/releases/latest")
    }

    static func check(userInitiated: Bool) async {
        guard let url = feedURL() else {
            if userInitiated {
                Toast.show("Set an update source in Settings > General first", seconds: 3)
                SettingsWindowController.show(tab: "general")
            }
            return
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        if userInitiated { Toast.show("Checking for updates…") }
        do {
            var request = URLRequest(url: url)
            request.setValue("Snapper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "Updater", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "The update server answered \(http.statusCode)."])
            }
            guard let release = parse(data) else {
                throw NSError(domain: "Updater", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The update feed has no downloadable .zip or .dmg."])
            }
            if isNewer(release.version, than: currentVersion) {
                available = release
                if userInitiated {
                    Toast.show("Version \(release.version) is available. Choose Update from the menu.", seconds: 3.5)
                } else {
                    Toast.show("Snapper \(release.version) is available. Update from the menu bar.", seconds: 3.5)
                }
            } else {
                available = nil
                if userInitiated { Toast.show("Snapper is up to date (\(currentVersion))") }
            }
        } catch {
            if userInitiated { Toast.show("Update check failed: \(error.localizedDescription)", seconds: 4) }
        }
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // GitHub release
        if let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]] {
            let candidates = assets.compactMap { a -> (String, URL)? in
                guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String,
                      let u = URL(string: s) else { return nil }
                return (name.lowercased(), u)
            }
            let pick = candidates.first { $0.0.hasSuffix(".zip") } ?? candidates.first { $0.0.hasSuffix(".dmg") }
            guard let url = pick?.1 else { return nil }
            return Release(version: tag, notes: json["body"] as? String ?? "", url: url)
        }
        // Plain feed
        if let v = json["version"] as? String, let s = json["url"] as? String, let url = URL(string: s) {
            return Release(version: v, notes: json["notes"] as? String ?? "", url: url)
        }
        return nil
    }

    private static func numbers(_ v: String) -> [Int] {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        return s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Unpacks a downloaded .zip or .dmg and returns the Snapper.app inside it.
    nonisolated private static func unpack(_ file: URL, into dir: URL) -> URL? {
        let fm = FileManager.default
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)

        if file.pathExtension.lowercased() == "dmg" {
            let mount = dir.appendingPathComponent("mount", isDirectory: true)
            try? fm.createDirectory(at: mount, withIntermediateDirectories: true)
            guard run("/usr/bin/hdiutil", ["attach", file.path, "-nobrowse", "-readonly", "-noautoopen",
                                           "-mountpoint", mount.path]) == 0 else { return nil }
            defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = findApp(in: mount) else { return nil }
            let copy = out.appendingPathComponent("Snapper.app")
            return run("/usr/bin/ditto", [app.path, copy.path]) == 0 ? copy : nil
        }

        guard run("/usr/bin/ditto", ["-x", "-k", file.path, out.path]) == 0 else { return nil }
        return findApp(in: out)
    }

    nonisolated private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in items where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let app = findApp(in: sub) { return app }
        }
        return nil
    }

    static func install(_ release: Release) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        Toast.show("Downloading Snapper \(release.version)…", seconds: 60)
        do {
            var request = URLRequest(url: release.url)
            request.setValue("Snapper/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (tmp, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "Updater", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Download failed (\(http.statusCode))."])
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("SnapperUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let ext = release.url.pathExtension.lowercased() == "dmg" ? "dmg" : "zip"
            let file = work.appendingPathComponent("update.\(ext)")
            try FileManager.default.moveItem(at: tmp, to: file)

            let newApp = await Task.detached { unpack(file, into: work) }.value
            guard let newApp else {
                throw NSError(domain: "Updater", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The download did not contain Snapper.app."])
            }

            let dest = Bundle.main.bundleURL.path
            let script = work.appendingPathComponent("swap.sh")
            let body = """
            #!/bin/bash
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(dest)"
            /usr/bin/ditto "\(newApp.path)" "\(dest)"
            /usr/bin/xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null
            /usr/bin/open "\(dest)"
            rm -rf "\(work.path)"
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [script.path]
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            Toast.show("Restarting…", seconds: 2)
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            Toast.show("Update failed: \(error.localizedDescription)", seconds: 5)
        }
    }
}
