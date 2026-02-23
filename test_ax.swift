import Cocoa
import ApplicationServices

let helper = AXUIElementCreateSystemWide()

var focusedElement: AnyObject?
let result = AXUIElementCopyAttributeValue(helper, kAXFocusedUIElementAttribute as CFString, &focusedElement)

if result == .success, let element = focusedElement as? AXUIElement {
    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    print("Role:", role ?? "nil")
    
    var isSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable)
    print("Value Settable: \(isSettable.boolValue)")
    
    var isSelectedSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSelectedSettable)
    print("SelectedText Settable: \(isSelectedSettable.boolValue)")
} else {
    print("Failed to get focused element")
}
