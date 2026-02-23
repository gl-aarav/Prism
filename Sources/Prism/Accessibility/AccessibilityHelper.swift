import AppKit
import ApplicationServices

/// Singleton wrapping the macOS Accessibility (AXUIElement) API.
/// Provides methods to read text, cursor position, and insertion point
/// frame from the currently focused element in any application.
class AccessibilityHelper {
    static let shared = AccessibilityHelper()
    private let systemWideElement: AXUIElement

    private init() {
        systemWideElement = AXUIElementCreateSystemWide()
    }

    // MARK: - Permission

    /// Check (and optionally prompt for) Accessibility permission.
    /// Returns `true` if the app is already trusted.
    @discardableResult
    func checkAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Focused Element

    /// Returns the currently focused AXUIElement (where the cursor sits).
    func getFocusedElement() -> AXUIElement? {
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success else { return nil }
        return (focusedElement as! AXUIElement)
    }

    /// Returns the focused application's AXUIElement.
    func getFocusedApp() -> AXUIElement? {
        var focusedApp: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard result == .success else { return nil }
        return (focusedApp as! AXUIElement)
    }

    // MARK: - Text Reading

    /// Reads the `kAXValueAttribute` (text content) from the given element.
    /// Falls back to kAXSelectedTextAttribute context for Electron/Chromium apps.
    func getTextFromElement(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        if result == .success, let text = value as? String {
            return text
        }

        // Fallback for Electron/Chromium contentEditable elements:
        // Try reading the full text via AXStringForRange if numberOfCharacters is available.
        var countValue: AnyObject?
        let countResult = AXUIElementCopyAttributeValue(
            element,
            "AXNumberOfCharacters" as CFString,
            &countValue
        )
        
        // If count is available, use it. Otherwise, assume a reasonably large number (e.g. 100000)
        // for Electron apps that don't report count but support AXStringForRange
        let count = (countResult == .success && countValue is Int) ? (countValue as! Int) : 100000
        
        if count > 0 {
            var cfRange = CFRange(location: 0, length: count)
            guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
            var stringValue: AnyObject?
            let strResult = AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXStringForRange" as CFString,
                rangeValue,
                &stringValue
            )
            if strResult == .success, let text = stringValue as? String {
                return text
            }
        }

        return nil
    }

    /// Returns the role of the element (e.g. "AXTextArea", "AXTextField").
    func getRole(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value as? String
    }

    // MARK: - Cursor Position

    /// Returns the selected text range as a CFRange.
    func getSelectedRange(_ element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard result == .success else { return nil }

        var range = CFRange(location: 0, length: 0)
        if AXValueGetValue(value as! AXValue, .cfRange, &range) {
            return range
        }
        return nil
    }

    /// Returns the selected text string.
    func getSelectedText(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value as? String
    }

    /// Returns the screen-space bounding rect of the insertion point
    /// in raw AX/CG coordinates (origin at top-left of primary display).
    /// The caller is responsible for converting to AppKit coordinates.
    func getInsertionPointFrame(_ element: AXUIElement) -> NSRect? {
        // First get the selected text range (cursor position)
        guard let range = getSelectedRange(element) else { return nil }

        // Create an AXValue for the range
        var cfRange = CFRange(location: range.location, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }

        // Get the bounds for that range
        var boundsValue: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )

        if result == .success, let axValue = boundsValue {
            var rect = CGRect.zero
            if AXValueGetValue(axValue as! AXValue, .cgRect, &rect) {
                // Return raw AX coordinates — origin at top-left of primary display
                return NSRect(origin: rect.origin, size: rect.size)
            }
        }

        return nil
    }

    // MARK: - Text Manipulation

    /// Sets the value attribute on the element (replaces all text).
    @discardableResult
    func setValue(_ element: AXUIElement, text: String) -> Bool {
        let result = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    /// Sets the selected text range on the element.
    @discardableResult
    func setSelectedRange(_ element: AXUIElement, location: Int, length: Int = 0) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        return result == .success
    }

    /// Inserts text at the current insertion point by setting selectedText.
    @discardableResult
    func insertTextAtCursor(_ element: AXUIElement, text: String) -> Bool {
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Frontmost App Info

    /// Returns the bundle identifier of the frontmost application.
    func getFrontmostAppBundleIdentifier() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: - Element Properties

    /// Checks if the element's value attribute is settable (editable).
    func isElementEditable(_ element: AXUIElement) -> Bool {
        var isSettable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        if result == .success && isSettable.boolValue { return true }

        // Fallback: Electron/Chromium contentEditable divs may not report kAXValueAttribute
        // as settable, but do support kAXSelectedTextAttribute.
        var isSelectedSettable: DarwinBoolean = false
        let selResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSelectedSettable
        )
        return selResult == .success && isSelectedSettable.boolValue
    }
}
