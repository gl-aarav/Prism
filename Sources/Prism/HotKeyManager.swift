import AppKit
import Carbon

// MARK: - Hotkey Configuration Types

struct HotkeyModifiers: OptionSet {
    let rawValue: Int
    
    static let control = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let command = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)
    
    /// Convert to Carbon modifier flags
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
    
    /// Human-readable string
    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option) { parts.append("⌥") }
        if contains(.shift) { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
    
    /// Initialize from stored integer
    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

// Common key codes
enum HotkeyKeyCode: Int, CaseIterable {
    case space = 0x31
    case returnKey = 0x24
    case tab = 0x30
    case escape = 0x35
    case a = 0x00
    case b = 0x0B
    case c = 0x08
    case d = 0x02
    case e = 0x0E
    case f = 0x03
    case g = 0x05
    case h = 0x04
    case i = 0x22
    case j = 0x26
    case k = 0x28
    case l = 0x25
    case m = 0x2E
    case n = 0x2D
    case o = 0x1F
    case p = 0x23
    case q = 0x0C
    case r = 0x0F
    case s = 0x01
    case t = 0x11
    case u = 0x20
    case v = 0x09
    case w = 0x0D
    case x = 0x07
    case y = 0x10
    case z = 0x06
    
    var displayString: String {
        switch self {
        case .space: return "Space"
        case .returnKey: return "Return"
        case .tab: return "Tab"
        case .escape: return "Escape"
        default: return String(describing: self).uppercased()
        }
    }
    
    static func fromRawValue(_ value: Int) -> HotkeyKeyCode? {
        return HotkeyKeyCode(rawValue: value)
    }
}

class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?
    
    // Published for UI binding
    @Published var currentModifiers: HotkeyModifiers = .control
    @Published var currentKeyCode: HotkeyKeyCode = .space
    
    // UserDefaults keys
    private let modifiersKey = "QuickAIHotkeyModifiers"
    private let keyCodeKey = "QuickAIHotkeyKeyCode"

    private init() {
        // Load saved settings
        let savedModifiers = UserDefaults.standard.integer(forKey: modifiersKey)
        if savedModifiers != 0 {
            currentModifiers = HotkeyModifiers(rawValue: savedModifiers)
        } else {
            // Default: Control
            currentModifiers = .control
        }
        
        let savedKeyCode = UserDefaults.standard.integer(forKey: keyCodeKey)
        if savedKeyCode != 0, let keyCode = HotkeyKeyCode.fromRawValue(savedKeyCode) {
            currentKeyCode = keyCode
        } else {
            // Default: Space
            currentKeyCode = .space
        }
    }
    
    /// Save current settings to UserDefaults
    private func saveSettings() {
        UserDefaults.standard.set(currentModifiers.rawValue, forKey: modifiersKey)
        UserDefaults.standard.set(currentKeyCode.rawValue, forKey: keyCodeKey)
    }
    
    /// Update hotkey configuration and re-register
    func updateHotkey(modifiers: HotkeyModifiers, keyCode: HotkeyKeyCode) {
        currentModifiers = modifiers
        currentKeyCode = keyCode
        saveSettings()
        reRegister()
    }
    
    /// Get human-readable hotkey string
    var hotkeyDisplayString: String {
        return "\(currentModifiers.displayString)\(currentKeyCode.displayString)"
    }

    func register() {
        // Install event handler if not already installed
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, _) -> OSStatus in
                    DispatchQueue.main.async {
                        HotKeyManager.shared.onTrigger?()
                    }
                    return noErr
                }, 1, &eventType, nil, &eventHandlerRef)
        }

        // Register hotkey with current settings
        let keyCode = UInt32(currentKeyCode.rawValue)
        let modifiers = currentModifiers.carbonFlags

        let hotKeyID = EventHotKeyID(signature: OSType(1111), id: 1)

        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status != noErr {
            print("Failed to register hotkey: \(status)")
        } else {
            print("Registered hotkey: \(hotkeyDisplayString)")
        }
    }

    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
    
    /// Re-register hotkey with new settings
    func reRegister() {
        unregister()
        register()
    }
}
