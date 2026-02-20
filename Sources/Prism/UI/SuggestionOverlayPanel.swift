import AppKit
import SwiftUI

/// A liquid glass panel that floats above all windows.
class SuggestionOverlayPanel: NSPanel {

    let hostingView: NSHostingView<SuggestionOverlayView>

    init() {
        let view = SuggestionOverlayView(suggestion: "Loading...", fontSize: 13, maxWidth: 800)
        let hostingView = NSHostingView(rootView: view)
        self.hostingView = hostingView
        
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Fully transparent — no native shadow/background, let SwiftUI handle it
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

        contentView = hostingView
    }

    /// Update the displayed suggestion text and font size.
    func update(text: String, fontSize: CGFloat, maxWidth: CGFloat = 800) {
        hostingView.rootView = SuggestionOverlayView(suggestion: text, fontSize: fontSize, maxWidth: maxWidth)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
