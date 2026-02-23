import AppKit
import CoreGraphics

/// Inserts accepted autocomplete text into the active application.
/// Tries AXUIElement direct insertion first, falls back to clipboard paste.
class TextInjector {
    static let shared = TextInjector()

    private init() {}

    /// Insert text at the current cursor position in the focused app.
    /// - Parameter text: The text to insert.
    func insertText(_ text: String) {
        // Try AX-based insertion first (preferred — no side effects)
        if insertViaAccessibility(text) {
            return
        }

        // Fallback: clipboard-based paste
        insertViaClipboard(text)
    }

    // MARK: - AX Insertion

    /// Directly inserts text by setting `kAXSelectedTextAttribute` on the focused element.
    /// This is the fastest method and doesn't disturb the clipboard.
    private func insertViaAccessibility(_ text: String) -> Bool {
        let helper = AccessibilityHelper.shared
        
        // Bypass accessibility insertion for the Messages app
        // because it accepts the insertion silently without updating the UI.
        if helper.getFrontmostAppBundleIdentifier() == "com.apple.MobileSMS" {
            return false
        }
        
        guard let element = helper.getFocusedElement() else { return false }
        return helper.insertTextAtCursor(element, text: text)
    }

    // MARK: - Clipboard Paste Fallback

    /// Inserts text by temporarily copying it to the clipboard,
    /// simulating Cmd+V, then restoring the original clipboard contents.
    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore original clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Only restore if nothing else has written to the clipboard
            if pasteboard.changeCount == previousChangeCount + 1 {
                pasteboard.clearContents()
                if let prev = previousContents {
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }

    // MARK: - CGEvent Simulation

    /// Simulates a Cmd+V keystroke to paste from clipboard.
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code for 'V' is 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Types text character-by-character using CGEvents.
    /// Slower than clipboard but doesn't disturb it.
    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)

        for scalar in text.unicodeScalars {
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            var char = UniChar(scalar.value)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            // Small delay between characters to prevent drops
            usleep(5000)  // 5ms
        }
    }
}
