import AppKit
import SwiftUI

/// Snapper's brand kit: name, colours, logo images and small reusable pieces.
enum Brand {
    static let name = "Snapper"
    static let tagline = "Capture, annotate, record."
    static let maker = "Bykorp"
    static let credit = "Built by Bykorp"

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    /// Logo navy (#1B1B4D).
    static let navy = NSColor(srgbRed: 0x1B / 255.0, green: 0x1B / 255.0, blue: 0x4D / 255.0, alpha: 1)
    /// Brand accent that reads in light and dark: navy in light mode, soft periwinkle in dark mode.
    static let accent = NSColor(name: NSColor.Name("SnapperAccent")) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.63, blue: 1.0, alpha: 1)
            : navy
    }

    /// Full-bleed logo badge (navy squircle, white snail). 64 pt with @2x.
    static let badge: NSImage = {
        if let img = Bundle.main.image(forResource: "BrandBadge") { return img }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()

    /// The badge at a fixed point size (menus and toolbars need explicit sizes).
    static func badge(size: CGFloat) -> NSImage {
        let img = badge.copy() as? NSImage ?? badge
        img.size = NSSize(width: size, height: size)
        return img
    }

    static var appIcon: NSImage { NSImage(named: NSImage.applicationIconName) ?? badge }

    /// "Snapper" set in the rounded system face.
    static func wordmarkFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// Badge + wordmark lockup for AppKit layouts.
    static func lockup(height: CGFloat = 22, textColor: NSColor = .labelColor) -> NSView {
        let icon = NSImageView(image: badge(size: height))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: height).isActive = true
        icon.heightAnchor.constraint(equalToConstant: height).isActive = true
        let label = NSTextField(labelWithString: name)
        label.font = wordmarkFont(size: height * 0.68)
        label.textColor = textColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = height * 0.32
        stack.alignment = .centerY
        return stack
    }
}

/// SwiftUI lockup.
struct BrandLockup: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: size * 0.32) {
            Image(nsImage: Brand.badge)
                .resizable()
                .frame(width: size, height: size)
            Text(Brand.name)
                .font(.system(size: size * 0.68, weight: .bold, design: .rounded))
        }
    }
}
