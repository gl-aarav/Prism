import Foundation
import SwiftUI

class GeminiModelManager: ObservableObject {
    static let shared = GeminiModelManager()

    @AppStorage("GeminiFavorites") private var favoritesJSON: String = "[]"
    @AppStorage("GeminiCustomModels") private var customModelsJSON: String = "[]"

    @Published var availableModels: [String] = [
        // Gemini 3
        "gemini-3.1-pro-preview",
        "gemini-3.1-pro-preview-customtools",
        "gemini-3.1-flash-lite-preview",
        "gemini-3.1-flash-image-preview",
        "gemini-3-pro-preview",
        "gemini-3-flash-preview",
        "gemini-3-pro-image-preview",
        "nano-banana-pro-preview",
        // Gemini 2.5
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite",
        "gemini-2.5-flash-preview-tts",
        "gemini-2.5-pro-preview-tts",
        "gemini-2.5-flash-lite-preview-09-2025",
        "gemini-2.5-flash-image",
        "gemini-2.5-computer-use-preview-10-2025",
        // Gemini 2.0
        "gemini-2.0-flash",
        "gemini-2.0-flash-001",
        "gemini-2.0-flash-exp-image-generation",
        "gemini-2.0-flash-lite-001",
        "gemini-2.0-flash-lite",
        // Gemma 3
        "gemma-3-1b-it",
        "gemma-3-4b-it",
        "gemma-3-12b-it",
        "gemma-3-27b-it",
        "gemma-3n-e4b-it",
        "gemma-3n-e2b-it",
        // Aliases
        "gemini-flash-latest",
        "gemini-flash-lite-latest",
        "gemini-pro-latest",
        // Other
        "gemini-robotics-er-1.5-preview",
        "deep-research-pro-preview-12-2025",
    ]

    static let displayNames: [String: String] = [
        "gemini-3.1-pro-preview": "Gemini 3.1 Pro Preview",
        "gemini-3.1-pro-preview-customtools": "Gemini 3.1 Pro Preview Custom Tools",
        "gemini-3.1-flash-lite-preview": "Gemini 3.1 Flash-Lite Preview",
        "gemini-3.1-flash-image-preview": "Nano Banana 2",
        "gemini-3-pro-preview": "Gemini 3 Pro Preview",
        "gemini-3-flash-preview": "Gemini 3 Flash Preview",
        "gemini-3-pro-image-preview": "Nano Banana Pro",
        "nano-banana-pro-preview": "Nano Banana Pro Preview",
        "gemini-2.5-pro": "Gemini 2.5 Pro",
        "gemini-2.5-flash": "Gemini 2.5 Flash",
        "gemini-2.5-flash-lite": "Gemini 2.5 Flash-Lite",
        "gemini-2.5-flash-preview-tts": "Gemini 2.5 Flash Preview TTS",
        "gemini-2.5-pro-preview-tts": "Gemini 2.5 Pro Preview TTS",
        "gemini-2.5-flash-lite-preview-09-2025": "Gemini 2.5 Flash-Lite Preview Sep 2025",
        "gemini-2.5-flash-image": "Nano Banana",
        "gemini-2.5-computer-use-preview-10-2025": "Gemini 2.5 Computer Use Preview 10-2025",
        "gemini-2.0-flash": "Gemini 2.0 Flash",
        "gemini-2.0-flash-001": "Gemini 2.0 Flash 001",
        "gemini-2.0-flash-exp-image-generation": "Gemini 2.0 Flash (Image Generation) Experimental",
        "gemini-2.0-flash-lite-001": "Gemini 2.0 Flash-Lite 001",
        "gemini-2.0-flash-lite": "Gemini 2.0 Flash-Lite",
        "gemma-3-1b-it": "Gemma 3 1B",
        "gemma-3-4b-it": "Gemma 3 4B",
        "gemma-3-12b-it": "Gemma 3 12B",
        "gemma-3-27b-it": "Gemma 3 27B",
        "gemma-3n-e4b-it": "Gemma 3n E4B",
        "gemma-3n-e2b-it": "Gemma 3n E2B",
        "gemini-flash-latest": "Gemini Flash Latest",
        "gemini-flash-lite-latest": "Gemini Flash-Lite Latest",
        "gemini-pro-latest": "Gemini Pro Latest",
        "gemini-robotics-er-1.5-preview": "Gemini Robotics-ER 1.5 Preview",
        "deep-research-pro-preview-12-2025": "Deep Research Pro Preview (Dec-12-2025)",
    ]

    struct ModelGroup {
        let name: String
        let models: [String]
    }

    static var modelGroups: [ModelGroup] {
        let allModels = shared.availableModels
        let groups: [(String, (String) -> Bool)] = [
            ("Gemini 3", { $0.hasPrefix("gemini-3") }),
            ("Nano Banana", { $0.contains("image") || $0.contains("nano-banana") }),
            ("Gemini 2.5", { $0.hasPrefix("gemini-2.5") && !$0.contains("image") }),
            ("Gemini 2.0", { $0.hasPrefix("gemini-2.0") && !$0.contains("image") }),
            ("Gemma", { $0.hasPrefix("gemma") }),
            ("Aliases", { $0.contains("latest") }),
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
        return ModelNameFormatter.format(name: GeminiModelManager.displayNames[model] ?? model)
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

extension Array where Element: Equatable {
    func unique() -> [Element] {
        var result = [Element]()
        for value in self {
            if !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }
}
