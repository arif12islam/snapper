import AppKit

/// Per-upload link settings. Sent as headers; the bundled server (server/server.js) enforces them.
struct UploadOptions {
    var password = ""
    var expiryHours = 0          // 0 = never
    var burnAfterReading = false // self-destruct after the first view

    static var defaults: UploadOptions {
        var o = UploadOptions()
        o.expiryHours = AppSettings.uploadExpiryHours
        return o
    }

    /// Asks for a password and expiry before uploading (⌥-click Upload).
    @MainActor
    static func ask() -> UploadOptions? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Upload Options"
        alert.informativeText = "The share link will follow these rules."
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        password.placeholderString = "Password (optional)"
        let expiry = NSPopUpButton(frame: .zero, pullsDown: false)
        let choices: [(String, Int)] = [("Never expires", 0), ("1 hour", 1), ("1 day", 24), ("1 week", 168), ("30 days", 720)]
        expiry.addItems(withTitles: choices.map { $0.0 })
        if let i = choices.firstIndex(where: { $0.1 == AppSettings.uploadExpiryHours }) { expiry.selectItem(at: i) }
        let burn = NSButton(checkboxWithTitle: "Delete after the first view", target: nil, action: nil)
        let stack = NSStackView(views: [password, expiry, burn])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 92)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Upload")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = password
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        var o = UploadOptions()
        o.password = password.stringValue
        o.expiryHours = choices[max(0, expiry.indexOfSelectedItem)].1
        o.burnAfterReading = burn.state == .on
        return o
    }
}

/// Uploads a file with HTTP PUT to the configured endpoint and returns a share link.
///
/// Endpoint forms:
///   https://host/upload/{name}   {name} is replaced with the file name
///   https://host/upload          the file name is appended as a path component
/// The link is taken from, in order: a JSON `url` field, a `Location` header, or a plain-text body.
enum Uploader {
    enum UploadError: LocalizedError {
        case notConfigured
        case badEndpoint
        case server(Int, String)
        case noLink

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Set an upload URL in Settings > Cloud first."
            case .badEndpoint: return "The upload URL in Settings is not valid."
            case .server(let code, let body): return "The server answered \(code). \(body)"
            case .noLink: return "The upload worked but the server did not return a link."
            }
        }
    }

    static func upload(data: Data, fileName: String, contentType: String,
                       options: UploadOptions = .defaults) async throws -> URL {
        let endpoint = AppSettings.uploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else { throw UploadError.notConfigured }
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName

        let urlString: String
        if endpoint.contains("{name}") {
            urlString = endpoint.replacingOccurrences(of: "{name}", with: encodedName)
        } else {
            urlString = endpoint.hasSuffix("/") ? endpoint + encodedName : endpoint + "/" + encodedName
        }
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw UploadError.badEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let token = AppSettings.uploadToken
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !options.password.isEmpty { request.setValue(options.password, forHTTPHeaderField: "X-Snapper-Password") }
        if options.expiryHours > 0 { request.setValue(String(options.expiryHours), forHTTPHeaderField: "X-Snapper-Expires-Hours") }
        if options.burnAfterReading { request.setValue("1", forHTTPHeaderField: "X-Snapper-Burn") }
        request.timeoutInterval = 300

        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw UploadError.noLink }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: body.prefix(200), encoding: .utf8) ?? ""
            throw UploadError.server(http.statusCode, text)
        }

        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let link = json["url"] as? String, let result = URL(string: link) {
            return result
        }
        if let location = http.value(forHTTPHeaderField: "Location"), let result = URL(string: location, relativeTo: url)?.absoluteURL {
            return result
        }
        if let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let result = URL(string: text), result.scheme?.hasPrefix("http") == true {
            return result
        }
        throw UploadError.noLink
    }
}
