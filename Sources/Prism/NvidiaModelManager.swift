import Foundation
import SwiftUI

class NvidiaModelManager: ObservableObject {
    static let shared = NvidiaModelManager()

    @AppStorage("NvidiaFavorites") private var favoritesJSON: String = "[]"
    @AppStorage("NvidiaCustomModels") private var customModelsJSON: String = "[]"

    @Published var availableModels: [String] = [
        // Reasoning
        "moonshotai/kimi-k2.5",
        "deepseek-ai/deepseek-r1",
        "qwen/qwq-32b",
        // Chat / General
        "nvidia/llama-3.3-nemotron-super-49b-v1",
        "nvidia/llama-3.1-nemotron-ultra-253b-v1",
        "meta/llama-3.3-70b-instruct",
        "meta/llama-3.1-405b-instruct",
        "meta/llama-3.1-70b-instruct",
        "meta/llama-3.1-8b-instruct",
        // Qwen
        "qwen/qwen2.5-72b-instruct",
        "qwen/qwen2.5-7b-instruct",
        // Mistral
        "mistralai/mistral-large-2-instruct",
        "mistralai/mixtral-8x22b-instruct-v0.1",
        // Code
        "qwen/qwen2.5-coder-32b-instruct",
        // Google
        "google/gemma-2-27b-it",
        "google/gemma-2-9b-it",
        // Microsoft
        "microsoft/phi-4",
        "microsoft/phi-3.5-mini-instruct",
    ]

    static let displayNames: [String: String] = [
        "moonshotai/kimi-k2.5": "Kimi K2.5",
        "deepseek-ai/deepseek-r1": "DeepSeek R1",
        "qwen/qwq-32b": "QwQ 32B",
        "nvidia/llama-3.3-nemotron-super-49b-v1": "Nemotron Super 49B",
        "nvidia/llama-3.1-nemotron-ultra-253b-v1": "Nemotron Ultra 253B",
        "meta/llama-3.3-70b-instruct": "Llama 3.3 70B",
        "meta/llama-3.1-405b-instruct": "Llama 3.1 405B",
        "meta/llama-3.1-70b-instruct": "Llama 3.1 70B",
        "meta/llama-3.1-8b-instruct": "Llama 3.1 8B",
        "qwen/qwen2.5-72b-instruct": "Qwen 2.5 72B",
        "qwen/qwen2.5-7b-instruct": "Qwen 2.5 7B",
        "mistralai/mistral-large-2-instruct": "Mistral Large 2",
        "mistralai/mixtral-8x22b-instruct-v0.1": "Mixtral 8x22B",
        "qwen/qwen2.5-coder-32b-instruct": "Qwen 2.5 Coder 32B",
        "google/gemma-2-27b-it": "Gemma 2 27B",
        "google/gemma-2-9b-it": "Gemma 2 9B",
        "microsoft/phi-4": "Phi-4",
        "microsoft/phi-3.5-mini-instruct": "Phi-3.5 Mini",
    ]

    struct ModelGroup {
        let name: String
        let models: [String]
    }

    static var modelGroups: [ModelGroup] {
        let allModels = shared.availableModels
        let groups: [(String, (String) -> Bool)] = [
            ("Reasoning", { $0.contains("kimi") || $0.contains("deepseek") || $0.contains("qwq") }),
            ("NVIDIA", { $0.hasPrefix("nvidia/") }),
            ("Meta Llama", { $0.hasPrefix("meta/") }),
            ("Qwen", { $0.hasPrefix("qwen/") && !$0.contains("qwq") }),
            ("Mistral", { $0.hasPrefix("mistralai/") }),
            ("Google", { $0.hasPrefix("google/") }),
            ("Microsoft", { $0.hasPrefix("microsoft/") }),
            ("Other", { _ in true }),
        ]

        var used = Set<String>()
        var result: [ModelGroup] = []
        for (name, predicate) in groups {
            let models = allModels.filter { predicate($0) && !used.contains($0) }
            if !models.isEmpty {
                result.append(ModelGroup(name: name, models: models))
                used.formUnion(models)
            }
        }

        let custom = shared.customModels
        if !custom.isEmpty {
            result.append(ModelGroup(name: "Custom", models: custom))
        }

        return result
    }

    var customModels: [String] {
        get {
            guard let data = customModelsJSON.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            {
                customModelsJSON = json
                objectWillChange.send()
            }
        }
    }

    func addCustomModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = customModels
        if !current.contains(trimmed) {
            current.append(trimmed)
            customModels = current
        }
    }

    func removeCustomModel(_ model: String) {
        var current = customModels
        if let index = current.firstIndex(of: model) {
            current.remove(at: index)
            customModels = current
        }
    }

    func displayName(for model: String) -> String {
        NvidiaModelManager.displayNames[model] ?? model
    }

    var favoriteModels: [String] {
        get {
            guard let data = favoritesJSON.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            {
                favoritesJSON = json
                objectWillChange.send()
            }
        }
    }

    var sortedModels: [String] {
        let favorites = favoriteModels
        let others = availableModels.filter { !favorites.contains($0) }
        let customs = customModels.filter { !favorites.contains($0) }
        return (favorites + others + customs).unique()
    }

    func toggleFavorite(_ model: String) {
        var currentFavorites = favoriteModels
        if let index = currentFavorites.firstIndex(of: model) {
            currentFavorites.remove(at: index)
        } else {
            currentFavorites.append(model)
        }
        favoriteModels = currentFavorites
    }

    func isFavorite(_ model: String) -> Bool {
        return favoriteModels.contains(model)
    }
}
