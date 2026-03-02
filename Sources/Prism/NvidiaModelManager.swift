import Foundation
import SwiftUI

class NvidiaModelManager: ObservableObject {
    static let shared = NvidiaModelManager()

    @AppStorage("NvidiaFavorites") private var favoritesJSON: String = "[]"
    @AppStorage("NvidiaCustomModels") private var customModelsJSON: String = "[]"

    @Published var availableModels: [String] = [
        // Featured / New
        "minimaxai/minimax-m2.5",
        "qwen/qwen3.5-397b-a17b",
        "z-ai/glm5",
        "minimaxai/minimax-m2.1",
        "stepfun-ai/step-3.5-flash",
        "moonshotai/kimi-k2.5",
        "z-ai/glm4.7",
        "deepseek-ai/deepseek-v3.2",
        "nvidia/nemotron-3-nano-30b-a3b",
        "mistralai/devstral-2-123b-instruct-2512",
        "moonshotai/kimi-k2-thinking",
        "mistralai/mistral-large-3-675b-instruct-2512",
        "mistralai/ministral-14b-instruct-2512",
        "nvidia/nemotron-nano-12b-v2-vl",
        "deepseek-ai/deepseek-v3.1-terminus",
        "stockmark/stockmark-2-100b-instruct",
        "qwen/qwen3-next-80b-a3b-instruct",
        "moonshotai/kimi-k2-instruct-0905",
        "speakleash/bielik-11b-v2.6-instruct",
        "qwen/qwen3-next-80b-a3b-thinking",
        "bytedance/seed-oss-36b-instruct",
        "qwen/qwen3-coder-480b-a35b-instruct",
        "deepseek-ai/deepseek-v3.1",
        "nvidia/nvidia-nemotron-nano-9b-v2",
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "nvidia/llama-3.3-nemotron-super-49b-v1.5",
        "opengpt-x/teuken-7b-instruct-commercial-v0.4",
        "sarvamai/sarvam-m",
        "microsoft/phi-4-mini-flash-reasoning",
        "moonshotai/kimi-k2-instruct",
        "mistralai/magistral-small-2506",
        "google/gemma-3n-e4b-it",
        "google/gemma-3n-e2b-it",
        "mistralai/mistral-nemotron",
        "nvidia/llama-3.1-nemotron-nano-vl-8b-v1",
        "nvidia/llama-3.1-nemotron-nano-4b-v1.1",
        "marin/marin-8b-instruct",
        "ibm/granite-3.3-8b-instruct",
        "qwen/qwen3-235b-a22b",
        "utter-project/eurollm-9b-instruct",
        "gotocompany/gemma-2-9b-cpt-sahabatai-instruct",
        "mistralai/mistral-small-3.1-24b-instruct-2503",
        "mistralai/mistral-medium-3-instruct",
        "nvidia/llama-3.1-nemotron-ultra-253b-v1",
        "meta/llama-4-maverick-17b-128e-instruct",
        "meta/llama-4-scout-17b-16e-instruct",
        "qwen/qwq-32b",
        "nvidia/llama-3.3-nemotron-super-49b-v1",
        "nvidia/llama-3.1-nemotron-nano-8b-v1",
        "deepseek-ai/deepseek-r1-distill-llama-8b",
        "google/gemma-3-27b-it",
        "google/gemma-3-1b-it",
        "deepseek-ai/deepseek-r1-distill-qwen-32b",
        "deepseek-ai/deepseek-r1-distill-qwen-14b",
        "deepseek-ai/deepseek-r1-distill-qwen-7b",
        "microsoft/phi-4-mini-instruct",
        "microsoft/phi-4-multimodal-instruct",
        "mistralai/mistral-small-24b-instruct",
        "igenius/colosseum_355b_instruct_16k",
        "tiiuae/falcon3-7b-instruct",
        "igenius/italia_10b_instruct_16k",
        "qwen/qwen2.5-7b-instruct",
        "qwen/qwen2.5-coder-32b-instruct",
        "qwen/qwen2.5-coder-7b-instruct",
        "nvidia/usdcode-llama-3.1-70b-instruct",
        "meta/llama-3.3-70b-instruct",
        "nvidia/nemotron-4-mini-hindi-4b-instruct",
        "institute-of-science-tokyo/llama-3.1-swallow-70b-instruct-v0.1",
        "institute-of-science-tokyo/llama-3.1-swallow-8b-instruct-v0.1",
        "meta/llama-3.2-3b-instruct",
        "meta/llama-3.2-11b-vision-instruct",
        "meta/llama-3.2-90b-vision-instruct",
        "meta/llama-3.2-1b-instruct",
        "qwen/qwen2-7b-instruct",
        "abacusai/dracarys-llama-3.1-70b-instruct",
        "yentinglin/llama-3-taiwan-70b-instruct",
        "tokyotech-llm/llama-3-swallow-70b-instruct-v0.1",
        "ai21labs/jamba-1.5-mini-instruct",
        "nvidia/nemotron-mini-4b-instruct",
        "microsoft/phi-3.5-mini-instruct",
        "rakuten/rakutenai-7b-instruct",
        "rakuten/rakutenai-7b-chat",
        "google/gemma-2-2b-it",
        "thudm/chatglm3-6b",
        "mistralai/mamba-codestral-7b-v0.1",
        "baichuan-inc/baichuan2-13b-chat",
        "meta/llama-3.1-405b-instruct",
        "meta/llama-3.1-70b-instruct",
        "meta/llama-3.1-8b-instruct",
        "microsoft/phi-3-medium-128k-instruct",
        "google/gemma-2-27b-it",
        "google/gemma-2-9b-it",
        "nvidia/llama3-chatqa-1.5-8b",
        "mistralai/mistral-7b-instruct-v0.3",
        "mediatek/breeze-7b-instruct",
        "microsoft/phi-3-small-8k-instruct",
        "microsoft/phi-3-small-128k-instruct",
        "microsoft/phi-3-medium-4k-instruct",
        "microsoft/phi-3-mini-4k-instruct",
        "microsoft/phi-3-mini-128k-instruct",
        "mistralai/mixtral-8x22b-instruct-v0.1",
        "meta/llama3-70b-instruct",
        "meta/llama3-8b-instruct",
        "google/gemma-7b",
        "mistralai/mistral-7b-instruct-v0.2",
        "mistralai/mixtral-8x7b-instruct-v0.1",
    ]

    static let displayNames: [String: String] = [:]

    struct ModelGroup {
        let name: String
        let models: [String]
    }

    static var modelGroups: [ModelGroup] {
        let allModels = shared.availableModels
        let groups: [(String, (String) -> Bool)] = [
            (
                "Reasoning / Thinking",
                {
                    $0.contains("reasoning") || $0.contains("thinking") || $0.contains("qwq")
                        || $0.hasPrefix("moonshotai/kimi")
                        || $0.hasPrefix("deepseek-ai/deepseek-r1")
                }
            ),
            ("NVIDIA", { $0.hasPrefix("nvidia/") }),
            ("Meta Llama", { $0.hasPrefix("meta/") }),
            ("DeepSeek", { $0.hasPrefix("deepseek-ai/") }),
            ("Qwen", { $0.hasPrefix("qwen/") }),
            (
                "Mistral",
                { $0.hasPrefix("mistralai/") }
            ),
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
        if let name = NvidiaModelManager.displayNames[model] {
            return name
        }
        if let slashIndex = model.firstIndex(of: "/") {
            return String(model[model.index(after: slashIndex)...])
        }
        return model
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
