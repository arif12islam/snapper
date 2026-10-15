import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Annotate editor window.
///
/// Layout:
///   top bar     grouped tools  ·  Background · Drag · Copy · Save
///   style bar   only the controls the current tool or selection uses, plus a short hint
///   canvas      (drop or paste pictures here to combine them)
///   bottom bar  undo · redo · delete  ·  rotate · flip · resize  ·  zoom
///
/// Built entirely in AppKit (no SwiftUI property-wrapper macros, see guide §11.2); the Background
/// popover is SwiftUI.
@MainActor
final class AnnotateWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static var controllers: [ObjectIdentifier: AnnotateWindowController] = [:]

    /// Tool groups shown as separate segmented controls.
    private static let toolLayout: [[AnnotationTool]] = [
        [.select, .crop],
        [.arrow, .line, .rectangle, .ellipse, .pencil, .highlighter],
        [.text, .number],
        [.spotlight, .pixelate, .blur]
    ]

    private enum StyleControl: CaseIterable { case color, stroke, fill, arrow, bubble, text, size, blur, spotlight, angle, crop }

    private static let cropAspects: [(String, CGFloat?)] = [
        ("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3.0), ("3:2", 1.5),
        ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0), ("4:5", 0.8)
    ]

    private let window: NSWindow
    private let canvas: AnnotateCanvas
    private var toolSegments: [NSSegmentedControl] = []
    private var styleGroups: [StyleControl: NSView] = [:]

    private let colorWell = NSColorWell(style: .minimal)
    private let paletteStack = NSStackView()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 28, minValue: 12, maxValue: 96, target: nil, action: nil)
    private let arrowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let textPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bubbleSeg = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Bubble") ?? NSImage(),
        NSImage(systemSymbolName: "textformat", accessibilityDescription: "Plain") ?? NSImage()],
        trackingMode: .selectOne, target: nil, action: nil)
    private let blurPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let spotlightPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cropPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fillCheck = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private let angleSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private let removeCropButton = NSButton(title: "Remove Crop", target: nil, action: nil)

    private let backgroundButton = NSButton()
    private var backgroundPopover: BackgroundPopover?
    private let savePopup = NSPopUpButton(frame: .zero, pullsDown: true)

    private weak var bottomUndo: NSButton?
    private weak var bottomRedo: NSButton?
    private let deleteButton = NSButton()
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var projectURL: URL?

    /// Style remembered per tool (a yellow highlighter stays yellow).
    private var toolStyles: [AnnotationTool: AnnotationStyle] = [:]
    private var lastTool: AnnotationTool = .arrow

    // MARK: - Entry points

    static func open(image: CGImage) {
        let c = AnnotateWindowController(canvas: AnnotateCanvas(image: image), projectURL: nil,
                                         background: BackgroundSettings.lastUsed)
        c.show()
    }

    static func openProject(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let project = try SnapperProject.decode(data)
            guard let rep = NSBitmapImageRep(data: project.imagePNG), let cg = rep.cgImage else {
                throw NSError(domain: "Snapper", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The project's image could not be read."])
            }
            let canvas = AnnotateCanvas(image: cg, objects: project.objects, cropRect: project.cropRect)
            let c = AnnotateWindowController(canvas: canvas, projectURL: url, background: project.resolvedBackground)
            c.show()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    static func openProjectPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "snapper") ?? .json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { openProject(at: url) }
    }

    // MARK: - Init

    private init(canvas: AnnotateCanvas, projectURL: URL?, background: BackgroundSettings) {
        self.canvas = canvas
        self.projectURL = projectURL
        let w = AnnotateNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        w.title = projectURL?.deletingPathExtension().lastPathComponent ?? "Annotate"
        w.subtitle = Brand.name
        w.titleVisibility = .hidden
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 940, height: 520)
        w.tabbingMode = .disallowed
        self.window = w
        super.init()
        w.delegate = self
        w.canvas = canvas
        w.commandHandler = { [weak self] id in self?.menuCommand(id) }
        w.currentToolID = { [weak self] in self?.canvas.tool.rawValue ?? "" }
        toolStyles = Self.loadToolStyles()
        buildUI()

        canvas.background = background
        updateBackgroundButton()

        canvas.onChange = { [weak self] in self?.canvasChanged() }
        canvas.onSelectionStyle = { [weak self] style in self?.load(style: style) }
        canvas.onSelectionRotation = { [weak self] degrees in
            self?.loadRotation(degrees)
            self?.refreshControls()
        }
        canvas.onZoomChange = { [weak self] _ in self?.updateZoomLabel() }
        canvas.onCopyShortcut = { [weak self] in self?.copyAction() }
        canvas.onSaveShortcut = { [weak self] in self?.quickSaveAction() }
        lastTool = canvas.tool
        if let s = toolStyles[canvas.tool] { load(style: s) }
        refreshControls()
    }

    private func show() {
        Self.controllers[ObjectIdentifier(self)] = self
        window.center()
        AppPresence.track(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func windowDidResize(_ notification: Notification) {
        updateZoomLabel()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitTextEditing()
        Self.saveToolStyles(toolStyles)
        Self.controllers[ObjectIdentifier(self)] = nil
    }

    // MARK: - UI helpers

    @discardableResult
    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        iconButton(NSButton(), symbol: symbol, tooltip: tooltip, action: action)
    }

    @discardableResult
    private func iconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) -> NSButton {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.imagePosition = .imageOnly
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func row(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = spacing
        return s
    }

    private func flexibleSpace() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return box
    }

    private func horizontalRule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func smallPopup(_ popup: NSPopUpButton, items: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: items)
        popup.target = self
        popup.action = #selector(styleChanged)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
    }

    // MARK: - Build

    private enum ToolbarID {
        static let background = NSToolbarItem.Identifier("snapper.background")
        static let copy = NSToolbarItem.Identifier("snapper.copy")
        static let save = NSToolbarItem.Identifier("snapper.save")
        static func tools(_ i: Int) -> NSToolbarItem.Identifier { NSToolbarItem.Identifier("snapper.tools.\(i)") }
    }

    /// Toolbar (tools, undo/redo, background, share) + canvas with floating glass bars.
    private func buildUI() {
        buildToolControls()

        let toolbar = NSToolbar(identifier: "SnapperAnnotateToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let styleBar = Glass.autoLayoutSurface(buildStyleBar(), cornerRadius: 17)
        let bottomBar = Glass.autoLayoutSurface(buildBottomBar(), cornerRadius: 19)

        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(styleBar)
        root.addSubview(bottomBar)
        window.contentView = root

        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            styleBar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            centered(styleBar, in: root),
            styleBar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            styleBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            styleBar.heightAnchor.constraint(equalToConstant: 34),

            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            centered(bottomBar, in: root),
            bottomBar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
            bottomBar.heightAnchor.constraint(equalToConstant: 38)
        ])
    }

    private func centered(_ v: NSView, in root: NSView) -> NSLayoutConstraint {
        let c = v.centerXAnchor.constraint(equalTo: root.centerXAnchor)
        c.priority = .defaultHigh
        return c
    }

    private func buildToolControls() {
        for (groupIndex, tools) in Self.toolLayout.enumerated() {
            let images = tools.map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage()
            }
            let seg = NSSegmentedControl(images: images, trackingMode: .selectOne,
                                         target: self, action: #selector(toolSegmentPicked(_:)))
            seg.tag = groupIndex
            seg.segmentStyle = .separated
            for (i, tool) in tools.enumerated() {
                seg.setToolTip("\(tool.title)  \(tool.key.uppercased())", forSegment: i)
                seg.setWidth(30, forSegment: i)
            }
            toolSegments.append(seg)
        }

        backgroundButton.bezelStyle = .texturedRounded
        backgroundButton.title = "Background"
        backgroundButton.imagePosition = .imageLeading
        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundButtonTapped)
        backgroundButton.toolTip = "Background: padding, alignment, aspect ratio, presets"

        savePopup.removeAllItems()
        savePopup.addItem(withTitle: "Save")                    // title item of a pull-down
        savePopup.addItem(withTitle: "Save Image…  ⌘S")
        savePopup.lastItem?.target = self
        savePopup.lastItem?.action = #selector(saveImageAction)
        savePopup.addItem(withTitle: "Save to \(AppSettings.saveFolder.lastPathComponent)")
        savePopup.lastItem?.target = self
        savePopup.lastItem?.action = #selector(quickSaveAction)
        savePopup.addItem(withTitle: "Save Project…")
        savePopup.lastItem?.target = self
        savePopup.lastItem?.action = #selector(saveProjectAction)
        savePopup.lastItem?.toolTip = "Editable .snapper file: annotations stay movable"
        savePopup.bezelStyle = .texturedRounded
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = []
        for i in 0..<Self.toolLayout.count { ids.append(ToolbarID.tools(i)) }
        ids += [.flexibleSpace, ToolbarID.background, ToolbarID.copy, ToolbarID.save]
        return ids
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case ToolbarID.background:
            item.view = backgroundButton
            item.label = "Background"
        case ToolbarID.copy:
            let b = NSButton(title: "Copy", target: self, action: #selector(copyAction))
            b.bezelStyle = .texturedRounded
            b.toolTip = "Copy image (⌘C)"
            item.view = b
            item.label = "Copy"
        case ToolbarID.save:
            item.view = savePopup
            item.label = "Save"
        default:
            let raw = id.rawValue
            guard raw.hasPrefix("snapper.tools."), let i = Int(raw.dropFirst("snapper.tools.".count)),
                  i < toolSegments.count else { return nil }
            item.view = toolSegments[i]
            item.label = "Tools"
        }
        return item
    }

    private func buildStyleBar() -> NSStackView {
        colorWell.color = NSColor(hex: "#FF3B30") ?? .systemRed
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Color"
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let picker = iconButton(symbol: "eyedropper", tooltip: "Pick a color from the screen", action: #selector(pickColorAction))
        paletteStack.orientation = .horizontal
        paletteStack.spacing = 4
        rebuildPalette()

        for slider in [widthSlider, sizeSlider, angleSlider] {
            slider.target = self
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        widthSlider.action = #selector(styleChanged)
        sizeSlider.action = #selector(styleChanged)
        angleSlider.action = #selector(angleChanged)
        angleSlider.isEnabled = false

        smallPopup(arrowPopup, items: AnnotationStyle.arrowStyleNames)
        smallPopup(textPopup, items: AnnotationStyle.textStyleNames)
        smallPopup(blurPopup, items: AnnotationStyle.blurModeNames)
        smallPopup(spotlightPopup, items: AnnotationStyle.spotlightShapeNames)
        blurPopup.toolTip = "Secure blurs a scrambled copy, so nothing can be recovered"
        cropPopup.removeAllItems()
        cropPopup.addItems(withTitles: Self.cropAspects.map { $0.0 })
        cropPopup.target = self
        cropPopup.action = #selector(cropAspectChanged)
        cropPopup.controlSize = .small
        cropPopup.font = .systemFont(ofSize: 11)

        fillCheck.target = self
        fillCheck.action = #selector(styleChanged)
        fillCheck.controlSize = .small
        fillCheck.font = .systemFont(ofSize: 11)

        styleGroups[.color] = row([colorWell, picker, paletteStack], spacing: 6)
        styleGroups[.stroke] = row([label("Stroke"), widthSlider], spacing: 6)
        styleGroups[.fill] = row([fillCheck], spacing: 6)
        styleGroups[.arrow] = row([label("Arrow"), arrowPopup], spacing: 6)
        bubbleSeg.target = self
        bubbleSeg.action = #selector(styleChanged)
        bubbleSeg.controlSize = .small
        bubbleSeg.selectedSegment = 0
        bubbleSeg.setToolTip("Speech bubble", forSegment: 0)
        bubbleSeg.setToolTip("Plain text", forSegment: 1)
        styleGroups[.bubble] = row([label("Box"), bubbleSeg], spacing: 6)
        styleGroups[.text] = row([label("Style"), textPopup], spacing: 6)
        styleGroups[.size] = row([label("Size"), sizeSlider], spacing: 6)
        styleGroups[.blur] = row([label("Blur"), blurPopup], spacing: 6)
        styleGroups[.spotlight] = row([label("Shape"), spotlightPopup], spacing: 6)
        styleGroups[.angle] = row([label("Angle"), angleSlider], spacing: 6)
        styleGroups[.crop] = row([label("Aspect"), cropPopup], spacing: 6)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeCropButton.target = self
        removeCropButton.action = #selector(clearCropAction)
        removeCropButton.bezelStyle = .rounded
        removeCropButton.controlSize = .small
        removeCropButton.font = .systemFont(ofSize: 11)

        let ordered: [StyleControl] = [.crop, .color, .stroke, .fill, .arrow, .bubble, .text, .size, .blur, .spotlight, .angle]
        var views: [NSView] = ordered.compactMap { styleGroups[$0] }
        views += [hintLabel, removeCropButton]
        let bar = row(views, spacing: 16)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        return bar
    }

    private func buildBottomBar() -> NSStackView {
        let undo = iconButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", action: #selector(undoAction))
        let redo = iconButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", action: #selector(redoAction))
        bottomUndo = undo
        bottomRedo = redo
        iconButton(deleteButton, symbol: "trash", tooltip: "Delete selected (⌫)", action: #selector(deleteAction))
        let rotateLeft = iconButton(symbol: "rotate.left", tooltip: "Rotate picture left", action: #selector(rotateLeftAction))
        let rotateRight = iconButton(symbol: "rotate.right", tooltip: "Rotate picture right", action: #selector(rotateRightAction))
        let flipH = iconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                               tooltip: "Flip horizontally", action: #selector(flipHAction))
        let flipV = iconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                               tooltip: "Flip vertically", action: #selector(flipVAction))
        let resize = iconButton(symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                                tooltip: "Resize picture…", action: #selector(resizeAction))
        let addImage = iconButton(symbol: "photo.badge.plus", tooltip: "Add a picture (or drop / paste one onto the canvas)",
                                  action: #selector(addImageAction))

        let zoomOut = iconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom out (⌘−)", action: #selector(zoomOutAction))
        let zoomIn = iconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom in (⌘+)", action: #selector(zoomInAction))
        let fit = iconButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Fit to window (⌘0). ⌘1 = actual size",
                             action: #selector(fitAction))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.toolTip = "Pinch or ⌘-scroll to zoom, scroll to pan"
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let bar = row([undo, redo, deleteButton, divider(),
                       rotateLeft, rotateRight, flipH, flipV, resize, divider(), addImage, divider(),
                       zoomOut, zoomLabel, zoomIn, fit], spacing: 4)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return bar
    }

    // MARK: - Favourite colours

    private static let defaultPalette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE", "#000000", "#FFFFFF"]

    private var palette: [String] {
        get { UserDefaults.standard.stringArray(forKey: "favoriteColors") ?? Self.defaultPalette }
        set { UserDefaults.standard.set(newValue, forKey: "favoriteColors") }
    }

    private func rebuildPalette() {
        for v in paletteStack.arrangedSubviews { paletteStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for hex in palette {
            let b = SwatchButton(hex: hex) { [weak self] in self?.applyColor(hex) }
            b.onRemove = { [weak self] in
                guard let self else { return }
                self.palette = self.palette.filter { $0 != hex }
                self.rebuildPalette()
            }
            paletteStack.addArrangedSubview(b)
        }
        let add = NSButton()
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add color")
        add.isBordered = false
        add.imagePosition = .imageOnly
        add.target = self
        add.action = #selector(addFavoriteColor)
        add.toolTip = "Save the current color to the palette (right-click a swatch to remove it)"
        add.widthAnchor.constraint(equalToConstant: 18).isActive = true
        paletteStack.addArrangedSubview(add)
    }

    private func applyColor(_ hex: String) {
        colorWell.color = NSColor(hex: hex) ?? .systemRed
        styleChanged()
    }

    @objc private func addFavoriteColor() {
        let hex = colorWell.color.hexString
        var list = palette.filter { $0 != hex }
        list.append(hex)
        if list.count > 12 { list.removeFirst(list.count - 12) }
        palette = list
        rebuildPalette()
    }

    @objc private func pickColorAction() {
        NSColorSampler().show { [weak self] color in
            guard let color else { return }
            Task { @MainActor in
                guard let self else { return }
                self.colorWell.color = color
                self.styleChanged()
            }
        }
    }

    // MARK: - Per-tool styles

    private static func loadToolStyles() -> [AnnotationTool: AnnotationStyle] {
        var result: [AnnotationTool: AnnotationStyle] = [:]
        if let data = UserDefaults.standard.data(forKey: "annotateToolStyles"),
           let dict = try? JSONDecoder().decode([String: AnnotationStyle].self, from: data) {
            for (k, v) in dict { if let t = AnnotationTool(rawValue: k) { result[t] = v } }
        }
        if result[.highlighter] == nil {
            var s = AnnotationStyle()
            s.colorHex = "#FFE600"
            s.lineWidth = 5
            result[.highlighter] = s
        }
        return result
    }

    private static func saveToolStyles(_ styles: [AnnotationTool: AnnotationStyle]) {
        var dict: [String: AnnotationStyle] = [:]
        for (k, v) in styles { dict[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: "annotateToolStyles") }
    }

    // MARK: - State sync

    private var activeKind: AnnotationKind? {
        canvas.tool == .select ? canvas.selectedKind : canvas.tool.objectKind
    }

    private func currentStyle() -> AnnotationStyle {
        var s = canvas.style
        s.colorHex = colorWell.color.hexString
        s.lineWidth = CGFloat(widthSlider.doubleValue)
        s.fontSize = CGFloat(sizeSlider.doubleValue)
        s.arrowStyle = max(0, arrowPopup.indexOfSelectedItem)
        s.textStyle = max(0, textPopup.indexOfSelectedItem)
        s.filled = fillCheck.state == .on
        s.bubble = bubbleSeg.selectedSegment != 1
        switch activeKind {
        case .blur?: s.effectMode = max(0, blurPopup.indexOfSelectedItem)
        case .spotlight?: s.effectMode = max(0, spotlightPopup.indexOfSelectedItem)
        default: break
        }
        return s
    }

    private func load(style: AnnotationStyle) {
        colorWell.color = style.color
        widthSlider.doubleValue = Double(style.lineWidth)
        sizeSlider.doubleValue = Double(style.fontSize)
        arrowPopup.selectItem(at: style.arrowStyle)
        textPopup.selectItem(at: style.textStyle)
        bubbleSeg.selectedSegment = style.bubble ? 0 : 1
        blurPopup.selectItem(at: min(style.effectMode, 1))
        spotlightPopup.selectItem(at: min(style.effectMode, 1))
        fillCheck.state = style.filled ? .on : .off
        // Update stored style without re-triggering an edit of the selected object.
        canvas.style = style
    }

    private func canvasChanged() {
        // Swap per-tool styles when the tool changes (from the toolbar or a key).
        if canvas.tool != lastTool {
            if lastTool != .select && lastTool != .crop { toolStyles[lastTool] = canvas.style }
            lastTool = canvas.tool
            if canvas.tool != .select, canvas.tool != .crop, let s = toolStyles[canvas.tool] { load(style: s) }
        }
        refreshControls()
    }

    private func refreshControls() {
        let tool = canvas.tool
        for (i, seg) in toolSegments.enumerated() {
            seg.selectedSegment = Self.toolLayout[i].firstIndex(of: tool) ?? -1
        }
        bottomUndo?.isEnabled = canvas.canUndo
        bottomRedo?.isEnabled = canvas.canRedo
        deleteButton.isEnabled = canvas.selectedKind != nil
        updateStyleBar()
        updateZoomLabel()
    }

    /// Shows only the controls that affect the current tool, or the selected annotation.
    private func updateStyleBar() {
        let tool = canvas.tool
        let kind = activeKind
        func isAny(_ kinds: AnnotationKind...) -> Bool {
            guard let k = kind else { return false }
            return kinds.contains(k)
        }
        let visible: [StyleControl: Bool] = [
            .color: kind != nil && !isAny(.pixelate, .blur, .spotlight, .image),
            .stroke: isAny(.arrow, .line, .rectangle, .ellipse, .pencil, .highlighter),
            .fill: isAny(.rectangle, .ellipse),
            .arrow: isAny(.arrow),
            .bubble: tool == .text,
            .text: isAny(.text) && !(tool == .text && bubbleSeg.selectedSegment != 1),
            .size: isAny(.text, .number, .callout),
            .blur: isAny(.blur),
            .spotlight: isAny(.spotlight),
            .angle: tool == .select && canvas.selectedRotation != nil,
            .crop: tool == .crop
        ]
        for (control, view) in styleGroups { view.isHidden = !(visible[control] ?? false) }

        let hint: String
        switch tool {
        case .select:
            hint = kind == nil ? "Click an annotation to edit it, drag handles to resize, arrow keys to nudge" : ""
        case .crop:
            hint = canvas.cropRect == nil
                ? "Drag to choose the area to keep. Edges snap to the picture"
                : "Drag the corners or move the box. Press Return to see the result"
        case .pixelate, .blur:
            hint = "Drag over anything you want to hide"
        case .spotlight:
            hint = "Drag over what to emphasise; the rest dims"
        case .highlighter:
            hint = "Drag across text: the stroke fits the line height. Shift for a straight line"
        case .number:
            hint = "Click to place 1, 2, 3…"
        case .text:
            hint = bubbleSeg.selectedSegment != 1 ? "Press on what to point at, then drag to place the box" : "Click to type"
        default:
            hint = ""
        }
        hintLabel.stringValue = hint
        hintLabel.isHidden = hint.isEmpty
        removeCropButton.isHidden = !(tool == .crop && canvas.cropRect != nil)
    }

    private func loadRotation(_ degrees: CGFloat?) {
        angleSlider.isEnabled = degrees != nil
        angleSlider.doubleValue = Double(degrees ?? 0)
    }

    private func updateZoomLabel() {
        zoomLabel.stringValue = "\(canvas.zoomPercent)%"
    }

    private func updateBackgroundButton() {
        backgroundButton.image = BackgroundMaker.thumbnail(canvas.background.fill, size: CGSize(width: 22, height: 15))
    }

    // MARK: - Actions

    @objc private func toolSegmentPicked(_ sender: NSSegmentedControl) {
        guard sender.tag >= 0, sender.tag < Self.toolLayout.count else { return }
        let tools = Self.toolLayout[sender.tag]
        let i = sender.selectedSegment
        guard i >= 0, i < tools.count else { return }
        canvas.tool = tools[i]
        window.makeFirstResponder(canvas)
    }

    @objc private func backgroundButtonTapped() {
        if backgroundPopover == nil {
            backgroundPopover = BackgroundPopover(settings: canvas.background) { [weak self] settings in
                guard let self else { return }
                self.canvas.background = settings
                if !settings.isNone { BackgroundSettings.lastUsed = settings }
                self.updateBackgroundButton()
            }
        }
        backgroundPopover?.toggle(from: backgroundButton)
    }

    @objc private func cropAspectChanged() {
        let i = max(0, cropPopup.indexOfSelectedItem)
        var aspect = Self.cropAspects[min(i, Self.cropAspects.count - 1)].1
        if aspect == -1 { aspect = canvas.imageSize.width / max(canvas.imageSize.height, 1) }
        canvas.applyCropAspect(aspect)
        window.makeFirstResponder(canvas)
    }

    @objc private func angleChanged() { canvas.setSelectedRotation(CGFloat(angleSlider.doubleValue)) }
    @objc private func rotateLeftAction() { canvas.rotateImage(clockwise: false) }
    @objc private func rotateRightAction() { canvas.rotateImage(clockwise: true) }
    @objc private func flipHAction() { canvas.flipImage(horizontal: true) }
    @objc private func flipVAction() { canvas.flipImage(horizontal: false) }
    @objc private func zoomInAction() { canvas.zoomIn() }
    @objc private func zoomOutAction() { canvas.zoomOut() }
    @objc private func fitAction() { canvas.fitView() }

    @objc private func styleChanged() { canvas.style = currentStyle() }
    @objc private func undoAction() { canvas.undo() }
    @objc private func redoAction() { canvas.redo() }
    @objc private func deleteAction() { canvas.deleteSelected() }
    @objc private func clearCropAction() { canvas.clearCrop() }

    @objc private func addImageAction() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        canvas.addImage(img)
    }

    @objc private func resizeAction() {
        let size = canvas.imageSize
        let alert = NSAlert()
        alert.messageText = "Resize Picture"
        alert.informativeText = "Currently \(Int(size.width)) × \(Int(size.height)) pixels. Annotations scale with the picture."
        let wField = NSTextField(string: "\(Int(size.width))")
        let hField = NSTextField(string: "\(Int(size.height))")
        let keep = NSButton(checkboxWithTitle: "Keep proportions", target: nil, action: nil)
        keep.state = .on
        for f in [wField, hField] { f.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        let fields = NSStackView(views: [label("Width"), wField, label("Height"), hField])
        fields.orientation = .horizontal
        fields.spacing = 6
        let stack = NSStackView(views: [fields, keep])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var w = CGFloat(Double(wField.stringValue) ?? Double(size.width))
        var h = CGFloat(Double(hField.stringValue) ?? Double(size.height))
        if keep.state == .on {
            if abs(w - size.width) >= abs(h - size.height) {
                h = (w * size.height / size.width).rounded()
            } else {
                w = (h * size.width / size.height).rounded()
            }
        }
        guard w >= 8, h >= 8, w <= 20000, h <= 20000 else { NSSound.beep(); return }
        canvas.resizeImage(to: CGSize(width: w, height: h))
    }

    // MARK: - Export

    private func finalImage() -> CGImage? { canvas.finalImage() }

    private func exportTempFile() -> URL? {
        guard let image = finalImage(), let data = CaptureEngine.pngData(image) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Snapper/Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(FileNamer.name(kind: "Annotated", width: image.width, height: image.height))
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    @objc private func copyAction() {
        guard let image = finalImage(), let data = CaptureEngine.pngData(image) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        Toast.show("Copied")
        if AppSettings.closeAfterCopy {
            canvas.commitTextEditing()
            window.close()
        }
    }

    @objc private func saveImageAction() {
        guard let image = finalImage(), let data = CaptureEngine.pngData(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = AppSettings.saveFolder
        panel.nameFieldStringValue = FileNamer.name(kind: "Annotated", width: image.width, height: image.height)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
    }

    /// Menu bar commands (File, Edit, Draw) arrive here by identifier.
    fileprivate func menuCommand(_ id: String) {
        if id.hasPrefix("tool:") {
            if let t = AnnotationTool(rawValue: String(id.dropFirst(5))) { canvas.tool = t }
            return
        }
        switch id {
        case "copy": copyAction()
        case "save": quickSaveAction()
        case "saveAs": saveImageAction()
        case "saveProject": saveProjectAction()
        case "upload": uploadAction()
        case "pin": if let image = finalImage() { PinPanel.pin(image) }
        case "print": printAction()
        case "addImage": addImageAction()
        case "rotateLeft": rotateLeftAction()
        case "rotateRight": rotateRightAction()
        case "flipH": flipHAction()
        case "flipV": flipVAction()
        case "background": backgroundButtonTapped()
        default: break
        }
    }

    private func uploadAction() {
        guard let image = finalImage(), let payload = CaptureEngine.pngData(image) else { return }
        let name = FileNamer.name(kind: "Annotated", width: image.width, height: image.height)
        Toast.show("Uploading…", seconds: 60)
        Task {
            do {
                let link = try await Uploader.upload(data: payload, fileName: name, contentType: "image/png")
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link.absoluteString, forType: .string)
                Toast.show("Link copied")
            } catch {
                Toast.show(error.localizedDescription, seconds: 5)
            }
        }
    }

    private func printAction() {
        guard let image = finalImage() else { return }
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 540, height: 540 * CGFloat(image.height) / CGFloat(max(image.width, 1))))
        view.image = ns
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared
        info.isHorizontallyCentered = true
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc private func quickSaveAction() {
        guard let image = finalImage(), let data = CaptureEngine.pngData(image) else { return }
        let url = AppSettings.saveFolder.appendingPathComponent(
            FileNamer.name(kind: "Annotated", width: image.width, height: image.height))
        do {
            try FileManager.default.createDirectory(at: AppSettings.saveFolder, withIntermediateDirectories: true)
            try data.write(to: url)
            Toast.show("Saved to \(AppSettings.saveFolder.lastPathComponent)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func saveProjectAction() {
        guard let project = canvas.makeProject() else { return }
        var url = projectURL
        if url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "snapper") ?? .json]
            panel.nameFieldStringValue = "Snapper \(Self.timestamp()).snapper"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let target = url else { return }
        do {
            try project.encoded().write(to: target, options: .atomic)
            projectURL = target
            window.title = target.deletingPathExtension().lastPathComponent
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }
}

// MARK: - Window

/// Routes editing shortcuts to the canvas before any menu can swallow them (⌘Z, ⇧⌘Z, ⌘C, ⌘V, ⌘S, zoom).
/// While a text annotation is being typed, the text field gets them instead.
/// Round colour swatch in the favourites row. Click applies it, right-click offers removal.
final class SwatchButton: NSButton {
    var onRemove: (() -> Void)?
    private let hex: String
    private let handler: () -> Void

    init(hex: String, handler: @escaping () -> Void) {
        self.hex = hex
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        isBordered = false
        title = ""
        target = self
        action = #selector(clicked)
        toolTip = hex
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { handler() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(ovalIn: r)
        (NSColor(hex: hex) ?? .systemRed).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove from Palette", action: #selector(remove), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func remove() { onRemove?() }
}

final class AnnotateNSWindow: NSWindow {
    weak var canvas: AnnotateCanvas?
    var commandHandler: ((String) -> Void)?
    var currentToolID: (() -> String)?

    @objc func snapperCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { commandHandler?(id) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let canvas, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let typing = firstResponder is NSTextView
        guard flags.contains(.command), !typing else { return super.performKeyEquivalent(with: event) }
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (ch, flags) {
        case ("z", [.command]): canvas.undo(); return true
        case ("z", [.command, .shift]), ("y", [.command]): canvas.redo(); return true
        case ("c", [.command]), ("s", [.command]), ("v", [.command]),
             ("=", _), ("+", _), ("-", [.command]), ("0", [.command]), ("1", [.command]):
            canvas.keyDown(with: event)
            return true
        case ("w", [.command]): performClose(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // Menu bar commands (Edit, File, View) reach the editor through the responder chain.
    @objc func undo(_ sender: Any?) { canvas?.undo() }
    @objc func redo(_ sender: Any?) { canvas?.redo() }
    @objc func copy(_ sender: Any?) { canvas?.onCopyShortcut?() }
    @objc func paste(_ sender: Any?) { _ = canvas?.pasteImage() }
    @objc func delete(_ sender: Any?) { canvas?.deleteSelected() }
    @objc func saveDocument(_ sender: Any?) { canvas?.onSaveShortcut?() }
    @objc func snapperZoomIn(_ sender: Any?) { canvas?.zoomIn() }
    @objc func snapperZoomOut(_ sender: Any?) { canvas?.zoomOut() }
    @objc func snapperActualSize(_ sender: Any?) { canvas?.actualSize() }
    @objc func snapperFit(_ sender: Any?) { canvas?.fitView() }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let canvas else { return super.validateMenuItem(item) }
        if item.action == Selector(("snapperCommand:")) {
            if let id = item.representedObject as? String, id.hasPrefix("tool:") {
                item.state = id == "tool:" + (currentToolID?() ?? "") ? .on : .off
            }
            return true
        }
        switch item.action {
        case Selector(("undo:")): return canvas.canUndo
        case Selector(("redo:")): return canvas.canRedo
        case Selector(("delete:")): return canvas.selectedID != nil
        case Selector(("copy:")), Selector(("paste:")), Selector(("saveDocument:")),
             Selector(("snapperZoomIn:")), Selector(("snapperZoomOut:")),
             Selector(("snapperActualSize:")), Selector(("snapperFit:")): return true
        default: return super.validateMenuItem(item)
        }
    }
}
