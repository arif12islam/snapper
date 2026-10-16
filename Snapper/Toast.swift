import AppKit
import QuartzCore

/// Small transient message near the bottom of the screen: a deep navy capsule with a coloured icon badge,
/// a springy entrance and a hairline that counts down the time left. The icon and colour are picked from the
/// wording (copied, saved, failed, "…" for work in progress), or passed explicitly.
@MainActor
enum Toast {
    enum Kind { case success, info, progress, warning, error }

    private struct Style {
        var kind: Kind
        var symbol: String
        var color: NSColor
        var light: NSColor
    }

    private static var current: NSPanel?

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func style(for message: String, kind: Kind?, symbol: String?) -> Style {
        let m = message.lowercased()
        var k: Kind
        var sym: String
        if m.contains("failed") || m.contains("could not") || m.contains("error") || m.contains("can't") {
            (k, sym) = (.error, "exclamationmark")
        } else if message.hasSuffix("…") || message.hasSuffix("...") {
            (k, sym) = (.progress, "arrow.triangle.2.circlepath")
        } else if m.hasPrefix("no ") || m.contains("moved or deleted") {
            (k, sym) = (.warning, m.contains("text") ? "text.magnifyingglass" : "questionmark")
        } else if m.contains("link copied") {
            (k, sym) = (.success, "link")
        } else if m.contains("copied") {
            (k, sym) = (.success, "doc.on.doc.fill")
        } else if m.contains("saved") {
            (k, sym) = (.success, "arrow.down.to.line")
        } else if m.contains("up to date") {
            (k, sym) = (.success, "checkmark.seal.fill")
        } else if m.contains("available") {
            (k, sym) = (.info, "arrow.down.circle.fill")
        } else if m.contains("ready") {
            (k, sym) = (.success, "sparkles")
        } else if m.contains("locked") {
            (k, sym) = (.info, "lock.fill")
        } else {
            (k, sym) = (.info, "sparkle")
        }
        if let kind { k = kind }
        if let symbol { sym = symbol }
        switch k {
        case .success:  return Style(kind: k, symbol: sym, color: rgb(0.20, 0.80, 0.58), light: rgb(0.46, 0.93, 0.76))
        case .info:     return Style(kind: k, symbol: sym, color: rgb(0.33, 0.62, 1.00), light: rgb(0.58, 0.80, 1.00))
        case .progress: return Style(kind: k, symbol: sym, color: rgb(1.00, 0.79, 0.24), light: rgb(1.00, 0.88, 0.52))
        case .warning:  return Style(kind: k, symbol: sym, color: rgb(1.00, 0.70, 0.22), light: rgb(1.00, 0.84, 0.50))
        case .error:    return Style(kind: k, symbol: sym, color: rgb(1.00, 0.36, 0.34), light: rgb(1.00, 0.60, 0.55))
        }
    }

    static func show(_ message: String, on screen: NSScreen? = nil, seconds: Double = 2.2,
                     kind: Kind? = nil, symbol: String? = nil) {
        guard let target = screen ?? NSScreen.main else { return }
        current?.orderOut(nil)
        let st = style(for: message, kind: kind, symbol: symbol)

        // Measure the text; long messages wrap onto a second line.
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let lineH = ceil(font.boundingRectForFont.height)
        let maxText = min(460, target.visibleFrame.width - 160)
        let measured = NSAttributedString(string: message, attributes: [.font: font])
            .boundingRect(with: NSSize(width: maxText, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let single = measured.height <= lineH * 1.5
        let textW = single ? min(ceil(measured.width) + 8, maxText) : maxText
        let textH = single ? lineH : lineH * 2
        let badge: CGFloat = 28, lead: CGFloat = 10, gap: CGFloat = 10, trail: CGFloat = 20
        let height = single ? 48 : textH + 26
        let size = NSSize(width: lead + badge + gap + textW + trail, height: height)

        // Body: navy gradient, hairline border, a soft glow of the accent colour behind the badge.
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let layer = root.layer!
        layer.cornerRadius = single ? height / 2 : 22
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let body = CAGradientLayer()
        body.frame = root.bounds
        body.colors = [rgb(0.17, 0.17, 0.43).cgColor, rgb(0.08, 0.08, 0.24).cgColor]
        body.startPoint = CGPoint(x: 0.5, y: 1)
        body.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(body)

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(x: -50, y: -30, width: 200, height: height + 60)
        glow.colors = [st.color.withAlphaComponent(0.34).cgColor, NSColor.clear.cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(glow)

        // Icon badge.
        let badgeView = NSView(frame: NSRect(x: lead, y: (height - badge) / 2, width: badge, height: badge))
        badgeView.wantsLayer = true
        let bl = badgeView.layer!
        bl.cornerRadius = badge / 2
        bl.shadowColor = st.color.cgColor
        bl.shadowOpacity = st.kind == .progress ? 0 : 0.55
        bl.shadowRadius = 7
        bl.shadowOffset = .zero
        let fill = CAGradientLayer()
        fill.frame = badgeView.bounds
        fill.cornerRadius = badge / 2
        fill.colors = st.kind == .progress
            ? [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0.10).cgColor]
            : [st.light.cgColor, st.color.cgColor]
        fill.startPoint = CGPoint(x: 0.2, y: 1)
        fill.endPoint = CGPoint(x: 0.8, y: 0)
        bl.addSublayer(fill)
        root.addSubview(badgeView)

        if st.kind == .progress {
            let spinner = NSProgressIndicator(frame: NSRect(x: 5, y: 5, width: 18, height: 18))
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.appearance = NSAppearance(named: .darkAqua)
            spinner.startAnimation(nil)
            badgeView.addSubview(spinner)
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            let icon = NSImageView(frame: badgeView.bounds)
            icon.image = NSImage(systemSymbolName: st.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            icon.contentTintColor = st.kind == .success || st.kind == .info || st.kind == .error ? .white : rgb(0.20, 0.14, 0.02)
            icon.imageScaling = .scaleNone
            badgeView.addSubview(icon)
        }

        // Message.
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = font
        label.textColor = .white
        label.isSelectable = false
        label.maximumNumberOfLines = single ? 1 : 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.frame = NSRect(x: lead + badge + gap, y: (height - textH) / 2, width: textW, height: textH)
        root.addSubview(label)

        // Time left, as a hairline along the bottom edge.
        if st.kind != .progress {
            let line = CALayer()
            line.anchorPoint = CGPoint(x: 0, y: 0.5)
            line.bounds = CGRect(x: 0, y: 0, width: size.width, height: 2.5)
            line.position = CGPoint(x: 0, y: 1.25)
            line.backgroundColor = st.color.withAlphaComponent(0.9).cgColor
            layer.addSublayer(line)
            let drain = CABasicAnimation(keyPath: "transform.scale.x")
            drain.fromValue = 1
            drain.toValue = 0
            drain.duration = seconds
            drain.timingFunction = CAMediaTimingFunction(name: .linear)
            drain.fillMode = .forwards
            drain.isRemovedOnCompletion = false
            line.add(drain, forKey: "drain")
        }

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
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 56))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        current = panel

        // Entrance: fade in while springing up from slightly below and a touch smaller.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -18
        rise.toValue = 0
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.88
        grow.toValue = 1
        for spring in [rise, grow] {
            spring.mass = 1
            spring.stiffness = 260
            spring.damping = 16
            spring.duration = spring.settlingDuration
            root.layer?.add(spring, forKey: spring.keyPath)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { dismiss(panel) }
    }

    private static func dismiss(_ panel: NSPanel) {
        guard panel.isVisible else { return }
        let drop = CABasicAnimation(keyPath: "transform.translation.y")
        drop.fromValue = 0
        drop.toValue = -10
        drop.duration = 0.22
        drop.fillMode = .forwards
        drop.isRemovedOnCompletion = false
        panel.contentView?.layer?.add(drop, forKey: "out")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                if current === panel { current = nil }
            }
        })
    }
}
