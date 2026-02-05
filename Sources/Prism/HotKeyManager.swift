import AppKit
import KeyboardShortcuts
import SwiftUI

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    var onTrigger: (() -> Void)?

    init() {
        // We listen for the shortcut here.
        // Whether the action is performed depends on the onTrigger callback implementation.
        KeyboardShortcuts.onKeyUp(for: .toggleQuickAI) { [weak self] in
            DispatchQueue.main.async {
                self?.onTrigger?()
            }
        }
    }
    
    func register() {
        // Initialization handled in init
    }
}
