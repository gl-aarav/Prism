import AppKit
import SwiftUI

struct SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    // MARK: - Token types and colors

    private struct TokenStyle {
        let pattern: String
        let color: NSColor
        let isRegex: Bool

        init(_ pattern: String, _ color: NSColor, isRegex: Bool = true) {
            self.pattern = pattern
            self.color = color
            self.isRegex = isRegex
        }
    }

    // Dark mode colors (vivid on dark background)
    private let darkKeyword = NSColor(red: 0.85, green: 0.40, blue: 0.95, alpha: 1.0)
    private let darkString = NSColor(red: 0.40, green: 0.87, blue: 0.42, alpha: 1.0)
    private let darkComment = NSColor(red: 0.55, green: 0.62, blue: 0.69, alpha: 1.0)
    private let darkNumber = NSColor(red: 0.95, green: 0.70, blue: 0.30, alpha: 1.0)
    private let darkType = NSColor(red: 0.30, green: 0.82, blue: 0.95, alpha: 1.0)
    private let darkFunction = NSColor(red: 1.00, green: 0.92, blue: 0.42, alpha: 1.0)

    // Light mode colors (rich on light background)
    private let lightKeyword = NSColor(red: 0.55, green: 0.10, blue: 0.75, alpha: 1.0)
    private let lightString = NSColor(red: 0.10, green: 0.52, blue: 0.15, alpha: 1.0)
    private let lightComment = NSColor(red: 0.42, green: 0.47, blue: 0.52, alpha: 1.0)
    private let lightNumber = NSColor(red: 0.80, green: 0.45, blue: 0.05, alpha: 1.0)
    private let lightType = NSColor(red: 0.05, green: 0.45, blue: 0.62, alpha: 1.0)
    private let lightFunction = NSColor(red: 0.60, green: 0.50, blue: 0.00, alpha: 1.0)

    // Common keywords across many languages
    private let commonKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "break", "continue", "return",
        "func", "function", "def", "class", "struct", "enum", "interface", "protocol",
        "import", "from", "as", "try", "catch", "throw", "throws", "finally",
        "var", "let", "const", "val", "static", "final", "public", "private", "protected",
        "new", "delete", "this", "self", "super", "nil", "null", "None", "true", "false",
        "True", "False", "async", "await", "yield", "fn", "pub", "mut", "impl", "trait",
        "where", "in", "is", "not", "and", "or", "with", "elif", "pass", "lambda",
        "guard", "defer", "override", "init", "deinit", "extension", "typealias",
        "package", "void", "int", "float", "double", "string", "bool", "char", "long",
        "short", "byte", "unsigned", "signed", "extern", "typedef", "sizeof",
        "include", "define", "ifdef", "endif", "pragma", "using", "namespace",
        "template", "typename", "virtual", "abstract", "sealed", "readonly",
        "export", "default", "module", "require", "type", "declare",
        "println", "print", "printf", "fmt", "go", "chan", "select", "range", "map",
    ]

    func highlight(_ code: String, language: String, isDark: Bool = true) -> AttributedString {
        let nsStr = code as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        let attributed = NSMutableAttributedString(string: code)

        // Pick color palette based on appearance
        let keywordColor = isDark ? darkKeyword : lightKeyword
        let stringColor = isDark ? darkString : lightString
        let commentColor = isDark ? darkComment : lightComment
        let numberColor = isDark ? darkNumber : lightNumber
        let typeColor = isDark ? darkType : lightType
        let functionColor = isDark ? darkFunction : lightFunction

        // Base style
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseColor = isDark ? NSColor(white: 0.92, alpha: 1.0) : NSColor(white: 0.15, alpha: 1.0)
        attributed.addAttribute(.font, value: baseFont, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        // Track which ranges are already colored (comments and strings take priority)
        var coloredRanges: [NSRange] = []

        func isAlreadyColored(_ range: NSRange) -> Bool {
            for existing in coloredRanges {
                if NSIntersectionRange(existing, range).length > 0 {
                    return true
                }
            }
            return false
        }

        func applyColor(_ color: NSColor, to range: NSRange) {
            if !isAlreadyColored(range) {
                attributed.addAttribute(.foregroundColor, value: color, range: range)
                coloredRanges.append(range)
            }
        }

        // 1. Comments (highest priority)
        // Single-line comments: // or #
        if let regex = try? NSRegularExpression(pattern: "(?://|#).*$", options: .anchorsMatchLines)
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(commentColor, to: match.range)
            }
        }

        // Multi-line comments: /* ... */
        if let regex = try? NSRegularExpression(pattern: "/\\*[\\s\\S]*?\\*/", options: []) {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(commentColor, to: match.range)
            }
        }

        // 2. Strings
        // Double-quoted strings
        if let regex = try? NSRegularExpression(
            pattern: "\"(?:[^\"\\\\]|\\\\.)*\"", options: .dotMatchesLineSeparators)
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(stringColor, to: match.range)
            }
        }

        // Single-quoted strings
        if let regex = try? NSRegularExpression(
            pattern: "'(?:[^'\\\\]|\\\\.)*'", options: .dotMatchesLineSeparators)
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(stringColor, to: match.range)
            }
        }

        // Backtick template strings
        if let regex = try? NSRegularExpression(
            pattern: "`(?:[^`\\\\]|\\\\.)*`", options: .dotMatchesLineSeparators)
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(stringColor, to: match.range)
            }
        }

        // 3. Numbers
        if let regex = try? NSRegularExpression(
            pattern: "\\b(?:0x[0-9a-fA-F]+|0b[01]+|0o[0-7]+|\\d+\\.?\\d*(?:[eE][+-]?\\d+)?)\\b",
            options: [])
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(numberColor, to: match.range)
            }
        }

        // 4. Keywords
        for keyword in commonKeywords {
            if let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", options: [])
            {
                let matches = regex.matches(in: code, range: fullRange)
                for match in matches {
                    applyColor(keywordColor, to: match.range)
                }
            }
        }

        // 5. Type names (PascalCase words)
        if let regex = try? NSRegularExpression(
            pattern: "\\b[A-Z][a-zA-Z0-9]*\\b", options: [])
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(typeColor, to: match.range)
            }
        }

        // 6. Function calls: word followed by (
        if let regex = try? NSRegularExpression(
            pattern: "\\b([a-zA-Z_][a-zA-Z0-9_]*)\\s*\\(", options: [])
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                if match.numberOfRanges > 1 {
                    applyColor(functionColor, to: match.range(at: 1))
                }
            }
        }

        // 7. Decorators / attributes (@something)
        if let regex = try? NSRegularExpression(
            pattern: "@[a-zA-Z_][a-zA-Z0-9_]*", options: [])
        {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                applyColor(functionColor, to: match.range)
            }
        }

        return AttributedString(attributed)
    }
}
