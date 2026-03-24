import AppKit
import SwiftUI

class QuickToolsManager: ObservableObject {
    static let shared = QuickToolsManager()
    var panel: QuickToolsPanel?
    var previousApp: NSRunningApplication?
    private var isClosingPanel = false

    private init() {}

    func setup() {
        let panel = QuickToolsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 600, height: 500)
        panel.maxSize = NSSize(width: 1200, height: 900)

        let rootView = QuickToolsView()
            .edgesIgnoringSafeArea(.all)

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        containerView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        self.panel = panel
    }

    func hidePanel() {
        closePanel(usingClickOutsideSemantics: true)
    }

    func closePanel(usingClickOutsideSemantics: Bool) {
        guard let panel = panel else { return }

        if usingClickOutsideSemantics
            && !UserDefaults.standard.bool(forKey: "QuickToolsClickOutsideCloses")
        {
            return
        }

        animateAndClose(panel)
    }

    private func animateAndClose(_ panel: NSPanel) {
        guard !isClosingPanel else { return }
        isClosingPanel = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.isClosingPanel = false
            self.restoreFocusIfNeeded(afterClosing: panel)
        }
    }

    private func restoreFocusIfNeeded(afterClosing panel: NSPanel) {
        let otherWindowsVisible = NSApp.windows.contains { $0 != panel && $0.isVisible }
        if !otherWindowsVisible {
            if let previousApp = self.previousApp {
                previousApp.activate(options: [])
                self.previousApp = nil
            } else {
                NSApp.hide(nil)
            }
        }
    }

    func closePanelFromShortcut() {
        closePanel(usingClickOutsideSemantics: false)
    }

    func closePanelFromOutsideClick() {
        closePanel(usingClickOutsideSemantics: true)
    }

    func toggle() {
        guard let panel = panel else { return }

        // When toggled while visible, close the panel unconditionally via shortcut semantics
        if panel.isVisible {
            closePanelFromShortcut()
        } else {
            if !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
                for window in NSApp.windows {
                    if window != panel {
                        window.orderOut(nil)
                    }
                }
            }

            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let panelSize = panel.frame.size
                let x = screenRect.midX - (panelSize.width / 2)
                let y = screenRect.midY - (panelSize.height / 2)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }

            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

class QuickToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        QuickToolsManager.shared.closePanelFromOutsideClick()
    }
}
