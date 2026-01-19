import Foundation
import SwiftUI

class OllamaModelManager: ObservableObject {
    static let shared = OllamaModelManager()
    
    @AppStorage("OllamaFavorites") private var favoritesJSON: String = "[]"
    @Published var availableModels: [String] = [
        "llama3:8b",
        "llama3",
        "llama2",
        "mistral",
        "gemma",
        "qwen",
        "neural-chat",
        "starling-lm",
        "codellama",
        "phi",
        "gpt-oss:120b-cloud",
        "gpt-oss:20b-cloud",
        "gpt-oss:120b",
        "gpt-oss:20b",
        "deepseek-v3.1:671b-cloud",
        "deepseek-r1:8b",
        "qwen3-coder:480b-cloud",
        "qwen3-coder:30b",
        "qwen3-vl:235b-cloud",
        "qwen3-vl:235b-instruct-cloud",
        "qwen3-vl:30b",
        "qwen3-vl:8b",
        "qwen3-vl:4b",
        "qwen3:30b",
        "qwen3:8b",
        "qwen3:4b",
        "minimax-m2:cloud",
        "glm-4.6:cloud",
        "gemma3:27b",
        "gemma3:12b",
        "gemma3:4b",
        "gemma3:1b"
    ]
    
    // Helper to group models by manufacturer/series
    func getManufacturer(for model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("llama") { return "Meta" }
        if lower.contains("gpt-oss") { return "OpenAI OSS" }
        if lower.contains("deepseek") { return "DeepSeek" }
        if lower.contains("qwen") { return "Qwen" }
        if lower.contains("gemma") { return "Google" }
        if lower.contains("minimax") { return "Minimax" }
        if lower.contains("glm") { return "GLM" }
        if lower.contains("mistral") { return "Mistral" }
        return "Other"
    }
    
    var groupedModels: [String: [String]] {
        Dictionary(grouping: sortedModels, by: { getManufacturer(for: $0) })
    }
    
    var sortedManufacturers: [String] {
        ["Meta", "OpenAI OSS", "DeepSeek", "Qwen", "Google", "Minimax", "GLM", "Mistral", "Other"]
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
        let others = availableModels.filter { !favorites.contains($0) }
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
