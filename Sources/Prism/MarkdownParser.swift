import AppKit
import Foundation
import SwiftMath
import SwiftUI

struct MarkdownParser {
    static let shared = MarkdownParser()

    private let latexScaleFactor: CGFloat = 2.0 / 3.0

    func parse(_ text: String) -> AttributedString {
        let preprocessedText = preprocessBlockMath(text)
        return parseMarkdownToAttributedString(preprocessedText)
    }

    /// Preprocesses text to handle edge cases where block math ($$...$$) appears
    /// on the same line as other content (text or inline math).
    /// This ensures block equations are properly separated for correct rendering.
    private func preprocessBlockMath(_ text: String) -> String {
        // Pattern to find $$...$$ followed by non-whitespace content on the same line,
        // then another $$...$$. We need to insert newlines to separate them.
        // This handles: $$eq1$$ text $$eq2$$ -> $$eq1$$\ntext\n$$eq2$$

        // First, normalize: ensure $$ blocks that have content between them are separated
        // We'll process line by line and fix lines that have multiple $$ blocks with text between

        let lines = text.components(separatedBy: "\n")
        var processedLines: [String] = []

        for line in lines {
            let processed = normalizeBlockMathInLine(line)
            processedLines.append(contentsOf: processed)
        }

        return processedLines.joined(separator: "\n")
    }

    /// Normalizes a single line that may contain multiple block math expressions with text between them.
    /// Handles both $$...$$ and \[...\] delimiters.
    /// Returns an array of lines (may split one line into multiple).
    private func normalizeBlockMathInLine(_ line: String) -> [String] {
        // First handle $$ delimiters
        let dollarResult = normalizeBlockDelimiters(in: line, openDelim: "$$", closeDelim: "$$")

        // Then handle \[...\] delimiters on each resulting line
        var finalResult: [String] = []
        for l in dollarResult {
            let processed = normalizeBlockDelimiters(in: l, openDelim: "\\[", closeDelim: "\\]")
            finalResult.append(contentsOf: processed)
        }

        return finalResult
    }

    /// Normalizes block delimiters in a line, splitting when there's text between blocks.
    private func normalizeBlockDelimiters(in line: String, openDelim: String, closeDelim: String)
        -> [String]
    {
        // For matching delimiters like $$...$$, we need to find pairs
        if openDelim == closeDelim {
            return normalizeMatchingDelimiters(in: line, delimiter: openDelim)
        }

        // For different delimiters like \[...\], find opening and closing separately
        return normalizeDistinctDelimiters(in: line, openDelim: openDelim, closeDelim: closeDelim)
    }

    /// Handles matching delimiters like $$...$$
    private func normalizeMatchingDelimiters(in line: String, delimiter: String) -> [String] {
        var positions: [String.Index] = []
        var index = line.startIndex

        while index < line.endIndex {
            if let range = line.range(of: delimiter, range: index..<line.endIndex) {
                positions.append(range.lowerBound)
                index = range.upperBound
            } else {
                break
            }
        }

        // Need at least 4 markers for the problematic case: $$...$$text$$...$$
        if positions.count < 4 {
            return [line]
        }

        var resultLines: [String] = []
        var currentPos = line.startIndex
        var i = 0
        let delimLen = delimiter.count

        while i + 3 < positions.count {
            let closeEnd = line.index(positions[i + 1], offsetBy: delimLen)
            let nextOpenStart = positions[i + 2]

            if closeEnd < nextOpenStart {
                let textBetween = String(line[closeEnd..<nextOpenStart])

                if !textBetween.trimmingCharacters(in: .whitespaces).isEmpty {
                    let firstPart = String(line[currentPos..<closeEnd])
                    resultLines.append(firstPart)

                    let middlePart = textBetween.trimmingCharacters(in: .whitespaces)
                    if !middlePart.isEmpty {
                        resultLines.append(middlePart)
                    }

                    currentPos = nextOpenStart
                    i += 2
                    continue
                }
            }
            i += 2
        }

        if currentPos < line.endIndex {
            let remaining = String(line[currentPos...])
            if !remaining.isEmpty {
                resultLines.append(remaining)
            }
        }

        return resultLines.isEmpty ? [line] : resultLines
    }

    /// Handles distinct delimiters like \[...\]
    private func normalizeDistinctDelimiters(in line: String, openDelim: String, closeDelim: String)
        -> [String]
    {
        var openPositions: [String.Index] = []
        var closePositions: [String.Index] = []
        var index = line.startIndex

        while index < line.endIndex {
            if let range = line.range(of: openDelim, range: index..<line.endIndex) {
                openPositions.append(range.lowerBound)
                index = range.upperBound
            } else {
                break
            }
        }

        index = line.startIndex
        while index < line.endIndex {
            if let range = line.range(of: closeDelim, range: index..<line.endIndex) {
                closePositions.append(range.lowerBound)
                index = range.upperBound
            } else {
                break
            }
        }

        // Need at least 2 complete blocks for the problematic case
        if openPositions.count < 2 || closePositions.count < 2 {
            return [line]
        }

        var resultLines: [String] = []
        var currentPos = line.startIndex
        let closeLen = closeDelim.count

        // Pair up opens with closes and check for text between blocks
        for i in 0..<min(openPositions.count - 1, closePositions.count - 1) {
            guard i < closePositions.count && i + 1 < openPositions.count else { break }

            let closeEnd = line.index(closePositions[i], offsetBy: closeLen)
            let nextOpenStart = openPositions[i + 1]

            if closeEnd < nextOpenStart {
                let textBetween = String(line[closeEnd..<nextOpenStart])

                if !textBetween.trimmingCharacters(in: .whitespaces).isEmpty {
                    let firstPart = String(line[currentPos..<closeEnd])
                    resultLines.append(firstPart)

                    let middlePart = textBetween.trimmingCharacters(in: .whitespaces)
                    if !middlePart.isEmpty {
                        resultLines.append(middlePart)
                    }

                    currentPos = nextOpenStart
                }
            }
        }

        if currentPos < line.endIndex {
            let remaining = String(line[currentPos...])
            if !remaining.isEmpty {
                resultLines.append(remaining)
            }
        }

        return resultLines.isEmpty ? [line] : resultLines
    }

    private func parseMarkdownToAttributedString(_ text: String) -> AttributedString {
        let displayDelimiters = ["$$", "\\["]

        var firstMatch: (delimiter: String, range: Range<String.Index>)? = nil

        // Check for block delimiters first
        for delim in displayDelimiters {
            if let range = text.range(of: delim) {
                if let current = firstMatch {
                    if range.lowerBound < current.range.lowerBound {
                        firstMatch = (delim, range)
                    }
                } else {
                    firstMatch = (delim, range)
                }
            }
        }

        if let match = firstMatch {
            let delimiter = match.delimiter
            let range = match.range
            let closingDelimiter = (delimiter == "\\[") ? "\\]" : "$$"

            let prefix = text[..<range.lowerBound]
            let remainder = text[range.upperBound...]

            // Look for closing delimiter - find the FIRST valid closing $$
            // that doesn't cross into inline $ math
            if let closeRange = findClosingBlockDelimiter(
                in: String(remainder), delimiter: closingDelimiter)
            {
                // If the closing delimiter is found immediately after (empty block), handle it
                if closeRange.lowerBound == remainder.startIndex {
                    return parseInlineMarkdown(String(prefix))
                        + parseMarkdownToAttributedString(
                            String(remainder[closeRange.upperBound...]))
                }

                // Proper block found
                let mathContent = String(remainder[..<closeRange.lowerBound])

                // Advance past closing delimiter
                let suffix = String(remainder[closeRange.upperBound...])

                return parseInlineMarkdown(String(prefix))
                    + mathText(mathContent, display: true)
                    + parseMarkdownToAttributedString(suffix)
            }
        }

        return parseInlineMarkdown(text)
    }

    /// Finds the closing block delimiter ($$), being careful to match properly
    private func findClosingBlockDelimiter(in text: String, delimiter: String) -> Range<
        String.Index
    >? {
        return text.range(of: delimiter)
    }

    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        // Handle <br> tags for line breaks
        let textWithBreaks = text.replacingOccurrences(
            of: "<br>", with: "\n", options: .caseInsensitive
        )
        .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)

        // Handle bold/italic wrapped links: **[text](url)** or *[text](url)*
        if let wrappedLinkMatch = try? NSRegularExpression(
            pattern: "(\\*\\*|\\*)\\[([^\\]]+)\\]\\((https?://[^)]+)\\)(\\*\\*|\\*)"
        )
        .firstMatch(
            in: textWithBreaks, range: NSRange(textWithBreaks.startIndex..., in: textWithBreaks)),
            wrappedLinkMatch.numberOfRanges == 5,
            let fullRange = Range(wrappedLinkMatch.range(at: 0), in: textWithBreaks),
            let openDelimRange = Range(wrappedLinkMatch.range(at: 1), in: textWithBreaks),
            let textRange = Range(wrappedLinkMatch.range(at: 2), in: textWithBreaks),
            let urlRange = Range(wrappedLinkMatch.range(at: 3), in: textWithBreaks),
            let closeDelimRange = Range(wrappedLinkMatch.range(at: 4), in: textWithBreaks)
        {
            let openDelim = String(textWithBreaks[openDelimRange])
            let closeDelim = String(textWithBreaks[closeDelimRange])
            // Only apply if delimiters match
            if openDelim == closeDelim {
                let prefix = String(textWithBreaks[..<fullRange.lowerBound])
                let linkText = String(textWithBreaks[textRange])
                let urlString = String(textWithBreaks[urlRange])
                let suffix = String(textWithBreaks[fullRange.upperBound...])

                var linkAttr = AttributedString(linkText)
                if let url = URL(string: urlString) {
                    linkAttr.link = url
                    linkAttr.underlineStyle = .single
                    linkAttr.foregroundColor = .blue
                }
                if openDelim == "**" {
                    linkAttr.font = .system(size: 15, weight: .bold)
                } else {
                    linkAttr.font = .system(size: 15).italic()
                }

                return parseInlineMarkdown(prefix) + linkAttr + parseInlineMarkdown(suffix)
            }
        }

        // Handle markdown links [text](url) before other delimiters
        if let linkMatch = try? NSRegularExpression(
            pattern: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)"
        )
        .firstMatch(
            in: textWithBreaks, range: NSRange(textWithBreaks.startIndex..., in: textWithBreaks)),
            linkMatch.numberOfRanges == 3,
            let fullRange = Range(linkMatch.range(at: 0), in: textWithBreaks),
            let textRange = Range(linkMatch.range(at: 1), in: textWithBreaks),
            let urlRange = Range(linkMatch.range(at: 2), in: textWithBreaks)
        {
            let prefix = String(textWithBreaks[..<fullRange.lowerBound])
            let linkText = String(textWithBreaks[textRange])
            let urlString = String(textWithBreaks[urlRange])
            let suffix = String(textWithBreaks[fullRange.upperBound...])

            var linkAttr = AttributedString(linkText)
            if let url = URL(string: urlString) {
                linkAttr.link = url
                linkAttr.underlineStyle = .single
                linkAttr.foregroundColor = .blue
            }

            return parseInlineMarkdown(prefix) + linkAttr + parseInlineMarkdown(suffix)
        }

        let delimiters = [
            "**", "*", "`", "\\(", "$", "\\textbf{", "\\textit{", "\\underline{", "\\emph{",
            "\\texttt{",
        ]

        var firstMatch: (delimiter: String, range: Range<String.Index>)? = nil

        for delim in delimiters {
            if let range = textWithBreaks.range(of: delim) {
                if let current = firstMatch {
                    if range.lowerBound < current.range.lowerBound {
                        firstMatch = (delim, range)
                    } else if range.lowerBound == current.range.lowerBound {
                        // Prefer longer delimiter (e.g. "**" over "*")
                        if delim.count > current.delimiter.count {
                            firstMatch = (delim, range)
                        }
                    }
                } else {
                    firstMatch = (delim, range)
                }
            }
        }

        if let match = firstMatch {
            let delimiter = match.delimiter
            let range = match.range

            let closingDelimiter: String
            if delimiter == "**" {
                closingDelimiter = "**"
            } else if delimiter == "*" {
                closingDelimiter = "*"
            } else if delimiter == "`" {
                closingDelimiter = "`"
            } else if delimiter == "\\(" {
                closingDelimiter = "\\)"
            } else if delimiter == "$" {
                closingDelimiter = "$"
            } else {
                closingDelimiter = "}"
            }

            let prefix = textWithBreaks[..<range.lowerBound]
            let remainder = textWithBreaks[range.upperBound...]

            if let endRange = remainder.range(of: closingDelimiter) {
                let content = String(remainder[..<endRange.lowerBound])
                let suffix = String(remainder[endRange.upperBound...])

                if delimiter == "**" || delimiter == "\\textbf{" {
                    var boldStr = parseInlineMarkdown(content)
                    boldStr.font = .system(size: 15, weight: .bold)
                    return parseInlineMarkdown(String(prefix)) + boldStr
                        + parseInlineMarkdown(suffix)
                } else if delimiter == "*" || delimiter == "\\textit{" || delimiter == "\\emph{" {
                    var italicStr = parseInlineMarkdown(content)
                    italicStr.font = .system(size: 15).italic()
                    return parseInlineMarkdown(String(prefix)) + italicStr
                        + parseInlineMarkdown(suffix)
                } else if delimiter == "\\underline{" {
                    var underlineStr = parseInlineMarkdown(content)
                    underlineStr.underlineStyle = .single
                    return parseInlineMarkdown(String(prefix)) + underlineStr
                        + parseInlineMarkdown(suffix)
                } else if delimiter == "`" || delimiter == "\\texttt{" {
                    var codeStr = AttributedString(content)
                    codeStr.font = .system(size: 15, design: .monospaced)
                    if delimiter == "`" {
                        codeStr.backgroundColor = .gray.opacity(0.2)
                    }
                    return parseInlineMarkdown(String(prefix)) + codeStr
                        + parseInlineMarkdown(suffix)
                } else {
                    // Math (inline)
                    let mathAttrStr = mathText(content, display: false)

                    return parseInlineMarkdown(String(prefix))
                        + mathAttrStr
                        + parseInlineMarkdown(suffix)
                }
            } else {
                // No closing delimiter found. Treat opening delimiter as text and continue.
                return AttributedString(String(prefix)) + AttributedString(delimiter)
                    + parseInlineMarkdown(String(remainder))
            }
        }

        return AttributedString(textWithBreaks)
    }

    private func mathText(_ latex: String, display: Bool) -> AttributedString {
        let cleanLatex = cleanLatex(latex)
        let fontSize: CGFloat = (display ? 16 : 14) * latexScaleFactor

        // For inline math, use text conversion since SwiftUI Text doesn't support NSTextAttachment
        if !display {
            let text = convertLatexToText(cleanLatex)
            // If conversion produced meaningful text, use it; otherwise show original
            if text.isEmpty || text == cleanLatex {
                // Show original LaTeX in monospace as fallback
                var attrStr = AttributedString("$\(latex)$")
                attrStr.font = .system(size: 14, design: .monospaced)
                attrStr.foregroundColor = .secondary
                return attrStr
            }
            var attrStr = AttributedString(text)
            attrStr.font = .system(size: 15).italic()
            return attrStr
        }

        // Display math uses MTMathImage
        let labelMode: MTMathUILabelMode = .display

        let mathImage = MTMathImage(
            latex: cleanLatex, fontSize: fontSize, textColor: .textColor, labelMode: labelMode)
        let (_, generatedImage) = mathImage.asImage()

        guard let img = generatedImage else {
            // Fallback to text conversion if rendering fails
            let text = convertLatexToText(cleanLatex)
            var attrStr = AttributedString(text)
            attrStr.font = .system(size: 14, design: .serif).italic()
            return attrStr
        }

        // Calculate Baseline using MTMathUILabel workaround
        let label = MTMathUILabel()
        label.latex = cleanLatex
        label.fontSize = fontSize
        label.labelMode = labelMode

        let size = label.fittingSize
        label.frame = CGRect(origin: .zero, size: size)
        label.layout()

        let baseline = label.displayList?.descent ?? 0

        let attachment = NSTextAttachment()
        attachment.image = img
        attachment.bounds = CGRect(
            x: 0,
            y: -baseline,
            width: img.size.width,
            height: img.size.height
        )

        let nsAttrStr = NSMutableAttributedString(attachment: attachment)
        return AttributedString("\n") + AttributedString(nsAttrStr) + AttributedString("\n")
    }

    private func convertLatexToText(_ latex: String) -> String {
        var content = latex

        // 1. Basic Replacements
        let replacements: [String: String] = [
            "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\epsilon": "ε",
            "\\zeta": "ζ", "\\eta": "η", "\\theta": "θ", "\\iota": "ι", "\\kappa": "κ",
            "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ", "\\omicron": "ο",
            "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ", "\\tau": "τ", "\\upsilon": "υ",
            "\\phi": "φ", "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω",
            "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ", "\\Xi": "Ξ",
            "\\Pi": "Π", "\\Sigma": "Σ", "\\Upsilon": "Υ", "\\Phi": "Φ", "\\Psi": "Ψ",
            "\\Omega": "Ω",
            "\\times": "×", "\\cdot": "·", "\\div": "÷", "\\pm": "±", "\\mp": "∓",
            "\\leq": "≤", "\\geq": "≥", "\\neq": "≠", "\\approx": "≈", "\\equiv": "≡",
            "\\forall": "∀", "\\exists": "∃", "\\in": "∈", "\\notin": "∉", "\\subset": "⊂",
            "\\subseteq": "⊆", "\\cup": "∪", "\\cap": "∩", "\\infty": "∞", "\\partial": "∂",
            "\\nabla": "∇", "\\rightarrow": "→", "\\leftarrow": "←", "\\Rightarrow": "⇒",
            "\\Leftarrow": "⇐", "\\leftrightarrow": "↔", "\\Leftrightarrow": "⇔",
            "\\dag": "†", "\\ddag": "‡", "\\dots": "...", "\\ldots": "...",
            "\\{": "{", "\\}": "}", "\\%": "%", "\\$": "$", "\\&": "&", "\\_": "_",
            "\\i": "ı",
            // Extras
            "\\to": "→", "\\star": "⋆", "\\ast": "∗", "\\circ": "∘", "\\bullet": "•",
            "\\oplus": "⊕", "\\otimes": "⊗", "\\angle": "∠", "\\perp": "⊥",
            "\\cong": "≅", "\\sim": "∼", "\\vert": "|", "\\Vert": "‖",
            "\\langle": "⟨", "\\rangle": "⟩",
            "\\mathbb{R}": "ℝ", "\\mathbb{N}": "ℕ", "\\mathbb{Z}": "ℤ",
            "\\mathbb{Q}": "ℚ", "\\mathbb{C}": "ℂ",
        ]

        for (key, value) in replacements {
            content = content.replacingOccurrences(of: key, with: value)
        }

        // 2. Handle Text Commands (Run early to avoid interfering with other commands)
        content = replaceTextCommand(content)

        // 3. Handle \boxed{...} -> [...]
        content = replaceCommand(content, command: "\\\\boxed", replacement: { "[\($0)]" })
        // Also handle /boxed just in case (user typo)
        content = replaceCommand(content, command: "/boxed", replacement: { "[\($0)]" })

        // 4. Handle \sqrt{...} -> √(...)
        content = replaceCommand(content, command: "\\\\sqrt", replacement: { "√(\($0))" })

        // 5. Handle \frac{a}{b} -> (a)/(b)
        content = replaceFrac(content)

        // 6. Handle Superscripts/Subscripts
        content = replaceSuperscripts(content)
        content = replaceSubscripts(content)

        // 7. Cleanup remaining commands - preserve spaces
        content = content.replacingOccurrences(of: "\\", with: "")
        content = content.replacingOccurrences(of: "{", with: "")
        content = content.replacingOccurrences(of: "}", with: "")

        // Collapse multiple spaces
        while content.contains("  ") {
            content = content.replacingOccurrences(of: "  ", with: " ")
        }
        content = content.trimmingCharacters(in: .whitespaces)

        // Fallback: if conversion resulted in empty/whitespace, return original latex
        if content.isEmpty {
            return latex
        }

        return content
    }

    private func replaceCommand(
        _ text: String, command: String, replacement: (String) -> String
    )
        -> String
    {
        var newText = text
        let pattern = "\(command)\\{([^}]+)\\}"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))
            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    let replaced = replacement(content)
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: replaced)
                    }
                }
            }
        }
        return newText
    }

    private func replaceSubscripts(_ text: String) -> String {
        var newText = text
        let map: [Character: String] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
            "n": "ₙ", "p": "ₚ", "s": "ₛ", "t": "ₜ",
        ]

        func convertToSub(_ str: String) -> String {
            return str.map { map[$0] ?? String($0) }.joined()
        }

        // _{...}
        let bracePattern = "_\\{([^}]+)\\}"
        if let regex = try? NSRegularExpression(pattern: bracePattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))
            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    let subStr = convertToSub(content)
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: subStr)
                    }
                }
            }
        }

        // _x
        let charPattern = "_([0-9aeoxhklmnpst+\\-=()])"
        if let regex = try? NSRegularExpression(pattern: charPattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))
            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    let subStr = convertToSub(content)
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: subStr)
                    }
                }
            }
        }

        return newText
    }

    private func replaceTextCommand(_ text: String) -> String {
        var newText = text
        let pattern =
            "\\\\(?:text|mathrm|textbf|textit|underline|emph|texttt|mathbf|mathit)\\{([^}]+)\\}"

        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: content)
                    }
                }
            }
        }
        return newText
    }

    private func replaceSuperscripts(_ text: String) -> String {
        var newText = text

        // Map of standard chars to superscripts
        let map: [Character: String] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        ]

        func convertToSuper(_ str: String) -> String {
            return str.map { map[$0] ?? String($0) }.joined()
        }

        // 1. Handle ^{...}
        let bracePattern = "\\^\\{([^}]+)\\}"
        if let regex = try? NSRegularExpression(pattern: bracePattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    let superStr = convertToSuper(content)
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: superStr)
                    }
                }
            }
        }

        // 2. Handle ^x (single char)
        let charPattern = "\\^([0-9a-zA-Z+\\-])"
        if let regex = try? NSRegularExpression(pattern: charPattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 2 {
                    let content = nsString.substring(with: result.range(at: 1))
                    let superStr = convertToSuper(content)
                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: superStr)
                    }
                }
            }
        }

        return newText
    }

    private func replaceFrac(_ text: String) -> String {
        var newText = text

        // 1. Handle \frac{a}{b}
        let bracePattern = "\\\\frac\\{([^}]+)\\}\\{([^}]+)\\}"
        if let regex = try? NSRegularExpression(pattern: bracePattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 3 {
                    let num = nsString.substring(with: result.range(at: 1))
                    let den = nsString.substring(with: result.range(at: 2))

                    let numStr = shouldParenthesize(num) ? "(\(num))" : num
                    let denStr = shouldParenthesize(den) ? "(\(den))" : den

                    let replacement = "\(numStr)/\(denStr)"

                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: replacement)
                    }
                }
            }
        }

        // 2. Handle \frac{a}b (single char denominator, not starting with {)
        // Note: Commands like \alpha are already converted to unicode, so they count as single chars.
        let singleDenPattern = "\\\\frac\\{([^}]+)\\}([^\\{])"
        if let regex = try? NSRegularExpression(pattern: singleDenPattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 3 {
                    let num = nsString.substring(with: result.range(at: 1))
                    let den = nsString.substring(with: result.range(at: 2))

                    let numStr = shouldParenthesize(num) ? "(\(num))" : num
                    // den is a single char, no parens needed usually, but let's be safe if it's a digit?
                    // Actually if it's a single char like 'x', 'x' is fine.
                    let replacement = "\(numStr)/\(den)"

                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: replacement)
                    }
                }
            }
        }

        // 3. Handle \frac12 (single digits)
        let digitPattern = "\\\\frac(\\d)(\\d)"
        if let regex = try? NSRegularExpression(pattern: digitPattern) {
            let nsString = newText as NSString
            let results = regex.matches(
                in: newText, range: NSRange(location: 0, length: nsString.length))

            for result in results.reversed() {
                if result.numberOfRanges == 3 {
                    let num = nsString.substring(with: result.range(at: 1))
                    let den = nsString.substring(with: result.range(at: 2))

                    let replacement = "\(num)/\(den)"

                    if let r = Range(result.range(at: 0), in: newText) {
                        newText.replaceSubrange(r, with: replacement)
                    }
                }
            }
        }

        return newText
    }

    private func shouldParenthesize(_ text: String) -> Bool {
        // Add parenthesis if there are multiple terms (contains + or -)
        return text.contains("+") || text.contains("-")
    }

    func cleanLatex(_ latex: String) -> String {
        var content = latex

        // Fix common typos and variants
        content = content.replacingOccurrences(of: "\\dfrac", with: "\\frac")
        content = content.replacingOccurrences(of: "\\tfrac", with: "\\frac")
        content = content.replacingOccurrences(of: "\\trac", with: "\\frac")

        // Fix legacy symbols
        content = content.replacingOccurrences(of: "\\dag", with: "\\dagger")
        content = content.replacingOccurrences(of: "\\ddag", with: "\\ddagger")

        // Remove sizing commands (longest first to avoid partial matches,
        // e.g. stripping \Big from \Bigl leaving a stray "l")
        let sizingCommands = [
            "\\Biggl", "\\Biggr", "\\Biggm", "\\Bigg",
            "\\biggl", "\\biggr", "\\biggm", "\\bigg",
            "\\Bigl", "\\Bigr", "\\Bigm", "\\Big",
            "\\bigl", "\\bigr", "\\bigm", "\\big",
        ]
        for cmd in sizingCommands {
            content = content.replacingOccurrences(of: cmd, with: "")
        }

        // Remove style commands that don't affect layout in display mode
        let styleCommands = [
            "\\displaystyle", "\\textstyle",
            "\\scriptstyle", "\\scriptscriptstyle",
        ]
        for cmd in styleCommands {
            content = content.replacingOccurrences(of: cmd, with: "")
        }

        // \boxed{...} should be supported by SwiftMath. If not, this line was removing it.
        // content = content.replacingOccurrences(of: "\\boxed{", with: "{")

        return content
    }

}
