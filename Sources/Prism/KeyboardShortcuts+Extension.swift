import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleQuickAI = Self("toggleQuickAI", default: .init(.space, modifiers: [.control]))
    static let toggleAIAutocomplete = Self(
        "toggleAIAutocomplete", default: .init(.c, modifiers: [.control, .option]))
    static let toggleWebOverlay = Self(
        "toggleWebOverlay", default: .init(.space, modifiers: [.control, .shift]))
    static let toggleQuickTools = Self(
        "toggleQuickTools", default: .init(.t, modifiers: [.control, .shift]))
}
