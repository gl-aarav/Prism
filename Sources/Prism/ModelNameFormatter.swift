import Foundation
import SwiftUI

public enum ModelNameFormatter {
    
    public static func format(name: String) -> String {
        let defaults = UserDefaults.standard
        if UserDefaults.standard.object(forKey: "FormatModelNames") == nil {
            // Default to true if not set
            UserDefaults.standard.set(true, forKey: "FormatModelNames")
        }
        guard defaults.bool(forKey: "FormatModelNames") else { return name }
        
        var formatted = name

        // specific replacements
        if formatted.hasSuffix("-cloud") {
            formatted = formatted.replacingOccurrences(of: "-cloud", with: " (cloud)")
        }
        
        // Handle colon
        formatted = formatted.replacingOccurrences(of: ":", with: " ")
        // Handle dashes and underscores
        formatted = formatted.replacingOccurrences(of: "-", with: " ")
        formatted = formatted.replacingOccurrences(of: "_", with: " ")

        let words = formatted.split(separator: " ").map { String($0) }
        
        let customCapitalizations: [String: String] = [
            "gpt": "GPT",
            "oss": "OSS",
            "gemini": "Gemini",
            "pro": "Pro",
            "image": "Image",
            "preview": "Preview",
            "claude": "Claude",
            "meta": "Meta",
            "llama": "Llama",
            "mixtral": "Mixtral",
            "nemotron": "Nemotron",
            "qwen": "Qwen",
            "phi": "Phi",
            "mistral": "Mistral",
            "sonnet": "Sonnet",
            "haiku": "Haiku",
            "opus": "Opus",
            "flash": "Flash"
        ]
        
        var capitalizedWords = [String]()
        for word in words {
            if word == "(cloud)" {
                capitalizedWords.append("(cloud)")
                continue
            }
            
            let lword = word.lowercased()
            if let custom = customCapitalizations[lword] {
                capitalizedWords.append(custom)
            } else {
                if let first = word.first {
                    capitalizedWords.append(first.uppercased() + word.dropFirst())
                } else {
                    capitalizedWords.append(word)
                }
            }
        }
        
        var result = capitalizedWords.joined(separator: " ")
        // specific rule for gpt-oss
        result = result.replacingOccurrences(of: "GPT OSS", with: "GPT-OSS")
        return result
    }
}
