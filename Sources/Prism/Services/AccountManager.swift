import Foundation
import SwiftUI

// MARK: - Account Configuration

enum ProviderType: String {
    case gemini, ollama, copilot
}

struct ProviderAccount: Identifiable, Codable, Equatable {
    var id = UUID()
    var providerType: String  // "gemini", "ollama", "copilot"
    var displayName: String  // User-customizable label
    var apiKey: String  // API key or token
    var endpoint: String  // URL endpoint (for Ollama)
    var isActive: Bool  // Whether this account is enabled

    static func geminiAccount(name: String = "Gemini", apiKey: String) -> ProviderAccount {
        ProviderAccount(
            providerType: "gemini", displayName: name, apiKey: apiKey, endpoint: "", isActive: true)
    }

    static func ollamaAccount(name: String = "Ollama", endpoint: String, apiKey: String = "")
        -> ProviderAccount
    {
        ProviderAccount(
            providerType: "ollama", displayName: name, apiKey: apiKey, endpoint: endpoint,
            isActive: true)
    }

    static func copilotAccount(name: String = "GitHub Copilot") -> ProviderAccount {
        ProviderAccount(
            providerType: "copilot", displayName: name, apiKey: "", endpoint: "", isActive: true)
    }
}

// MARK: - Multi-Account Manager

class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published var accounts: [ProviderAccount] = []

    private let saveKey = "ProviderAccounts"

    private init() {
        loadAccounts()
        migrateFromLegacy()
    }

    /// Migrate existing single API key / Ollama URL from AppStorage
    private func migrateFromLegacy() {
        let defaults = UserDefaults.standard
        var didMigrate = false

        // Migrate legacy Gemini key
        if let geminiKey = defaults.string(forKey: "GeminiKey"), !geminiKey.isEmpty {
            if !accounts.contains(where: { $0.providerType == "gemini" }) {
                accounts.append(.geminiAccount(apiKey: geminiKey))
                didMigrate = true
            }
        }

        // Migrate legacy Ollama URL
        let ollamaURL = defaults.string(forKey: "OllamaURL") ?? "http://localhost:11434"
        let ollamaAPIKey = defaults.string(forKey: "OllamaAPIKey") ?? ""
        if !accounts.contains(where: { $0.providerType == "ollama" }) {
            accounts.append(.ollamaAccount(endpoint: ollamaURL, apiKey: ollamaAPIKey))
            didMigrate = true
        }

        // Migrate GitHub Copilot if signed in
        // Check Keychain directly to avoid circular singleton initialization with GitHubCopilotService
        if hasCopilotTokenInKeychain() {
            if !accounts.contains(where: { $0.providerType == "copilot" }) {
                accounts.append(.copilotAccount())
                didMigrate = true
            }
        }

        if didMigrate {
            saveAccounts()
        }
    }

    /// Check Keychain directly for a Copilot token without touching GitHubCopilotService.shared
    private func hasCopilotTokenInKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prism.github-copilot",
            kSecAttrAccount as String: "GitHubCopilotToken",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return false }
        return true
    }

    // MARK: - CRUD

    func addAccount(_ account: ProviderAccount) {
        accounts.append(account)
        saveAccounts()
        syncLegacySettings()
    }

    func removeAccount(id: UUID) {
        accounts.removeAll { $0.id == id }
        saveAccounts()
        syncLegacySettings()
    }

    func updateAccount(_ account: ProviderAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            saveAccounts()
            syncLegacySettings()
        }
    }

    func renameAccount(id: UUID, newName: String) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].displayName = newName
            saveAccounts()
        }
    }

    func updateAccount(id: UUID, apiKey: String? = nil, endpoint: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            if let apiKey = apiKey { accounts[index].apiKey = apiKey }
            if let endpoint = endpoint { accounts[index].endpoint = endpoint }
            saveAccounts()
            syncLegacySettings()
        }
    }

    func addAccount(
        providerType: ProviderType, displayName: String, apiKey: String = "", endpoint: String = ""
    ) {
        let account = ProviderAccount(
            providerType: providerType.rawValue,
            displayName: displayName,
            apiKey: apiKey,
            endpoint: endpoint,
            isActive: true
        )
        accounts.append(account)
        saveAccounts()
        syncLegacySettings()
    }

    // MARK: - Queries

    func geminiAccounts() -> [ProviderAccount] {
        accounts.filter { $0.providerType == "gemini" && $0.isActive }
    }

    func ollamaAccounts() -> [ProviderAccount] {
        accounts.filter { $0.providerType == "ollama" && $0.isActive }
    }

    func copilotAccounts() -> [ProviderAccount] {
        accounts.filter { $0.providerType == "copilot" && $0.isActive }
    }

    /// Returns true if there are any configured & active accounts for a provider type
    func hasActiveAccount(type: String) -> Bool {
        switch type {
        case "gemini":
            return geminiAccounts().contains(where: { !$0.apiKey.isEmpty })
        case "ollama":
            return !ollamaAccounts().isEmpty
        case "copilot":
            return GitHubCopilotService.shared.isAuthenticated
        default:
            return false
        }
    }

    /// Get display name for a provider in the dropdown
    func providerDisplayName(type: String, index: Int) -> String {
        let accts: [ProviderAccount]
        switch type {
        case "gemini": accts = geminiAccounts()
        case "ollama": accts = ollamaAccounts()
        case "copilot": accts = copilotAccounts()
        default: return type
        }
        guard index < accts.count else { return type }
        return accts[index].displayName
    }

    // MARK: - Persistence

    private func saveAccounts() {
        // Don't persist raw API keys in UserDefaults – store structure without secrets
        // For simplicity here we encode everything, but in production use Keychain for API keys.
        if let data = try? JSONEncoder().encode(accounts),
            let json = String(data: data, encoding: .utf8)
        {
            UserDefaults.standard.set(json, forKey: saveKey)
        }
    }

    private func loadAccounts() {
        guard let json = UserDefaults.standard.string(forKey: saveKey),
            let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([ProviderAccount].self, from: data)
        else {
            return
        }
        accounts = decoded
    }

    /// Sync the first account of each type back to legacy AppStorage keys
    /// so existing code continues to work
    func syncLegacySettings() {
        let defaults = UserDefaults.standard

        if let firstGemini = geminiAccounts().first {
            defaults.set(firstGemini.apiKey, forKey: "GeminiKey")
        }

        if let firstOllama = ollamaAccounts().first {
            defaults.set(firstOllama.endpoint, forKey: "OllamaURL")
            defaults.set(firstOllama.apiKey, forKey: "OllamaAPIKey")
        }
    }
}
