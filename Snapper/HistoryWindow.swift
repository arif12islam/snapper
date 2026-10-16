import SwiftUI
import AppKit

/// Capture history: thumbnails filtered by type, with restore, annotate, copy, reveal and delete.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    private static var shared: HistoryWindowController?
    private let window: NSWindow

    static func show() {
        if shared == nil { shared = HistoryWindowController() }
        if let w = shared?.window { AppPresence.present(w) }
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Capture History"
        window.subtitle = Brand.name
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 360)
        super.init()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: HistoryView(store: HistoryStore.shared, ui: HistoryFilterModel()))
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

/// Holds the filter (an ObservableObject instead of @State: the State macro needs Xcode's plugins).
private final class HistoryFilterModel: ObservableObject {
    @Published var filter: HistoryStore.Filter = .all
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var ui: HistoryFilterModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $ui.filter) {
                    ForEach(HistoryStore.Filter.allCases) { f in
                        Label(f.rawValue, systemImage: f.symbol).labelStyle(.iconOnly).help(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                Text("Kept for \(Int(AppSettings.retentionDays)) days")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Clear All…") { confirmClear() }
                    .disabled(store.entries.isEmpty)
            }
            .padding(12)
            Divider()
            let items = store.entries.filter { ui.filter.matches($0) }
            if items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(nsImage: Brand.badge).resizable().frame(width: 56, height: 56).opacity(0.85)
                    Text("Nothing here yet").font(.headline)
                    Text("Your captures and recordings will show up here.").foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { entry in
                            HistoryCell(entry: entry, store: store)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Screenshots kept in history are deleted. Recordings stay where they were saved."
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.deleteAll() }
    }
}

private struct HistoryCell: View {
    let entry: HistoryStore.Entry
    let store: HistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08))
                if let img = store.thumbnail(for: entry) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: entry.isVideo ? "film" : "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
                if entry.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
            }
            .frame(height: 130)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.annotate(entry) }
            .onTapGesture { store.restore(entry) }

            Text(title).font(.caption).bold().lineLimit(1)
            Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
        .help("Click: open in Quick Access. Double-click: \(entry.isVideo ? "open video" : "annotate")")
        .contextMenu {
            Button("Open in Quick Access") { store.restore(entry) }
            Button(entry.isVideo ? "Open Video" : "Annotate") { store.annotate(entry) }
            Button("Copy") { copy() }
            Button("Show in Finder") {
                let url = entry.path.map { URL(fileURLWithPath: $0) } ?? store.fileURL(for: entry)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Delete from History") { store.delete(entry) }
        }
    }

    private var title: String {
        switch entry.kind {
        case "area": return "Area"
        case "window": return "Window"
        case "fullscreen": return "Fullscreen"
        case "scrolling": return "Scrolling"
        case "gif": return "GIF"
        case "recording": return "Recording"
        default: return entry.kind.capitalized
        }
    }

    private var subtitle: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let dims = entry.width > 0 ? "  ·  \(entry.width)×\(entry.height)" : ""
        return f.string(from: entry.date) + dims
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let path = entry.path {
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else if let data = try? Data(contentsOf: store.fileURL(for: entry)) {
            pb.setData(data, forType: .png)
        }
    }
}
