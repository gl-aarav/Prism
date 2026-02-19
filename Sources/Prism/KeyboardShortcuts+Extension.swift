import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleQuickAI = Self("toggleQuickAI", default: .init(.space, modifiers: [.control]))
    static let toggleCotypist = Self("toggleCotypist", default: .init(.c, modifiers: [.control, .option]))
}
