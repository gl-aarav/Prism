import Foundation
import SwiftUI

class OllamaModelManager: ObservableObject {
    static let shared = OllamaModelManager()
    
    @AppStorage("OllamaFavorites") private var favoritesJSON: String = "[]"
    @AppStorage("OllamaCustomModels") private var customModelsJSON: String = "[]"
    
    @Published var availableModels: [String] = [
        "llama3.3",
        "llama3.2",
        "llama3.1",
        "deepseek-r1",
        "phi4",
        "mistral-small",
        "gemma2",
        "qwen2.5",
        "codellama"
    ]
    
    /// Models fetched from the local Ollama instance via /api/tags.
    @Published var installedModels: [String] = []

    private init() {
        fetchInstalledModels()
    }

    /// Fetch the list of locally installed models from Ollama's /api/tags endpoint.
    func fetchInstalledModels(endpoint: String? = nil) {
        let baseURL = (endpoint ?? UserDefaults.standard.string(forKey: "OllamaURL") ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/api/tags") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return }

            let names = models.compactMap { $0["name"] as? String }
            DispatchQueue.main.async {
                self?.installedModels = names
                // Merge into availableModels so pickers reflect what's actually installed
                let merged = Array(Set((self?.availableModels ?? []) + names)).sorted()
                self?.availableModels = merged
            }
        }.resume()
    }
    
    // Helper to group models by manufacturer/series
    func getManufacturer(for model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("llama") { return "Meta" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Google" }
        if lower.contains("mistral") { return "Mistral" }
        if lower.contains("phi") { return "Microsoft" }
        return "Other"
    }
    
    var customModels: [String] {
        get {
            guard let data = customModelsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
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

    var allModels: [String] {
        let combined = Array(Set(availableModels + customModels))
        return combined.sorted()
    }
    
    var groupedModels: [String: [String]] {
        Dictionary(grouping: sortedModels, by: { getManufacturer(for: $0) })
    }
    
    var sortedManufacturers: [String] {
        ["Meta", "DeepSeek", "Microsoft", "Qwen", "Google", "Mistral", "Other"]
    }
    
    var favoriteModels: [String] {
        get {
            guard let data = favoritesJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                favoritesJSON = json
                objectWillChange.send()
            }
        }
    }
    
    var sortedModels: [String] {
        let favorites = favoriteModels
        let others = allModels.filter { !favorites.contains($0) }
        return favorites + others
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
