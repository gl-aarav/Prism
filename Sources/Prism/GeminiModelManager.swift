import Foundation
import SwiftUI

class GeminiModelManager: ObservableObject {
    static let shared = GeminiModelManager()
    
    @AppStorage("GeminiFavorites") private var favoritesJSON: String = "[]"
    
    @Published var availableModels: [String] = [
        "gemini-3-pro-preview",
        "gemini-3-pro-image-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite"
    ]
    
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
        return (favorites + others).unique()
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
