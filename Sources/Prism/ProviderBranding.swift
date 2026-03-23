import AppKit
import SwiftUI

enum ProviderBranding {
    private static let imageCache = NSCache<NSString, NSImage>()

    private static let iconResources: [String: String] = [
        "apple": "apple",
        "apple foundation": "apple",
        "apple intelligence": "apple",
        "anthropic": "anthropic",
        "claude": "anthropic",
        "claude web": "anthropic",
        "chatgpt": "openai",
        "chatgpt web": "openai",
        "openai": "openai",
        "gemini api": "googlegemini",
        "gemini web": "googlegemini",
        "google": "googlegemini",
        "github copilot": "githubcopilot",
        "nvidia": "nvidia",
        "nvidia api": "nvidia",
        "ollama": "ollama",
        "perplexity": "perplexity",
        "perplexity web": "perplexity",
        "xai": "xai",
        "grok web": "xai",
    ]

    private static let fallbackSymbols: [String: String] = [
        "customwebview": "globe",
        "on-device": "iphone",
        "other": "cpu",
        "private cloud": "lock.icloud",
        "unknown": "cpu",
    ]

    static func normalizedKey(for provider: String) -> String {
        let base = provider.split(separator: "|").first.map(String.init) ?? provider
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("customwebview:") {
            return "customwebview"
        }
        return lower
    }

    static func resourceName(for provider: String) -> String? {
        iconResources[normalizedKey(for: provider)]
    }

    static func fallbackSystemName(
        for provider: String, customFallbackSymbol: String? = nil
    ) -> String {
        let key = normalizedKey(for: provider)
        if key == "customwebview", let customFallbackSymbol, !customFallbackSymbol.isEmpty {
            return customFallbackSymbol
        }
        if let symbol = fallbackSymbols[key] {
            return symbol
        }
        return customFallbackSymbol ?? "cpu"
    }

    static func nsImage(for provider: String) -> NSImage? {
        guard let resourceName = resourceName(for: provider) else { return nil }
        let cacheKey = "\(normalizedKey(for: provider))|\(resourceName)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        guard let url = resourceURL(named: resourceName),
            let image = NSImage(contentsOfFile: url.path)
        else {
            return nil
        }

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    static func image(for provider: String, customFallbackSymbol: String? = nil) -> Image {
        if let nsImage = nsImage(for: provider) {
            return Image(nsImage: nsImage).renderingMode(.template)
        }
        return Image(
            systemName: fallbackSystemName(
                for: provider, customFallbackSymbol: customFallbackSymbol)
        )
    }

    private static func resourceURL(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "ProviderIcons")
            ?? Bundle.module.url(
                forResource: name, withExtension: "svg", subdirectory: "Resources/ProviderIcons")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
    }
}

struct ProviderIconView: View {
    let provider: String
    var size: CGFloat = 16
    var darkModeWhite: Bool = false
    var customFallbackSymbol: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let icon = Group {
            if let nsImage = ProviderBranding.nsImage(for: provider) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(
                    systemName: ProviderBranding.fallbackSystemName(
                        for: provider, customFallbackSymbol: customFallbackSymbol)
                )
                .font(.system(size: size, weight: .regular))
                .frame(width: size, height: size)
            }
        }
        if darkModeWhite {
            icon.foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
        } else {
            icon
        }
    }
}

extension Image {
    init(providerIcon provider: String, customFallbackSymbol: String? = nil) {
        self = ProviderBranding.image(
            for: provider, customFallbackSymbol: customFallbackSymbol)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, providerIcon provider: String, customFallbackSymbol: String? = nil) {
        self.init(
            title: { Text(title) },
            icon: {
                Image(providerIcon: provider, customFallbackSymbol: customFallbackSymbol)
            })
    }

    init(
        _ titleKey: LocalizedStringKey, providerIcon provider: String,
        customFallbackSymbol: String? = nil
    ) {
        self.init(
            title: { Text(titleKey) },
            icon: {
                Image(providerIcon: provider, customFallbackSymbol: customFallbackSymbol)
            })
    }
}
