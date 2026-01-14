import AppKit
import SwiftUI

class QuickAIManager: ObservableObject {
    static let shared = QuickAIManager()
    var panel: QuickAIPanel?
    private var previousApp: NSRunningApplication?
    private var resizeWorkItem: DispatchWorkItem?
    private var pendingResize: CGSize?
    private var isApplyingResize = false
    private let debounceInterval: TimeInterval = 0.18

    private init() {}

    func setup() {
        let panel = QuickAIPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
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

        let rootView = QuickAIView(
            onResize: { [weak self, weak panel] size in
                guard let self = self, let panel = panel else { return }
                self.scheduleResize(to: size, panel: panel)
            },
            onClose: { [weak panel] in
                panel?.orderOut(nil)

                // If no other windows are visible, hide the app to return focus to previous app
                let otherWindowsVisible = NSApp.windows.contains { $0 != panel && $0.isVisible }
                if !otherWindowsVisible {
                    if let previousApp = QuickAIManager.shared.previousApp {
                        previousApp.activate(options: [])
                        QuickAIManager.shared.previousApp = nil
                    } else {
                        NSApp.hide(nil)
                    }
                }
            }
        )
        // Ensure SwiftUI view covers the edges
        .edgesIgnoringSafeArea(.all)

        // Use a container NSView to isolate SwiftUI hosting from the NSPanel's direct content view logic.
        // This decouples the layout engine and prevents auto-resizing crashes (SIGABRT in _postWindowNeedsUpdateConstraints)
        // caused by NSHostingView or NSHostingController fighting with the manual setFrame calls.
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 80))
        containerView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]  // Ensure it resizes with the container
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        // We do NOT use contentViewController to avoid interfering with the window frame.
        self.panel = panel
    }

    func toggle() {
        guard let panel = panel else { return }

        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
            let otherWindowsVisible = NSApp.windows.contains { $0 != panel && $0.isVisible }
            if !otherWindowsVisible {
                if let previousApp = previousApp {
                    previousApp.activate(options: [])
                    self.previousApp = nil
                } else {
                    NSApp.hide(nil)
                }
            }
        } else {
            // If app is not active, we are coming from outside.
            // We should ensure the main window doesn't pop up and distract.
            if !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
                for window in NSApp.windows {
                    if window != panel {
                        window.orderOut(nil)
                    }
                }
            }

            // Switch to accessory mode if no other windows are visible to avoid Dock/Menu bar activation

            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let panelSize = panel.frame.size
                let x = screenRect.midX - (panelSize.width / 2)
                let y = screenRect.maxY - 200 - panelSize.height
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                panel.center()
            }

            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func scheduleResize(to size: CGSize, panel: QuickAIPanel) {
        let currentHeight = panel.frame.height
        let targetHeight = max(72, size.height)
        let diff = abs(currentHeight - targetHeight)
        
        // If the change is significant (expansion/collapse), run immediately without debounce
        // to match the SwiftUI animation.
        if diff > 50 {
            resizeWorkItem?.cancel()
            self.applyResize(size: size, panel: panel)
            return
        }

        pendingResize = size
        resizeWorkItem?.cancel()

        // Trailing debounce: coalesce rapid changes and apply only after
        // the UI has been quiet for a short interval to avoid constraint churn.
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }
            self.applyResize(size: self.pendingResize ?? size, panel: panel)
            self.pendingResize = nil
        }

        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func applyResize(size: CGSize, panel: QuickAIPanel) {
        // Prevent re-entrant frame churn from windowDidLayout / constraint passes.
        if isApplyingResize {
            pendingResize = size
            return
        }

        let currentFrame = panel.frame
        let targetHeight = max(72, size.height)
        let diff = abs(currentFrame.height - targetHeight)

        guard diff > 0.5 else { return }

        // Avoid fighting SwiftUI/Auto Layout update cycles.
        if panel.contentView?.needsUpdateConstraints == true || panel.inLiveResize {
            // If it's a large jump, force it through anyway to avoid getting stuck
            if diff <= 50 {
               scheduleResize(to: size, panel: panel)
               return
            }
        }

        // Perform the actual frame change on the next runloop turn to stay out of the
        // active display/layout cycle.
        isApplyingResize = true
        let targetSize = targetHeight

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }

            let currentFrame = panel.frame
            let newY = currentFrame.maxY - targetSize
            let newFrame = NSRect(
                x: currentFrame.minX,
                y: newY,
                width: currentFrame.width,  // keep width fixed; only grow vertically
                height: targetSize)

            NSAnimationContext.runAnimationGroup { context in
                // "Slow and smooth" to match SwiftUI .spring(response: 0.55, damping: 0.8)
                // A response of 0.55s means the spring settles over a longer period. 
                // We'll set the window duration to approx 0.6s with a smooth eased curve.
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeOut) // Standard ease-out is smoother/slower feeling than quint
                panel.animator().setFrame(newFrame, display: true)
            } completionHandler: {
                 // Ensure final frame is set correctly
                 panel.setFrame(newFrame, display: true)
            }

            self.isApplyingResize = false

            // If another resize was queued while applying, run it once.
            if let next = self.pendingResize {
                self.pendingResize = nil
                self.scheduleResize(to: next, panel: panel)
            }
        }
    }
}

class QuickAIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
