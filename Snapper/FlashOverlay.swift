import AppKit

@MainActor
enum FlashOverlay {
    static func flash(on screen: NSScreen? = nil) {
        guard let target = screen ?? NSScreen.main else { return }
        let window = NSWindow(contentRect: target.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.setFrame(target.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .white
        window.alphaValue = 0.5
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in window.orderOut(nil) }
        })
    }
}
