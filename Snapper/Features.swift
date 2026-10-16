import Foundation

/// Features that are built but held back from the alpha. Flip one to bring it back; nothing is deleted.
enum Features {
    /// Upload to a self-hosted server (Quick Access, video window, File menu, Settings > Cloud).
    static let cloudUpload = false
    /// Turning on Do Not Disturb while recording (needs two hand-made Shortcuts).
    static let doNotDisturb = false
    /// Horizontal scrolling capture from the menu. The URL scheme `?horizontal=1` still works.
    static let horizontalScroll = false
    /// Swiping a Quick Access card away from the screen edge saves it.
    static let swipeToSave = false
}
