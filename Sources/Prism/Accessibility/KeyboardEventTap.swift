import AppKit
import CoreGraphics

/// Global keyboard event monitor using a CGEvent tap.
/// Intercepts Tab ONLY when a suggestion is visible,
/// otherwise passes them through normally.
class KeyboardEventTap {
    static let shared = KeyboardEventTap()

    /// Callback: returns `true` if a suggestion is currently visible.
    var isSuggestionVisible: (() -> Bool)?

    /// Callbacks for key actions.
    var onTab: (() -> Void)?        // Accept entire suggestion/next word

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isInstalled = false

    private init() {}

    // MARK: - Setup

    func install() {
        guard !isInstalled else { return }

        // Create the event tap
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: keyboardEventCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            print("[KeyboardEventTap] Failed to create event tap. Check Accessibility/Input Monitoring permissions.")
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isInstalled = true
        print("[KeyboardEventTap] Installed successfully.")
    }

    func uninstall() {
        guard isInstalled else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isInstalled = false
        print("[KeyboardEventTap] Uninstalled.")
    }

    // MARK: - Event Handling

    fileprivate func handleKeyEvent(_ event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let eventType = event.type

        // Only intercept keyDown events (let keyUp pass through)
        guard eventType == .keyDown else { return event }

        // Only intercept when a suggestion is visible
        guard let isVisible = isSuggestionVisible, isVisible() else { return event }

        // Don't intercept if any modifier keys are held (allow Shift+Tab, Cmd+Right, etc.)
        let flags = event.flags
        let hasModifiers = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
        if hasModifiers { return event }

        switch keyCode {
        case 48:  // Tab → accept entire suggestion
            DispatchQueue.main.async { [weak self] in
                self?.onTab?()
            }
            return nil  // Suppress the event


        default:
            return event  // Pass through everything else
        }
    }
}

// MARK: - C Callback

private func keyboardEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled events (system can disable the tap)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let tap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            if let machPort = tap.eventTap {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let tap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()

    if let result = tap.handleKeyEvent(event) {
        return Unmanaged.passRetained(result)
    }

    // Event was consumed (suppressed)
    return nil
}
