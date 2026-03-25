import Foundation
import SwiftUI

struct APIProviderDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    let storageKeyPrefix: String
    let accountType: ProviderType
    let presetModels: [String]
    let defaultModel: String
    let customPlaceholder: String
    let fetchStrategy: APIModelFetchStrategy
    let presetModeLabel: String
}

enum APIModelFetchStrategy: Hashable {
    case openAICompatible(baseURL: String)
    case anthropic
    case gemini
    case none
}

enum APIProviderRegistry {
    static let providers: [APIProviderDefinition] = [
        APIProviderDefinition(
            id: "gemini",
            title: "Gemini",
            icon: "sparkles",
            tint: .cyan,
            storageKeyPrefix: "Gemini",
            accountType: .gemini,
            presetModels: GeminiModelManager.shared.availableModels,
            defaultModel: "gemini-2.5-flash",
            customPlaceholder: "gemini-3.1-pro-preview",
            fetchStrategy: .gemini,
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "chatgpt",
            title: "ChatGPT",
            icon: "bubble.left.and.bubble.right.fill",
            tint: .blue,
            storageKeyPrefix: "ChatGPT",
            accountType: .chatgpt,
            presetModels: ["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4o", "o3"],
            defaultModel: "gpt-5",
            customPlaceholder: "gpt-4.1-mini",
            fetchStrategy: .openAICompatible(baseURL: "https://api.openai.com"),
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "claude",
            title: "Claude",
            icon: "brain.head.profile",
            tint: .orange,
            storageKeyPrefix: "Claude",
            accountType: .claude,
            presetModels: [
                "claude-opus-4-1-20250805", "claude-sonnet-4-20250514",
                "claude-3-7-sonnet-20250219", "claude-3-5-haiku-20241022",
            ],
            defaultModel: "claude-sonnet-4-20250514",
            customPlaceholder: "claude-sonnet-4-20250514",
            fetchStrategy: .anthropic,
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "grok",
            title: "Grok",
            icon: "bolt.horizontal.fill",
            tint: .pink,
            storageKeyPrefix: "Grok",
            accountType: .grok,
            presetModels: ["grok-4", "grok-3", "grok-3-mini", "grok-2-vision-1212"],
            defaultModel: "grok-4",
            customPlaceholder: "grok-beta",
            fetchStrategy: .openAICompatible(baseURL: "https://api.x.ai"),
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "kimi",
            title: "Kimi",
            icon: "moon.stars.fill",
            tint: .indigo,
            storageKeyPrefix: "Kimi",
            accountType: .kimi,
            presetModels: ["kimi-k2-0711-preview", "kimi-k1.5", "moonshot-v1-128k"],
            defaultModel: "kimi-k2-0711-preview",
            customPlaceholder: "moonshot-v1-32k",
            fetchStrategy: .openAICompatible(baseURL: "https://api.moonshot.cn"),
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "mistral",
            title: "Mistral",
            icon: "wind",
            tint: .mint,
            storageKeyPrefix: "Mistral",
            accountType: .mistral,
            presetModels: [
                "mistral-large-latest", "mistral-medium-latest", "mistral-small-latest",
                "codestral-latest", "ministral-8b-latest",
            ],
            defaultModel: "mistral-large-latest",
            customPlaceholder: "mistral-saba-latest",
            fetchStrategy: .openAICompatible(baseURL: "https://api.mistral.ai"),
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "nvidia",
            title: "NVIDIA",
            icon: "bolt.fill",
            tint: .green,
            storageKeyPrefix: "Nvidia",
            accountType: .nvidia,
            presetModels: NvidiaModelManager.shared.availableModels,
            defaultModel: "meta/llama-3.1-70b-instruct",
            customPlaceholder: "meta/llama-3.1-405b-instruct",
            fetchStrategy: .none,
            presetModeLabel: "Choose Preset"
        ),
        APIProviderDefinition(
            id: "customapi",
            title: "Custom API",
            icon: "slider.horizontal.3",
            tint: .teal,
            storageKeyPrefix: "CustomAPI",
            accountType: .customapi,
            presetModels: [],
            defaultModel: "",
            customPlaceholder: "your-model-id",
            fetchStrategy: .none,
            presetModeLabel: "Use Custom Model"
        ),
    ]

    static func provider(for id: String) -> APIProviderDefinition? {
        providers.first(where: { $0.id == id })
    }
}

final class APIProviderModelStore: ObservableObject {
    static let shared = APIProviderModelStore()

    private let defaults = UserDefaults.standard

    func fetchedModels(for provider: APIProviderDefinition) -> [String] {
        loadArray(forKey: "\(provider.storageKeyPrefix)FetchedModels")
    }

    func customModels(for provider: APIProviderDefinition) -> [String] {
        loadArray(forKey: "\(provider.storageKeyPrefix)CustomModels")
    }

    func addedPresets(for provider: APIProviderDefinition) -> [String] {
        loadArray(forKey: "\(provider.storageKeyPrefix)AddedPresetModels")
    }

    func combinedModels(for provider: APIProviderDefinition) -> [String] {
        (provider.presetModels + fetchedModels(for: provider) + addedPresets(for: provider)
            + customModels(for: provider)).unique()
    }

    func enabledModels(for provider: APIProviderDefinition) -> [String] {
        let combined = combinedModels(for: provider)
        let stored = loadArray(forKey: "\(provider.storageKeyPrefix)EnabledModels")
        if stored.isEmpty {
            return combined
        }
        return stored.filter { combined.contains($0) }
    }

    func selectedModel(for provider: APIProviderDefinition) -> String {
        let key = "\(provider.storageKeyPrefix)SelectedModel"
        let stored = defaults.string(forKey: key) ?? ""
        if !stored.isEmpty {
            return stored
        }
        return provider.defaultModel.isEmpty ? combinedModels(for: provider).first ?? "" : provider.defaultModel
    }

    func setSelectedModel(_ model: String, for provider: APIProviderDefinition) {
        defaults.set(model, forKey: "\(provider.storageKeyPrefix)SelectedModel")
        ensureModelEnabled(model, for: provider)
        objectWillChange.send()
    }

    func toggleEnabled(_ model: String, for provider: APIProviderDefinition) {
        var current = enabledModels(for: provider)
        if let index = current.firstIndex(of: model) {
            current.remove(at: index)
        } else {
            current.append(model)
        }
        saveArray(current.unique(), forKey: "\(provider.storageKeyPrefix)EnabledModels")
        if !current.contains(selectedModel(for: provider)) {
            defaults.set(current.first ?? "", forKey: "\(provider.storageKeyPrefix)SelectedModel")
        }
        objectWillChange.send()
    }

    func selectAll(for provider: APIProviderDefinition) {
        saveArray(combinedModels(for: provider), forKey: "\(provider.storageKeyPrefix)EnabledModels")
    }

    func unselectAll(for provider: APIProviderDefinition) {
        saveArray([], forKey: "\(provider.storageKeyPrefix)EnabledModels")
        defaults.set("", forKey: "\(provider.storageKeyPrefix)SelectedModel")
    }

    func addCustomModel(_ model: String, for provider: APIProviderDefinition) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = customModels(for: provider)
        if !current.contains(trimmed) {
            current.append(trimmed)
            saveArray(current, forKey: "\(provider.storageKeyPrefix)CustomModels")
            ensureModelEnabled(trimmed, for: provider)
            if selectedModel(for: provider).isEmpty { setSelectedModel(trimmed, for: provider) }
            objectWillChange.send()
        }
    }

    func addPresetModel(_ model: String, for provider: APIProviderDefinition) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let builtIn = provider.presetModels.contains(trimmed)
        if !builtIn {
            var current = addedPresets(for: provider)
            if !current.contains(trimmed) {
                current.append(trimmed)
                saveArray(current, forKey: "\(provider.storageKeyPrefix)AddedPresetModels")
            }
        }
        ensureModelEnabled(trimmed, for: provider)
        if selectedModel(for: provider).isEmpty { setSelectedModel(trimmed, for: provider) }
        objectWillChange.send()
    }

    func removeModel(_ model: String, for provider: APIProviderDefinition) {
        var didChange = false

        var custom = customModels(for: provider)
        if let index = custom.firstIndex(of: model) {
            custom.remove(at: index)
            saveArray(custom, forKey: "\(provider.storageKeyPrefix)CustomModels")
            didChange = true
        }

        var presets = addedPresets(for: provider)
        if let index = presets.firstIndex(of: model) {
            presets.remove(at: index)
            saveArray(presets, forKey: "\(provider.storageKeyPrefix)AddedPresetModels")
            didChange = true
        }

        if selectedModel(for: provider) == model {
            setSelectedModel(combinedModels(for: provider).first ?? provider.defaultModel, for: provider)
        } else if didChange {
            objectWillChange.send()
        }
    }

    func replaceFetchedModels(_ models: [String], for provider: APIProviderDefinition) {
        let cleaned = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
            .unique()
        saveArray(cleaned, forKey: "\(provider.storageKeyPrefix)FetchedModels")

        let combined = combinedModels(for: provider)
        let currentEnabled = enabledModels(for: provider)
        if currentEnabled.isEmpty && !combined.isEmpty {
            saveArray(combined, forKey: "\(provider.storageKeyPrefix)EnabledModels")
        } else {
            let filtered = currentEnabled.filter { combined.contains($0) }
            saveArray(filtered, forKey: "\(provider.storageKeyPrefix)EnabledModels")
        }

        let currentSelected = selectedModel(for: provider)
        if currentSelected.isEmpty || !combined.contains(currentSelected) {
            defaults.set(combined.first ?? provider.defaultModel, forKey: "\(provider.storageKeyPrefix)SelectedModel")
        }
        objectWillChange.send()
    }

    func isBuiltInPreset(_ model: String, for provider: APIProviderDefinition) -> Bool {
        provider.presetModels.contains(model)
    }

    private func loadArray(forKey key: String) -> [String] {
        guard let data = defaults.string(forKey: key)?.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func saveArray(_ array: [String], forKey key: String) {
        if let data = try? JSONEncoder().encode(array),
            let json = String(data: data, encoding: .utf8)
        {
            defaults.set(json, forKey: key)
        }
        objectWillChange.send()
    }

    private func ensureModelEnabled(_ model: String, for provider: APIProviderDefinition) {
        var current = enabledModels(for: provider)
        if !current.contains(model) {
            current.append(model)
            saveArray(current.unique(), forKey: "\(provider.storageKeyPrefix)EnabledModels")
        }
    }
}

final class APIModelFetcher {
    static let shared = APIModelFetcher()

    private let session = URLSession.shared

    func fetchModels(
        for provider: APIProviderDefinition,
        apiKey: String,
        endpointOverride: String = ""
    ) async throws -> [String] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return [] }

        switch provider.fetchStrategy {
        case let .openAICompatible(baseURL):
            let origin = endpointOverride.isEmpty ? baseURL : endpointOverride
            let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models")!
            var request = URLRequest(url: url)
            request.addValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data)
            return response.data.map(\.id)

        case .anthropic:
            let url = URL(string: "https://api.anthropic.com/v1/models")!
            var request = URLRequest(url: url)
            request.addValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(AnthropicModelListResponse.self, from: data)
            return response.data.map(\.id)

        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: trimmedKey)]
            let (data, _) = try await session.data(from: components.url!)
            let response = try JSONDecoder().decode(GeminiModelListResponse.self, from: data)
            return response.models.map { $0.name.replacingOccurrences(of: "models/", with: "") }

        case .none:
            return []
        }
    }
}

private struct OpenAIModelListResponse: Decodable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    let id: String
}

private struct AnthropicModelListResponse: Decodable {
    let data: [AnthropicModel]
}

private struct AnthropicModel: Decodable {
    let id: String
}

private struct GeminiModelListResponse: Decodable {
    let models: [GeminiModel]
}

private struct GeminiModel: Decodable {
    let name: String
}
