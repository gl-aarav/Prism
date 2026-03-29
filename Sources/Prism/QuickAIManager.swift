import AppKit
import SwiftUI

extension Notification.Name {
    static let quickAIOverlayWidthDidChange = Notification.Name("QuickAIOverlayWidthDidChange")
    static let quickAIOverlayHeightDidChange = Notification.Name("QuickAIOverlayHeightDidChange")
}

class QuickAIManager: ObservableObject {
    static let shared = QuickAIManager()
    var panel: QuickAIPanel?
    var previousApp: NSRunningApplication?
    private var resizeWorkItem: DispatchWorkItem?
    private var pendingResize: CGSize?
    private var isApplyingResize = false
    private let debounceInterval: TimeInterval = 0.18
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var isProgrammaticMove = false
    private var lastKnownPanelWidth: CGFloat = 700
    private var preferredOrigin: NSPoint?
    private var compactOriginBeforeShift: NSPoint?
    private var lastCompactOrigin: NSPoint?
    private var shouldRestoreCompactPosition = false
    private var isClosingPanel = false
    private var isOpeningPanel = false
    private var snappedToCenterX = false

    private let compactHeightThreshold: CGFloat = 130
    private let minPanelWidth: CGFloat = 520
    private let maxPanelWidth: CGFloat = 700
    private let minPanelHeight: CGFloat = 72
    private let maxPanelHeight: CGFloat = 850
    private let compactPanelHeight: CGFloat = 110
    private let defaultTopInset: CGFloat = 84
    private let centerSnapThreshold: CGFloat = 22
    private let originXDefaultsKey = "QuickAIOverlayOriginX"
    private let originYDefaultsKey = "QuickAIOverlayOriginY"
    private let widthDefaultsKey = "QuickAIOverlayWidth"
    private let heightDefaultsKey = "QuickAIOverlayHeight"

    var userExpandedHeight: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: heightDefaultsKey)
            return saved > 0 ? CGFloat(saved) : 550
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: heightDefaultsKey)
        }
    }

    private init() {
        if UserDefaults.standard.object(forKey: originXDefaultsKey) != nil,
            UserDefaults.standard.object(forKey: originYDefaultsKey) != nil
        {
            preferredOrigin = NSPoint(
                x: UserDefaults.standard.double(forKey: originXDefaultsKey),
                y: UserDefaults.standard.double(forKey: originYDefaultsKey)
            )
            lastCompactOrigin = preferredOrigin
        }
    }

    func setup() {
        let savedWidth = UserDefaults.standard.double(forKey: widthDefaultsKey)
        let restoredWidth: CGFloat = savedWidth > 0 ? CGFloat(savedWidth) : 700
        let initialWidth: CGFloat = min(max(restoredWidth, minPanelWidth), maxPanelWidth)

        let panel = QuickAIPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: compactPanelHeight),
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
        panel.minSize = NSSize(width: minPanelWidth, height: minPanelHeight)
        panel.maxSize = NSSize(width: maxPanelWidth, height: maxPanelHeight)
        lastKnownPanelWidth = panel.frame.width

        let rootView = QuickAIView(
            onResize: { [weak self, weak panel] size in
                guard let self = self, let panel = panel else { return }
                self.scheduleResize(to: size, panel: panel)
            },
            onClose: { [weak self] in
                self?.closePanel(usingClickOutsideSemantics: false)
            }
        )
        // Ensure SwiftUI view covers the edges
        .edgesIgnoringSafeArea(.all)

        // Use a container NSView to isolate SwiftUI hosting from the NSPanel's direct content view logic.
        // This decouples the layout engine and prevents auto-resizing crashes (SIGABRT in _postWindowNeedsUpdateConstraints)
        // caused by NSHostingView or NSHostingController fighting with the manual setFrame calls.
        let containerView = NSView(
            frame: NSRect(x: 0, y: 0, width: initialWidth, height: compactPanelHeight)
        )
        containerView.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = containerView.bounds
        hostingView.autoresizingMask = [.width, .height]  // Ensure it resizes with the container
        containerView.addSubview(hostingView)

        panel.contentView = containerView
        // We do NOT use contentViewController to avoid interfering with the window frame.
        self.panel = panel
        registerMoveObserver(for: panel)
        registerResizeObserver(for: panel)
    }

    func toggle() {
        guard let panel = panel else { return }

        if panel.isVisible && panel.isKeyWindow {
            closePanel(usingClickOutsideSemantics: false)
        } else {
            // If app is not active, we are coming from outside.
            // We should ensure the main window doesn't pop up and distract.
            if !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
            } else {
                if QuickToolsManager.shared.panel?.isVisible == true {
                    if let app = QuickToolsManager.shared.previousApp { previousApp = app }
                    QuickToolsManager.shared.previousApp = nil
                }
                if WebOverlayManager.shared.panel?.isVisible == true {
                    if let app = WebOverlayManager.shared.previousApp { previousApp = app }
                    WebOverlayManager.shared.previousApp = nil
                }
            }

            for window in NSApp.windows {
                if window != panel {
                    window.orderOut(nil)
                }
            }

            // Switch to accessory mode if no other windows are visible to avoid Dock/Menu bar activation

            positionPanelForOpening(panel)

            presentPanel(panel)
        }
    }

    func closePanel(usingClickOutsideSemantics: Bool) {
        guard let panel = panel else { return }

        if usingClickOutsideSemantics
            && !UserDefaults.standard.bool(forKey: "QuickAIClickOutsideCloses")
        {
            return
        }

        animateAndClose(panel)
    }

    func requestRestoreCompactPositionAfterNewChat() {
        shouldRestoreCompactPosition = true
        guard let panel = panel else { return }
        if panel.frame.height <= compactHeightThreshold {
            restoreCompactPositionIfNeeded(panel: panel)
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
            var newX = currentFrame.minX
            var newY = currentFrame.minY  // Keep chat bar anchored unless top overflow forces shift.

            // Cache compact origin before a large expansion so we can restore it on New Chat.
            if targetSize > currentFrame.height + 1, self.compactOriginBeforeShift == nil {
                self.compactOriginBeforeShift = currentFrame.origin
            }

            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame

                let maxYForTargetHeight = visible.maxY - targetSize
                if newY > maxYForTargetHeight {
                    newY = maxYForTargetHeight
                }
                if newY < visible.minY {
                    newY = visible.minY
                }

                let maxX = visible.maxX - currentFrame.width
                if newX > maxX {
                    newX = maxX
                }
                if newX < visible.minX {
                    newX = visible.minX
                }
            }

            let newFrame = NSRect(
                x: newX,
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
                self.isProgrammaticMove = true  // Ensure observers ignore this programmatic resize
                panel.animator().setFrame(newFrame, display: true)
            } completionHandler: { [weak self, weak panel] in
                // Ensure final frame is set correctly (only if panel is still valid)
                panel?.setFrame(newFrame, display: true)
                _ = self  // prevent unused capture warning

                if let self = self, let panel = panel {
                    self.isProgrammaticMove = false
                    self.isApplyingResize = false

                    if self.shouldRestoreCompactPosition
                        && panel.frame.height <= self.compactHeightThreshold
                    {
                        self.restoreCompactPositionIfNeeded(panel: panel)
                    }

                    // If another resize was queued while applying, run it once.
                    if let next = self.pendingResize {
                        self.pendingResize = nil
                        self.scheduleResize(to: next, panel: panel)
                    }
                }
            }
        }
    }

    private func registerMoveObserver(for panel: QuickAIPanel) {
        if let observer = moveObserver {
            NotificationCenter.default.removeObserver(observer)
            moveObserver = nil
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self = self, let panel = panel else { return }
            guard !self.isProgrammaticMove else { return }
            let adjustedOrigin = self.applyCenterSnapIfNeeded(for: panel)
            self.persistOrigin(adjustedOrigin, panelHeight: panel.frame.height)
        }
    }

    private func registerResizeObserver(for panel: QuickAIPanel) {
        if let observer = resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            resizeObserver = nil
        }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self = self, let panel = panel else { return }

            let newWidth = panel.frame.width
            let newHeight = panel.frame.height
            UserDefaults.standard.set(Double(newWidth), forKey: self.widthDefaultsKey)

            if !self.isProgrammaticMove && newHeight > self.compactHeightThreshold {
                // We broadcast the new height so the view can adjust its own base height
                NotificationCenter.default.post(
                    name: Notification.Name("QuickAIOverlayHeightDidChange"), object: newHeight)
            }

            if abs(newWidth - self.lastKnownPanelWidth) > 0.5 {
                self.lastKnownPanelWidth = newWidth
                NotificationCenter.default.post(name: .quickAIOverlayWidthDidChange, object: nil)
            }

            if !self.isProgrammaticMove {
                self.persistOrigin(panel.frame.origin, panelHeight: panel.frame.height)
            }
        }
    }

    private func positionPanelForOpening(_ panel: QuickAIPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }

        let visible = screen.visibleFrame
        let panelSize = panel.frame.size

        let defaultTopOrigin = NSPoint(
            x: visible.midX - (panelSize.width / 2),
            y: visible.maxY - panelSize.height - defaultTopInset
        )

        let targetOrigin = preferredOrigin ?? defaultTopOrigin
        let clamped = clampOrigin(targetOrigin, panelSize: panelSize, visibleFrame: visible)
        setFrameOrigin(panel: panel, origin: clamped)

        if panel.frame.height <= compactHeightThreshold {
            compactOriginBeforeShift = clamped
            lastCompactOrigin = clamped
        }
    }

    private func restoreCompactPositionIfNeeded(panel: QuickAIPanel) {
        guard shouldRestoreCompactPosition else { return }
        shouldRestoreCompactPosition = false

        guard let target = compactOriginBeforeShift ?? lastCompactOrigin ?? preferredOrigin else {
            return
        }
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        let finalOrigin: NSPoint
        if let screenFrame = screenFrame {
            finalOrigin = clampOrigin(
                target, panelSize: panel.frame.size, visibleFrame: screenFrame)
        } else {
            finalOrigin = target
        }

        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            context.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(finalOrigin)
        } completionHandler: { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }
            panel.setFrameOrigin(finalOrigin)
            self.isProgrammaticMove = false
            self.persistOrigin(finalOrigin, panelHeight: panel.frame.height)
        }
    }

    private func setFrameOrigin(panel: QuickAIPanel, origin: NSPoint) {
        isProgrammaticMove = true
        panel.setFrameOrigin(origin)
        isProgrammaticMove = false
    }

    private func persistOrigin(_ origin: NSPoint, panelHeight: CGFloat) {
        preferredOrigin = origin
        UserDefaults.standard.set(origin.x, forKey: originXDefaultsKey)
        UserDefaults.standard.set(origin.y, forKey: originYDefaultsKey)

        if panelHeight <= compactHeightThreshold {
            compactOriginBeforeShift = origin
            lastCompactOrigin = origin
        }
    }

    private func applyCenterSnapIfNeeded(for panel: QuickAIPanel) -> NSPoint {
        guard let screen = panel.screen ?? NSScreen.main else {
            snappedToCenterX = false
            return panel.frame.origin
        }

        let visibleFrame = screen.visibleFrame
        let centeredX = visibleFrame.midX - (panel.frame.width / 2)
        let currentOrigin = panel.frame.origin
        let delta = abs(currentOrigin.x - centeredX)

        guard delta <= centerSnapThreshold else {
            snappedToCenterX = false
            return currentOrigin
        }

        let snappedOrigin = NSPoint(x: centeredX, y: currentOrigin.y)
        if !snappedToCenterX {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            snappedToCenterX = true
        }

        isProgrammaticMove = true
        panel.setFrameOrigin(snappedOrigin)
        isProgrammaticMove = false
        return snappedOrigin
    }

    private func presentPanel(_ panel: QuickAIPanel) {
        guard !isOpeningPanel else { return }
        isOpeningPanel = true

        let finalFrame = panel.frame
        let startFrame = NSRect(
            x: finalFrame.minX,
            y: finalFrame.minY - 18,
            width: finalFrame.width,
            height: max(minPanelHeight, finalFrame.height - 10)
        )

        panel.alphaValue = 0
        panel.setFrame(startFrame, display: true)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            context.allowsImplicitAnimation = true
            self.isProgrammaticMove = true
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: true)
            self.isProgrammaticMove = false
            self.isOpeningPanel = false
        }
    }

    private func animateAndClose(_ panel: QuickAIPanel) {
        guard !isClosingPanel else { return }
        isClosingPanel = true

        let currentFrame = panel.frame
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.minY - 14,
            width: currentFrame.width,
            height: max(minPanelHeight, currentFrame.height - 8)
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            context.allowsImplicitAnimation = true
            self.isProgrammaticMove = true
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            guard let self = self, let panel = panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(currentFrame, display: true)
            self.isProgrammaticMove = false
            self.isClosingPanel = false
            self.restoreFocusIfNeeded(afterClosing: panel)
        }
    }

    private func restoreFocusIfNeeded(afterClosing panel: NSPanel) {
        let otherWindowsVisible = NSApp.windows.contains { $0 != panel && $0.isVisible }
        if !otherWindowsVisible {
            if let previousApp = previousApp {
                previousApp.activate(options: [])
                self.previousApp = nil
            } else {
                NSApp.hide(nil)
            }
        }
    }

    private func clampOrigin(_ origin: NSPoint, panelSize: CGSize, visibleFrame: NSRect) -> NSPoint
    {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)

        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
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

    override func cancelOperation(_ sender: Any?) {
        QuickAIManager.shared.closePanel(usingClickOutsideSemantics: false)
    }

    override func resignKey() {
        super.resignKey()
        QuickAIManager.shared.closePanel(usingClickOutsideSemantics: true)
    }
}
