import AppKit
import PDFKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDF Document Store

struct PDFDocumentItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var timestamp: Date
    var pageSize: String  // "Letter", "A4", "Legal"
    var format: String?  // "pdf", "md", "docx" — nil defaults to "pdf"

    var fileExtension: String {
        switch format ?? "pdf" {
        case "md": return "md"
        case "docx": return "docx"
        case "txt": return "txt"
        case "html": return "html"
        case "swift": return "swift"
        case "py": return "py"
        case "js": return "js"
        case "css": return "css"
        case "json": return "json"
        case "csv": return "csv"
        case "xml": return "xml"
        case "yaml": return "yaml"
        default: return "pdf"
        }
    }

    var formatLabel: String {
        switch format ?? "pdf" {
        case "md": return "Markdown"
        case "docx": return "DOCX"
        case "txt": return "Text"
        case "html": return "HTML"
        case "swift": return "Swift"
        case "py": return "Python"
        case "js": return "JavaScript"
        case "css": return "CSS"
        case "json": return "JSON"
        case "csv": return "CSV"
        case "xml": return "XML"
        case "yaml": return "YAML"
        default: return "PDF"
        }
    }

    var formatIcon: String {
        switch format ?? "pdf" {
        case "md": return "doc.plaintext"
        case "docx": return "doc.text"
        case "txt": return "doc.text"
        case "html": return "globe"
        case "swift", "py", "js": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "json", "xml", "yaml": return "curlybraces"
        case "csv": return "tablecells"
        default: return "doc.richtext.fill"
        }
    }
}

class PDFCreatorStore: ObservableObject {
    static let shared = PDFCreatorStore()

    @Published var items: [PDFDocumentItem] = []

    private let saveDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Prism")
            .appendingPathComponent("CreatedPDFs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var metadataPath: URL { saveDir.appendingPathComponent("pdf_metadata.json") }

    init() {
        loadItems()
    }

    func addItem(_ item: PDFDocumentItem, fileData: Data?) {
        items.insert(item, at: 0)
        if let data = fileData {
            saveFileData(data, for: item)
        }
        saveMetadata()
    }

    func updateItem(_ item: PDFDocumentItem, fileData: Data?) {
        if let data = fileData {
            saveFileData(data, for: item)
        }
        saveMetadata()
    }

    func fileData(for item: PDFDocumentItem) -> Data? {
        let path = saveDir.appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
        if let data = try? Data(contentsOf: path) { return data }
        // Backward compat: try .pdf
        let pdfPath = saveDir.appendingPathComponent("\(item.id.uuidString).pdf")
        return try? Data(contentsOf: pdfPath)
    }

    func deleteItem(_ item: PDFDocumentItem) {
        items.removeAll { $0.id == item.id }
        for ext in ["pdf", "md", "docx", "txt", "html", "swift", "py", "js", "css", "json", "csv", "xml", "yaml"] {
            let path = saveDir.appendingPathComponent("\(item.id.uuidString).\(ext)")
            try? FileManager.default.removeItem(at: path)
        }
        saveMetadata()
    }

    func clearAll() {
        for item in items {
            for ext in ["pdf", "md", "docx", "txt", "html", "swift", "py", "js", "css", "json", "csv", "xml", "yaml"] {
                let path = saveDir.appendingPathComponent("\(item.id.uuidString).\(ext)")
                try? FileManager.default.removeItem(at: path)
            }
        }
        items.removeAll()
        saveMetadata()
    }

    private func saveFileData(_ data: Data, for item: PDFDocumentItem) {
        let path = saveDir.appendingPathComponent("\(item.id.uuidString).\(item.fileExtension)")
        try? data.write(to: path)
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: metadataPath)
        }
    }

    private func loadItems() {
        guard let data = try? Data(contentsOf: metadataPath),
            let loaded = try? JSONDecoder().decode([PDFDocumentItem].self, from: data)
        else { return }
        items = loaded
    }
}

// MARK: - PDF Renderer

struct PDFRenderer {
    /// Page size dimensions in points (72 points = 1 inch)
    static func pageRect(for size: String) -> CGRect {
        switch size {
        case "A4": return CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        case "Legal": return CGRect(x: 0, y: 0, width: 612, height: 1008)
        default: return CGRect(x: 0, y: 0, width: 612, height: 792)  // Letter
        }
    }

    static func renderPDF(from content: String, title: String, pageSize: String) -> Data {
        let pageRect = Self.pageRect(for: pageSize)
        let margin: CGFloat = 54  // 0.75 inch margins
        let contentRect = pageRect.insetBy(dx: margin, dy: margin)

        let pdfData = NSMutableData()
        guard
            let consumer = CGDataConsumer(data: pdfData as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            return Data()
        }

        // Save the previous graphics state so we can restore it when done
        NSGraphicsContext.saveGraphicsState()

        // Parse blocks
        let blocks = parseContentBlocks(content)

        // Render pages
        var yPosition: CGFloat = 0
        var pageStarted = false

        func beginPage() {
            var mediaBox = pageRect
            context.beginPage(mediaBox: &mediaBox)
            // Flip coordinate system for text drawing
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)
            // Re-establish NSGraphicsContext for this page so NSAttributedString.draw() works
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            yPosition = margin
            pageStarted = true
        }

        func endPage() {
            if pageStarted {
                context.endPage()
                pageStarted = false
            }
        }

        func ensureSpace(_ needed: CGFloat) {
            if !pageStarted {
                beginPage()
                return
            }
            if yPosition + needed > pageRect.height - margin {
                endPage()
                beginPage()
            }
        }

        /// Draw an attributed string, splitting across pages if necessary.
        func drawTextBlock(
            _ attrStr: NSAttributedString, x: CGFloat, width: CGFloat, spacing: CGFloat
        ) {
            let totalSize = attrStr.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])

            let remaining = pageRect.height - margin - yPosition
            // If it fits on the current page, draw directly
            if totalSize.height + spacing <= remaining {
                ensureSpace(totalSize.height + spacing)
                attrStr.draw(
                    with: CGRect(
                        x: x, y: yPosition, width: width, height: totalSize.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                yPosition += totalSize.height + spacing
                return
            }

            // Split text line-by-line for page breaks
            let fullString = attrStr.string
            let lines = fullString.components(separatedBy: "\n")
            for line in lines {
                let lineRange = (fullString as NSString).range(of: line)
                let lineAttr: NSAttributedString
                if lineRange.location != NSNotFound
                    && lineRange.location + lineRange.length <= attrStr.length
                {
                    lineAttr = attrStr.attributedSubstring(from: lineRange)
                } else {
                    lineAttr = NSAttributedString(
                        string: line,
                        attributes: attrStr.attributes(at: 0, effectiveRange: nil))
                }
                let lineSize = lineAttr.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                ensureSpace(lineSize.height + 2)
                lineAttr.draw(
                    with: CGRect(
                        x: x, y: yPosition, width: width, height: lineSize.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                yPosition += lineSize.height + 2
            }
            yPosition += max(0, spacing - 2)
        }

        beginPage()

        // Draw title if present
        if !title.isEmpty {
            let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.black,
            ]
            let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
            let titleSize = titleStr.boundingRect(
                with: CGSize(width: contentRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            ensureSpace(titleSize.height + 16)
            titleStr.draw(
                with: CGRect(
                    x: margin, y: yPosition, width: contentRect.width, height: titleSize.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            yPosition += titleSize.height + 16

            // Draw a subtle line under the title
            context.setStrokeColor(NSColor.separatorColor.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: yPosition))
            context.addLine(to: CGPoint(x: pageRect.width - margin, y: yPosition))
            context.strokePath()
            yPosition += 12
        }

        for block in blocks {
            switch block {
            case .heading(let text, let level):
                let fontSize: CGFloat = level == 1 ? 20 : level == 2 ? 17 : 14
                let weight: NSFont.Weight = .bold
                let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.black,
                ]
                let attrStr = NSAttributedString(string: text, attributes: attrs)
                let topPadding: CGFloat = level == 1 ? 18 : 12
                ensureSpace(topPadding + 20)
                yPosition += topPadding
                drawTextBlock(attrStr, x: margin, width: contentRect.width, spacing: 6)

            case .text(let text):
                let attributed = renderInlineFormatting(
                    text, baseFont: NSFont.systemFont(ofSize: 12), width: contentRect.width)
                drawTextBlock(attributed, x: margin, width: contentRect.width, spacing: 6)

            case .bullet(let text):
                let bulletStr = "•  "
                let fullText = bulletStr + text
                let attributed = renderInlineFormatting(
                    fullText, baseFont: NSFont.systemFont(ofSize: 12),
                    width: contentRect.width - 16)
                drawTextBlock(
                    attributed, x: margin + 16, width: contentRect.width - 16, spacing: 4)

            case .numbered(let text, let num):
                let fullText = "\(num).  \(text)"
                let attributed = renderInlineFormatting(
                    fullText, baseFont: NSFont.systemFont(ofSize: 12),
                    width: contentRect.width - 16)
                drawTextBlock(
                    attributed, x: margin + 16, width: contentRect.width - 16, spacing: 4)

            case .code(let code, let language):
                let codeFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                let codeAttrs: [NSAttributedString.Key: Any] = [
                    .font: codeFont,
                    .foregroundColor: NSColor.darkGray,
                ]
                let attrStr = NSAttributedString(string: code, attributes: codeAttrs)
                let size = attrStr.boundingRect(
                    with: CGSize(width: contentRect.width - 20, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                let blockHeight = size.height + 16
                ensureSpace(blockHeight + 8)

                // Draw code background
                let codeRect = CGRect(
                    x: margin, y: yPosition, width: contentRect.width, height: blockHeight)
                context.setFillColor(NSColor(white: 0.94, alpha: 1.0).cgColor)
                let codePath = CGPath(
                    roundedRect: codeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                context.addPath(codePath)
                context.fillPath()

                // Draw language label if present
                if !language.isEmpty {
                    let langFont = NSFont.systemFont(ofSize: 9, weight: .medium)
                    let langAttrs: [NSAttributedString.Key: Any] = [
                        .font: langFont,
                        .foregroundColor: NSColor.gray,
                    ]
                    let langStr = NSAttributedString(string: language, attributes: langAttrs)
                    langStr.draw(at: CGPoint(x: margin + 8, y: yPosition + 4))
                }

                attrStr.draw(
                    with: CGRect(
                        x: margin + 10, y: yPosition + (language.isEmpty ? 8 : 16),
                        width: contentRect.width - 20, height: size.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                yPosition += blockHeight + 8

            case .blockquote(let text):
                let quoteFont = NSFont.systemFont(ofSize: 12)
                let quoteAttrs: [NSAttributedString.Key: Any] = [
                    .font: quoteFont,
                    .foregroundColor: NSColor.darkGray,
                    .obliqueness: 0.15 as NSNumber,
                ]
                let attrStr = NSAttributedString(string: text, attributes: quoteAttrs)
                let size = attrStr.boundingRect(
                    with: CGSize(width: contentRect.width - 24, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                ensureSpace(size.height + 8)

                // Draw quote bar
                context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.3).cgColor)
                context.fill(
                    CGRect(x: margin + 4, y: yPosition, width: 3, height: size.height + 4))

                attrStr.draw(
                    with: CGRect(
                        x: margin + 16, y: yPosition + 2, width: contentRect.width - 24,
                        height: size.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
                yPosition += size.height + 8

            case .divider:
                ensureSpace(16)
                yPosition += 6
                context.setStrokeColor(NSColor.separatorColor.cgColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: margin, y: yPosition))
                context.addLine(to: CGPoint(x: pageRect.width - margin, y: yPosition))
                context.strokePath()
                yPosition += 10

            case .math(let latex):
                // Render LaTeX as an image using SwiftMath
                if let mathImage = renderLaTeXToImage(
                    latex, width: contentRect.width, fontSize: 16)
                {
                    let imgSize = mathImage.size
                    let scale = min(1.0, contentRect.width / imgSize.width)
                    let drawWidth = imgSize.width * scale
                    let drawHeight = imgSize.height * scale
                    ensureSpace(drawHeight + 12)
                    let xOffset = margin + (contentRect.width - drawWidth) / 2
                    let drawRect = CGRect(
                        x: xOffset, y: yPosition, width: drawWidth, height: drawHeight)

                    // Draw math background
                    let mathBgRect = CGRect(
                        x: margin, y: yPosition - 4, width: contentRect.width,
                        height: drawHeight + 8)
                    context.setFillColor(NSColor(white: 0.97, alpha: 1.0).cgColor)
                    let mathPath = CGPath(
                        roundedRect: mathBgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                    context.addPath(mathPath)
                    context.fillPath()

                    // Draw math image directly via NSImage.draw for best quality
                    mathImage.draw(in: drawRect)
                    yPosition += drawHeight + 12
                } else {
                    // Fallback: render as monospaced text
                    let mathFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    let mathAttrs: [NSAttributedString.Key: Any] = [
                        .font: mathFont,
                        .foregroundColor: NSColor.darkGray,
                    ]
                    let attrStr = NSAttributedString(string: latex, attributes: mathAttrs)
                    let size = attrStr.boundingRect(
                        with: CGSize(
                            width: contentRect.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                    ensureSpace(size.height + 8)
                    attrStr.draw(
                        with: CGRect(
                            x: margin, y: yPosition, width: contentRect.width,
                            height: size.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                    yPosition += size.height + 8
                }

            case .table(let headers, let rows):
                let colCount = max(headers.count, rows.first?.count ?? 0)
                guard colCount > 0 else { break }
                let colWidth = contentRect.width / CGFloat(colCount)
                let cellFont = NSFont.systemFont(ofSize: 11)
                let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let rowHeight: CGFloat = 22

                let totalHeight = rowHeight * CGFloat(1 + rows.count)
                ensureSpace(totalHeight + 8)

                // Header row
                context.setFillColor(NSColor(white: 0.92, alpha: 1.0).cgColor)
                context.fill(
                    CGRect(
                        x: margin, y: yPosition, width: contentRect.width, height: rowHeight))
                for (colIdx, header) in headers.enumerated() {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: headerFont, .foregroundColor: NSColor.black,
                    ]
                    let str = NSAttributedString(string: header, attributes: attrs)
                    str.draw(
                        in: CGRect(
                            x: margin + CGFloat(colIdx) * colWidth + 6, y: yPosition + 4,
                            width: colWidth - 12, height: rowHeight - 8))
                }
                yPosition += rowHeight

                // Data rows
                for row in rows {
                    // Alternating row bg
                    for (colIdx, cell) in row.enumerated() {
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: cellFont, .foregroundColor: NSColor.darkGray,
                        ]
                        let str = NSAttributedString(string: cell, attributes: attrs)
                        str.draw(
                            in: CGRect(
                                x: margin + CGFloat(colIdx) * colWidth + 6, y: yPosition + 4,
                                width: colWidth - 12, height: rowHeight - 8))
                    }
                    yPosition += rowHeight
                }

                // Table border
                context.setStrokeColor(NSColor.separatorColor.cgColor)
                context.setLineWidth(0.5)
                context.stroke(
                    CGRect(
                        x: margin, y: yPosition - totalHeight, width: contentRect.width,
                        height: totalHeight))
                yPosition += 8
            }
        }

        endPage()
        context.closePDF()

        NSGraphicsContext.restoreGraphicsState()

        return pdfData as Data
    }

    // MARK: - Block Parsing

    private enum ContentBlock {
        case heading(String, Int)
        case text(String)
        case bullet(String)
        case numbered(String, Int)
        case code(String, String)
        case blockquote(String)
        case divider
        case math(String)
        case table([String], [[String]])
    }

    private static func parseContentBlocks(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let lines = content.components(separatedBy: .newlines)
        var currentText = ""
        var inCodeBlock = false
        var codeContent = ""
        var codeLang = ""
        var inMathBlock = false
        var mathContent = ""
        var mathDelimiter = ""

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(
                        .code(codeContent.trimmingCharacters(in: .newlines), codeLang))
                    codeContent = ""
                    codeLang = ""
                    inCodeBlock = false
                } else {
                    if !currentText.isEmpty {
                        blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                        currentText = ""
                    }
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                codeContent += line + "\n"
            } else if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let isBracket = trimmed.hasPrefix("\\[")
                let startDelim = isBracket ? "\\[" : "$$"
                let endDelim = isBracket ? "\\]" : "$$"

                if inMathBlock && trimmed.hasSuffix(mathDelimiter) {
                    mathContent += String(trimmed.dropLast(mathDelimiter.count))
                    blocks.append(.math(mathContent.trimmingCharacters(in: .newlines)))
                    mathContent = ""
                    inMathBlock = false
                } else if !inMathBlock {
                    if !currentText.isEmpty {
                        blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                        currentText = ""
                    }
                    let afterOpen = String(trimmed.dropFirst(startDelim.count))
                    if let closeRange = afterOpen.range(of: endDelim) {
                        let mathStr = String(afterOpen[..<closeRange.lowerBound])
                        blocks.append(.math(mathStr.trimmingCharacters(in: .whitespaces)))
                    } else {
                        inMathBlock = true
                        mathDelimiter = endDelim
                        if !afterOpen.isEmpty { mathContent += afterOpen + "\n" }
                    }
                } else {
                    mathContent += line + "\n"
                }
            } else if inMathBlock {
                if trimmed.hasSuffix(mathDelimiter) {
                    mathContent += String(trimmed.dropLast(mathDelimiter.count))
                    blocks.append(.math(mathContent.trimmingCharacters(in: .newlines)))
                    mathContent = ""
                    inMathBlock = false
                } else {
                    mathContent += line + "\n"
                }
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.divider)
            } else if trimmed.hasPrefix("# ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.heading(String(trimmed.dropFirst(2)), 1))
            } else if trimmed.hasPrefix("## ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.heading(String(trimmed.dropFirst(3)), 2))
            } else if trimmed.hasPrefix("### ") || trimmed.hasPrefix("#### ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                let level = trimmed.hasPrefix("#### ") ? 4 : 3
                let drop = level + 1
                blocks.append(.heading(String(trimmed.dropFirst(drop)), level))
            } else if trimmed.hasPrefix("\\section{") && trimmed.hasSuffix("}") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.heading(String(trimmed.dropFirst(9).dropLast(1)), 1))
            } else if trimmed.hasPrefix("\\subsection{") && trimmed.hasSuffix("}") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.heading(String(trimmed.dropFirst(12).dropLast(1)), 2))
            } else if trimmed.hasPrefix("\\item ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.bullet(String(trimmed.dropFirst(6))))
            } else if trimmed.hasPrefix("\\begin{") || trimmed.hasPrefix("\\end{") {
                // Detect math environments and collect as math blocks
                let mathEnvs = [
                    "equation", "align", "aligned", "gather", "gathered",
                    "multline", "eqnarray", "math", "displaymath", "split",
                    "equation*", "align*", "gather*", "multline*", "eqnarray*",
                ]
                var isMathEnv = false
                for env in mathEnvs {
                    if trimmed == "\\begin{\(env)}" {
                        isMathEnv = true
                        break
                    }
                }
                if isMathEnv && !inMathBlock {
                    if !currentText.isEmpty {
                        blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                        currentText = ""
                    }
                    // Find the env name for the end marker
                    let envStart = trimmed.index(trimmed.startIndex, offsetBy: 7)
                    let envEnd = trimmed.firstIndex(of: "}") ?? trimmed.endIndex
                    let envName = String(trimmed[envStart..<envEnd])
                    let endMarker = "\\end{\(envName)}"
                    inMathBlock = true
                    mathDelimiter = endMarker
                } else if inMathBlock && trimmed == mathDelimiter {
                    blocks.append(
                        .math(mathContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                    mathContent = ""
                    inMathBlock = false
                } else if inMathBlock {
                    mathContent += line + "\n"
                }
                // Non-math environments: skip
            } else if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                let numStr = String(trimmed[..<match.upperBound].dropLast(2))
                let num = Int(numStr) ?? 1
                blocks.append(.numbered(String(trimmed[match.upperBound...]), num))
            } else if trimmed.hasPrefix("> ") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                blocks.append(.blockquote(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("|") {
                if !currentText.isEmpty {
                    blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.hasPrefix("|") && nextLine.contains("---") {
                        let headers = trimmed.split(separator: "|").map {
                            String($0).trimmingCharacters(in: .whitespaces)
                        }
                        var rows: [[String]] = []
                        i += 2
                        while i < lines.count {
                            let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                            if !rowLine.hasPrefix("|") {
                                i -= 1
                                break
                            }
                            let cells = rowLine.split(separator: "|").map {
                                String($0).trimmingCharacters(in: .whitespaces)
                            }
                            if !cells.isEmpty { rows.append(cells) }
                            i += 1
                        }
                        blocks.append(.table(headers, rows))
                    } else {
                        currentText += line + "\n"
                    }
                } else {
                    currentText += line + "\n"
                }
            } else {
                // Check for inline $$ math embedded in text (e.g., "The formula is $$x^2$$ here")
                if trimmed.contains("$$") {
                    var rest = trimmed
                    var hasInlineMath = false
                    while let openRange = rest.range(of: "$$") {
                        let before = String(rest[rest.startIndex..<openRange.lowerBound])
                        let afterOpen = String(rest[openRange.upperBound...])
                        if let closeRange = afterOpen.range(of: "$$") {
                            hasInlineMath = true
                            if !before.trimmingCharacters(in: .whitespaces).isEmpty {
                                if !currentText.isEmpty {
                                    blocks.append(
                                        .text(currentText.trimmingCharacters(in: .newlines)))
                                    currentText = ""
                                }
                                blocks.append(
                                    .text(before.trimmingCharacters(in: .whitespaces)))
                            } else if !currentText.isEmpty {
                                blocks.append(
                                    .text(currentText.trimmingCharacters(in: .newlines)))
                                currentText = ""
                            }
                            let mathStr = String(afterOpen[..<closeRange.lowerBound])
                            blocks.append(
                                .math(mathStr.trimmingCharacters(in: .whitespaces)))
                            rest = String(afterOpen[closeRange.upperBound...])
                        } else {
                            break
                        }
                    }
                    if hasInlineMath {
                        let leftover = rest.trimmingCharacters(in: .whitespaces)
                        if !leftover.isEmpty {
                            currentText += leftover + "\n"
                        }
                    } else {
                        currentText += line + "\n"
                    }
                } else {
                    currentText += line + "\n"
                }
            }
            i += 1
        }

        if !currentText.isEmpty {
            blocks.append(.text(currentText.trimmingCharacters(in: .newlines)))
        }

        return blocks
    }

    // MARK: - Inline Formatting

    private static func renderInlineFormatting(
        _ text: String, baseFont: NSFont, width: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]

        // Process inline formatting: **bold**, *italic*, `code`, $math$, \(math\)
        // Uses position-based matching to handle earliest match first
        var remaining = text
        while !remaining.isEmpty {
            var earliestRange: Range<String.Index>?
            var earliestType = ""

            // Find bold **text**
            if let r = remaining.range(of: "\\*\\*(.+?)\\*\\*", options: .regularExpression) {
                if earliestRange == nil || r.lowerBound < earliestRange!.lowerBound {
                    earliestRange = r
                    earliestType = "bold"
                }
            }
            // Find italic *text*
            if let r = remaining.range(
                of: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", options: .regularExpression)
            {
                if earliestRange == nil || r.lowerBound < earliestRange!.lowerBound {
                    earliestRange = r
                    earliestType = "italic"
                }
            }
            // Find code `text`
            if let r = remaining.range(of: "`(.+?)`", options: .regularExpression) {
                if earliestRange == nil || r.lowerBound < earliestRange!.lowerBound {
                    earliestRange = r
                    earliestType = "code"
                }
            }
            // Find $math$
            if let r = remaining.range(
                of: "(?<!\\$)\\$(?!\\$)(.+?)(?<!\\$)\\$(?!\\$)", options: .regularExpression)
            {
                if earliestRange == nil || r.lowerBound < earliestRange!.lowerBound {
                    earliestRange = r
                    earliestType = "dollarmath"
                }
            }
            // Find \(math\)
            if let r = remaining.range(
                of: "\\\\\\((.+?)\\\\\\)", options: .regularExpression)
            {
                if earliestRange == nil || r.lowerBound < earliestRange!.lowerBound {
                    earliestRange = r
                    earliestType = "parenmath"
                }
            }

            guard let matchRange = earliestRange else {
                result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
                break
            }

            // Append text before the match
            let prefix = String(remaining[remaining.startIndex..<matchRange.lowerBound])
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
            }

            let matched = String(remaining[matchRange])

            switch earliestType {
            case "bold":
                let inner = String(matched.dropFirst(2).dropLast(2))
                var attrs = baseAttrs
                attrs[.font] = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                result.append(NSAttributedString(string: inner, attributes: attrs))

            case "italic":
                let inner = String(matched.dropFirst(1).dropLast(1))
                var attrs = baseAttrs
                attrs[.font] = NSFontManager.shared.convert(
                    baseFont, toHaveTrait: .italicFontMask)
                result.append(NSAttributedString(string: inner, attributes: attrs))

            case "code":
                let inner = String(matched.dropFirst(1).dropLast(1))
                var attrs = baseAttrs
                attrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize - 1, weight: .regular)
                attrs[.backgroundColor] = NSColor(white: 0.92, alpha: 1.0)
                result.append(NSAttributedString(string: inner, attributes: attrs))

            case "dollarmath":
                let inner = String(matched.dropFirst(1).dropLast(1))
                if let mathImage = renderLaTeXToImage(
                    inner, width: width, fontSize: baseFont.pointSize + 2)
                {
                    let attachment = NSTextAttachment()
                    attachment.image = mathImage
                    let imgHeight = mathImage.size.height
                    attachment.bounds = CGRect(
                        x: 0, y: -(imgHeight * 0.25),
                        width: mathImage.size.width, height: imgHeight)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    var attrs = baseAttrs
                    attrs[.font] = NSFont.monospacedSystemFont(
                        ofSize: baseFont.pointSize, weight: .regular)
                    attrs[.foregroundColor] = NSColor.darkGray
                    result.append(NSAttributedString(string: inner, attributes: attrs))
                }

            case "parenmath":
                let inner = String(matched.dropFirst(2).dropLast(2))
                if let mathImage = renderLaTeXToImage(
                    inner, width: width, fontSize: baseFont.pointSize + 2)
                {
                    let attachment = NSTextAttachment()
                    attachment.image = mathImage
                    let imgHeight = mathImage.size.height
                    attachment.bounds = CGRect(
                        x: 0, y: -(imgHeight * 0.25),
                        width: mathImage.size.width, height: imgHeight)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    var attrs = baseAttrs
                    attrs[.font] = NSFont.monospacedSystemFont(
                        ofSize: baseFont.pointSize, weight: .regular)
                    attrs[.foregroundColor] = NSColor.darkGray
                    result.append(NSAttributedString(string: inner, attributes: attrs))
                }

            default:
                break
            }

            remaining = String(remaining[matchRange.upperBound...])
        }

        return result
    }

    // MARK: - LaTeX Sanitization

    /// Clean up LaTeX to improve SwiftMath compatibility
    private static func cleanLatex(_ latex: String) -> String {
        var content = latex

        // Fix common typos and variants
        content = content.replacingOccurrences(of: "\\dfrac", with: "\\frac")
        content = content.replacingOccurrences(of: "\\tfrac", with: "\\frac")
        content = content.replacingOccurrences(of: "\\trac", with: "\\frac")

        // Fix legacy symbols
        content = content.replacingOccurrences(of: "\\dag", with: "\\dagger")
        content = content.replacingOccurrences(of: "\\ddag", with: "\\ddagger")

        // Remove sizing commands (longest first to avoid partial matches)
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

        // Strip unsupported environment wrappers (aligned, equation, gather, etc.)
        // but keep matrix, pmatrix, bmatrix, Bmatrix, vmatrix, Vmatrix, cases
        // which SwiftMath supports natively
        let unsupportedEnvs = [
            "aligned", "equation", "equation*", "align", "align*",
            "gather", "gather*", "gathered", "multline", "multline*",
            "eqnarray", "eqnarray*", "split", "displaymath", "math",
        ]
        for env in unsupportedEnvs {
            content = content.replacingOccurrences(of: "\\begin{\(env)}", with: "")
            content = content.replacingOccurrences(of: "\\end{\(env)}", with: "")
        }

        // Handle \boxed{...} → just the content
        if let regex = try? NSRegularExpression(
            pattern: "\\\\boxed\\{([^}]*)\\}", options: [])
        {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(
                in: content, options: [], range: range, withTemplate: "$1")
        }

        // Normalize spacing commands
        content = content.replacingOccurrences(of: "\\qquad", with: "\\quad")
        content = content.replacingOccurrences(
            of: "\\hspace{[^}]*}", with: " ", options: .regularExpression)

        // NOTE: Do NOT remove \\ and & here — handled by renderLaTeXToImage
        // for proper multi-line math support

        // Clean up excessive whitespace
        while content.contains("  ") {
            content = content.replacingOccurrences(of: "  ", with: " ")
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        return content
    }

    // MARK: - LaTeX to Image (SwiftMath)

    private static func renderLaTeXToImage(
        _ latex: String, width: CGFloat, fontSize: CGFloat
    ) -> NSImage? {
        // Handle multi-line math (aligned environments with \\ line breaks)
        if latex.contains("\\\\") {
            let lines = latex.components(separatedBy: "\\\\")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if lines.count > 1 {
                var images: [NSImage] = []
                for line in lines {
                    var cleaned = cleanLatex(line)
                    cleaned = cleaned.replacingOccurrences(of: "&", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    if cleaned.isEmpty { continue }
                    let img = MTMathImage(
                        latex: cleaned, fontSize: fontSize, textColor: .black,
                        labelMode: .display)
                    let (_, result) = img.asImage()
                    if let r = result, r.size.width > 0, r.size.height > 0 {
                        images.append(r)
                    }
                }
                if !images.isEmpty {
                    return composeVertically(images)
                }
            }
        }

        let cleaned = cleanLatex(latex)
        guard !cleaned.isEmpty else { return nil }

        // For single-line, replace alignment chars
        let finalCleaned =
            cleaned
            .replacingOccurrences(of: "\\\\", with: " ")
            .replacingOccurrences(of: "&", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !finalCleaned.isEmpty else { return nil }

        // Use MTMathImage for high-quality vector rendering
        let mathImage = MTMathImage(
            latex: finalCleaned, fontSize: fontSize, textColor: .black,
            labelMode: .display)
        let (_, generatedImage) = mathImage.asImage()

        if let img = generatedImage, img.size.width > 0, img.size.height > 0 {
            return img
        }

        // If full expression fails, try progressively simplifying
        return renderLaTeXWithSimplification(finalCleaned, width: width, fontSize: fontSize)
    }

    /// Compose multiple images vertically (for multi-line math)
    private static func composeVertically(_ images: [NSImage], spacing: CGFloat = 4) -> NSImage {
        let maxWidth = images.map { $0.size.width }.max() ?? 0
        let totalHeight =
            images.map { $0.size.height }.reduce(0, +)
            + CGFloat(images.count - 1) * spacing
        let combined = NSImage(size: NSSize(width: maxWidth, height: totalHeight))
        combined.lockFocus()
        var y = totalHeight
        for img in images {
            y -= img.size.height
            img.draw(
                at: NSPoint(x: (maxWidth - img.size.width) / 2, y: y),
                from: .zero, operation: .sourceOver, fraction: 1.0)
            y -= spacing
        }
        combined.unlockFocus()
        return combined
    }

    /// Progressively simplify LaTeX until SwiftMath can render it
    private static func renderLaTeXWithSimplification(
        _ latex: String, width: CGFloat, fontSize: CGFloat
    ) -> NSImage? {
        var content = latex

        // Step 1: Try stripping \left and \right (they require matched pairs)
        let simplified1 =
            content
            .replacingOccurrences(of: "\\left", with: "")
            .replacingOccurrences(of: "\\right", with: "")
        let img1 = MTMathImage(
            latex: simplified1, fontSize: fontSize, textColor: .black, labelMode: .display)
        let (_, result1) = img1.asImage()
        if let img = result1, img.size.width > 0, img.size.height > 0 {
            return img
        }

        // Step 2: Also strip \text{...} → just inner content
        content = simplified1
        // Use NSRegularExpression to properly match \text{...}
        if let regex = try? NSRegularExpression(
            pattern: "\\\\text\\{([^}]*)\\}", options: [])
        {
            let range = NSRange(content.startIndex..., in: content)
            content = regex.stringByReplacingMatches(
                in: content, options: [], range: range, withTemplate: "$1")
        }
        // Also try \textbf, \textit, \mathrm, \mathit patterns
        for cmd in [
            "\\\\textbf", "\\\\textit", "\\\\mathrm", "\\\\mathit", "\\\\mathbb", "\\\\mathcal",
        ] {
            if let regex = try? NSRegularExpression(
                pattern: cmd + "\\{([^}]*)\\}", options: [])
            {
                let range = NSRange(content.startIndex..., in: content)
                content = regex.stringByReplacingMatches(
                    in: content, options: [], range: range, withTemplate: "$1")
            }
        }

        let img2 = MTMathImage(
            latex: content, fontSize: fontSize, textColor: .black, labelMode: .display)
        let (_, result2) = img2.asImage()
        if let img = result2, img.size.width > 0, img.size.height > 0 {
            return img
        }

        // Step 3: Try rendering as just the core expression without any wrappers
        // Strip remaining braces and try
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            let img3 = MTMathImage(
                latex: content, fontSize: fontSize, textColor: .black, labelMode: .text)
            let (_, result3) = img3.asImage()
            if let img = result3, img.size.width > 0, img.size.height > 0 {
                return img
            }
        }

        return nil
    }
}

// MARK: - PDF Creator View

struct PDFCreatorView: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("ImageDownloadPath") private var fileDownloadPath: String = ""
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String = "llama-3.1-70b-instruct"
    @AppStorage("SelectedCopilotModel") private var selectedCopilotModel: String = "gpt-4o"
    @AppStorage("SelectedGeminiCLIModel") private var selectedGeminiCLIModel: String = "gemini-2.5-flash"
    @AppStorage("PDFProvider") private var pdfProvider: String = "Gemini API"
    @AppStorage("PDFModel") private var pdfModel: String = "gemini-2.5-flash"
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var store = PDFCreatorStore.shared
    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @ObservedObject private var copilotModelManager = GitHubCopilotModelManager.shared
    @ObservedObject private var geminiCLIService = GeminiCLIService.shared

    @State private var prompt: String = ""
    @State private var selectedPageSize: String = "Letter"
    @State private var showResetConfirmation: Bool = false
    @State private var selectedPDFPreview: UUID? = nil
    @State private var pdfPreviewData: Data? = nil
    @State private var showPDFPreview: Bool = false
    @State private var previewItem: PDFDocumentItem? = nil
    @State private var savedItemIds: Set<UUID> = []
    @State private var isInputExpanded: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generateTask: Task<Void, Never>?
    @State private var generationError: String? = nil
    @State private var pdfThinkingLevel: String = "medium"
    @State private var pdfWebSearchEnabled: Bool = false
    @State private var isPromptFocused: Bool = false
    @State private var selectedFormat: String = "pdf"

    private let pageSizes = ["Letter", "A4", "Legal"]
    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()
    private let nvidiaService = NvidiaService()
    private let webSearchService = WebSearchService()

    private var pdfHasThinkingCapability: Bool {
        let lower = pdfModel.lowercased()
        return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
    }

    private var providerIcon: String {
        switch pdfProvider {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "chevron.left.forwardslash.chevron.right"
        case "Gemini CLI": return "terminal"
        default: return "cpu"
        }
    }

    private func effectiveThinkingLevel(provider: String, model: String, level: String) -> String {
        if provider == "Gemini API" {
            return "none"
        } else if provider == "Ollama" {
            let lower = model.lowercased()
            if lower.contains("gpt-oss") {
                return level
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return level == "high" ? "true" : "false"
            }
            return "false"
        }
        return "none"
    }

    var body: some View {
        ZStack {
            Group {
                if store.items.isEmpty && !isGenerating {
                    emptyState
                } else if isGenerating {
                    generatingView
                } else {
                    mainContent
                }
            }
            .safeAreaInset(edge: .top) {
                header
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
            .allowsHitTesting(!showPDFPreview)

            // Preview overlay
            if showPDFPreview, let data = pdfPreviewData {
                FilePreviewOverlay(
                    data: data,
                    format: previewItem?.format ?? "pdf",
                    content: previewItem?.content ?? ""
                ) {
                    showPDFPreview = false
                    pdfPreviewData = nil
                    selectedPDFPreview = nil
                    previewItem = nil
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear All Files", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("This will permanently delete all created files. This cannot be undone.")
        }
        .onDisappear {
            generateTask?.cancel()
            generateTask = nil
            isGenerating = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors.isEmpty
                                ? [.indigo, .purple] : appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("File Creator")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            // Provider pill
            HStack(spacing: 4) {
                Image(systemName: providerIcon)
                    .font(.system(size: 10))
                Text(pdfModel.count > 20 ? String(pdfModel.prefix(18)) + "…" : pdfModel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)

            if !store.items.isEmpty {
                Button(action: { showResetConfirmation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.clear)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .indigo
        let endColor = colors.last ?? .purple

        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [startColor.opacity(0.12), startColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .offset(x: -70, y: -50)
                .blur(radius: 40)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [endColor.opacity(0.1), endColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)
                .offset(x: 80, y: 40)
                .blur(radius: 35)

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 82, height: 82)
                        .glassEffect(.regular, in: .circle)
                        .shadow(color: startColor.opacity(0.12), radius: 16, x: 0, y: 8)

                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                VStack(spacing: 8) {
                    Text("AI File Creator")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text(
                        "Describe what you need and AI will generate a formatted file"
                    )
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                }

                HStack(spacing: 8) {
                    ForEach(["Markdown", "LaTeX", "Code", "Tables"], id: \.self) { feature in
                        Text(feature)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.top, 2)

                // Template suggestions
                VStack(spacing: 8) {
                    Text("Quick Start")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .padding(.top, 8)

                    let templates: [(String, String, String)] = [
                        ("doc.text", "Essay", "Write a well-structured essay about"),
                        ("list.bullet", "Study Guide", "Create a comprehensive study guide for"),
                        ("chart.bar", "Report", "Generate a professional report with data on"),
                        ("chevron.left.forwardslash.chevron.right", "Code File", "Write clean, well-documented code for"),
                        ("globe", "Web Page", "Create an HTML page with CSS for"),
                        ("tablecells", "CSV Data", "Generate a CSV dataset with sample data for"),
                    ]

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(templates, id: \.1) { icon, label, promptPrefix in
                            Button(action: {
                                prompt = promptPrefix + " "
                                // Auto-set format based on template
                                switch label {
                                case "Code File": selectedFormat = "swift"
                                case "Web Page": selectedFormat = "html"
                                case "CSV Data": selectedFormat = "csv"
                                default: selectedFormat = "pdf"
                                }
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    isInputExpanded = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    isPromptFocused = true
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(startColor)
                                    Text(label)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.7))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 400)
                }
                .padding(.top, 4)

                if let error = generationError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 400)
                        .transition(.opacity)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    // MARK: - Generating View

    private var generatingView: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .indigo
        let endColor = colors.last ?? .purple

        return VStack(spacing: 20) {
            Spacer()

            ProgressView()
                .scaleEffect(1.2)
                .tint(startColor)

            Text("Generating \(selectedFormat.uppercased())…")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [startColor, endColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text(prompt.prefix(100) + (prompt.count > 100 ? "…" : ""))
                .font(.system(size: 13))
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button(action: {
                generateTask?.cancel()
                generateTask = nil
                isGenerating = false
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main Content (Document List)

    private var mainContent: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if let error = generationError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 400)
                        .transition(.opacity)
                }

                ForEach(store.items) { item in
                    documentCard(item)
                        .id(item.id)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Document Card

    private func documentCard(_ item: PDFDocumentItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? "Untitled Document" : item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.formatLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))
                        Text(item.pageSize)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Text("·")
                            .foregroundStyle(.secondary.opacity(0.4))
                        Text(item.timestamp, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
                Spacer()

                Image(systemName: item.formatIcon)
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors.isEmpty
                                ? [.indigo, .purple] : appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text(item.content.prefix(200) + (item.content.count > 200 ? "..." : ""))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.7))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ExpandingActionButton(
                    title: "Preview",
                    icon: "eye",
                    color: .secondary,
                    font: .system(size: 12),
                    action: {
                        if let data = store.fileData(for: item) {
                            pdfPreviewData = data
                            selectedPDFPreview = item.id
                            previewItem = item
                            showPDFPreview = true
                        }
                    }
                )

                ExpandingActionButton(
                    title: "Copy",
                    icon: "doc.on.doc",
                    color: .secondary,
                    font: .system(size: 12),
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.content, forType: .string)
                    }
                )

                ExpandingActionButton(
                    title: "Regenerate",
                    icon: "arrow.clockwise",
                    color: .secondary,
                    font: .system(size: 12),
                    action: {
                        // Re-generate using the same content as the prompt
                        let titlePrompt = item.title.isEmpty ? String(item.content.prefix(100)) : item.title
                        prompt = "Regenerate: \(titlePrompt)"
                        selectedFormat = item.format ?? "pdf"
                        selectedPageSize = item.pageSize
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            isInputExpanded = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isPromptFocused = true
                        }
                    }
                )

                if !fileDownloadPath.isEmpty {
                    ExpandingActionButton(
                        title: savedItemIds.contains(item.id)
                            ? "Saved!" : "Save",
                        icon: savedItemIds.contains(item.id)
                            ? "checkmark" : "arrow.down.circle",
                        color: savedItemIds.contains(item.id) ? .green : .secondary,
                        font: .system(size: 12),
                        action: {
                            saveFileToConfiguredPath(item)
                            savedItemIds.insert(item.id)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                savedItemIds.remove(item.id)
                            }
                        }
                    )
                }

                ExpandingActionButton(
                    title: "Export",
                    icon: "square.and.arrow.up",
                    color: .secondary,
                    font: .system(size: 12),
                    action: {
                        exportFile(item)
                    }
                )

                Spacer()

                Button(action: {
                    withAnimation {
                        store.deleteItem(item)
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .contextMenu {
            Button("Preview") {
                if let data = store.fileData(for: item) {
                    pdfPreviewData = data
                    selectedPDFPreview = item.id
                    previewItem = item
                    showPDFPreview = true
                }
            }
            Button("Copy Content") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.content, forType: .string)
            }
            Button("Export...") { exportFile(item) }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteItem(item)
            }
        }
    }

    // MARK: - Input Bar (Bottom)

    private var inputBar: some View {
        VStack(spacing: 0) {
            if isInputExpanded {
                expandedInputBar
            } else {
                collapsedInputBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.clear)
    }

    private var collapsedInputBar: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isInputExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPromptFocused = true
            }
        }) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: appTheme.colors.isEmpty
                            ? [.indigo, .purple] : appTheme.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: appTheme.colors.isEmpty
                                    ? [.indigo.opacity(0.5), .purple.opacity(0.5)]
                                    : appTheme.colors.map { $0.opacity(0.5) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.3) : Color.black.opacity(0.06),
            radius: 16, x: 0, y: 6
        )
    }

    private var expandedInputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Provider selector button
                Menu {
                    Button(action: {
                        pdfProvider = "Apple Foundation"
                        pdfModel = "Apple Foundation"
                    }) {
                        Label("Apple Foundation", systemImage: "apple.logo")
                    }
                    Divider()
                    Menu("Gemini API") {
                        ForEach(geminiManager.availableModels, id: \.self) { model in
                            Button(action: {
                                pdfProvider = "Gemini API"
                                pdfModel = model
                            }) {
                                Text(geminiManager.displayName(for: model))
                            }
                        }
                    }
                    Menu("Ollama") {
                        ForEach(ollamaManager.allModels, id: \.self) { model in
                            Button(action: {
                                pdfProvider = "Ollama"
                                pdfModel = model
                            }) {
                                Text(model)
                            }
                        }
                    }
                    if !nvidiaKey.isEmpty {
                        Menu("NVIDIA API") {
                            ForEach(nvidiaManager.availableModels, id: \.self) { model in
                                Button(action: {
                                    pdfProvider = "NVIDIA API"
                                    pdfModel = model
                                }) {
                                    Text(nvidiaManager.displayName(for: model))
                                }
                            }
                        }
                    }
                    if copilotService.isAuthenticated {
                        Menu("GitHub Copilot") {
                            ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                Button(action: {
                                    pdfProvider = "GitHub Copilot"
                                    pdfModel = model
                                }) {
                                    Text(copilotModelManager.displayName(for: model))
                                }
                            }
                        }
                    }
                    if geminiCLIService.isAvailable {
                        Menu("Gemini CLI") {
                            ForEach(GeminiCLIService.availableModels, id: \.id) { model in
                                Button(action: {
                                    pdfProvider = "Gemini CLI"
                                    pdfModel = model.id
                                }) {
                                    Text(model.name)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: providerIcon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.04))
                        )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .help("\(pdfProvider) — \(pdfModel)")

                // Text input
                ZStack(alignment: .leading) {
                    if prompt.isEmpty && !isPromptFocused {
                        Text("Describe what you want to create")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.55)
                                    : Color.secondary.opacity(0.6)
                            )
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }

                    NativeTextInput(
                        text: $prompt,
                        isFocused: $isPromptFocused,
                        font: .systemFont(ofSize: 15),
                        textColor: colorScheme == .dark ? .white : .labelColor,
                        maxLines: 6,
                        onCommit: {
                            generateWithAI()
                        },
                        onEscape: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                isInputExpanded = false
                            }
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Format selector button
                Menu {
                    Section("Documents") {
                        Button(action: { selectedFormat = "pdf" }) {
                            if selectedFormat == "pdf" {
                                Label("PDF", systemImage: "checkmark")
                            } else {
                                Text("PDF")
                            }
                        }
                        Button(action: { selectedFormat = "md" }) {
                            if selectedFormat == "md" {
                                Label("Markdown", systemImage: "checkmark")
                            } else {
                                Text("Markdown")
                            }
                        }
                        Button(action: { selectedFormat = "docx" }) {
                            if selectedFormat == "docx" {
                                Label("DOCX", systemImage: "checkmark")
                            } else {
                                Text("DOCX")
                            }
                        }
                        Button(action: { selectedFormat = "txt" }) {
                            if selectedFormat == "txt" {
                                Label("Plain Text", systemImage: "checkmark")
                            } else {
                                Text("Plain Text")
                            }
                        }
                        Button(action: { selectedFormat = "html" }) {
                            if selectedFormat == "html" {
                                Label("HTML", systemImage: "checkmark")
                            } else {
                                Text("HTML")
                            }
                        }
                    }
                    Section("Code") {
                        Button(action: { selectedFormat = "swift" }) {
                            if selectedFormat == "swift" {
                                Label("Swift", systemImage: "checkmark")
                            } else {
                                Text("Swift")
                            }
                        }
                        Button(action: { selectedFormat = "py" }) {
                            if selectedFormat == "py" {
                                Label("Python", systemImage: "checkmark")
                            } else {
                                Text("Python")
                            }
                        }
                        Button(action: { selectedFormat = "js" }) {
                            if selectedFormat == "js" {
                                Label("JavaScript", systemImage: "checkmark")
                            } else {
                                Text("JavaScript")
                            }
                        }
                        Button(action: { selectedFormat = "css" }) {
                            if selectedFormat == "css" {
                                Label("CSS", systemImage: "checkmark")
                            } else {
                                Text("CSS")
                            }
                        }
                    }
                    Section("Data") {
                        Button(action: { selectedFormat = "json" }) {
                            if selectedFormat == "json" {
                                Label("JSON", systemImage: "checkmark")
                            } else {
                                Text("JSON")
                            }
                        }
                        Button(action: { selectedFormat = "csv" }) {
                            if selectedFormat == "csv" {
                                Label("CSV", systemImage: "checkmark")
                            } else {
                                Text("CSV")
                            }
                        }
                        Button(action: { selectedFormat = "xml" }) {
                            if selectedFormat == "xml" {
                                Label("XML", systemImage: "checkmark")
                            } else {
                                Text("XML")
                            }
                        }
                        Button(action: { selectedFormat = "yaml" }) {
                            if selectedFormat == "yaml" {
                                Label("YAML", systemImage: "checkmark")
                            } else {
                                Text("YAML")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(
                            systemName: selectedFormat == "pdf"
                                ? "doc.richtext"
                                : selectedFormat == "md" ? "doc.plaintext"
                                : selectedFormat == "html" ? "globe"
                                : selectedFormat == "csv" ? "tablecells"
                                : ["swift", "py", "js"].contains(selectedFormat) ? "chevron.left.forwardslash.chevron.right"
                                : selectedFormat == "css" ? "paintbrush"
                                : ["json", "xml", "yaml"].contains(selectedFormat) ? "curlybraces"
                                : "doc.text"
                        )
                        .font(.system(size: 12, weight: .medium))
                        Text(selectedFormat.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 34)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule()
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.04))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Format: \(selectedFormat.uppercased())")

                // Page size button
                Menu {
                    ForEach(pageSizes, id: \.self) { size in
                        Button(action: { selectedPageSize = size }) {
                            if selectedPageSize == size {
                                Label(size, systemImage: "checkmark")
                            } else {
                                Text(size)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.04))
                        )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 34)
                .help("Page Size: \(selectedPageSize)")

                // Thinking button (Ollama only, capable models)
                if pdfProvider == "Ollama" && pdfHasThinkingCapability {
                    Menu {
                        Button(action: { pdfThinkingLevel = "low" }) {
                            if pdfThinkingLevel == "low" {
                                Label("Low", systemImage: "checkmark")
                            } else {
                                Text("Low")
                            }
                        }
                        Button(action: { pdfThinkingLevel = "medium" }) {
                            if pdfThinkingLevel == "medium" {
                                Label("Medium", systemImage: "checkmark")
                            } else {
                                Text("Medium")
                            }
                        }
                        Button(action: { pdfThinkingLevel = "high" }) {
                            if pdfThinkingLevel == "high" {
                                Label("High", systemImage: "checkmark")
                            } else {
                                Text("High")
                            }
                        }
                    } label: {
                        Image(systemName: "brain")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.08)
                                            : Color.black.opacity(0.04))
                            )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 34)
                    .help("Thinking: \(pdfThinkingLevel.capitalized)")
                }

                // Web Search toggle (Ollama with API key)
                if pdfProvider == "Ollama" && !ollamaAPIKey.isEmpty {
                    Button(action: {
                        pdfWebSearchEnabled.toggle()
                    }) {
                        Image(systemName: "globe")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(pdfWebSearchEnabled ? Color.blue : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        pdfWebSearchEnabled
                                            ? Color.blue.opacity(colorScheme == .dark ? 0.2 : 0.1)
                                            : (colorScheme == .dark
                                                ? Color.white.opacity(0.08)
                                                : Color.black.opacity(0.04))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(pdfWebSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }

                // Send/Stop button — Liquid Glass orb
                Button(action: {
                    if isGenerating {
                        generateTask?.cancel()
                        generateTask = nil
                        isGenerating = false
                    } else {
                        generateWithAI()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isGenerating
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                            ? [
                                                Color.secondary.opacity(0.3),
                                                Color.secondary.opacity(0.15),
                                            ]
                                            : [
                                                Color.primary.opacity(0.85),
                                                Color.primary.opacity(0.65),
                                            ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 36, height: 36)
                            .overlay(
                                Ellipse()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white.opacity(0.5), .white.opacity(0.0)],
                                            startPoint: .top,
                                            endPoint: .center
                                        )
                                    )
                                    .frame(width: 22, height: 14)
                                    .offset(y: -6)
                            )

                        Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                            .font(.system(size: isGenerating ? 12 : 14, weight: .bold))
                            .foregroundStyle(
                                isGenerating
                                    ? Color.white
                                    : (colorScheme == .dark ? Color.black : Color.white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
        }
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.3) : Color.black.opacity(0.06),
            radius: 16, x: 0, y: 6
        )
        .transition(
            .asymmetric(
                insertion: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity),
                removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)
            ))
    }

    // MARK: - AI Generation

    private func generateWithAI() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isGenerating = true
        generationError = nil

        let systemPrompt: String
        switch selectedFormat {
        case "html":
            systemPrompt = """
                You are an HTML file generator. The user will describe what they want. \
                Generate a complete, valid HTML5 document with embedded CSS styling. \
                Include a proper <!DOCTYPE html>, <head> with <style>, and <body>. \
                Make it visually polished with modern CSS (flexbox, grid, good typography, colors). \
                Generate ONLY the HTML code. Do NOT include any preamble, explanation, or commentary.
                """
        case "swift":
            systemPrompt = """
                You are a Swift code generator. The user will describe what they want. \
                Generate clean, idiomatic Swift code with proper structure, types, and error handling. \
                Include necessary imports. Use modern Swift conventions (async/await, value types, etc.). \
                Add brief inline comments for complex logic. \
                Generate ONLY the Swift code. Do NOT include any preamble, explanation, or commentary.
                """
        case "py":
            systemPrompt = """
                You are a Python code generator. The user will describe what they want. \
                Generate clean, idiomatic Python code following PEP 8 conventions. \
                Include necessary imports and type hints where appropriate. \
                Add brief docstrings for functions/classes. \
                Generate ONLY the Python code. Do NOT include any preamble, explanation, or commentary.
                """
        case "js":
            systemPrompt = """
                You are a JavaScript code generator. The user will describe what they want. \
                Generate clean, modern JavaScript (ES2020+) with proper structure. \
                Use const/let, arrow functions, async/await, and modern APIs where appropriate. \
                Add brief JSDoc comments for functions. \
                Generate ONLY the JavaScript code. Do NOT include any preamble, explanation, or commentary.
                """
        case "css":
            systemPrompt = """
                You are a CSS stylesheet generator. The user will describe what they want. \
                Generate clean, well-organized CSS with modern features (custom properties, flexbox, grid). \
                Use a logical structure with comments separating sections. \
                Generate ONLY the CSS code. Do NOT include any preamble, explanation, or commentary.
                """
        case "json":
            systemPrompt = """
                You are a JSON data generator. The user will describe what they want. \
                Generate valid, well-structured JSON data. Use proper nesting and arrays. \
                Generate ONLY the raw JSON. Do NOT wrap in code fences. Do NOT include any preamble, explanation, or commentary.
                """
        case "csv":
            systemPrompt = """
                You are a CSV data generator. The user will describe what they want. \
                Generate valid CSV data with a header row and data rows. \
                Use proper escaping for fields containing commas or quotes. \
                Generate ONLY the raw CSV data. Do NOT wrap in code fences. Do NOT include any preamble, explanation, or commentary.
                """
        case "xml":
            systemPrompt = """
                You are an XML document generator. The user will describe what they want. \
                Generate valid, well-formed XML with proper nesting and attributes. \
                Include an XML declaration. \
                Generate ONLY the XML. Do NOT include any preamble, explanation, or commentary.
                """
        case "yaml":
            systemPrompt = """
                You are a YAML file generator. The user will describe what they want. \
                Generate clean, properly indented YAML with appropriate structure. \
                Use comments to document sections where helpful. \
                Generate ONLY the YAML. Do NOT include any preamble, explanation, or commentary.
                """
        case "txt":
            systemPrompt = """
                You are a plain text document generator. The user will describe what they want. \
                Generate well-formatted plain text with clear structure using spacing and simple formatting. \
                Use dashes, equals signs, or spaces for visual structure — no Markdown or HTML. \
                Generate ONLY the document content. Do NOT include any preamble, explanation, or commentary.
                """
        case "md":
            systemPrompt = """
                You are a Markdown document generator. The user will describe what they want. \
                Generate well-formatted Markdown content using headings, lists, code blocks, tables, and emphasis. \
                Generate ONLY the Markdown content. Do NOT include any preamble, explanation, or commentary.
                """
        default:
            systemPrompt = """
                You are a PDF content generator. The user will describe what they want in a PDF document. \
                Generate well-formatted content using Markdown syntax. You can use:
                - # Headings (##, ###, etc.)
                - **bold** and *italic* text
                - Bullet points (- or *) and numbered lists (1. 2. 3.)
                - Code blocks with ```language
                - LaTeX math with $$ delimiters for block math or $ for inline math
                - Tables with | column | syntax
                - > blockquotes
                - --- horizontal rules

                Generate ONLY the document content in Markdown format. Do NOT include any preamble, \
                explanation, or commentary outside the document content. Start directly with the content.
                """
        }

        let userMsg = Message(content: trimmed, isUser: true)
        let history = [userMsg]

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            isInputExpanded = false
        }

        generateTask = Task {
            do {
                var fullContent = ""

                switch pdfProvider {
                case "Gemini API":
                    guard !geminiKey.isEmpty else {
                        await MainActor.run {
                            generationError = "No Gemini API key set. Please configure in Settings."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _, _) in geminiService.sendMessageStream(
                        history: history, apiKey: geminiKey, model: pdfModel,
                        systemPrompt: systemPrompt, thinkingLevel: "none"
                    ) {
                        fullContent += chunk
                    }

                case "Ollama":
                    let thinking = effectiveThinkingLevel(
                        provider: pdfProvider, model: pdfModel, level: pdfThinkingLevel)
                    var ollamaSystemPrompt = systemPrompt
                    if pdfWebSearchEnabled && !ollamaAPIKey.isEmpty {
                        do {
                            let searchResults = try await webSearchService.search(
                                query: trimmed, apiKey: ollamaAPIKey)
                            let searchContext = webSearchService.buildSearchContext(
                                results: searchResults)
                            if !searchContext.isEmpty {
                                ollamaSystemPrompt = searchContext + "\n\n" + systemPrompt
                            }
                        } catch {
                            print("PDF web search failed: \(error.localizedDescription)")
                        }
                    }
                    for try await (chunk, _) in ollamaService.sendMessageStream(
                        history: history, endpoint: ollamaURL, model: pdfModel,
                        systemPrompt: ollamaSystemPrompt, thinkingLevel: thinking
                    ) {
                        fullContent += chunk
                    }

                case "Apple Foundation":
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: systemPrompt
                    ) {
                        fullContent += chunk
                    }

                case "NVIDIA API":
                    guard !nvidiaKey.isEmpty else {
                        await MainActor.run {
                            generationError = "No NVIDIA API key set. Please configure in Settings."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _) in nvidiaService.sendMessageStream(
                        history: history, apiKey: nvidiaKey, model: pdfModel,
                        systemPrompt: systemPrompt
                    ) {
                        fullContent += chunk
                    }

                case "GitHub Copilot":
                    guard copilotService.isAuthenticated else {
                        await MainActor.run {
                            generationError = "GitHub Copilot not authenticated. Please sign in."
                            isGenerating = false
                        }
                        return
                    }
                    for try await (chunk, _) in copilotService.sendMessageStream(
                        history: history, model: pdfModel, systemPrompt: systemPrompt
                    ) {
                        fullContent += chunk
                    }

                case "Gemini CLI":
                    guard geminiCLIService.isAvailable else {
                        await MainActor.run {
                            generationError = "Gemini CLI not available. Please install it first."
                            isGenerating = false
                        }
                        return
                    }
                    for try await chunk in geminiCLIService.sendMessageStream(
                        history: history, model: pdfModel, systemPrompt: systemPrompt
                    ) {
                        fullContent += chunk
                    }

                default:
                    await MainActor.run {
                        generationError = "Provider not supported."
                        isGenerating = false
                    }
                    return
                }

                let content = fullContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    await MainActor.run {
                        generationError =
                            "AI returned empty content. Try a different prompt or model."
                        isGenerating = false
                    }
                    return
                }

                // Extract title from first heading or use prompt excerpt
                let title = extractTitle(from: content, fallback: trimmed)
                let pageSize = selectedPageSize
                let format = selectedFormat

                // Generate file data based on selected format
                let fileData: Data
                switch format {
                case "md", "txt", "swift", "py", "js", "css", "json", "csv", "xml", "yaml", "html":
                    fileData = Data(content.utf8)
                case "docx":
                    fileData = Self.renderDOCX(from: content, title: title)
                default:
                    fileData = PDFRenderer.renderPDF(
                        from: content, title: title, pageSize: pageSize)
                }

                let item = PDFDocumentItem(
                    id: UUID(), title: title, content: content,
                    timestamp: Date(), pageSize: pageSize, format: format)

                await MainActor.run {
                    store.addItem(item, fileData: fileData)

                    prompt = ""
                    isGenerating = false
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        generationError = "Error: \(error.localizedDescription)"
                        isGenerating = false
                    }
                }
            }
        }
    }

    private func extractTitle(from content: String, fallback: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return String(fallback.prefix(50))
    }

    private func saveFileToConfiguredPath(_ item: PDFDocumentItem) {
        guard !fileDownloadPath.isEmpty,
            let data = store.fileData(for: item)
        else { return }
        let dir = URL(fileURLWithPath: fileDownloadPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let sanitized =
            (item.title.isEmpty ? "Untitled" : item.title).prefix(40)
            .replacingOccurrences(
                of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        let filename =
            "Prism_\(sanitized)_\(Int(Date().timeIntervalSince1970)).\(item.fileExtension)"
        let fileURL = dir.appendingPathComponent(filename)
        try? data.write(to: fileURL)
    }

    private func exportFile(_ item: PDFDocumentItem) {
        guard let data = store.fileData(for: item) else { return }
        let panel = NSSavePanel()
        let ext = item.fileExtension
        if let utType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [utType]
        }
        panel.nameFieldStringValue =
            (item.title.isEmpty ? "Untitled" : item.title) + ".\(ext)"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    /// Render Markdown content to a simple DOCX using NSAttributedString
    private static func renderDOCX(from content: String, title: String) -> Data {
        let attrStr = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 12)

        // Add title
        if !title.isEmpty {
            let titleFont = NSFont.systemFont(ofSize: 22, weight: .bold)
            attrStr.append(
                NSAttributedString(
                    string: title + "\n\n",
                    attributes: [.font: titleFont, .foregroundColor: NSColor.black]))
        }

        // Add body content
        attrStr.append(
            NSAttributedString(
                string: content,
                attributes: [.font: baseFont, .foregroundColor: NSColor.black]))

        // Export as DOCX
        let range = NSRange(location: 0, length: attrStr.length)
        if let data = try? attrStr.data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML
            ])
        {
            return data
        }

        // Fallback: plain text
        return Data(content.utf8)
    }
}

// MARK: - File Preview Overlay

struct FilePreviewOverlay: View {
    let data: Data
    let format: String
    let content: String
    let onDismiss: () -> Void

    @State private var expanded = false
    @State private var dismissing = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(expanded ? 0.5 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .opacity(expanded ? 1 : 0)
                        .padding(16)
                    }

                    Group {
                        if format == "pdf" {
                            PDFKitView(data: data)
                        } else {
                            // Markdown or DOCX: show content as text
                            ScrollView {
                                Text(content)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 15)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.8)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                expanded = true
            }
        }
        .onExitCommand { dismiss() }
    }

    private func dismiss() {
        guard !dismissing else { return }
        dismissing = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            expanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            onDismiss()
        }
    }
}

// MARK: - PDFKit SwiftUI Wrapper

struct PDFKitView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = PDFDocument(data: data)
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.dataRepresentation() != data {
            nsView.document = PDFDocument(data: data)
        }
    }
}
