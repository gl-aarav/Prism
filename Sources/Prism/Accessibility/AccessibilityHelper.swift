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
    func getTextFromElement(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )
        guard result == .success else { return nil }
        return value as? String
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
}
