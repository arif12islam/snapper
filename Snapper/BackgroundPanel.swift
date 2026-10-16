import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// State behind the Background popover. Changes are pushed to `onChange` immediately (live preview).
final class BackgroundModel: ObservableObject {
    @Published var settings: BackgroundSettings {
        didSet { if oldValue != settings { onChange?(settings) } }
    }
    @Published var presets: [BackgroundPreset] = BackgroundPreset.all
    @Published var customImages: [String] = BackgroundCatalog.customImages
    var onChange: ((BackgroundSettings) -> Void)?

    init(settings: BackgroundSettings) {
        self.settings = settings
    }

    /// Turning a background on from "None" starts from sensible values.
    func choose(_ fill: BackgroundSettings.Fill) {
        var s = settings
        if s.isNone, fill != .none {
            let last = BackgroundSettings.lastUsed
            s = last.isNone ? BackgroundSettings.starter : last
        }
        s.fill = fill
        // Big pictures decode in the background first, then the preview switches over.
        let target = s
        BackgroundCatalog.prepare(fill) { [weak self] in self?.settings = target }
    }

    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture to use as a background"
        guard panel.runModal() == .OK, let url = panel.url,
              let name = BackgroundCatalog.importImage(from: url) else { return }
        customImages = BackgroundCatalog.customImages
        choose(.image(name))
    }

    func removeImage(_ name: String) {
        BackgroundCatalog.removeImage(name)
        customImages = BackgroundCatalog.customImages
        if settings.fill == .image(name) { choose(.builtIn(0)) }
    }

    func savePreset() {
        let alert = NSAlert()
        alert.messageText = "Save Background Preset"
        alert.informativeText = "The fill, padding, corners, shadow, alignment and aspect ratio are saved together."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        var list = BackgroundPreset.all
        list.append(BackgroundPreset(name: name.isEmpty ? "Preset \(list.count + 1)" : name, settings: settings))
        BackgroundPreset.all = list
        presets = list
    }

    func deletePreset(_ preset: BackgroundPreset) {
        var list = BackgroundPreset.all
        list.removeAll { $0.id == preset.id }
        BackgroundPreset.all = list
        presets = list
    }
}

struct BackgroundPanelView: View {
    @ObservedObject var model: BackgroundModel

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Background").font(.headline)
                Spacer()
                presetsMenu
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                swatch(.none, help: "No background")
                ForEach(0..<BackgroundCatalog.builtIn.count, id: \.self) { i in
                    swatch(.builtIn(i), help: BackgroundCatalog.builtIn[i].name)
                }
                swatch(.wallpaper, help: "Desktop wallpaper")
                ForEach(model.customImages, id: \.self) { name in
                    swatch(.image(name), help: "Your image")
                        .contextMenu {
                            Button("Remove") { model.removeImage(name) }
                        }
                }
                Button(action: { model.addImage() }) {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.5),
                                                                                  style: StrokeStyle(lineWidth: 1, dash: [3])))
                }
                .buttonStyle(.plain)
                .help("Add your own image")
            }

            HStack(spacing: 8) {
                Text("Plain color").font(.callout).foregroundColor(.secondary)
                ColorPicker("", selection: plainColor, supportsOpacity: false)
                    .labelsHidden()
                Spacer()
            }

            Divider()

            slider("Padding", value: Binding(get: { Double(model.settings.padding) },
                                             set: { model.settings.padding = CGFloat($0) }), range: 0...0.3)
            slider("Corners", value: Binding(get: { Double(model.settings.cornerRadius) },
                                             set: { model.settings.cornerRadius = CGFloat($0) }), range: 0...48)
            slider("Shadow", value: Binding(get: { Double(model.settings.shadow) },
                                            set: { model.settings.shadow = CGFloat($0) }), range: 0...1)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Alignment").font(.callout).foregroundColor(.secondary)
                    alignmentGrid
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aspect ratio").font(.callout).foregroundColor(.secondary)
                    TilePicker(selection: Binding(get: { model.settings.aspect }, set: { model.settings.aspect = $0 }),
                               choices: BackgroundSettings.Aspect.allCases.map { a in
                                   Choice(a, a.rawValue) { AspectArt(ratio: a.ratio) }
                               },
                               tile: CGSize(width: 34, height: 28), columns: 4)
                    Toggle("Auto Balance", isOn: Binding(get: { model.settings.autoBalance },
                                                         set: { model.settings.autoBalance = $0 }))
                        .help("Trims plain margins around the content so the padding looks even")
                }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var plainColor: Binding<Color> {
        Binding(get: {
            if case .color(let hex) = model.settings.fill, let c = NSColor(hex: hex) { return Color(nsColor: c) }
            return .white
        }, set: { newValue in
            model.choose(.color(NSColor(newValue).hexString))
        })
    }

    private func swatch(_ fill: BackgroundSettings.Fill, help: String) -> some View {
        let selected = model.settings.fill == fill
        return Button(action: { model.choose(fill) }) {
            Image(nsImage: BackgroundMaker.thumbnail(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                        .padding(-2)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.callout).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private var alignmentGrid: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { col in
                        let index = row * 3 + col
                        Button(action: { model.settings.alignment = index }) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(model.settings.alignment == index ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 22, height: 15)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .help("Where the screenshot sits when there is extra space (aspect ratio)")
    }

    private var presetsMenu: some View {
        Menu {
            if model.presets.isEmpty {
                Text("No saved presets")
            }
            ForEach(model.presets) { preset in
                Button(preset.name) { model.settings = preset.settings }
            }
            Divider()
            Button("Save Current as Preset…") { model.savePreset() }
            if !model.presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "star")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Hosts the panel in an NSPopover.
@MainActor
final class BackgroundPopover: NSObject, NSPopoverDelegate {
    let model: BackgroundModel
    private let popover = NSPopover()

    init(settings: BackgroundSettings, onChange: @escaping (BackgroundSettings) -> Void) {
        model = BackgroundModel(settings: settings)
        super.init()
        model.onChange = onChange
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BackgroundPanelView(model: model))
        popover.delegate = self
    }

    func toggle(from view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.presets = BackgroundPreset.all
            model.customImages = BackgroundCatalog.customImages
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
    }
}
