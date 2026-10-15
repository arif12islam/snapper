import AppKit

/// Liquid Glass surfaces.
///
/// On macOS 26 (Tahoe) this uses the system's NSGlassEffectView; on earlier versions it falls back to a
/// HUD-style NSVisualEffectView blur with the same shape. The glass class is looked up at runtime, so the app
/// still builds with older Command Line Tools SDKs.
enum Glass {
    static var isLiquidGlass: Bool { NSClassFromString("NSGlassEffectView") != nil }

    /// A rounded glass surface hosting `content` (sized to `content.frame`).
    /// `dark` forces a dark look (HUDs over arbitrary screen content).
    static func surface(_ content: NSView, cornerRadius: CGFloat, dark: Bool = false, tint: NSColor? = nil) -> NSView {
        let frame = content.frame
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]

        if let cls = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
           let glass = cls.init() as? NSView {
            glass.frame = frame
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            if let tint { glass.setValue(tint, forKey: "tintColor") }
            content.frame = NSRect(origin: .zero, size: frame.size)
            glass.setValue(content, forKey: "contentView")
            if dark { glass.appearance = NSAppearance(named: .darkAqua) }
            return glass
        }

        let v = NSVisualEffectView(frame: frame)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        // A mask image (not a layer mask) gives smooth anti-aliased corners and a matching window shadow.
        v.maskImage = roundedMask(cornerRadius)
        if dark { v.appearance = NSAppearance(named: .vibrantDark) }
        content.frame = v.bounds
        v.addSubview(content)
        return v
    }

    /// Stretchable rounded-rect mask for NSVisualEffectView.
    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    /// Glass surface for Auto Layout: the glass sizes itself to `content` (pinned to its edges).
    static func autoLayoutSurface(_ content: NSView, cornerRadius: CGFloat, dark: Bool = false) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let container: NSView
        if let cls = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
           let glass = cls.init() as? NSView {
            glass.setValue(cornerRadius, forKey: "cornerRadius")
            glass.setValue(content, forKey: "contentView")
            if dark { glass.appearance = NSAppearance(named: .darkAqua) }
            container = glass
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .withinWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
            v.layer?.borderWidth = 0.5
            v.layer?.borderColor = NSColor.separatorColor.cgColor
            if dark { v.appearance = NSAppearance(named: .vibrantDark) }
            v.addSubview(content)
            container = v
        }
        container.translatesAutoresizingMaskIntoConstraints = false
        if content.superview == nil { container.addSubview(content) }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    /// A borderless, transparent floating panel whose content is a glass surface.
    static func panel(size: NSSize, cornerRadius: CGFloat, level: NSWindow.Level = .floating,
                      dark: Bool = true, content: NSView) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = level
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.frame = NSRect(origin: .zero, size: size)
        p.contentView = surface(content, cornerRadius: cornerRadius, dark: dark)
        return p
    }
}
