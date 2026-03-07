import AppKit
import SwiftUI

class QuickAIManager: ObservableObject {
    static let shared = QuickAIManager()
    var panel: QuickAIPanel?
    var previousApp: NSRunningApplication?
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

        // Determine if this is a major transition (expand/collapse)
        let isMajorTransition = diff > 100

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self = self, let panel = panel else {
                self?.isApplyingResize = false
                return
            }

            let currentFrame = panel.frame
            let newY = currentFrame.maxY - targetSize
            let newFrame = NSRect(
                x: currentFrame.minX,
                y: newY,
                width: currentFrame.width,  // keep width fixed; only grow vertically
                height: targetSize)

            NSAnimationContext.runAnimationGroup { context in
                // Use different durations for major vs minor transitions
                // Major transitions (expand/collapse) use a longer, smoother animation
                // Minor transitions (text input changes) use a quicker response
                if isMajorTransition {
                    // Match the SwiftUI spring animation (response: 0.5, damping: 0.82)
                    // Spring response of 0.5s with high damping = smooth, controlled expansion
                    context.duration = 0.55
                    context.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.22, 1.0, 0.36, 1.0)  // Custom ease-out curve
                } else {
                    context.duration = 0.35
                    context.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.25, 0.1, 0.25, 1.0)  // Smooth ease
                }
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(newFrame, display: true)
            } completionHandler: { [weak self, weak panel] in
                // Ensure final frame is set correctly (only if panel is still valid)
                panel?.setFrame(newFrame, display: true)
                _ = self  // prevent unused capture warning
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

extension QuickAIManager {
    /// Paste text into the previously active application
    /// - Parameter text: The text to paste
    func pasteToActiveApp(text: String) {
        // 1. Copy text to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 2. Close Quick AI panel
        panel?.orderOut(nil)

        // 3. Activate previous app
        guard let previousApp = previousApp else {
            // If no previous app, just hide ourselves
            NSApp.hide(nil)

            // Simulate paste after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.simulatePaste()
            }
            return
        }

        previousApp.activate()
        self.previousApp = nil

        // 4. Simulate Cmd+V after a brief delay to ensure app is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.simulatePaste()
        }
    }

    /// Simulate Cmd+V keystroke
    private func simulatePaste() {
        // Create key down event for 'V' with Command modifier
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for 'V' is 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            return
        }

        // Add Command modifier
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Post the events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

class QuickAIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
