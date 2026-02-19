import AppKit

/// A completely transparent, non-activating panel that floats above all windows.
/// Used to display inline ghost text at the cursor position — no shadow, no chrome.
class SuggestionOverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Fully transparent — no shadow, no background
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        // Don't steal focus or appear in Mission Control
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
