import AppKit

/// Hides desktop icons by covering them with a window that shows the wallpaper, one per display,
/// just above the icon layer and below every app window. Instant, and Finder is never restarted
/// (the old `defaults write … CreateDesktop` + `killall Finder` approach cost seconds of CPU per capture).
@MainActor
enum DesktopIconManager {
    private static var covers: [NSWindow] = []
    private static var wallpaperCache: [URL: CGImage] = [:]

    /// True when the icons are not covered by Snapper.
    static func areVisible() -> Bool { covers.isEmpty }

    static func setVisible(_ visible: Bool) {
        if visible { uncover() } else { cover() }
    }

    private static func cover() {
        guard covers.isEmpty else { return }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.level = level
            w.isOpaque = true
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.backgroundColor = fillColor(for: screen)

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            if let img = wallpaper(for: screen) {
                view.layer?.contents = img
                view.layer?.contentsGravity = gravity(for: screen)
            }
            w.contentView = view
            w.orderFrontRegardless()
            covers.append(w)
        }
    }

    private static func uncover() {
        for w in covers { w.orderOut(nil) }
        covers.removeAll()
    }

    private static func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let cached = wallpaperCache[url] { return cached }
        var target = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = files.first(where: { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) })
            else { return nil }
            target = first
        }
        // Decode at screen size, not the wallpaper's full (often 6K) size.
        let maxPixel = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        guard let src = CGImageSourceCreateWithURL(target as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }
        if wallpaperCache.count > 4 { wallpaperCache.removeAll() }
        wallpaperCache[url] = img
        return img
    }

    private static func gravity(for screen: NSScreen) -> CALayerContentsGravity {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch scaling {
        case .scaleAxesIndependently?: return .resize
        case .scaleNone?: return .center
        default: return clipping ? .resizeAspectFill : .resizeAspect
        }
    }

    private static func fillColor(for screen: NSScreen) -> NSColor {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return (options[.fillColor] as? NSColor) ?? .black
    }
}
