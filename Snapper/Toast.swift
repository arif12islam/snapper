import AppKit
import QuartzCore

/// Small transient message near the bottom of the screen: a compact near-black capsule with a small icon,
/// readable on any wallpaper, in light or dark mode. The icon is picked from the wording (copied, saved,
/// failed, "…" for work in progress), or passed explicitly.
@MainActor
enum Toast {
    enum Kind { case success, info, progress, warning, error }

    private static var current: NSPanel?

    private static func style(for message: String, kind: Kind?, symbol: String?) -> (Kind, String) {
        let m = message.lowercased()
        var k: Kind = .info
        var sym = "info.circle"
        if m.contains("failed") || m.contains("could not") || m.contains("couldn\u{2019}t") || m.contains("error") || m.contains("can't") {
            (k, sym) = (.error, "exclamationmark.circle.fill")
        } else if message.hasSuffix("\u{2026}") || message.hasSuffix("...") {
            (k, sym) = (.progress, "")
        } else if m.hasPrefix("no ") || m.contains("moved or deleted") {
            (k, sym) = (.warning, "exclamationmark.triangle.fill")
        } else if m.contains("link copied") {
            (k, sym) = (.success, "link")
        } else if m.contains("copied") {
            (k, sym) = (.success, "doc.on.doc")
        } else if m.contains("saved") {
            (k, sym) = (.success, "checkmark.circle.fill")
        } else if m.contains("up to date") || m.contains("ready") {
            (k, sym) = (.success, "checkmark.circle.fill")
        } else if m.contains("available") {
            (k, sym) = (.info, "arrow.down.circle")
        } else if m.contains("locked") {
            (k, sym) = (.info, "lock")
        }
        if let kind { k = kind; if symbol == nil, k == .progress { sym = "" } }
        if let symbol { sym = symbol }
        return (k, sym)
    }

    private static func tint(_ kind: Kind) -> NSColor {
        switch kind {
        case .success: return NSColor(srgbRed: 0.30, green: 0.85, blue: 0.47, alpha: 1)
        case .error:   return NSColor(srgbRed: 1.00, green: 0.42, blue: 0.40, alpha: 1)
        case .warning: return NSColor(srgbRed: 1.00, green: 0.76, blue: 0.30, alpha: 1)
        case .info, .progress: return NSColor.white.withAlphaComponent(0.85)
        }
    }

    static func show(_ message: String, on screen: NSScreen? = nil, seconds: Double = 2.2,
                     kind: Kind? = nil, symbol: String? = nil) {
        guard let target = screen ?? NSScreen.main else { return }
        current?.orderOut(nil)
        let (k, sym) = style(for: message, kind: kind, symbol: symbol)

        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        let maxText = min(420, target.visibleFrame.width - 140)
        let measured = NSAttributedString(string: message, attributes: [.font: font])
            .boundingRect(with: NSSize(width: maxText, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let single = measured.height <= lineH * 1.5
        let textW = single ? min(ceil(measured.width) + 4, maxText) : maxText
        let textH = single ? lineH : lineH * 2
        let icon: CGFloat = 16, lead: CGFloat = 14, gap: CGFloat = 8, trail: CGFloat = 16
        let height = single ? 36 : textH + 20
        let size = NSSize(width: lead + icon + gap + textW + trail, height: height)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let layer = root.layer!
        layer.cornerRadius = single ? height / 2 : 16
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.92).cgColor
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let iconFrame = NSRect(x: lead, y: (height - icon) / 2, width: icon, height: icon)
        if k == .progress {
            let spinner = NSProgressIndicator(frame: iconFrame)
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.appearance = NSAppearance(named: .darkAqua)
            spinner.startAnimation(nil)
            root.addSubview(spinner)
        } else {
            let view = NSImageView(frame: iconFrame)
            view.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            view.contentTintColor = tint(k)
            view.imageScaling = .scaleNone
            root.addSubview(view)
        }

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = font
        label.textColor = NSColor.white.withAlphaComponent(0.95)
        label.isSelectable = false
        label.maximumNumberOfLines = single ? 1 : 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(x: lead + icon + gap, y: (height - textH) / 2, width: textW, height: textH)
        root.addSubview(label)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = root
        let vf = target.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 48))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -8
        rise.toValue = 0
        rise.mass = 1
        rise.stiffness = 300
        rise.damping = 26
        rise.duration = rise.settlingDuration
        layer.add(rise, forKey: "rise")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { dismiss(panel) }
    }

    private static func dismiss(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                if current === panel { current = nil }
            }
        })
    }
}
