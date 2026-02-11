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

    func addItem(_ item: PDFDocumentItem, pdfData: Data?) {
        items.insert(item, at: 0)
        if let data = pdfData {
            savePDFData(data, for: item.id)
        }
        saveMetadata()
    }

    func updateItem(id: UUID, pdfData: Data?) {
        if let data = pdfData {
            savePDFData(data, for: id)
        }
        saveMetadata()
    }

    func pdfData(for id: UUID) -> Data? {
        let path = saveDir.appendingPathComponent("\(id.uuidString).pdf")
        return try? Data(contentsOf: path)
    }

    func deleteItem(id: UUID) {
        items.removeAll { $0.id == id }
        let path = saveDir.appendingPathComponent("\(id.uuidString).pdf")
        try? FileManager.default.removeItem(at: path)
        saveMetadata()
    }

    func clearAll() {
        for item in items {
            let path = saveDir.appendingPathComponent("\(item.id.uuidString).pdf")
            try? FileManager.default.removeItem(at: path)
        }
        items.removeAll()
        saveMetadata()
    }

    private func savePDFData(_ data: Data, for id: UUID) {
        let path = saveDir.appendingPathComponent("\(id.uuidString).pdf")
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

                    // Save state, flip back for image drawing
                    context.saveGState()
                    context.translateBy(x: drawRect.origin.x, y: drawRect.origin.y + drawHeight)
                    context.scaleBy(x: 1, y: -1)
                    if let cgImage = mathImage.cgImage(
                        forProposedRect: nil, context: nil, hints: nil)
                    {
                        context.draw(
                            cgImage, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
                    }
                    context.restoreGState()
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
                // Skip LaTeX environment markers
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
                currentText += line + "\n"
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

        // Process inline formatting: **bold**, *italic*, `code`, $math$
        var remaining = text
        while !remaining.isEmpty {
            // Bold: **text**
            if let boldRange = remaining.range(of: "\\*\\*(.+?)\\*\\*", options: .regularExpression)
            {
                let prefix = String(remaining[remaining.startIndex..<boldRange.lowerBound])
                if !prefix.isEmpty {
                    result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
                }
                let inner = String(remaining[boldRange]).dropFirst(2).dropLast(2)
                var boldAttrs = baseAttrs
                boldAttrs[.font] = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                result.append(
                    NSAttributedString(string: String(inner), attributes: boldAttrs))
                remaining = String(remaining[boldRange.upperBound...])
                continue
            }

            // Italic: *text*
            if let italicRange = remaining.range(
                of: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", options: .regularExpression)
            {
                let prefix = String(remaining[remaining.startIndex..<italicRange.lowerBound])
                if !prefix.isEmpty {
                    result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
                }
                let inner = String(remaining[italicRange]).dropFirst(1).dropLast(1)
                var italicAttrs = baseAttrs
                let italicFont =
                    NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                italicAttrs[.font] = italicFont
                result.append(
                    NSAttributedString(string: String(inner), attributes: italicAttrs))
                remaining = String(remaining[italicRange.upperBound...])
                continue
            }

            // Inline code: `text`
            if let codeRange = remaining.range(of: "`(.+?)`", options: .regularExpression) {
                let prefix = String(remaining[remaining.startIndex..<codeRange.lowerBound])
                if !prefix.isEmpty {
                    result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
                }
                let inner = String(remaining[codeRange]).dropFirst(1).dropLast(1)
                var codeAttrs = baseAttrs
                codeAttrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize - 1, weight: .regular)
                codeAttrs[.backgroundColor] = NSColor(white: 0.92, alpha: 1.0)
                result.append(
                    NSAttributedString(string: String(inner), attributes: codeAttrs))
                remaining = String(remaining[codeRange.upperBound...])
                continue
            }

            // Inline math: $text$
            if let mathRange = remaining.range(
                of: "(?<!\\$)\\$(?!\\$)(.+?)(?<!\\$)\\$(?!\\$)", options: .regularExpression)
            {
                let prefix = String(remaining[remaining.startIndex..<mathRange.lowerBound])
                if !prefix.isEmpty {
                    result.append(NSAttributedString(string: prefix, attributes: baseAttrs))
                }
                let inner = String(remaining[mathRange]).dropFirst(1).dropLast(1)
                // Render inline math as monospace fallback
                var mathAttrs = baseAttrs
                mathAttrs[.font] = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize, weight: .regular)
                mathAttrs[.foregroundColor] = NSColor.darkGray
                result.append(
                    NSAttributedString(string: String(inner), attributes: mathAttrs))
                remaining = String(remaining[mathRange.upperBound...])
                continue
            }

            // No inline formatting found, append rest
            result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
            break
        }

        return result
    }

    // MARK: - LaTeX to Image (SwiftMath)

    private static func renderLaTeXToImage(
        _ latex: String, width: CGFloat, fontSize: CGFloat
    ) -> NSImage? {
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = .black
        label.textAlignment = .center

        // Calculate intrinsic size
        let intrinsicSize = label.fittingSize
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else { return nil }

        let drawSize = CGSize(
            width: min(intrinsicSize.width + 16, width),
            height: intrinsicSize.height + 8
        )

        label.frame = CGRect(origin: .zero, size: drawSize)
        label.wantsLayer = true
        label.layout()

        // Use bitmapImageRepForCachingDisplay for reliable off-screen rendering
        guard let bitmapRep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            return nil
        }
        label.cacheDisplay(in: label.bounds, to: bitmapRep)

        let image = NSImage(size: drawSize)
        image.addRepresentation(bitmapRep)

        return image
    }
}

// MARK: - PDF Creator View

struct PDFCreatorView: View {
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("ImageDownloadPath") private var fileDownloadPath: String = ""
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("PDFProvider") private var pdfProvider: String = "Gemini API"
    @AppStorage("PDFModel") private var pdfModel: String = "gemini-2.5-flash"
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var store = PDFCreatorStore.shared
    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared

    @State private var prompt: String = ""
    @State private var selectedPageSize: String = "Letter"
    @State private var showResetConfirmation: Bool = false
    @State private var selectedPDFPreview: UUID? = nil
    @State private var pdfPreviewData: Data? = nil
    @State private var showPDFPreview: Bool = false
    @State private var savedItemIds: Set<UUID> = []
    @State private var isInputExpanded: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generateTask: Task<Void, Never>?
    @State private var generationError: String? = nil
    @State private var pdfThinkingLevel: String = "medium"
    @State private var pdfWebSearchEnabled: Bool = false
    @State private var isPromptFocused: Bool = false

    private let pageSizes = ["Letter", "A4", "Legal"]
    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()
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

            // PDF Preview overlay
            if showPDFPreview, let data = pdfPreviewData {
                PDFPreviewOverlay(pdfData: data) {
                    showPDFPreview = false
                    pdfPreviewData = nil
                    selectedPDFPreview = nil
                }
                .zIndex(100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear All PDFs", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("This will permanently delete all created PDFs. This cannot be undone.")
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
                Text("PDF Creator")
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
                    Text("AI PDF Creator")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text(
                        "Describe what you need and AI will generate a formatted PDF"
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

            Text("Generating PDF…")
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

                Image(systemName: "doc.richtext.fill")
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
                        if let data = store.pdfData(for: item.id) {
                            pdfPreviewData = data
                            selectedPDFPreview = item.id
                            showPDFPreview = true
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
                            savePDFToConfiguredPath(item)
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
                        exportPDF(item)
                    }
                )

                Spacer()

                Button(action: {
                    withAnimation {
                        store.deleteItem(id: item.id)
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
                if let data = store.pdfData(for: item.id) {
                    pdfPreviewData = data
                    selectedPDFPreview = item.id
                    showPDFPreview = true
                }
            }
            Button("Export...") { exportPDF(item) }
            Divider()
            Button("Delete", role: .destructive) {
                store.deleteItem(id: item.id)
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
                        Text("Instructions for content of pdf")
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

        let systemPrompt = """
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

                let pdfData = PDFRenderer.renderPDF(from: content, title: title, pageSize: pageSize)

                let item = PDFDocumentItem(
                    id: UUID(), title: title, content: content,
                    timestamp: Date(), pageSize: pageSize)

                await MainActor.run {
                    store.addItem(item, pdfData: pdfData)

                    // Auto-save to configured path
                    if !fileDownloadPath.isEmpty {
                        let dir = URL(fileURLWithPath: fileDownloadPath, isDirectory: true)
                        if FileManager.default.fileExists(atPath: dir.path) {
                            let sanitized =
                                title.prefix(40)
                                .replacingOccurrences(
                                    of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
                            let filename =
                                "Prism_\(sanitized)_\(Int(Date().timeIntervalSince1970)).pdf"
                            let fileURL = dir.appendingPathComponent(filename)
                            try? pdfData.write(to: fileURL)
                        }
                    }

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

    private func savePDFToConfiguredPath(_ item: PDFDocumentItem) {
        guard !fileDownloadPath.isEmpty,
            let data = store.pdfData(for: item.id)
        else { return }
        let dir = URL(fileURLWithPath: fileDownloadPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let sanitized =
            (item.title.isEmpty ? "Untitled" : item.title).prefix(40)
            .replacingOccurrences(
                of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        let filename =
            "Prism_\(sanitized)_\(Int(Date().timeIntervalSince1970)).pdf"
        let fileURL = dir.appendingPathComponent(filename)
        try? data.write(to: fileURL)
    }

    private func exportPDF(_ item: PDFDocumentItem) {
        guard let data = store.pdfData(for: item.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue =
            (item.title.isEmpty ? "Untitled" : item.title) + ".pdf"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}

// MARK: - PDF Preview Overlay

struct PDFPreviewOverlay: View {
    let pdfData: Data
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

                    PDFKitView(data: pdfData)
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
