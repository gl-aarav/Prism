import AppKit
import SwiftUI

class QuickToolsManager: ObservableObject {
    static let shared = QuickToolsManager()
    var panel: QuickToolsPanel?
    var previousApp: NSRunningApplication?

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
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

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
        guard let panel = panel else { return }

        panel.orderOut(nil)

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

    func toggle() {
        guard let panel = panel else { return }

        if panel.isVisible && panel.isKeyWindow {
            hidePanel()
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

            panel.makeKeyAndOrderFront(nil)
        }
    }
}

class QuickToolsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        if UserDefaults.standard.bool(forKey: "QuickToolsClickOutsideCloses") {
            QuickToolsManager.shared.hidePanel()
        }
    }
}
