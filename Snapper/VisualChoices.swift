import AppKit
import SwiftUI

// Visual option pickers: every choice is a small picture of what it does, with a tiny caption underneath,
// instead of a text menu.

// MARK: - SwiftUI tiles

struct Choice<V: Hashable> {
    let value: V
    let label: String
    let art: AnyView

    init<A: View>(_ value: V, _ label: String, @ViewBuilder art: () -> A) {
        self.value = value
        self.label = label
        self.art = AnyView(art())
    }
}

/// A row (or grid) of picture tiles. The selected tile is outlined in the accent colour.
struct TilePicker<V: Hashable>: View {
    var title: String? = nil
    @Binding var selection: V
    let choices: [Choice<V>]
    var tile = CGSize(width: 58, height: 40)
    var columns: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title) }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile.width), spacing: 10, alignment: .top),
                                     count: max(1, columns ?? choices.count)),
                      alignment: .leading, spacing: 10) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, c in cell(c) }
            }
        }
    }

    private func cell(_ c: Choice<V>) -> some View {
        let on = c.value == selection
        return Button { selection = c.value } label: {
            VStack(spacing: 5) {
                c.art
                    .frame(width: tile.width - 16, height: tile.height - 12)
                    .frame(width: tile.width, height: tile.height)
                    .foregroundColor(on ? .accentColor : .secondary)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
                Text(c.label)
                    .font(.system(size: 10, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: tile.width + 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.label)
    }
}

// MARK: - Art

/// A little screen with a block placed at `at`.
struct ScreenArt: View {
    var at: Alignment = .bottomTrailing
    var block = CGSize(width: 12, height: 8)
    var round = false
    var body: some View {
        ZStack(alignment: at) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.5)
            Group {
                if round { Circle().frame(width: block.height, height: block.height) }
                else { RoundedRectangle(cornerRadius: 2).frame(width: block.width, height: block.height) }
            }
            .padding(3.5)
        }
    }
}

/// The shape of an aspect ratio (nil = follows the content).
struct AspectArt: View {
    let ratio: CGFloat?
    var body: some View {
        GeometryReader { g in
            let box = g.size
            let r = ratio ?? 1.45
            let w = min(box.width, box.height * r), h = w / r
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.6, dash: ratio == nil ? [3, 2] : []))
                .frame(width: w, height: h)
                .position(x: box.width / 2, y: box.height / 2)
        }
    }
}

/// Signal-style bars: n of 3 filled.
struct BarsArt: View {
    let n: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .frame(width: 5, height: CGFloat(7 + i * 6))
                    .opacity(i < n ? 1 : 0.22)
            }
        }
    }
}

/// Frames per second as a strip of frames: more, thinner frames for higher rates.
struct FramesArt: View {
    let count: Int
    var body: some View {
        HStack(spacing: count > 5 ? 1.5 : 2.5) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.2)
                    .frame(height: 16)
                    .opacity(0.35 + 0.65 * Double(i + 1) / Double(count))
            }
        }
    }
}

/// A countdown ring with the number of seconds.
struct TimerArt: View {
    let seconds: Int
    var body: some View {
        ZStack {
            Circle().stroke(lineWidth: 2.5).opacity(0.22)
            Circle().trim(from: 0, to: CGFloat(seconds) / 10)
                .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)").font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .frame(width: 24, height: 24)
    }
}

/// A run of days as small squares.
struct DaysArt: View {
    let days: Int
    var body: some View {
        let cols = days <= 7 ? days : 6
        let rows = Int((Double(days) / Double(cols)).rounded(.up))
        let cell: CGFloat = days <= 7 ? 3.5 : 2.6
        VStack(spacing: 1.5) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 1.5) {
                    ForEach(0..<cols, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 0.8)
                            .frame(width: cell, height: cell)
                            .opacity(r * cols + c < days ? 1 : 0)
                    }
                }
            }
        }
    }
}

/// Window capture styles: on a background, transparent with a shadow, transparent flat.
struct WindowStyleArt: View {
    let style: Int
    var body: some View {
        ZStack {
            if style == 0 {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.55), Color(red: 0.62, green: 0.55, blue: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Checker().clipShape(RoundedRectangle(cornerRadius: 4))
            }
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.white)
                .overlay(VStack { Rectangle().fill(Color.black.opacity(0.12)).frame(height: 3); Spacer() }
                    .clipShape(RoundedRectangle(cornerRadius: 2.5)))
                .padding(.horizontal, 7).padding(.vertical, 5)
                .shadow(color: .black.opacity(style == 1 ? 0.45 : 0), radius: 2.5, y: 1.5)
        }
    }

    private struct Checker: View {
        var body: some View {
            Canvas { ctx, size in
                let s: CGFloat = 4
                for y in stride(from: 0, to: size.height, by: s) {
                    for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                        ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.28)))
                    }
                }
            }
        }
    }
}

/// A keycap.
struct KeycapArt: View {
    var scale: CGFloat = 1
    var dark = true
    var body: some View {
        Text("\u{2318}K")
            .font(.system(size: 8 * scale, weight: .semibold))
            .foregroundColor(dark ? .white : .black)
            .padding(.horizontal, 3 * scale).padding(.vertical, 1.5 * scale)
            .background(RoundedRectangle(cornerRadius: 2.5 * scale).fill(dark ? Color.black.opacity(0.8) : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 2.5 * scale).strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.6))
    }
}

/// Click highlight: outline ring or filled dot, with a pointer.
struct ClickArt: View {
    let filled: Bool
    var body: some View {
        ZStack {
            if filled { Circle().opacity(0.55).frame(width: 20, height: 20) }
            else { Circle().stroke(lineWidth: 2.2).frame(width: 20, height: 20) }
            Image(systemName: "cursorarrow").font(.system(size: 11, weight: .bold)).foregroundColor(.primary).offset(x: 3, y: 3)
        }
    }
}

struct SymbolArt: View {
    let name: String
    var size: CGFloat = 16
    var body: some View { Image(systemName: name).font(.system(size: size, weight: .medium)) }
}

// MARK: - AppKit image segments

/// A segmented control of pictures that reads like a popup button (indexOfSelectedItem, selectItem(at:)).
final class ImageSegments: NSSegmentedControl {
    convenience init(images: [NSImage], tips: [String], width: CGFloat = 30) {
        self.init(frame: .zero)
        segmentCount = images.count
        trackingMode = .selectOne
        controlSize = .small
        for (i, image) in images.enumerated() {
            setImage(image, forSegment: i)
            setImageScaling(.scaleNone, forSegment: i)
            setWidth(width, forSegment: i)
            setToolTip(tips[i], forSegment: i)
        }
        selectedSegment = 0
    }

    func selectItem(at index: Int) { if index >= 0, index < segmentCount { selectedSegment = index } }
}

/// Template images (they follow the control's tint) for the annotation style options.
enum ChoiceArt {
    private static func image(_ size: NSSize = NSSize(width: 26, height: 16), _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in draw(r); return true }
        img.isTemplate = true
        return img
    }

    /// "Aa" in each text style: plain, bold, outlined, highlight, boxed, dark pill, handwritten.
    static func textStyle(_ i: Int) -> NSImage {
        image { r in
            let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]
            var attrs = base
            switch i {
            case 1: attrs[.font] = NSFont.systemFont(ofSize: 12, weight: .heavy)
            case 2:
                attrs[.font] = NSFont.systemFont(ofSize: 12, weight: .heavy)
                attrs[.strokeWidth] = 3.0
            case 6: attrs[.font] = NSFont(name: "Noteworthy-Bold", size: 12) ?? NSFont(name: "Bradley Hand", size: 12)
                ?? NSFont.systemFont(ofSize: 12)
            default: attrs[.font] = NSFont.systemFont(ofSize: 12, weight: .medium)
            }
            let text = NSAttributedString(string: "Aa", attributes: attrs)
            let s = text.size()
            let at = NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2)
            switch i {
            case 3:
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.midX - 10, y: r.minY + 2, width: 20, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
                text.draw(at: at)
            case 4:
                NSColor.black.setStroke()
                let box = NSBezierPath(roundedRect: r.insetBy(dx: 2.5, dy: 1.5), xRadius: 2.5, yRadius: 2.5)
                box.lineWidth = 1.2
                box.stroke()
                text.draw(at: at)
            case 5:
                NSColor.black.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1), xRadius: 7, yRadius: 7).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: at)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            default:
                text.draw(at: at)
            }
        }
    }

    /// Smooth blur (soft dot) or secure (mosaic).
    static func blurMode(_ i: Int) -> NSImage {
        image { r in
            if i == 0 {
                for (k, a) in [(7.0, 0.25), (5.0, 0.5), (3.0, 1.0)] {
                    NSColor.black.withAlphaComponent(a).setFill()
                    NSBezierPath(ovalIn: NSRect(x: r.midX - k, y: r.midY - k, width: k * 2, height: k * 2)).fill()
                }
            } else {
                let s: CGFloat = 4
                let origin = NSPoint(x: r.midX - 8, y: r.midY - 6)
                for row in 0..<3 {
                    for col in 0..<4 {
                        let alpha = [1.0, 0.35, 0.7, 0.5][(row + col * 2) % 4]
                        NSColor.black.withAlphaComponent(alpha).setFill()
                        NSRect(x: origin.x + CGFloat(col) * s, y: origin.y + CGFloat(row) * s, width: s - 0.5, height: s - 0.5).fill()
                    }
                }
            }
        }
    }

    /// Spotlight shape: rectangle or ellipse.
    static func spotlight(_ i: Int) -> NSImage {
        image { r in
            NSColor.black.setStroke()
            let rect = r.insetBy(dx: 5, dy: 2.5)
            let path = i == 0 ? NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2) : NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.6
            path.stroke()
        }
    }

    /// Crop aspect: "free" corners, the original picture, or the ratio's shape.
    static func crop(_ ratio: CGFloat?) -> NSImage {
        image { r in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            guard let ratio else {
                // Free: crop corners
                let p = NSBezierPath()
                let b = r.insetBy(dx: 6, dy: 2)
                p.move(to: NSPoint(x: b.minX + 5, y: b.minY)); p.line(to: NSPoint(x: b.minX, y: b.minY)); p.line(to: NSPoint(x: b.minX, y: b.minY + 5))
                p.move(to: NSPoint(x: b.maxX - 5, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY)); p.line(to: NSPoint(x: b.maxX, y: b.maxY - 5))
                p.lineWidth = 1.8
                p.lineCapStyle = .round
                p.stroke()
                return
            }
            if ratio < 0 {
                // Original: a little picture
                let b = r.insetBy(dx: 5, dy: 2)
                let frame = NSBezierPath(roundedRect: b, xRadius: 2, yRadius: 2)
                frame.lineWidth = 1.4
                frame.stroke()
                let hill = NSBezierPath()
                hill.move(to: NSPoint(x: b.minX + 2, y: b.minY + 2))
                hill.line(to: NSPoint(x: b.midX - 1, y: b.midY + 1))
                hill.line(to: NSPoint(x: b.maxX - 2, y: b.minY + 2))
                hill.close()
                hill.fill()
                return
            }
            let maxW: CGFloat = 18, maxH: CGFloat = 13
            let w = min(maxW, maxH * ratio), h = w / ratio
            let path = NSBezierPath(roundedRect: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1.6
            path.stroke()
        }
    }
}

// MARK: - Quiet settings controls

/// A mini screen you click where the thing should go. The chosen spot is filled; the others are faint.
struct PositionPad: View {
    @Binding var selection: Int
    let slots: [(value: Int, at: Alignment, help: String)]
    var block = CGSize(width: 12, height: 8)
    var round = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            ForEach(slots.indices, id: \.self) { i in
                let slot = slots[i]
                let on = slot.value == selection
                Button { selection = slot.value } label: {
                    shape
                        .fill(on ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(width: round ? block.height : block.width, height: block.height)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(slot.help)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slot.at)
            }
        }
        .frame(width: 64, height: 40)
    }

    private var shape: AnyShape {
        round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// Native segmented control with short labels or symbols, sized to its content.
struct Segments<V: Hashable>: View {
    @Binding var selection: V
    let items: [(value: V, label: String, symbol: String?)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                Group {
                    if let symbol = item.symbol { Image(systemName: symbol).help(item.label) } else { Text(item.label) }
                }
                .tag(item.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Small picture previews with a selection ring and no captions (the name is the tooltip).
struct PreviewPicker<V: Hashable>: View {
    @Binding var selection: V
    let items: [Choice<V>]
    var size = CGSize(width: 44, height: 30)

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                let item = items[i]
                let on = item.value == selection
                Button { selection = item.value } label: {
                    item.art
                        .frame(width: size.width - 8, height: size.height - 8)
                        .foregroundColor(on ? .accentColor : .secondary)
                        .frame(width: size.width, height: size.height)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.label)
            }
        }
    }
}
