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
        [.arrow, .line, .rectangle, .pencil, .highlighter],
        [.text, .number, .magnifier],
        [.spotlight, .blur]
    ]

    private enum StyleControl: CaseIterable { case color, stroke, fill, arrow, bubble, text, size, blur, spotlight, angle, crop, shapeKind, smart, zoom }

    static let cropAspects: [(String, CGFloat?)] = [
        ("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3.0), ("3:2", 1.5),
        ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0), ("4:5", 0.8)
    ]

    private let window: NSWindow
    private let canvas: AnnotateCanvas
    private var toolSegments: [ToolGroup] = []
    private var styleGroups: [StyleControl: NSView] = [:]

    private let colorWell = NSColorWell(style: .minimal)
    private let paletteStack = NSStackView()
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 28, minValue: 12, maxValue: 96, target: nil, action: nil)
    private let arrowSeg = NSSegmentedControl()
    private let shapeKindSeg = NSSegmentedControl()
    private let shapeStyleSeg = NSSegmentedControl()
    /// Smart shapes as an icon toggle (lit when on) instead of a worded checkbox.
    private let smartCheck: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Smart shapes") ?? NSImage(),
                         target: nil, action: nil)
        b.setButtonType(.pushOnPushOff)
        b.bezelStyle = .texturedRounded
        return b
    }()
    private let magSlider = NSSlider(value: 2.5, minValue: 1.5, maxValue: 4, target: nil, action: nil)
    private let textPopup = ImageSegments(images: (0..<AnnotationStyle.textStyleNames.count).map { ChoiceArt.textStyle($0) },
                                          tips: AnnotationStyle.textStyleNames)
    private let bubbleSeg = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Bubble") ?? NSImage(),
        NSImage(systemSymbolName: "textformat", accessibilityDescription: "Plain") ?? NSImage()],
        trackingMode: .selectOne, target: nil, action: nil)
    private let blurPopup = ImageSegments(images: [ChoiceArt.blurMode(0), ChoiceArt.blurMode(1)],
                                          tips: ["Smooth blur", "Secure: blurs a scrambled copy, so nothing can be recovered"])
    private let spotlightPopup = ImageSegments(images: [ChoiceArt.spotlight(0), ChoiceArt.spotlight(1)],
                                               tips: AnnotationStyle.spotlightShapeNames)
    private let cropPopup = ImageSegments(images: AnnotateWindowController.cropAspects.map { ChoiceArt.crop($0.1) },
                                          tips: AnnotateWindowController.cropAspects.map { $0.0 })
    private let fillCheck = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private let angleSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")
    private let removeCropButton = NSButton(title: "Remove Crop", target: nil, action: nil)

    private let backgroundButton = NSButton()
    private var backgroundPopover: BackgroundPopover?
    private let savePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let canvasPopup = NSPopUpButton(frame: .zero, pullsDown: true)

    private let historyView = NSStackView()
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
        AppPresence.present(window, focus: canvas)
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        button.contentTintColor = .labelColor
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

    /// A small symbol in place of a word label; the name is its tooltip.
    private func glyph(_ symbol: String, _ tip: String) -> NSView {
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) ?? NSImage())
        v.contentTintColor = .secondaryLabelColor
        v.toolTip = tip
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
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

    private static func symbol(_ name: String, _ weight: NSFont.Weight = .semibold) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: weight)) ?? img
    }

    private func configure(_ seg: NSSegmentedControl, images: [NSImage], tips: [String]) {
        seg.segmentCount = images.count
        seg.trackingMode = .selectOne
        seg.controlSize = .small
        seg.selectedSegmentBezelColor = Brand.accent
        seg.target = self
        seg.action = #selector(styleChanged)
        for (i, img) in images.enumerated() {
            seg.setImage(img, forSegment: i)
            seg.setWidth(30, forSegment: i)
            seg.setToolTip(tips[i], forSegment: i)
        }
        seg.selectedSegment = 0
    }

    private static func arrowSegment(for style: Int) -> Int {
        switch style {
        case 0: return 0
        case 2, 4: return 1
        case 1: return 2
        default: return 3
        }
    }

    private func smallPopup(_ seg: ImageSegments) {
        seg.target = self
        seg.action = #selector(styleChanged)
    }

    // MARK: - Build

    private enum ToolbarID {
        static let background = NSToolbarItem.Identifier("snapper.background")
        static let history = NSToolbarItem.Identifier("snapper.history")
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
            styleBar.heightAnchor.constraint(equalToConstant: 36),

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
            let seg = ToolGroup(images: images, tips: tools.map { "\($0.title)  \($0.key.uppercased())" })
            seg.onPick = { [weak self] i in self?.pickTool(group: groupIndex, index: i) }
            toolSegments.append(seg)
        }

        let undo = iconButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", action: #selector(undoAction))
        let redo = iconButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", action: #selector(redoAction))
        bottomUndo = undo
        bottomRedo = redo
        historyView.orientation = .horizontal
        historyView.spacing = 2
        historyView.addArrangedSubview(undo)
        historyView.addArrangedSubview(redo)

        backgroundButton.bezelStyle = .texturedRounded
        backgroundButton.title = "Background"
        backgroundButton.imagePosition = .imageLeading
        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundButtonTapped)
        backgroundButton.toolTip = "Background: padding, alignment, aspect ratio, presets"

        savePopup.removeAllItems()
        savePopup.addItem(withTitle: "")                        // title item of a pull-down: just the icon
        savePopup.item(at: 0)?.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
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
        savePopup.isBordered = false
        savePopup.toolTip = "Save"
        (savePopup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        savePopup.widthAnchor.constraint(equalToConstant: 30).isActive = true

        backgroundButton.title = ""
        backgroundButton.imagePosition = .imageOnly
        backgroundButton.isBordered = false
        backgroundButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
    }


    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = [ToolbarID.history]
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
        case ToolbarID.history:
            item.view = historyView
            item.label = "Undo"
        case ToolbarID.background:
            item.view = backgroundButton
            item.label = "Background"
        case ToolbarID.copy:
            item.view = iconButton(symbol: "doc.on.doc", tooltip: "Copy image (⌘C)", action: #selector(copyAction))
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
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let picker = iconButton(symbol: "eyedropper", tooltip: "Pick a color from the screen", action: #selector(pickColorAction))
        paletteStack.orientation = .horizontal
        paletteStack.spacing = 4
        rebuildPalette()

        for slider in [widthSlider, sizeSlider, angleSlider] {
            slider.target = self
            slider.controlSize = .small
            slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        // Stroke and text size use a wedge track: thin on the left, thick on the right.
        for slider in [widthSlider, sizeSlider] {
            let cell = WedgeSliderCell()
            cell.minValue = slider.minValue
            cell.maxValue = slider.maxValue
            cell.doubleValue = slider.doubleValue
            cell.isContinuous = true
            slider.cell = cell
            slider.target = self
            slider.action = #selector(styleChanged)
        }
        widthSlider.action = #selector(styleChanged)
        sizeSlider.action = #selector(styleChanged)
        angleSlider.action = #selector(angleChanged)
        angleSlider.isEnabled = false

        configure(arrowSeg, images: [Self.symbol("arrowshape.right"), Self.symbol("arrow.right", .heavy),
                                     Self.symbol("arrow.right", .light), Self.symbol("arrow.left.and.right")],
                  tips: ["Tapered", "Bold", "Thin", "Double-ended"])
        configure(shapeKindSeg, images: [Self.symbol("rectangle"), Self.symbol("circle")], tips: ["Rectangle", "Ellipse"])
        configure(shapeStyleSeg, images: [Self.symbol("app"), Self.symbol("square"), Self.symbol("square.tophalf.filled"),
                                          Self.symbol("square.fill")],
                  tips: ["Rounded outline", "Sharp outline", "Tinted", "Solid"])
        smartCheck.target = self
        smartCheck.action = #selector(styleChanged)
        smartCheck.controlSize = .small
        smartCheck.font = .systemFont(ofSize: 11)
        smartCheck.state = .off
        smartCheck.toolTip = "Turn clean pen strokes into lines, arrows, rectangles and ellipses"
        magSlider.target = self
        magSlider.action = #selector(styleChanged)
        magSlider.controlSize = .small
        magSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        smallPopup(textPopup)
        smallPopup(blurPopup)
        smallPopup(spotlightPopup)
        cropPopup.target = self
        cropPopup.action = #selector(cropAspectChanged)

        fillCheck.target = self
        fillCheck.action = #selector(styleChanged)
        fillCheck.controlSize = .small
        fillCheck.font = .systemFont(ofSize: 11)

        styleGroups[.color] = row([colorWell, picker, paletteStack], spacing: 6)
        styleGroups[.stroke] = row([widthSlider], spacing: 6)
        styleGroups[.shapeKind] = row([shapeKindSeg, shapeStyleSeg], spacing: 8)
        styleGroups[.arrow] = row([arrowSeg], spacing: 6)
        styleGroups[.smart] = row([smartCheck], spacing: 6)
        styleGroups[.zoom] = row([glyph("plus.magnifyingglass", "Zoom"), magSlider], spacing: 6)
        bubbleSeg.target = self
        bubbleSeg.action = #selector(styleChanged)
        bubbleSeg.controlSize = .small
        bubbleSeg.selectedSegment = 0
        bubbleSeg.setToolTip("Speech bubble", forSegment: 0)
        bubbleSeg.setToolTip("Plain text", forSegment: 1)
        styleGroups[.bubble] = row([bubbleSeg], spacing: 6)
        styleGroups[.text] = row([textPopup], spacing: 6)
        styleGroups[.size] = row([sizeSlider], spacing: 6)
        styleGroups[.blur] = row([blurPopup], spacing: 6)
        styleGroups[.spotlight] = row([spotlightPopup], spacing: 6)
        styleGroups[.crop] = row([glyph("aspectratio", "Aspect ratio"), cropPopup], spacing: 6)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        removeCropButton.target = self
        removeCropButton.action = #selector(clearCropAction)
        removeCropButton.bezelStyle = .rounded
        removeCropButton.controlSize = .small
        removeCropButton.font = .systemFont(ofSize: 11)

        let ordered: [StyleControl] = [.crop, .color, .stroke, .shapeKind, .arrow, .smart, .zoom, .bubble, .text, .size, .blur, .spotlight]
        var views: [NSView] = ordered.compactMap { styleGroups[$0] }
        views += [hintLabel, removeCropButton]
        let bar = row(views, spacing: 14)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        return bar
    }

    private func buildBottomBar() -> NSStackView {
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

        canvasPopup.isBordered = false
        canvasPopup.toolTip = "Canvas: let annotations extend past the picture"
        canvasPopup.widthAnchor.constraint(equalToConstant: 52).isActive = true
        rebuildCanvasMenu()

        let zoomOut = iconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom out (⌘−)", action: #selector(zoomOutAction))
        let zoomIn = iconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom in (⌘+)", action: #selector(zoomInAction))
        let fit = iconButton(symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Fit to window (⌘0). ⌘1 = actual size",
                             action: #selector(fitAction))
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.toolTip = "Pinch or ⌘-scroll to zoom, scroll to pan"
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let bar = row([deleteButton, divider(),
                       rotateLeft, rotateRight, flipH, flipV, resize, divider(), addImage, canvasPopup, divider(),
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
            Task { @MainActor [weak self] in
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
        // Alpha defaults: shape recognition off, and Redact starts on its secure mode. Applied once.
        if !UserDefaults.standard.bool(forKey: "alphaDefaultsApplied") {
            for k in result.keys { result[k]?.smartShapes = false }
            result[.blur]?.effectMode = 1
            UserDefaults.standard.set(true, forKey: "alphaDefaultsApplied")
        }
        if result[.blur] == nil {
            var s = AnnotationStyle()
            s.effectMode = 1
            result[.blur] = s
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
        s.arrowStyle = [0, 2, 1, 3][max(0, min(3, arrowSeg.selectedSegment))]
        s.textStyle = max(0, textPopup.indexOfSelectedItem)
        s.shapeStyle = max(0, shapeStyleSeg.selectedSegment)
        if activeKind == .magnifier { s.magRound = shapeKindSeg.selectedSegment == 1 } else { s.ellipse = shapeKindSeg.selectedSegment == 1 }
        s.magnify = CGFloat(magSlider.doubleValue)
        s.smartShapes = smartCheck.state == .on
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
        arrowSeg.selectedSegment = Self.arrowSegment(for: style.arrowStyle)
        shapeKindSeg.selectedSegment = (activeKind == .magnifier ? style.magRound : style.ellipse) ? 1 : 0
        shapeStyleSeg.selectedSegment = max(0, min(3, style.shapeStyle))
        magSlider.doubleValue = Double(style.magnify)
        smartCheck.state = style.smartShapes ? .on : .off
        textPopup.selectItem(at: style.textStyle)
        bubbleSeg.selectedSegment = style.bubble ? 0 : 1
        blurPopup.selectItem(at: min(style.effectMode, 1))
        spotlightPopup.selectItem(at: min(style.effectMode, 1))
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
            .stroke: isAny(.arrow, .line, .rectangle, .ellipse, .pencil, .highlighter, .magnifier),
            .shapeKind: isAny(.rectangle, .ellipse, .magnifier),
            .smart: isAny(.pencil),
            .zoom: isAny(.magnifier),
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

        // The bar stays the same compact size for every tool; only cropping needs a word of guidance.
        let hint = tool == .crop ? (canvas.cropRect == nil ? "Drag to crop" : "Return to apply") : ""
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

    private func pickTool(group: Int, index: Int) {
        guard group >= 0, group < Self.toolLayout.count else { return }
        let tools = Self.toolLayout[group]
        guard index >= 0, index < tools.count else { return }
        canvas.tool = tools[index]
        window.makeFirstResponder(canvas)
    }

    private func rebuildCanvasMenu() {
        canvasPopup.removeAllItems()
        canvasPopup.addItem(withTitle: "")
        canvasPopup.item(at: 0)?.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right.square", accessibilityDescription: "Canvas")
        let extend = NSMenuItem(title: "Extend canvas for annotations", action: #selector(toggleExtendCanvas), keyEquivalent: "")
        extend.target = self
        extend.state = canvas.extendCanvas ? .on : .off
        let transparent = NSMenuItem(title: "Added area: transparent", action: #selector(setTransparentFill), keyEquivalent: "")
        transparent.target = self
        transparent.state = canvas.extendFillWhite ? .off : .on
        let white = NSMenuItem(title: "Added area: white", action: #selector(setWhiteFill), keyEquivalent: "")
        white.target = self
        white.state = canvas.extendFillWhite ? .on : .off
        canvasPopup.menu?.addItem(extend)
        canvasPopup.menu?.addItem(transparent)
        canvasPopup.menu?.addItem(white)
    }

    @objc private func toggleExtendCanvas() {
        canvas.extendCanvas.toggle()
        rebuildCanvasMenu()
        Toast.show(canvas.extendCanvas ? "Canvas grows to fit annotations" : "Annotations stay inside the picture")
    }

    @objc private func setTransparentFill() { canvas.extendFillWhite = false; rebuildCanvasMenu() }
    @objc private func setWhiteFill() { canvas.extendFillWhite = true; rebuildCanvasMenu() }

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


/// A row of icon buttons for one group of tools: no dividers, the active tool gets a soft highlight.
final class ToolGroup: NSStackView {
    var onPick: ((Int) -> Void)?
    private var buttons: [NSButton] = []

    var selectedSegment: Int = -1 {
        didSet {
            for (i, b) in buttons.enumerated() {
                let on = i == selectedSegment
                b.layer?.backgroundColor = on ? Brand.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
                b.contentTintColor = on ? Brand.accent : .labelColor
            }
        }
    }

    init(images: [NSImage], tips: [String]) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        for (i, image) in images.enumerated() {
            let b = NSButton()
            b.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)) ?? image
            b.contentTintColor = .labelColor
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.toolTip = tips[i]
            b.tag = i
            b.target = self
            b.action = #selector(tapped(_:))
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.cornerCurve = .continuous
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            buttons.append(b)
            addArrangedSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func tapped(_ sender: NSButton) { onPick?(sender.tag) }
}


// MARK: - Wedge slider

/// Slider track drawn as a wedge, so the control itself shows that the value is a thickness.
final class WedgeSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let r = rect.insetBy(dx: 2, dy: 0)
        let midY = r.midY
        let thin: CGFloat = 1.2, thick: CGFloat = 6
        func wedge(to x: CGFloat) -> NSBezierPath {
            let k = (x - r.minX) / max(r.width, 1)
            let h = thin + (thick - thin) * k
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: midY - thin / 2))
            p.line(to: NSPoint(x: x, y: midY - h / 2))
            p.line(to: NSPoint(x: x, y: midY + h / 2))
            p.line(to: NSPoint(x: r.minX, y: midY + thin / 2))
            p.close()
            return p
        }
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        wedge(to: r.maxX).fill()
        let span = maxValue - minValue
        let fraction = span > 0 ? (doubleValue - minValue) / span : 0
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        wedge(to: r.minX + r.width * CGFloat(fraction)).fill()
    }
}
