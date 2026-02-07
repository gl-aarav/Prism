import Foundation
import SwiftUI

// MARK: - Slash Command Model

struct SlashCommand: Identifiable, Codable, Equatable {
    var id = UUID()
    var trigger: String  // e.g. "/summarize"
    var expansion: String  // what it expands to
    var isBuiltIn: Bool  // built-in commands can't be deleted

    /// Display name without the leading "/"
    var displayName: String {
        trigger.hasPrefix("/") ? String(trigger.dropFirst()) : trigger
    }
}

// MARK: - Slash Command Manager

class SlashCommandManager: ObservableObject {
    static let shared = SlashCommandManager()

    @Published var commands: [SlashCommand] = []

    private let saveKey = "SlashCommands"

    private init() {
        loadCommands()
        ensureBuiltInCommands()
    }

    // MARK: - Built-in Commands

    static let builtInCommands: [SlashCommand] = [
        SlashCommand(
            trigger: "/summarize",
            expansion: "Please summarize the above conversation concisely.",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/explain",
            expansion: "Please explain this in simple terms:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/translate",
            expansion: "Please translate the following text to English:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/fix",
            expansion: "Please fix any grammar and spelling errors in the following text:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/code",
            expansion: "Please write code for the following:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/rewrite",
            expansion: "Please rewrite the following text to be more clear and professional:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/bullets",
            expansion: "Please convert the following into bullet points:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/eli5",
            expansion: "Explain this like I'm 5 years old:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/pros-cons",
            expansion: "List the pros and cons of the following:",
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/clear",
            expansion: "",  // special: handled by the app to clear chat
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/quit",
            expansion: "",  // special: handled by the app to quit Prism
            isBuiltIn: true
        ),
        SlashCommand(
            trigger: "/new",
            expansion: "",  // special: creates a new chat session
            isBuiltIn: true
        ),
    ]

    /// Action commands that don't expand to text but trigger app actions
    static let actionCommands: Set<String> = ["/clear", "/quit", "/new"]

    // MARK: - Persistence

    private func loadCommands() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
            let decoded = try? JSONDecoder().decode([SlashCommand].self, from: data)
        else {
            commands = Self.builtInCommands
            return
        }
        commands = decoded
    }

    private func saveCommands() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: saveKey)
        }
    }

    private func ensureBuiltInCommands() {
        let existingTriggers = Set(commands.map(\.trigger))
        for cmd in Self.builtInCommands where !existingTriggers.contains(cmd.trigger) {
            commands.append(cmd)
        }
        saveCommands()
    }

    // MARK: - CRUD

    func addCommand(trigger: String, expansion: String) {
        let normalized = trigger.hasPrefix("/") ? trigger : "/\(trigger)"
        guard !normalized.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // Don't allow duplicates
        if commands.contains(where: { $0.trigger.lowercased() == normalized.lowercased() }) {
            return
        }
        let cmd = SlashCommand(
            trigger: normalized.lowercased(), expansion: expansion, isBuiltIn: false)
        commands.append(cmd)
        saveCommands()
    }

    func updateCommand(id: UUID, trigger: String, expansion: String) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        let normalized = trigger.hasPrefix("/") ? trigger : "/\(trigger)"
        commands[index].trigger = normalized.lowercased()
        commands[index].expansion = expansion
        saveCommands()
    }

    func deleteCommand(id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        guard !commands[index].isBuiltIn else { return }  // can't delete built-ins
        commands.remove(at: index)
        saveCommands()
    }

    // MARK: - Autocomplete

    /// Returns matching commands for the current input prefix
    func matches(for input: String) -> [SlashCommand] {
        let trimmed = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("/") else { return [] }
        if trimmed == "/" {
            return commands.sorted { $0.trigger < $1.trigger }
        }
        return
            commands
            .filter { $0.trigger.lowercased().hasPrefix(trimmed) }
            .sorted { $0.trigger < $1.trigger }
    }

    /// Check if a text is an exact command match
    func exactMatch(for input: String) -> SlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return commands.first { $0.trigger.lowercased() == trimmed }
    }

    /// Returns true if this is a special action command (not text expansion)
    func isActionCommand(_ trigger: String) -> Bool {
        Self.actionCommands.contains(trigger.lowercased())
    }
}
