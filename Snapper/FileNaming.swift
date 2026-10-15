import Foundation

/// Expands the user's file-name template. Tokens: {date} {time} {kind} {width} {height} {counter}
enum FileNamer {
    static func name(kind: String, width: Int, height: Int, date: Date = Date(), ext: String = "png") -> String {
        let d = DateFormatter()
        d.dateFormat = "yyyy-MM-dd"
        let t = DateFormatter()
        t.dateFormat = "HH.mm.ss"

        var template = AppSettings.fileNameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.isEmpty { template = "Snapper {date} at {time}" }

        var counter = 0
        if template.contains("{counter}") {
            counter = UserDefaults.standard.integer(forKey: "fileCounter") + 1
            UserDefaults.standard.set(counter, forKey: "fileCounter")
        }

        var out = template
        let values: [String: String] = [
            "{date}": d.string(from: date),
            "{time}": t.string(from: date),
            "{kind}": kind,
            "{width}": String(width),
            "{height}": String(height),
            "{counter}": String(format: "%03d", counter)
        ]
        for (token, value) in values { out = out.replacingOccurrences(of: token, with: value) }

        // File-system safe.
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|")
        out = out.components(separatedBy: bad).joined(separator: "-")
        if out.isEmpty { out = "Snapper" }
        return "\(out).\(ext)"
    }
}
