import AppKit
import Foundation
import PDFKit
import SwiftMath
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Models

struct MarkdownBlock: Identifiable, Equatable {
    let id = UUID()
    let type: MarkdownBlockType
    var attributedText: AttributedString?

    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        return lhs.type == rhs.type
    }
}

enum MarkdownBlockType: Equatable {
    case text(String)
    case code(String, String)
    case heading(String, Int)
    case divider
    case bullet(String)
    case numbered(String, Int)
    case blockquote(String)
    case table(headers: [String], rows: [[String]])
    case math(String)
}

struct ChatSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var date = Date()
    var messages: [Message]
}

enum AttachmentType {
    case image
    case pdf
}

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let type: AttachmentType
    let data: Data
}

struct MessageAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: String  // "image" or "pdf"
    var data: Data
}

struct Message: Identifiable, Codable, Equatable {
    var id = UUID()
    var content: String {
        didSet {
            _cachedBlocks = nil
        }
    }
    var thinkingContent: String?
    var thinkingDuration: TimeInterval?
    var model: String?
    var imageData: Data?
    var pdfData: Data?
    var attachments: [MessageAttachment]?
    var isUser: Bool
    var timestamp = Date()
    var isStreaming: Bool = false
    var isGeneratingImage: Bool? = false

    // Cache the decoded image to avoid expensive decoding on main thread
    private var _cachedImage: NSImage?

    // Cache parsed markdown blocks
    private var _cachedBlocks: [MarkdownBlock]?

    var image: NSImage? {
        if let cached = _cachedImage { return cached }
        if let data = imageData {
            return NSImage(data: data)
        }
        if let firstImg = attachments?.first(where: { $0.type == "image" }) {
            return NSImage(data: firstImg.data)
        }
        return nil
    }

    var blocks: [MarkdownBlock] {
        if let cached = _cachedBlocks { return cached }
        return Message.parseMarkdown(content)
    }

    enum CodingKeys: String, CodingKey {
        case id, content, thinkingContent, thinkingDuration, model, imageData, pdfData, attachments,
            isUser,
            timestamp
    }

    init(
        content: String, thinkingContent: String? = nil, thinkingDuration: TimeInterval? = nil,
        model: String? = nil,
        image: NSImage? = nil, pdfData: Data? = nil, attachments: [MessageAttachment]? = nil,
        isUser: Bool
    ) {
        self.content = content
        self.thinkingContent = thinkingContent
        self.thinkingDuration = thinkingDuration
        self.model = model
        self.imageData = image?.tiffRepresentation
        self.pdfData = pdfData
        self.attachments = attachments
        self.isUser = isUser
        self._cachedImage = image
        self._cachedBlocks = Message.parseMarkdown(content)

        // If legacy params are nil but attachments exist, populate legacy for compatibility if single file?
        // Actually, we should check attachments in accessors.
        if self._cachedImage == nil, let atts = attachments,
            let firstImg = atts.first(where: { $0.type == "image" })
        {
            self._cachedImage = NSImage(data: firstImg.data)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        thinkingContent = try container.decodeIfPresent(String.self, forKey: .thinkingContent)
        thinkingDuration = try container.decodeIfPresent(
            TimeInterval.self, forKey: .thinkingDuration)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        pdfData = try container.decodeIfPresent(Data.self, forKey: .pdfData)
        attachments = try container.decodeIfPresent([MessageAttachment].self, forKey: .attachments)
        isUser = try container.decode(Bool.self, forKey: .isUser)
        timestamp = try container.decode(Date.self, forKey: .timestamp)

        if let data = imageData {
            _cachedImage = NSImage(data: data)
        } else if let atts = attachments, let firstImg = atts.first(where: { $0.type == "image" }) {
            _cachedImage = NSImage(data: firstImg.data)
        }
        _cachedBlocks = Message.parseMarkdown(content)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(thinkingContent, forKey: .thinkingContent)
        try container.encode(thinkingDuration, forKey: .thinkingDuration)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(imageData, forKey: .imageData)
        try container.encode(pdfData, forKey: .pdfData)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encode(isUser, forKey: .isUser)
        try container.encode(timestamp, forKey: .timestamp)
    }

    static func parseMarkdown(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var currentText = ""
        var inCodeBlock = false
        var codeBlockContent = ""
        var codeLanguage = ""
        var inMathBlock = false
        var mathBlockContent = ""
        var mathDelimiter = ""

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(
                        MarkdownBlock(
                            type: .code(
                                codeBlockContent.trimmingCharacters(in: .newlines), codeLanguage)))
                    codeBlockContent = ""
                    codeLanguage = ""
                    inCodeBlock = false
                } else {
                    if !currentText.isEmpty {
                        blocks.append(
                            MarkdownBlock(
                                type: .text(currentText.trimmingCharacters(in: .newlines))))
                        currentText = ""
                    }
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                codeBlockContent += line + "\n"
            } else if trimmedLine.hasPrefix("$$") || trimmedLine.hasPrefix("\\[") {
                let isBracket = trimmedLine.hasPrefix("\\[")
                let startDelim = isBracket ? "\\[" : "$$"
                let endDelim = isBracket ? "\\]" : "$$"

                if inMathBlock {
                    // Check if this line closes the current block
                    if trimmedLine.hasSuffix(mathDelimiter) {
                        mathBlockContent += String(trimmedLine.dropLast(mathDelimiter.count))
                        blocks.append(
                            MarkdownBlock(
                                type: .math(mathBlockContent.trimmingCharacters(in: .newlines))))
                        mathBlockContent = ""
                        inMathBlock = false
                    } else {
                        mathBlockContent += line + "\n"
                    }
                } else {
                    if !currentText.isEmpty {
                        blocks.append(
                            MarkdownBlock(
                                type: .text(currentText.trimmingCharacters(in: .newlines))))
                        currentText = ""
                    }

                    if trimmedLine.count > startDelim.count && trimmedLine.hasSuffix(endDelim) {
                        // Single line block: $$ x^2 $$ or \[ x^2 \]
                        let content = String(
                            trimmedLine.dropFirst(startDelim.count).dropLast(endDelim.count))
                        blocks.append(
                            MarkdownBlock(type: .math(content.trimmingCharacters(in: .whitespaces)))
                        )
                    } else {
                        inMathBlock = true
                        mathDelimiter = endDelim
                        let content = String(trimmedLine.dropFirst(startDelim.count))
                        if !content.isEmpty {
                            mathBlockContent += content + "\n"
                        }
                    }
                }
            } else if inMathBlock {
                if trimmedLine.hasSuffix(mathDelimiter) {
                    mathBlockContent += String(trimmedLine.dropLast(mathDelimiter.count))
                    blocks.append(
                        MarkdownBlock(
                            type: .math(mathBlockContent.trimmingCharacters(in: .newlines))))
                    mathBlockContent = ""
                    inMathBlock = false
                } else {
                    mathBlockContent += line + "\n"
                }
            } else if trimmedLine.contains("$$") && !inCodeBlock {
                // Handle inline display math that should be a block
                let parts = line.components(separatedBy: "$$")
                if parts.count >= 3 {
                    currentText += line + "\n"
                } else {
                    currentText += line + "\n"
                }
            } else if trimmedLine == "---" {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .divider))
            } else if line.hasPrefix("# ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .heading(String(line.dropFirst(2)), 1)))
            } else if line.hasPrefix("## ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .heading(String(line.dropFirst(3)), 2)))
            } else if line.hasPrefix("### ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .heading(String(line.dropFirst(4)), 3)))
            } else if line.hasPrefix("#### ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .heading(String(line.dropFirst(5)), 4)))
            } else if line.hasPrefix("\\section{") && line.hasSuffix("}") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                let title = String(line.dropFirst(9).dropLast(1))
                blocks.append(MarkdownBlock(type: .heading(title, 1)))
            } else if line.hasPrefix("\\subsection{") && line.hasSuffix("}") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                let title = String(line.dropFirst(12).dropLast(1))
                blocks.append(MarkdownBlock(type: .heading(title, 2)))
            } else if trimmedLine.hasPrefix("\\item ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                let content = String(trimmedLine.dropFirst(6))
                blocks.append(MarkdownBlock(type: .bullet(content)))
            } else if trimmedLine.hasPrefix("\\begin{itemize}")
                || trimmedLine.hasPrefix("\\end{itemize}")
                || trimmedLine.hasPrefix("\\begin{enumerate}")
                || trimmedLine.hasPrefix("\\end{enumerate}")
            {
                // Ignore these lines as they are just structure markers
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
            } else if trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("- ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                let content = String(trimmedLine.dropFirst(2))
                blocks.append(MarkdownBlock(type: .bullet(content)))
            } else if let match = trimmedLine.range(of: "^\\d+\\. ", options: .regularExpression) {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                let numberStr = String(trimmedLine[..<match.upperBound].dropLast(2))
                let number = Int(numberStr) ?? 1
                let content = String(trimmedLine[match.upperBound...])
                blocks.append(MarkdownBlock(type: .numbered(content, number)))
            } else if trimmedLine.hasPrefix("> ") {
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }
                blocks.append(MarkdownBlock(type: .blockquote(String(trimmedLine.dropFirst(2)))))
            } else if trimmedLine.hasPrefix("|") {
                // Potential table start
                if !currentText.isEmpty {
                    blocks.append(
                        MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
                    currentText = ""
                }

                // Check if next line is separator
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if nextLine.hasPrefix("|") && nextLine.contains("---") {
                        // It is a table
                        let headers = trimmedLine.split(separator: "|").map {
                            String($0).trimmingCharacters(in: .whitespaces)
                        }
                        var rows: [[String]] = []

                        // Skip header and separator
                        i += 2

                        while i < lines.count {
                            let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                            if !rowLine.hasPrefix("|") {
                                i -= 1  // Backtrack so main loop processes this line
                                break
                            }
                            let cells = rowLine.split(separator: "|").map {
                                String($0).trimmingCharacters(in: .whitespaces)
                            }
                            if !cells.isEmpty {
                                rows.append(cells)
                            }
                            i += 1
                        }
                        blocks.append(MarkdownBlock(type: .table(headers: headers, rows: rows)))
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
            blocks.append(MarkdownBlock(type: .text(currentText.trimmingCharacters(in: .newlines))))
        }

        return blocks
    }

    mutating func ensureBlocksCached() {
        if _cachedBlocks == nil {
            _cachedBlocks = Message.parseMarkdown(content)
        }

        // Enrich blocks with computed AttributedStrings to avoid main thread hang during scrolling
        if var blocks = _cachedBlocks {
            var changed = false
            for i in 0..<blocks.count {
                if blocks[i].attributedText == nil {
                    switch blocks[i].type {
                    case .text(let text), .bullet(let text), .numbered(let text, _),
                        .blockquote(let text), .heading(let text, _):
                        // Use the shared parser to pre-compute attributed string
                        blocks[i].attributedText = MarkdownParser.shared.parse(text)
                        changed = true
                    default:
                        break
                    }
                }
            }
            if changed {
                _cachedBlocks = blocks
            }
        }
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        // Optimization: Check ID and metadata first
        if lhs.id != rhs.id { return false }
        if lhs.isUser != rhs.isUser { return false }
        if lhs.timestamp != rhs.timestamp { return false }
        if lhs.content != rhs.content { return false }
        if lhs.thinkingContent != rhs.thinkingContent { return false }
        if lhs.isStreaming != rhs.isStreaming { return false }
        if lhs.model != rhs.model { return false }
        if lhs.isGeneratingImage != rhs.isGeneratingImage { return false }

        // Optimization: Avoid deep data comparison for images if possible
        // If both have no image, equal.
        if lhs.imageData == nil && rhs.imageData == nil && lhs.pdfData == nil && rhs.pdfData == nil
        {
            return true
        }
        // If one has image and other doesn't, not equal.
        if (lhs.imageData == nil) != (rhs.imageData == nil) { return false }
        if (lhs.pdfData == nil) != (rhs.pdfData == nil) { return false }

        // If both have image, check size first
        if let lData = lhs.imageData, let rData = rhs.imageData {
            if lData.count != rData.count { return false }
            // If sizes match, we assume they are the same for performance in this context.
            // A true deep compare would be lData == rData, but that causes scroll hitching.
        }

        if let lPdf = lhs.pdfData, let rPdf = rhs.pdfData {
            if lPdf.count != rPdf.count { return false }
        }

        return true
    }
}

// MARK: - Services

class ChatManager: ObservableObject {
    static let shared = ChatManager()
    @Published var sessions: [ChatSession] = []
    @Published var currentSessionId: UUID?
    @Published var currentTask: Task<Void, Never>?

    private let savePath: URL

    init(fileName: String = "chat_history.json") {
        self.savePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        loadSessions()
        if sessions.isEmpty {
            createNewSession()
        }
        enrichHistory()
    }

    private func enrichHistory() {
        Task { @MainActor in
            // Progressively enrich messages to ensure smooth scrolling
            // We iterate safely to avoid index errors if sessions change
            for sessionIndex in sessions.indices {
                guard sessionIndex < sessions.count else { break }

                for msgIndex in sessions[sessionIndex].messages.indices {
                    guard sessionIndex < sessions.count,
                        msgIndex < sessions[sessionIndex].messages.count
                    else { break }

                    sessions[sessionIndex].messages[msgIndex].ensureBlocksCached()

                    // Yield frequently to prevent UI freeze
                    if msgIndex % 2 == 0 { await Task.yield() }
                }
                await Task.yield()
            }
        }
    }

    func createNewSession() {
        // Reuse any existing empty session
        if let index = sessions.firstIndex(where: { $0.messages.isEmpty }) {
            let session = sessions[index]
            // Move to top if not already
            if index != 0 {
                sessions.remove(at: index)
                sessions.insert(session, at: 0)
            }
            currentSessionId = session.id
            return
        }

        let newSession = ChatSession(title: "New Chat", messages: [])
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        saveSessions()
    }

    func deleteCurrentSession() {
        guard let id = currentSessionId else { return }
        deleteSession(id: id)
    }

    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty {
            createNewSession()
        } else if currentSessionId == id {
            currentSessionId = sessions.first?.id
        }
        saveSessions()
    }

    func renameSession(id: UUID, newTitle: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = newTitle
            saveSessions()
        }
    }

    func deleteAllSessions() {
        sessions.removeAll()
        createNewSession()
    }

    func addMessage(_ message: Message) {
        if sessions.isEmpty {
            createNewSession()
        }
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }

        var session = sessions[index]
        session.messages.append(message)
        session.date = Date()

        // Update title if it's the first user message
        if session.messages.filter({ $0.isUser }).count == 1 && message.isUser {
            session.title = String(message.content.prefix(30))
        }

        sessions.remove(at: index)
        sessions.insert(session, at: 0)

        saveSessions()
    }

    func updateMessage(
        id: UUID, content: String, thinkingContent: String? = nil, image: NSImage? = nil,
        isStreaming: Bool = false, isGeneratingImage: Bool? = nil
    ) {
        // Find session containing the message (search all sessions to support background generation)
        guard
            let sessionIndex = sessions.firstIndex(where: { session in
                session.messages.contains(where: { $0.id == id })
            }),
            let msgIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id })
        else { return }

        var msg = sessions[sessionIndex].messages[msgIndex]
        msg.content = content
        msg.isStreaming = isStreaming
        if let thinking = thinkingContent {
            msg.thinkingContent = thinking
        }
        if let genImage = isGeneratingImage {
            msg.isGeneratingImage = genImage
        }
        if let image = image {
            msg.imageData = image.tiffRepresentation
            // Also need to update cache if we were using it, but Message struct handles that in init or when accessing.
            // Actually Message struct has private _cachedImage. We should probably recreate the message or handle it.
            // SisessionIce `Message` is a struct, modifying `msg` creates a copy.
            // Let's just rely on `imageData` update.
        }

        if !isStreaming {
            msg.ensureBlocksCached()
        }

        sessions[sessionIndex].messages[msgIndex] = msg
        // We don't save on every chunk to avoid disk thrashing, but we should save at the end
    }

    func finalizeMessageUpdate() {
        saveSessions()
    }

    func getCurrentMessages() -> [Message] {
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionId }) else {
            return []
        }
        return sessions[index].messages
    }

    func removeLastMessage() {
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        if !sessions[index].messages.isEmpty {
            sessions[index].messages.removeLast()
            saveSessions()
        }
    }

    func truncateHistory(from messageId: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        if let msgIndex = sessions[index].messages.firstIndex(where: { $0.id == messageId }) {
            sessions[index].messages.removeSubrange(msgIndex...)
            saveSessions()
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: savePath)
        }
    }

    private func loadSessions() {
        if let data = try? Data(contentsOf: savePath),
            let loaded = try? JSONDecoder().decode([ChatSession].self, from: data)
        {
            sessions = loaded.sorted(by: { $0.date > $1.date })
            currentSessionId = sessions.first?.id
        }
    }
}

struct OllamaAPIError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        return "Ollama Error \(statusCode): \(message)"
    }
}

class OllamaService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func sendMessageStream(
        history: [Message], endpoint: String, model: String, systemPrompt: String = "",
        thinkingLevel: String = "medium"
    ) -> AsyncThrowingStream<(String, String?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let baseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(baseURL)/api/chat") else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                var messages: [[String: Any]] = []
                let lowerModel = model.lowercased()

                if !systemPrompt.isEmpty {
                    messages.append([
                        "role": "system",
                        "content": systemPrompt,
                    ])
                } else if lowerModel.contains("deepseek") || lowerModel.contains("r1") {
                    // DeepSeek models with thinking enabled often default to Chinese.
                    // If no system prompt is provided, enforce English.
                    messages.append([
                        "role": "system",
                        "content":
                            "You are a helpful AI assistant. Please think and respond in English.",
                    ])
                }

                let isVisionModel =
                    model.contains("qwen3-vl") || model.contains("gemma3") || model.contains("clip")
                    || model.contains("llava")

                messages.append(
                    contentsOf: history.map { msg in
                        var content = msg.content
                        var images: [String] = []

                        if let data = msg.imageData {
                            images.append(data.base64EncodedString())
                        }

                        if let pdfData = msg.pdfData {
                            if isVisionModel {
                                // Vision models can see the PDF pages as images (simplification: sending raw PDF bytes if supported,
                                // or better, we should rasterize. For now, assuming Ollama 2026 handles PDF bytes in 'images' for VL models
                                // or we fallback to text extraction if this fails. But user said qwen3-vl handles PDF visual OCR.)
                                //
                                // Note: In current real Ollama, one must convert to images.
                                // For 2026 simulation, we'll try sending PDF base64 in images if the protocol allows,
                                // otherwise we should probably extract text for safety unless we implement rasterization.
                                // Given I can't easily rasterize in this script without more code,
                                // and the prompt says "gpt-oss can read a PDF if you pipe it as text",
                                // implying others do it visually.
                                //
                                // Let's try sending as image for VL, and text for others.
                                images.append(pdfData.base64EncodedString())
                            } else {
                                // Text-only model: Extract text from PDF
                                if let pdf = PDFDocument(data: pdfData) {
                                    let pageCount = pdf.pageCount
                                    var extractedText = "\n\n--- PDF Content ---\n"
                                    for i in 0..<pageCount {
                                        if let page = pdf.page(at: i), let pageText = page.string {
                                            extractedText += "Page \(i+1):\n\(pageText)\n"
                                        }
                                    }
                                    extractedText += "--- End PDF Content ---\n"
                                    content += extractedText
                                }
                            }
                        }

                        var message: [String: Any] = [
                            "role": msg.isUser ? "user" : "assistant",
                            "content": content,
                        ]

                        // Only attach images if it's a vision model or if we are forcing it
                        // For non-vision models, we shouldn't send images field at all usually,
                        // but if the user attached an image to a text model, we just ignore it (or maybe describe it? too hard).
                        // We'll send it if we have it, let Ollama error or ignore.
                        if !images.isEmpty && isVisionModel {
                            message["images"] = images
                        }

                        return message
                    })

                var body: [String: Any] = [
                    "model": model.isEmpty ? "llama3" : model,
                    "messages": messages,
                    "stream": true,
                    "options": [:],
                ]

                // Apply native thinking parameter
                if lowerModel.contains("gpt-oss") {
                    body["think"] = thinkingLevel
                } else if lowerModel.contains("deepseek") || lowerModel.contains("r1") {
                    // DeepSeek models with thinking enabled often default to Chinese.
                    // If no system prompt is provided, enforce English.
                    // Note: We removed 'qwen' from here as qwen models (like qwen3-coder) generally don't support top-level 'think' param in Ollama
                    // and sending it causes a 400 Bad Request.
                    if thinkingLevel == "high" {
                        body["think"] = true
                    }
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (result, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorMsg = ""
                        for try await line in result.lines {
                            errorMsg += line
                        }
                        // Simple cleanup of JSON format if present
                        if let data = errorMsg.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            let msg = json["error"] as? String
                        {
                            errorMsg = msg
                        }
                        continuation.finish(
                            throwing: OllamaAPIError(
                                statusCode: httpResponse.statusCode, message: errorMsg))
                        return
                    }

                    for try await line in result.lines {
                        guard let data = line.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any]
                        else { continue }

                        if let done = json["done"] as? Bool, done {
                            if let message = json["message"] as? [String: Any] {
                                let content = message["content"] as? String
                                let thinking = message["thinking"] as? String
                                if let thinking = thinking, !thinking.isEmpty {
                                    continuation.yield(("", thinking))
                                }
                                if let content = content, !content.isEmpty {
                                    continuation.yield((content, nil))
                                }
                            }
                            break
                        }

                        guard let message = json["message"] as? [String: Any] else { continue }
                        let content = message["content"] as? String
                        let thinking = message["thinking"] as? String

                        if let thinking = thinking, !thinking.isEmpty {
                            continuation.yield(("", thinking))
                        }
                        if let content = content, !content.isEmpty {
                            continuation.yield((content, nil))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

class GeminiService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func sendMessageStream(
        history: [Message], apiKey: String, model: String, systemPrompt: String = "",
        thinkingLevel: String = "medium"
    ) -> AsyncThrowingStream<(String, String?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let modelName = model.isEmpty ? "gemini-1.5-flash" : model
                guard
                    let url = URL(
                        string:
                            "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?key=\(apiKey)&alt=sse"
                    )
                else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                // Convert history to Gemini format
                let contents: [[String: Any]] = history.map { msg in
                    var parts: [[String: Any]] = []

                    if !msg.content.isEmpty {
                        parts.append(["text": msg.content])
                    }

                    if let data = msg.imageData, NSImage(data: data) != nil {
                        // Convert to base64
                        let base64 = data.base64EncodedString()
                        parts.append([
                            "inline_data": [
                                "mime_type": "image/jpeg",  // Assuming JPEG/PNG compatible data
                                "data": base64,
                            ]
                        ])
                    } else if let pdfData = msg.pdfData {
                        let base64 = pdfData.base64EncodedString()
                        parts.append([
                            "inline_data": [
                                "mime_type": "application/pdf",
                                "data": base64,
                            ]
                        ])
                    }

                    // Ensure at least one part exists (Gemini requires non-empty parts)
                    if parts.isEmpty {
                        parts.append(["text": " "])
                    }

                    return [
                        "role": msg.isUser ? "user" : "model",
                        "parts": parts,
                    ]
                }

                var body: [String: Any] = ["contents": contents]

                if !systemPrompt.isEmpty {
                    body["system_instruction"] = [
                        "parts": [
                            ["text": systemPrompt]
                        ]
                    ]
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (result, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        // Try to read error
                        var errorText = ""
                        for try await line in result.lines {
                            errorText += line
                        }
                        continuation.finish(
                            throwing: NSError(
                                domain: "GeminiError", code: httpResponse.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: errorText]))
                        return
                    }

                    for try await line in result.lines {
                        if line.hasPrefix("data: ") {
                            let jsonStr = String(line.dropFirst(6))
                            if jsonStr == "[DONE]" { break }

                            guard let data = jsonStr.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any],
                                let candidates = json["candidates"] as? [[String: Any]],
                                let content = candidates.first?["content"] as? [String: Any],
                                let parts = content["parts"] as? [[String: Any]],
                                let text = parts.first?["text"] as? String
                            else { continue }

                            continuation.yield((text, nil))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

class ShortcutService {
    func runShortcut(name: String, input: String, style: String? = nil, image: NSImage?)
        async throws -> (
            String, NSImage?
        )
    {
        let task = Process()
        let pipe = Pipe()
        let inputPipe = Pipe()

        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = inputPipe
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

        do {
            let tempDir = FileManager.default.temporaryDirectory
            let uniqueId = UUID().uuidString
            var filesToDelete: [URL] = []
            let isLegacyMode = (style == nil)  // Use legacy mode if style is NOT provided

            if !isLegacyMode {
                // MARK: - JSON Strategy (Image Creation)
                // Passes simple JSON text via Stdin: { "prompt": "...", "style": "...", "image_path": "..." }

                var inputDict: [String: String] = [:]

                let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasText {
                    inputDict["prompt"] = input
                }

                if let style = style, !style.isEmpty {
                    inputDict["style"] = style
                }

                // Image handling removed as requested to avoid bugs for now.
                // Can be re-enabled here later.

                // Serialize to JSON
                let jsonData = try JSONSerialization.data(
                    withJSONObject: inputDict, options: [.prettyPrinted, .sortedKeys])  // sortedKeys for deterministic output

                // Run with NO arguments (uses Stdin)
                task.arguments = ["run", name]

                try task.run()

                // Write JSON to Stdin
                try inputPipe.fileHandleForWriting.write(contentsOf: jsonData)
                try inputPipe.fileHandleForWriting.close()

            } else {
                // MARK: - Legacy Strategy (Standard Chat)
                // Preserves original behavior for "Ask ChatGPT" etc.

                if let image = image {
                    // Image Mode: Save text and image to temporary files
                    let txtPath = tempDir.appendingPathComponent("\(uniqueId)_prompt.txt")
                    let imgPath = tempDir.appendingPathComponent("\(uniqueId)_image.png")

                    try input.write(to: txtPath, atomically: true, encoding: .utf8)

                    if let tiff = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: tiff),
                        let png = bitmap.representation(using: .png, properties: [:])
                    {
                        try png.write(to: imgPath)
                    }

                    task.arguments = ["run", name, "-i", txtPath.path, "-i", imgPath.path]

                    // Close Stdin as we are using file inputs
                    try inputPipe.fileHandleForWriting.close()

                    filesToDelete.append(txtPath)
                    filesToDelete.append(imgPath)

                    try task.run()

                } else {
                    // Text Mode: Pass raw text via Stdin
                    task.arguments = ["run", name]

                    try task.run()

                    if let data = input.data(using: .utf8) {
                        try inputPipe.fileHandleForWriting.write(contentsOf: data)
                        try inputPipe.fileHandleForWriting.close()
                    }
                }
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            // Cleanup
            for file in filesToDelete {
                try? FileManager.default.removeItem(at: file)
            }

            return processOutput(data)

        } catch {
            return ("System Error: \(error.localizedDescription)", nil)
        }
    }

    private func processOutput(_ data: Data) -> (String, NSImage?) {
        // Check if output is an image
        if let image = NSImage(data: data) {
            return ("", image)
        }

        // RTF Cleanup
        if let attributedString = try? NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        {
            let plainText = attributedString.string.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !plainText.isEmpty { return (plainText, nil) }
        }

        let output = String(data: data, encoding: .utf8) ?? ""
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}

// MARK: - Views

struct WebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        // Use standard Mac Safari User Agent to ensure compatibility with Google Sign-In and WebAuthn
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedURL != url {
            context.coordinator.lastLoadedURL = url
            let request = URLRequest(url: url)
            nsView.load(request)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: WebView
        var lastLoadedURL: URL?

        init(_ parent: WebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Create a new window for popups (essential for Google Sign-In)
            let popupWebView = WKWebView(frame: .zero, configuration: configuration)
            popupWebView.navigationDelegate = self
            popupWebView.uiDelegate = self
            popupWebView.customUserAgent =
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

            let popupWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            popupWindow.center()
            popupWindow.title = "Sign In"
            popupWindow.contentView = popupWebView
            popupWindow.makeKeyAndOrderFront(nil)

            return popupWebView
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.window?.close()
        }
    }
}

enum ThinkingMode {
    case none
    case binary  // On/Off (e.g. DeepSeek)
    case threeState  // Low/Med/High (Standard)
}

struct ContentView: View {
    @ObservedObject private var chatManager = ChatManager.shared
    @State private var inputText: String = ""
    @State private var selectedAttachments: [Attachment] = []
    // Legacy single selection states removed/replaced
    @State private var imageCreationStyle: String = "Animation"
    @State private var isLoading: Bool = false
    @State private var thinkingLevel: String = "medium"
    @State private var showSidebar: Bool = false
    @State private var lastMessageCount: Int = 0
    @State private var lastSessionId: UUID?
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    // Settings
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("selectedProvider") private var selectedProvider: String = "Apple Foundation Model"

    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"
    @AppStorage("ShortcutOnDevice") private var shortcutOnDevice: String = "Ask AI Device"
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String =
        "Generate Image ChatGPT"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @AppStorage("BackgroundImagePath") private var backgroundImagePath: String = ""
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var showSplash: Bool = !AppState.shared.hasShownSplash
    @State private var currentTask: Task<Void, Never>?
    @State private var showImageGallery: Bool = false
    @State private var streamBuffer: [UUID: String] = [:]  // live text per message
    @State private var streamThinkingBuffer: [UUID: String] = [:]  // live reasoning per message

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let shortcutService = ShortcutService()
    private let appleFoundationService = AppleFoundationService()

    var thinkingMode: ThinkingMode {
        if selectedProvider == "Gemini API" {
            // Remove thinking for Gemini
            return .none
        } else if selectedProvider.contains("Ollama") {
            let lower = selectedOllamaModel.lowercased()
            if lower.contains("gpt-oss") {
                return .threeState  // Low, Med, High
            } else if lower.contains("deepseek") {
                return .binary  // On/Off
            }
            // All others (llama3, etc) -> None
            return .none
        }
        return .none
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(chatManager: chatManager, showImageGallery: $showImageGallery)
            } detail: {
                ZStack {
                    // Background Layer
                    GeometryReader { geometry in
                        ZStack {
                            if !backgroundImagePath.isEmpty,
                                let image = NSImage(contentsOfFile: backgroundImagePath)
                            {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                                    .opacity(0.3)
                            } else {
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(nsColor: .windowBackgroundColor),
                                        Color.blue.opacity(0.05),
                                    ]), startPoint: .top, endPoint: .bottom
                                )
                                .frame(width: geometry.size.width, height: geometry.size.height)
                            }

                            // Accent Color Tint
                            let colors = appTheme.colors
                            let startColor = colors.first ?? .blue
                            let endColor = colors.last ?? .green

                            LinearGradient(
                                colors: [
                                    startColor.opacity(0.08),
                                    endColor.opacity(0.05),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .ignoresSafeArea()
                        }
                    }
                    .ignoresSafeArea()

                    // Content Layer
                    if showImageGallery {
                        ImageGalleryView(
                            chatManager: chatManager, showImageGallery: $showImageGallery)
                    } else if isWebViewProvider(selectedProvider) {
                        VStack(spacing: 0) {
                            HeaderView(
                                selectedProvider: $selectedProvider,
                                onNewChat: chatManager.createNewSession
                            )

                            if let url = getWebURL(for: selectedProvider) {
                                WebView(url: url)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            HeaderView(
                                selectedProvider: $selectedProvider,
                                onNewChat: chatManager.createNewSession
                            )

                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(spacing: 24) {
                                        let messages = chatManager.getCurrentMessages()
                                        if messages.isEmpty {
                                            EmptyStateView(appTheme: appTheme)
                                        } else {
                                            ForEach(messages) { message in
                                                let isLast = message.id == messages.last?.id
                                                MessageView(
                                                    message: message,
                                                    liveContent: streamBuffer[message.id] ?? nil,
                                                    liveThinking: streamThinkingBuffer[message.id]
                                                        ?? nil,
                                                    onRegenerate: (!message.isUser && !isLoading
                                                        && isLast)
                                                        ? { regenerateResponse(for: message.id) }
                                                        : nil
                                                )
                                                .equatable()
                                            }
                                        }
                                    }
                                    .padding()
                                }
                                .safeAreaInset(edge: .bottom) {
                                    InputView(
                                        inputText: $inputText,
                                        selectedAttachments: $selectedAttachments,
                                        thinkingLevel: $thinkingLevel,
                                        isLoading: isLoading,
                                        onSend: sendMessage,
                                        onStop: stopGeneration,
                                        onSelectAttachment: selectAttachment,
                                        isImageGen: selectedProvider == "Image Creation",
                                        thinkingMode: thinkingMode,
                                        imageStyle: $imageCreationStyle,
                                        isOllama: selectedProvider.contains("Ollama"),
                                        isGemini: selectedProvider == "Gemini API"
                                    )
                                }
                                .onChange(of: chatManager.getCurrentMessages().count) { _, count in
                                    handleScroll(proxy: proxy, newCount: count)
                                }
                                .onChange(of: chatManager.currentSessionId) { _, _ in
                                    handleScroll(proxy: proxy)
                                }
                                .onChange(of: streamBuffer) { _, _ in
                                    if isLoading,
                                        let lastId = chatManager.getCurrentMessages().last?.id
                                    {
                                        proxy.scrollTo(lastId, anchor: .bottom)
                                    }
                                }
                                .onChange(of: isLoading) { _, loading in
                                    if loading {
                                        withAnimation {
                                            proxy.scrollTo("typingIndicator", anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 500)
            .disabled(showSplash)  // Disable main content when splash is showing to prevent focus ring bleed-through
            .toolbar(showSplash ? .hidden : .visible, for: .windowToolbar)

            if !hasSeenWelcome {
                WelcomeView {
                    withAnimation {
                        hasSeenWelcome = true
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }

            if showSplash {
                SplashScreen {
                    showSplash = false
                    AppState.shared.hasShownSplash = true
                }
                .transition(.opacity)
                .zIndex(200)
            }
        }
    }

    func isWebViewProvider(_ provider: String) -> Bool {
        return ["Gemini Web", "ChatGPT Web", "Perplexity Web", "Grok Web"].contains(provider)
    }

    func getWebURL(for provider: String) -> URL? {
        switch provider {
        case "Gemini Web": return URL(string: "https://gemini.google.com")
        case "ChatGPT Web": return URL(string: "https://chatgpt.com")
        case "Perplexity Web": return URL(string: "https://www.perplexity.ai")
        case "Grok Web": return URL(string: "https://grok.com")
        default: return nil
        }
    }

    func handleScroll(proxy: ScrollViewProxy, newCount: Int? = nil) {
        let currentCount = newCount ?? chatManager.getCurrentMessages().count

        if chatManager.currentSessionId != lastSessionId {
            // Session Switch
            lastSessionId = chatManager.currentSessionId
            lastMessageCount = currentCount

            // Jump to bottom (No Animation) to prevent freeze on large lists
            if let lastId = chatManager.getCurrentMessages().last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        } else {
            // Same Session
            if currentCount > lastMessageCount {
                // New Message -> Animate
                if let lastId = chatManager.getCurrentMessages().last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
            lastMessageCount = currentCount
        }
    }
    func selectAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        if panel.runModal() == .OK {
            for url in panel.urls {
                if url.pathExtension.lowercased() == "pdf" {
                    if let data = try? Data(contentsOf: url) {
                        selectedAttachments.append(Attachment(type: .pdf, data: data))
                    }
                } else {
                    let imageExtensions = [
                        "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                    ]
                    if imageExtensions.contains(url.pathExtension.lowercased()) {
                        if let data = try? Data(contentsOf: url) {
                            selectedAttachments.append(Attachment(type: .image, data: data))
                        }
                    }
                }
            }
        }
    }

    func sendMessage() {
        guard !isLoading else { return }
        guard
            !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedAttachments.isEmpty
        else { return }

        // Convert to MessageAttachment
        let msgAttachments = selectedAttachments.map {
            MessageAttachment(type: $0.type == .image ? "image" : "pdf", data: $0.data)
        }

        // Fallback for legacy services
        var legacyImage: NSImage?
        var legacyPDF: Data?

        for attachment in selectedAttachments {
            if attachment.type == .image && legacyImage == nil {
                legacyImage = NSImage(data: attachment.data)
            } else if attachment.type == .pdf && legacyPDF == nil {
                legacyPDF = attachment.data
            }
        }

        let userMsg = Message(
            content: inputText,
            image: legacyImage,
            pdfData: legacyPDF,
            attachments: msgAttachments,
            isUser: true
        )
        chatManager.addMessage(userMsg)

        let currentInput = inputText
        let currentAttachments = selectedAttachments

        inputText = ""
        selectedAttachments = []

        performSend(input: currentInput, attachments: currentAttachments)
    }

    func regenerateResponse(for messageId: UUID? = nil) {
        if let messageId = messageId {
            chatManager.truncateHistory(from: messageId)
        } else {
            let messages = chatManager.getCurrentMessages()
            guard let lastMsg = messages.last, !lastMsg.isUser else { return }
            chatManager.removeLastMessage()
        }

        // Find last user message
        if let lastUserMsg = chatManager.getCurrentMessages().last(where: { $0.isUser }) {
            var attachments: [Attachment] = []
            if let msgAttachments = lastUserMsg.attachments {
                attachments = msgAttachments.map {
                    Attachment(type: $0.type == "image" ? .image : .pdf, data: $0.data)
                }
            } else {
                if let img = lastUserMsg.image, let tiff = img.tiffRepresentation {
                    attachments.append(Attachment(type: .image, data: tiff))
                }
                if let pdf = lastUserMsg.pdfData {
                    attachments.append(Attachment(type: .pdf, data: pdf))
                }
            }
            performSend(
                input: lastUserMsg.content, attachments: attachments)
        }
    }

    func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    func performSend(input: String, attachments: [Attachment]) {
        isLoading = true
        let currentHistory = chatManager.getCurrentMessages()
        let style = imageCreationStyle

        // Helper for Image Creation legacy support
        var firstImage: NSImage?
        if let imgAtt = attachments.first(where: { $0.type == .image }) {
            firstImage = NSImage(data: imgAtt.data)
        }

        currentTask?.cancel()

        currentTask = Task {
            if selectedProvider == "Image Creation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", isUser: false)
                aiMsg.isGeneratingImage = true
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    // Only plain "ChatGPT" (no styles) uses the specialized ChatGPT shortcut
                    let targetShortcut =
                        (style == "ChatGPT") ? shortcutImageGenChatGPT : shortcutImageGen

                    let result = try await shortcutService.runShortcut(
                        name: targetShortcut, input: input, style: style, image: firstImage)
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: result.0, image: result.1,
                            isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Gemini API" {
                if !geminiKey.isEmpty {
                    let aiMsgId = UUID()
                    // Store model name
                    var aiMsg = Message(content: "", model: geminiModel, isUser: false)
                    aiMsg.id = aiMsgId
                    aiMsg.isStreaming = true

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk)
                            in geminiService.sendMessageStream(
                                history: currentHistory, apiKey: geminiKey, model: geminiModel,
                                systemPrompt: systemPrompt, thinkingLevel: thinkingLevel)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentToUpdate = fullContent
                                let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.chatManager.updateMessage(
                                        id: aiMsgId, content: contentToUpdate,
                                        thinkingContent: thinkingToUpdate, isStreaming: true)
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: fullContent,
                                thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: "Error: \(error.localizedDescription)",
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Please enter your Gemini API Key in settings.", isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Apple Foundation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", model: "Apple Foundation", isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    var accumulatedContent = ""
                    var lastUpdateTime = Date()

                    for try await contentSnapshot in appleFoundationService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), systemPrompt: systemPrompt
                    ) {
                        accumulatedContent += contentSnapshot

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentToUpdate = accumulatedContent
                            DispatchQueue.main.async {
                                self.chatManager.updateMessage(
                                    id: aiMsgId, content: contentToUpdate, isStreaming: true)
                            }
                            lastUpdateTime = Date()
                        }
                    }

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: accumulatedContent, isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Ollama" {
                let aiMsgId = UUID()
                let activeModel = selectedOllamaModel
                var aiMsg = Message(content: "", model: activeModel, isUser: false)
                aiMsg.id = aiMsgId

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                // Removed redeclaration of activeModel

                do {
                    var fullContent = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()

                    for try await (contentChunk, thinkingChunk) in ollamaService.sendMessageStream(
                        history: currentHistory, endpoint: ollamaURL, model: activeModel,
                        systemPrompt: systemPrompt, thinkingLevel: thinkingLevel)
                    {
                        fullContent += contentChunk
                        if let thinking = thinkingChunk {
                            fullThinking += thinking
                        }

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentToUpdate = fullContent
                            let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                            DispatchQueue.main.async {
                                self.chatManager.updateMessage(
                                    id: aiMsgId, content: contentToUpdate,
                                    thinkingContent: thinkingToUpdate, isStreaming: true)
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId,
                            content: fullContent,
                            thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else {
                // Shortcuts
                let shortcutName: String
                let displayModelName: String
                switch selectedProvider {
                case "Private Cloud":
                    shortcutName = shortcutPrivateCloud
                    displayModelName = "Private Cloud Compute"
                case "On-Device":
                    shortcutName = shortcutOnDevice
                    displayModelName = "On-Device"
                case "ChatGPT":
                    shortcutName = shortcutChatGPT
                    displayModelName = "ChatGPT"
                default:
                    shortcutName = shortcutPrivateCloud
                    displayModelName = "Private Cloud Compute"
                }

                // Create placeholder message with streaming state
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", model: displayModelName, isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                // Build transcript for shortcuts
                var transcript = "Please reply to the last message:\n\n"
                for msg in currentHistory.suffix(10) {
                    let role = msg.isUser ? "User" : "Assistant"
                    transcript += "\(role): \(msg.content)\n"
                }
                transcript += "Assistant:"

                do {
                    let result = try await shortcutService.runShortcut(
                        name: shortcutName, input: transcript, image: firstImage)
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId,
                            content: result.0,
                            image: result.1,
                            isStreaming: false
                        )
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId,
                            content: "Error: \(error.localizedDescription)",
                            isStreaming: false
                        )
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

struct SidebarView: View {
    @ObservedObject var chatManager: ChatManager
    @Binding var showImageGallery: Bool
    @Namespace private var animation

    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var renamingSessionId: UUID?
    @State private var renameText: String = ""

    // Service for summarization
    private let summarizer = AppleFoundationService()

    var filteredSessions: [ChatSession] {
        if searchText.isEmpty {
            return chatManager.sessions
        } else {
            return chatManager.sessions.filter { session in
                if session.title.localizedCaseInsensitiveContains(searchText) { return true }
                return session.messages.contains { msg in
                    msg.content.localizedCaseInsensitiveContains(searchText)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Section
            VStack(alignment: .leading, spacing: 4) {
                // New Chat
                SidebarItem(icon: "square.and.pencil", title: "New chat") {
                    showImageGallery = false
                    chatManager.createNewSession()
                }

                // Search
                SidebarItem(icon: "magnifyingglass", title: "Search chats") {
                    isSearchVisible.toggle()
                }
                .popover(isPresented: $isSearchVisible, arrowEdge: .leading) {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Search chats...", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                        if filteredSessions.isEmpty {
                            Text("No chats found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 4) {
                                    ForEach(filteredSessions) { session in
                                        Button(action: {
                                            showImageGallery = false
                                            chatManager.currentSessionId = session.id
                                            isSearchVisible = false
                                        }) {
                                            HStack {
                                                Text(session.title)
                                                    .lineLimit(1)
                                                    .font(.system(size: 13))
                                                Spacer()
                                                Text(session.date, style: .date)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(8)
                                            .background(Color.primary.opacity(0.05))
                                            .cornerRadius(6)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 300)
                        }
                    }
                    .padding()
                    .frame(width: 300)
                }

                // Images
                SidebarItem(icon: "photo", title: "Images", isSelected: showImageGallery) {
                    withAnimation {
                        showImageGallery = true
                        chatManager.currentSessionId = nil
                    }
                }
            }
            .padding(10)

            // Section Header
            Text("Your chats")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Chat List
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(
                        chatManager.sessions.filter {
                            !$0.messages.isEmpty || $0.id == chatManager.currentSessionId
                        }
                    ) { session in
                        SidebarRow(
                            session: session,
                            isSelected: !showImageGallery
                                && chatManager.currentSessionId == session.id,
                            isRenaming: renamingSessionId == session.id,
                            renameText: $renameText,
                            animation: animation,
                            onSelect: {
                                showImageGallery = false
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    chatManager.currentSessionId = session.id
                                }
                            },
                            onDelete: {
                                withAnimation {
                                    chatManager.deleteSession(id: session.id)
                                }
                            },
                            onRename: {
                                renameText = session.title
                                renamingSessionId = session.id
                            },
                            onCommitRename: {
                                chatManager.renameSession(id: session.id, newTitle: renameText)
                                renamingSessionId = nil
                            },
                            onSummarize: {
                                summarize(session: session)
                            },
                            onExport: {
                                exportChat(session: session)
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private func summarize(session: ChatSession) {
        guard !session.messages.isEmpty else { return }

        let prompt = """
            Analyze the following conversation and provide a short, concise title (3-5 words max).
            Return ONLY the title, no quotes or explanation.
            """

        Task {
            do {
                var newTitle = ""
                for try await chunk in summarizer.sendMessageStream(
                    history: session.messages, systemPrompt: prompt)
                {
                    newTitle += chunk
                }

                let cleaned = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "")

                DispatchQueue.main.async {
                    if !cleaned.isEmpty {
                        chatManager.renameSession(id: session.id, newTitle: cleaned)
                    }
                }
            } catch {
                print("Summarization failed: \(error)")
            }
        }
    }

    private func exportChat(session: ChatSession) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        savePanel.nameFieldStringValue = "\(session.title).md"
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                var markdown = "# \(session.title)\n\n"
                markdown += "Date: \(session.date.formatted())\n\n"

                for message in session.messages {
                    let role =
                        message.isUser ? "**User**" : "**AI (\(message.model ?? "Unknown"))**"
                    markdown += "\(role):\n\(message.content)\n\n"
                }

                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    print("Failed to save file: \(error)")
                }
            }
        }
    }
}

struct SidebarItem: View {
    let icon: String
    let title: String
    var isSelected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 20)  // Fixed width for alignment
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.primary.opacity(0.1) : Color.clear
            )
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .primary.opacity(0.8))
    }
}

struct SidebarRow: View {
    let session: ChatSession
    let isSelected: Bool
    var isRenaming: Bool = false
    @Binding var renameText: String
    var animation: Namespace.ID
    var onSelect: () -> Void
    var onDelete: () -> Void
    var onRename: () -> Void
    var onCommitRename: () -> Void
    var onSummarize: () -> Void
    var onExport: () -> Void

    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @State private var offset: CGFloat = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            // Delete Action Background
            if offset < 0 {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .frame(maxHeight: .infinity)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.trailing, 0)
            }

            // Content
            HStack(spacing: 12) {
                // Indicator
                Circle()
                    .fill(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 8, height: 8)
                    .opacity(isSelected ? 1 : 0)

                VStack(alignment: .leading, spacing: 3) {
                    if isRenaming {
                        TextField("Title", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .focused($isFocused)
                            .onSubmit(onCommitRename)
                            .onAppear { isFocused = true }
                    } else {
                        Text(session.title.isEmpty ? "New Chat" : session.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .primary : .primary.opacity(0.9))
                            .lineLimit(1)
                    }

                    Text(session.date, style: .date)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !session.messages.isEmpty {
                    Text("\(session.messages.count)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                            .matchedGeometryEffect(id: "selection", in: animation)
                    }
                }
            )
            .contentShape(Rectangle())
            .offset(x: offset)
            .gesture(
                DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { gesture in
                        if gesture.translation.width < 0 {
                            withAnimation(.interactiveSpring()) {
                                offset = gesture.translation.width
                            }
                        }
                    }
                    .onEnded { gesture in
                        if gesture.translation.width < -60 {
                            withAnimation(.spring()) {
                                offset = -60
                            }
                        } else {
                            withAnimation(.spring()) {
                                offset = 0
                            }
                        }
                    }
            )
            .onTapGesture {
                if offset < 0 {
                    withAnimation(.spring()) {
                        offset = 0
                    }
                } else if !isRenaming {
                    onSelect()
                }
            }
            .contextMenu {
                Button("Rename") {
                    onRename()
                }
                Button("Rename with Apple Intelligence") {
                    onSummarize()
                }
                Button("Export as Markdown") {
                    onExport()
                }
                Divider()
                Button("Delete", role: .destructive) {
                    onDelete()
                }
            }
        }
    }
}

struct HeaderView: View {
    @Binding var selectedProvider: String
    var onNewChat: () -> Void

    var body: some View {
        HStack {
            Menu {
                Section("Apple Intelligence") {
                    Button(action: { selectedProvider = "Apple Foundation" }) {
                        Label("Apple Foundation", systemImage: getProviderIcon("Apple Foundation"))
                    }
                }
                Section("API") {
                    Button(action: { selectedProvider = "Gemini API" }) {
                        Label("Gemini API", systemImage: getProviderIcon("Gemini API"))
                    }
                    Button(action: { selectedProvider = "Ollama" }) {
                        Label("Ollama", systemImage: getProviderIcon("Ollama"))
                    }
                }
                Section("Shortcuts") {
                    Button(action: { selectedProvider = "Private Cloud" }) {
                        Label("Private Cloud", systemImage: getProviderIcon("Private Cloud"))
                    }
                    Button(action: { selectedProvider = "On-Device" }) {
                        Label("On-Device", systemImage: getProviderIcon("On-Device"))
                    }
                    Button(action: { selectedProvider = "ChatGPT" }) {
                        Label("ChatGPT", systemImage: getProviderIcon("ChatGPT"))
                    }
                }
                Section("Tools") {
                    Button(action: { selectedProvider = "Image Creation" }) {
                        Label("Image Creation", systemImage: getProviderIcon("Image Creation"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: getProviderIcon(selectedProvider))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .green], startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                    Text(selectedProvider)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            Color.gray.opacity(0.14)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    Color.white.opacity(0.18),
                                    lineWidth: 0.8
                                )
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusEffectDisabled()
            .padding(.horizontal, 4)  // Padding around the menu for click area

            Spacer()
        }
        .padding()
        // Transparent background
    }
    func getProviderIcon(_ provider: String) -> String {
        switch provider {
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
        case "Image Creation": return "paintbrush"
        case "ChatGPT": return "message"
        default: return "cpu"
        }
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment.type {
                case .image:
                    if let image = NSImage(data: attachment.data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .pdf:
                    VStack(spacing: 2) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                        Text("PDF")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .background(Color.white.clipShape(Circle()))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
        }
    }
}

class PasteMonitor: ObservableObject {
    private var monitor: Any?
    var onPaste: (([Attachment]) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                let pb = NSPasteboard.general
                var newAttachments: [Attachment] = []

                // 1. Try reading as File URLs
                if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                    !urls.isEmpty
                {
                    for url in urls {
                        if url.pathExtension.lowercased() == "pdf" {
                            if let data = try? Data(contentsOf: url) {
                                newAttachments.append(Attachment(type: .pdf, data: data))
                            }
                        } else {
                            let imageExtensions = [
                                "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                            ]
                            if imageExtensions.contains(url.pathExtension.lowercased()) {
                                if let data = try? Data(contentsOf: url) {
                                    newAttachments.append(Attachment(type: .image, data: data))
                                }
                            }
                        }
                    }
                }

                if !newAttachments.isEmpty {
                    // If we found files, paste them and consume event
                    self.onPaste?(newAttachments)
                    return nil
                }

                // 2. Fallback to NSImage objects (e.g. copied from browser or screenshot)
                if let objects = pb.readObjects(forClasses: [NSImage.self], options: nil)
                    as? [NSImage], !objects.isEmpty
                {
                    for image in objects {
                        if let tiff = image.tiffRepresentation {
                            newAttachments.append(Attachment(type: .image, data: tiff))
                        }
                    }
                }

                if !newAttachments.isEmpty {
                    self.onPaste?(newAttachments)
                    return nil
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        stop()
    }
}

struct InputView: View {
    @Binding var inputText: String
    @Binding var selectedAttachments: [Attachment]
    @Binding var thinkingLevel: String
    var isLoading: Bool
    var onSend: () -> Void
    var onStop: () -> Void
    var onSelectAttachment: () -> Void
    var isImageGen: Bool
    var thinkingMode: ThinkingMode
    @Binding var imageStyle: String
    var isOllama: Bool = false
    var isGemini: Bool = false
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared

    @FocusState private var isFocused: Bool
    @StateObject private var pasteMonitor = PasteMonitor()
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            imagePreview
            inputBar
        }
        .padding()
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handlePaste(providers)
            return true
        }
        .onAppear {
            setupMonitor()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                pasteMonitor.start()
            } else {
                pasteMonitor.stop()
            }
        }
    }

    private func setupMonitor() {
        pasteMonitor.onPaste = { attachments in
            DispatchQueue.main.async {
                self.selectedAttachments.append(contentsOf: attachments)
            }
        }
        // If already focused on appear (rare but possible)
        if isFocused {
            pasteMonitor.start()
        }
    }

    private var imagePreview: some View {
        Group {
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedAttachments) { attachment in
                            AttachmentPreview(attachment: attachment) {
                                if let index = selectedAttachments.firstIndex(where: {
                                    $0.id == attachment.id
                                }) {
                                    selectedAttachments.remove(at: index)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .padding(.bottom, 4)
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 12) {
            if isImageGen {
                // Style Picker
                Menu {
                    Section("Apple Intelligence") {
                        styleButton("Animation", value: "Animation")
                        styleButton("Illustration", value: "Illustration")
                        styleButton("Sketch", value: "Sketch")
                    }
                    Divider()
                    Section("ChatGPT") {
                        styleButton("ChatGPT (Default)", value: "ChatGPT")
                        styleButton("Oil Painting", value: "Oil Painting (ChatGPT)")
                        styleButton("Watercolor", value: "Watercolor (ChatGPT)")
                        styleButton("Vector", value: "Vector (ChatGPT)")
                        styleButton("Anime", value: "Anime (ChatGPT)")
                        styleButton("Print", value: "Print (ChatGPT)")
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 16))
                        .foregroundColor(imageStyle.isEmpty ? .secondary : .orange)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Image Style")
            } else {
                Button(action: onSelectAttachment) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            inputField

            if isOllama {
                Menu {
                    Section("Favorites") {
                        ForEach(ollamaManager.favoriteModels, id: \.self) { model in
                            Button(action: { selectedOllamaModel = model }) {
                                if selectedOllamaModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                    ForEach(ollamaManager.sortedManufacturers, id: \.self) { manufacturer in
                        let models = ollamaManager.allModels
                            .filter { !ollamaManager.isFavorite($0) }
                            .filter { ollamaManager.getManufacturer(for: $0) == manufacturer }

                        if !models.isEmpty {
                            Section(manufacturer) {
                                ForEach(models, id: \.self) { model in
                                    Button(action: { selectedOllamaModel = model }) {
                                        if selectedOllamaModel == model {
                                            Label(model, systemImage: "checkmark")
                                        } else {
                                            Text(model)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Menu("Manage Favorites") {
                        ForEach(ollamaManager.allModels, id: \.self) { model in
                            Button(action: { ollamaManager.toggleFavorite(model) }) {
                                if ollamaManager.isFavorite(model) {
                                    Label(model, systemImage: "star.fill")
                                } else {
                                    Label(model, systemImage: "star")
                                }
                            }
                        }
                    }

                    Button(action: { showAddCustomOllamaModel = true }) {
                        Label("Add Custom Model...", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Select Ollama Model")
                .alert("Add Custom Ollama Model", isPresented: $showAddCustomOllamaModel) {
                    TextField("Model Name (e.g., llama3:70b)", text: $newCustomModelName)
                    Button("Add") {
                        ollamaManager.addCustomModel(newCustomModelName)
                        selectedOllamaModel = newCustomModelName
                        newCustomModelName = ""
                    }
                    Button("Cancel", role: .cancel) {
                        newCustomModelName = ""
                    }
                } message: {
                    Text("Enter the name of the model as it appears in Ollama.")
                }
            }

            if isGemini {
                Menu {
                    Section("Favorites") {
                        ForEach(geminiManager.favoriteModels, id: \.self) { model in
                            Button(action: { geminiModel = model }) {
                                if geminiModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }

                    Section("All Models") {
                        ForEach(
                            geminiManager.availableModels.filter { !geminiManager.isFavorite($0) },
                            id: \.self
                        ) { model in
                            Button(action: { geminiModel = model }) {
                                if geminiModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }

                    Divider()

                    Menu("Manage Favorites") {
                        ForEach(geminiManager.availableModels, id: \.self) { model in
                            Button(action: { geminiManager.toggleFavorite(model) }) {
                                if geminiManager.isFavorite(model) {
                                    Label(model, systemImage: "star.fill")
                                } else {
                                    Label(model, systemImage: "star")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Select Gemini Model")
            }

            if thinkingMode != .none {
                Menu {
                    if thinkingMode == .binary {
                        Button {
                            thinkingLevel = "high"
                        } label: {
                            if thinkingLevel == "high" {
                                Label("Reasoning: On", systemImage: "checkmark")
                            } else {
                                Text("Reasoning: On")
                            }
                        }
                        Button {
                            thinkingLevel = "low"
                        } label: {
                            if thinkingLevel != "high" {
                                Label("Reasoning: Off", systemImage: "checkmark")
                            } else {
                                Text("Reasoning: Off")
                            }
                        }
                    } else {
                        Button {
                            thinkingLevel = "low"
                        } label: {
                            if thinkingLevel == "low" {
                                Label("Low", systemImage: "checkmark")
                            } else {
                                Text("Low")
                            }
                        }
                        Button {
                            thinkingLevel = "medium"
                        } label: {
                            if thinkingLevel == "medium" {
                                Label("Medium", systemImage: "checkmark")
                            } else {
                                Text("Medium")
                            }
                        }
                        Button {
                            thinkingLevel = "high"
                        } label: {
                            if thinkingLevel == "high" {
                                Label("High", systemImage: "checkmark")
                            } else {
                                Text("High")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 16))
                        .foregroundColor(
                            (thinkingLevel == "medium" && thinkingMode == .threeState)
                                || (thinkingLevel == "low" && thinkingMode == .binary)
                                ? .secondary : .primary
                        )
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Reasoning Effort")
            }

            // Send/Stop Button
            Button(action: {
                if isLoading {
                    onStop()
                } else {
                    onSend()
                }
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.primary)
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(
                (inputText.isEmpty && selectedAttachments.isEmpty) && !isLoading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if inputText.isEmpty && !isFocused {
                Text(isImageGen ? "Describe image to generate..." : "Ask AI anything...")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
                    .padding(.leading, 4)
            }

            TextField("", text: $inputText, axis: .vertical)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .lineLimit(1...10)
                .onKeyPress(.return) {
                    if NSEvent.modifierFlags.contains(.shift) {
                        return .ignored
                    } else {
                        onSend()
                        return .handled
                    }
                }
                .onPasteCommand(of: [.image, .fileURL]) { providers in
                    handlePaste(providers)
                }
        }
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("com.adobe.pdf") {
                provider.loadItem(forTypeIdentifier: "com.adobe.pdf", options: nil) { urlData, _ in
                    if let urlData = urlData as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil),
                        let data = try? Data(contentsOf: url)
                    {
                        DispatchQueue.main.async {
                            self.selectedAttachments.append(Attachment(type: .pdf, data: data))
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    if let image = image as? NSImage, let tiff = image.tiffRepresentation {
                        DispatchQueue.main.async {
                            self.selectedAttachments.append(Attachment(type: .image, data: tiff))
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) {
                    urlData, _ in
                    if let urlData = urlData as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    {
                        if url.pathExtension.lowercased() == "pdf" {
                            if let data = try? Data(contentsOf: url) {
                                DispatchQueue.main.async {
                                    self.selectedAttachments.append(
                                        Attachment(type: .pdf, data: data))
                                }
                                return
                            }
                        }

                        // Handle file URL - for now just try to load as image
                        let imageExtensions = [
                            "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                        ]
                        if imageExtensions.contains(url.pathExtension.lowercased()) {
                            if let data = try? Data(contentsOf: url) {
                                DispatchQueue.main.async {
                                    self.selectedAttachments.append(
                                        Attachment(type: .image, data: data))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func styleButton(_ title: String, value: String) -> some View {
        Button(action: { imageStyle = value }) {
            if imageStyle == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct ThumbnailView: View {
    let image: NSImage
    let maxWidth: CGFloat
    let maxHeight: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .cornerRadius(12)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .cornerRadius(12)
                    .onAppear {
                        generateThumbnail()
                    }
            }
        }
    }

    private func generateThumbnail() {
        Task {
            // Keep original aspect ratio
            let aspectRatio = image.size.width / image.size.height
            let newWidth: CGFloat
            let newHeight: CGFloat

            if aspectRatio > 1 {
                // Wide image: Cap width
                newWidth = min(image.size.width, maxWidth * 2)  // Retina
                newHeight = newWidth / aspectRatio
            } else {
                // Tall image: Cap height
                newHeight = min(image.size.height, maxHeight * 2)  // Retina
                newWidth = newHeight * aspectRatio
            }

            let targetSize = NSSize(width: newWidth, height: newHeight)

            let thumb = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let newImage = NSImage(size: targetSize)
                    newImage.lockFocus()
                    // Use standard image scaling instead of force-stretching
                    image.draw(
                        in: NSRect(origin: .zero, size: targetSize),
                        from: NSRect(origin: .zero, size: image.size),
                        operation: .copy,
                        fraction: 1.0)
                    newImage.unlockFocus()
                    continuation.resume(returning: newImage)
                }
            }
            await MainActor.run {
                self.thumbnail = thumb
            }
        }
    }
}

private let latexScaleFactor: CGFloat = 2.0 / 3.0  // ~1.5x smaller rendering

struct MathView: NSViewRepresentable {
    var equation: String
    var fontSize: CGFloat = 20 * latexScaleFactor

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.textAlignment = .center
        view.fontSize = fontSize
        view.textColor = NSColor.labelColor
        return view
    }

    func updateNSView(_ uiView: MTMathUILabel, context: Context) {
        uiView.latex = equation
        uiView.fontSize = fontSize
        uiView.textColor = NSColor.labelColor
    }
}

struct KaTeXView: NSViewRepresentable {
    var latex: String
    var fontSize: CGFloat
    @Binding var height: CGFloat
    @Binding var didRender: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "height")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Escape for JS template literal: keep backslashes intact, only escape backticks and interpolation
        let escapedLatex =
            latex
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
            .replacingOccurrences(of: "\n", with: " ")

        let html = """
            <!doctype html>
            <html>
                <head>
                    <meta charset="utf-8">
                    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
                    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
                    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
                    <style>
                        :root { color-scheme: light dark; }
                        body { margin:0; padding:8px; background: transparent; color: #111; font-size: \(fontSize)pt; text-align: center; overflow: hidden; }
                        @media (prefers-color-scheme: dark) { body { color: #f5f5f5; } }
                        .katex, .katex * { color: inherit !important; }
                        .katex-display { margin: 0; }
                    </style>
                </head>
                <body>
                    <div id="math"></div>
                    <script>
                        function sendHeight() {
                            const h = document.documentElement.scrollHeight || document.body.scrollHeight || 0;
                            window.webkit.messageHandlers.height.postMessage(h);
                        }
                        document.addEventListener('DOMContentLoaded', () => {
                            try {
                                katex.render(String.raw`\(escapedLatex)`, document.getElementById('math'), { displayMode: true, throwOnError: false });
                            } catch (e) {
                                document.getElementById('math').innerText = e.toString();
                            }
                            setTimeout(sendHeight, 30);
                        });
                    </script>
                </body>
            </html>
            """

        nsView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: KaTeXView

        init(parent: KaTeXView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "height" else { return }
            if let h = message.body as? Double {
                DispatchQueue.main.async {
                    self.parent.height = max(40, CGFloat(h))
                    self.parent.didRender = true
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(
                "(function(){ const h = document.documentElement.scrollHeight || document.body.scrollHeight || 0; window.webkit.messageHandlers.height.postMessage(h); })();"
            ) { _, _ in }
        }
    }
}

struct MathBlockView: View {
    let equation: String
    @State private var height: CGFloat = 60
    @State private var didRender = false

    private var scaledFontSize: CGFloat { 14 * latexScaleFactor }

    var body: some View {
        VStack {
            KaTeXView(
                latex: equation, fontSize: scaledFontSize, height: $height, didRender: $didRender
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .opacity(didRender ? 1 : 0)

            if !didRender {
                MathView(equation: equation, fontSize: scaledFontSize)
                    .frame(minHeight: 30)
                    .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

struct MarkdownView: View, Equatable {
    let blocks: [MarkdownBlock]
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        return lhs.blocks == rhs.blocks
    }

    private var textColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private func renderRichText(_ text: String, cached: AttributedString? = nil) -> Text {
        if let cached = cached {
            return Text(cached)
        }
        return Text(MarkdownParser.shared.parse(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks, id: \.id) { block in
                switch block.type {
                case .text(let text):
                    renderRichText(text, cached: block.attributedText)
                        .font(.system(size: 15))
                        .foregroundColor(textColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code, let language):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if !language.isEmpty {
                                Text(language)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Button(action: {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(code, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                            .help("Copy Code")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.2))

                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(textColor)
                                .padding(12)
                                .textSelection(.enabled)
                        }
                    }
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                case .heading(let text, let level):
                    renderRichText(text, cached: block.attributedText)
                        .font(
                            .system(
                                size: level == 1 ? 24 : (level == 2 ? 20 : (level == 3 ? 18 : 16)),
                                weight: .bold)
                        )
                        .padding(.top, 8)
                        .foregroundColor(textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .divider:
                    Divider()
                        .padding(.vertical, 8)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                        renderRichText(text, cached: block.attributedText)
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 8)
                case .numbered(let text, let number):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(number).")
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                        renderRichText(text, cached: block.attributedText)
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 8)
                case .blockquote(let text):
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: 4)
                        renderRichText(text, cached: block.attributedText)
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .math(let equation):
                    let cleanEq = MarkdownParser.shared.cleanLatex(equation)
                    if cleanEq.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        renderRichText(equation)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        MathBlockView(equation: cleanEq)
                            .frame(maxWidth: .infinity)
                    }
                case .table(let headers, let rows):
                    ScrollView(.horizontal, showsIndicators: true) {
                        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                            // Header
                            GridRow {
                                ForEach(headers.indices, id: \.self) { i in
                                    renderRichText(headers[i])
                                        .font(.system(size: 14, weight: .semibold))
                                        .multilineTextAlignment(.leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.04))
                                        .overlay(
                                            Divider(), alignment: .bottom
                                        )
                                }
                            }

                            // Rows
                            ForEach(rows.indices, id: \.self) { i in
                                GridRow {
                                    ForEach(0..<headers.count, id: \.self) { j in
                                        let content = j < rows[i].count ? rows[i][j] : ""
                                        renderRichText(content)
                                            .font(.system(size: 14))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                            .background(
                                                i % 2 == 0
                                                    ? Color.clear : Color.primary.opacity(0.04))  // Alternating row color
                                    }
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.02))  // Very subtle background
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var appTheme: AppTheme = .default
    @State private var animate = false

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        return VStack(spacing: 30) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [startColor.opacity(0.1), endColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                    .scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "sparkles")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [startColor, endColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: startColor.opacity(0.3), radius: 10, x: 0, y: 5)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    animate.toggle()
                }
            }

            VStack(spacing: 8) {
                Text("Hello")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [startColor, endColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Text("How can I help you today?")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

struct MessageView: View, Equatable {
    let message: Message
    var liveContent: String? = nil
    var liveThinking: String? = nil
    var onRegenerate: (() -> Void)?
    var maxBubbleWidth: CGFloat = 500

    @State private var isCopied = false
    @State private var showImagePreview = false
    @State private var isCursorVisible = true
    @State private var isThinkingExpanded = false
    @Environment(\.colorScheme) private var colorScheme
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        return lhs.message == rhs.message && lhs.liveContent == rhs.liveContent
            && lhs.liveThinking == rhs.liveThinking
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer()
                VStack(alignment: .trailing) {
                    if let image = message.image {
                        ThumbnailView(image: image, maxWidth: 200, maxHeight: 300)
                            .onTapGesture {
                                showImagePreview = true
                            }
                    }
                    if message.pdfData != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .font(.title2)
                                .foregroundColor(.red)
                            Text("PDF Document")
                                .font(.callout)
                                .foregroundColor(.primary)
                        }
                        .padding(10)
                        .background(Material.ultraThin)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.bottom, 4)
                    }
                    Text(message.content)
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .padding(12)
                        .background(Color.blue.opacity(0.2))
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                }
                .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if message.isGeneratingImage == true {
                        GeneratingImagePlaceholder()
                    } else {
                        if let thinking = (liveThinking ?? message.thinkingContent) {
                            DisclosureGroup(isExpanded: $isThinkingExpanded) {
                                Text(thinking)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.caption)
                                    Text("Reasoning Process")
                                        .font(.caption)
                                }
                                .foregroundColor(.secondary)
                            }
                            .padding(.bottom, 4)
                        }

                        if let image = message.image {
                            ThumbnailView(image: image, maxWidth: 300, maxHeight: 300)
                                .padding(.bottom, 4)
                                .onTapGesture {
                                    showImagePreview = true
                                }
                        }
                        let activeContent = liveContent ?? message.content

                        if message.isStreaming && activeContent.isEmpty
                            && (liveThinking ?? message.thinkingContent) == nil
                        {
                            ThinkingIndicator()
                        } else if !activeContent.isEmpty || message.isStreaming {
                            if message.isStreaming {
                                Text(activeContent + (isCursorVisible ? " ▋" : ""))
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                            } else {
                                MarkdownView(blocks: message.blocks)
                                    .equatable()
                                    .foregroundColor(colorScheme == .dark ? .white : .black)
                            }
                        }
                    }

                    // Action Buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            if let image = message.image {
                                pasteboard.writeObjects([image])
                            } else {
                                pasteboard.setString(message.content, forType: .string)
                            }
                            isCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                isCopied = false
                            }
                        }) {
                            Label(
                                isCopied ? "Copied" : "Copy",
                                systemImage: isCopied ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption)
                            .foregroundColor(isCopied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)

                        if let onRegenerate = onRegenerate {
                            Button(action: onRegenerate) {
                                Label("Regenerate", systemImage: "arrow.counterclockwise")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)

                    if let model = message.model {
                        Text("Model used: \(model). Information could be inaccurate.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.top, 2)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showImagePreview) {
            if let image = message.image {
                ImagePreviewView(image: image)
            }
        }
        .onReceive(cursorTimer) { _ in
            if message.isStreaming {
                isCursorVisible.toggle()
            }
        }
        .onChange(of: liveThinking) { _, newValue in
            if let val = newValue, !val.isEmpty, liveContent == nil || liveContent!.isEmpty {
                isThinkingExpanded = true
            }
        }
        .onChange(of: liveContent) { _, newValue in
            if let val = newValue, !val.isEmpty {
                withAnimation {
                    isThinkingExpanded = false
                }
            }
        }
        .onChange(of: message.thinkingContent) { _, newValue in
            let currentContent = liveContent ?? message.content
            if let val = newValue, !val.isEmpty, currentContent.isEmpty {
                isThinkingExpanded = true
            }
        }
        .onChange(of: message.content) { _, newValue in
            if !newValue.isEmpty {
                withAnimation {
                    isThinkingExpanded = false
                }
            }
        }
    }
}

struct ImagePreviewView: View {
    let image: NSImage
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding()

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct SettingsView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"
    @AppStorage("ShortcutOnDevice") private var shortcutOnDevice: String = "Ask AI Device"
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String =
        "Generate Image ChatGPT"
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("ShowMenuBar") private var showMenuBar = true
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("EnableQuickAI") private var enableQuickAI = true
    @AppStorage("QuickAIBackgroundOpacity") private var quickAIBackgroundOpacity: Double = 0.18
    @AppStorage("QuickAICommandBarVibrancy") private var quickAICommandBarVibrancy: Double = 0.55
    @AppStorage("BackgroundImagePath") private var backgroundImagePath: String = ""

    @EnvironmentObject var chatManager: ChatManager
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""

    var body: some View {
        Form {
            Section {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 50)
            }
            .listRowBackground(Color.clear)

            Section(header: Text("Theme")) {
                HStack(alignment: .top) {
                    Text("Color")
                        .padding(.top, 6)
                    Spacer()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AppTheme.allCases) { theme in
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: theme.colors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                        )
                                        .padding(3)
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    Color.accentColor,
                                                    lineWidth: appTheme == theme ? 2 : 0)
                                        )
                                        .onTapGesture {
                                            appTheme = theme
                                            IconManager.shared.updateIcon(theme: theme)
                                        }

                                    Text(
                                        theme.rawValue == "Default" ? "Multicolor" : theme.rawValue
                                    )
                                    .font(.caption2)
                                    .foregroundColor(appTheme == theme ? .secondary : .clear)
                                    .fixedSize()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                }
            }

            Section(header: Text("General")) {
                Toggle("Show Menu Bar Icon", isOn: $showMenuBar)
                    .toggleStyle(.switch)
                Toggle("Enable Quick AI Hotkey", isOn: $enableQuickAI)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quick AI Background Opacity")
                        Spacer()
                        Text("\(Int(min(max(quickAIBackgroundOpacity, 0.05), 0.55) * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { quickAIBackgroundOpacity },
                            set: { quickAIBackgroundOpacity = min(max($0, 0.05), 0.55) }
                        ),
                        in: 0.05...0.55
                    )
                    HStack {
                        Text("Clear").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Opaque").font(.caption).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quick AI Chat Bar Vibrancy")
                        Spacer()
                        Text(
                            "\(Int(min(max(quickAICommandBarVibrancy, 0.05), 0.9) * 100))%"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { quickAICommandBarVibrancy },
                            set: { quickAICommandBarVibrancy = min(max($0, 0.05), 0.9) }
                        ),
                        in: 0.05...0.9
                    )
                    HStack {
                        Text("Subtle").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("Punchy").font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Background Image")
                    Spacer()
                    TextField("Path", text: $backgroundImagePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK {
                            backgroundImagePath = panel.url?.path ?? ""
                        }
                    }
                }
            }

            Section(header: Text("Gemini API")) {
                TextField("API Key", text: $geminiKey)
                    .textFieldStyle(.roundedBorder)
                Picker("Default Model", selection: $geminiModel) {
                    ForEach(geminiManager.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            Section(header: Text("System Prompt")) {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            Color.gray.opacity(0.2), lineWidth: 1))
                Text("Instructions for how the AI should behave.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Ollama")) {
                TextField("Endpoint URL", text: $ollamaURL)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading) {
                    Text("Custom Models").font(.headline)
                    HStack {
                        TextField("Add model (e.g. llama3:70b)", text: $newCustomModelName)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            ollamaManager.addCustomModel(newCustomModelName)
                            newCustomModelName = ""
                        }
                    }

                    List {
                        ForEach(ollamaManager.customModels, id: \.self) { model in
                            HStack {
                                Text(model)
                                Spacer()
                                Button(role: .destructive) {
                                    ollamaManager.removeCustomModel(model)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                    .frame(height: 100)
                }
            }

            Section(header: Text("Shortcuts")) {
                TextField("Private Cloud", text: $shortcutPrivateCloud)
                    .textFieldStyle(.roundedBorder)
                TextField("On-Device", text: $shortcutOnDevice)
                    .textFieldStyle(.roundedBorder)
                TextField("ChatGPT", text: $shortcutChatGPT)
                    .textFieldStyle(.roundedBorder)
                TextField("Image Gen", text: $shortcutImageGen)
                    .textFieldStyle(.roundedBorder)
                TextField("Image Gen (ChatGPT)", text: $shortcutImageGenChatGPT)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                Button(role: .destructive) {
                    chatManager.deleteAllSessions()
                } label: {
                    Text("Clear All Chat History")
                        .frame(maxWidth: .infinity)
                }
            }

            Section {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 50)
            }
            .listRowBackground(Color.clear)
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 600)
        .padding()
    }
}

// Helper
struct TypingIndicator: View {
    @State private var animate = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 52, height: 22)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [
                            .blue.opacity(0.5), .cyan.opacity(0.5), .green.opacity(0.5),
                            .cyan.opacity(0.5),
                            .blue.opacity(0.5), .cyan.opacity(0.5), .green.opacity(0.5),
                            .cyan.opacity(0.5),
                            .blue.opacity(0.5),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: animate ? -geo.size.width : 0)
                }
                .mask(Capsule())
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .green.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    animate = true
                }
            }
    }
}

struct WelcomeView: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 30) {
                Image(systemName: "sparkles")
                    .font(.system(size: 80))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .green], startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                    )
                    .shadow(radius: 10)

                VStack(spacing: 10) {
                    Text("Welcome to Prism")
                        .font(.system(size: 40, weight: .bold))

                    Text("Your All-in-One AI Assistant")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }

                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 200, height: 50)
                        .background(Color.blue)
                        .cornerRadius(25)
                }
                .buttonStyle(.plain)
            }
            .padding(50)
            .background(.ultraThinMaterial)
            .cornerRadius(30)
            .shadow(radius: 20)
        }
    }
}

struct SplashScreen: View {
    var onFinish: () -> Void
    @State private var stage: Int = 0
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let mainColor = colorScheme == .dark ? Color.white : Color.black

        ZStack {
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()

            // Prism Animation Container
            ZStack {
                // 1. Light Beam (enters from left)
                // We use a fixed frame container to anchor the growth to the leading edge (Source side),
                // so it appears to travel towards the prism (Trailing side).
                // Offset places the container: Width 150, Center -95 => Right Edge at -20 (hitting prism).
                Color.clear
                    .frame(width: 150, height: 2)
                    .overlay(
                        Rectangle()
                            .fill(mainColor)
                            .frame(width: stage >= 1 ? 150 : 0)  // Animates 0 -> 150
                        , alignment: .leading  // Anchored at Source (Left)
                    )
                    .offset(x: -95, y: -2)
                    .rotationEffect(.degrees(15), anchor: .trailing)  // Rotate around the Prism impact point
                    .opacity(stage >= 1 ? 0.9 : 0)
                    .blur(radius: 4)

                // 2. The Prism (Triangle)
                Triangle()
                    .stroke(
                        LinearGradient(
                            colors: [mainColor.opacity(0.8), mainColor.opacity(0.2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
                    )
                    .background(Triangle().fill(mainColor.opacity(0.05)))
                    .frame(width: 80, height: 80)
                    .shadow(color: mainColor.opacity(0.3), radius: 10)
                    .overlay(
                        // Shine effect on prism
                        Triangle()
                            .stroke(mainColor.opacity(stage >= 1 ? 0.8 : 0), lineWidth: 2)
                            .blur(radius: 2)
                    )

                // 3. Refracted Light (Rainbow out to right)
                // Removed the "if stage >= 2" check so the views exist in the hierarchy.
                // This ensures the width animation (0 -> 150) plays smoothly when stage changes to 2.
                ZStack {
                    ForEach(0..<7) { i in
                        Color.clear
                            .frame(width: 150, height: 3, alignment: .leading)
                            .overlay(
                                Rectangle()
                                    .fill(rainbowColor(i))
                                    .frame(width: stage >= 2 ? 150 : 0), alignment: .leading
                            )
                            .offset(x: 95, y: 0)
                            .rotationEffect(
                                .degrees(Double(i) * 6.0 - 18.0), anchor: .leading
                            )
                            .opacity(0.8)
                            .blur(radius: 6)
                    }
                }

                if stage >= 2 {
                    Text("Prism")
                        .font(.system(size: 40, weight: .light, design: .serif))
                        .foregroundStyle(mainColor.opacity(0.9))
                        .offset(y: 100)
                        .transition(.opacity.animation(.easeIn(duration: 1.0)))
                }
            }
            .scaleEffect(stage == 3 ? 1.05 : 1.0)  // Gentle scale out
            .opacity(stage == 3 ? 0 : 1)
        }
        .onAppear {
            // Animate beam in
            withAnimation(.easeOut(duration: 0.8)) {
                stage = 1
            }

            // Animate rainbow out (starts after beam hits prism)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 1.2)) {
                    stage = 2
                }
            }

            // Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                withAnimation(.easeInOut(duration: 1.5)) {
                    stage = 3
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) {
                onFinish()
            }
        }
    }

    func rainbowColor(_ i: Int) -> Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .indigo, .purple]
        return colors[i % colors.count]
    }
}

struct QuickChatView: View {
    @ObservedObject var chatManager = ChatManager.shared
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var imageCreationStyle: String = "Animation"
    @AppStorage("selectedProvider") private var selectedProvider: String = "Apple Foundation Model"
    @State private var thinkingLevel: String = "medium"
    @State private var streamBuffer: [UUID: String] = [:]  // live text per message
    @State private var streamThinkingBuffer: [UUID: String] = [:]  // live reasoning per message
    @Environment(\.colorScheme) private var colorScheme

    // Settings (Read-only access to keys)
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("OllamaModel") private var ollamaModel: String = "llama3"
    @AppStorage("OllamaModel2") private var ollamaModel2: String = "gpt-oss:20b-cloud"
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"
    @AppStorage("ShortcutOnDevice") private var shortcutOnDevice: String = "Ask AI Device"
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String =
        "Generate Image ChatGPT"
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @AppStorage("BackgroundImagePath") private var backgroundImagePath: String = ""
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @State private var showSplash: Bool = !AppState.shared.hasShownSplash
    @State private var currentTask: Task<Void, Never>?
    @State private var showImageGallery: Bool = false

    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let shortcutService = ShortcutService()
    private let appleFoundationService = AppleFoundationService()

    var thinkingMode: ThinkingMode {
        if selectedProvider.contains("Ollama") {
            let lower = selectedOllamaModel.lowercased()
            if lower.contains("gpt-oss") {
                return .threeState  // Low, Med, High
            } else if lower.contains("deepseek") {
                return .binary  // On/Off
            }
        }
        return .none
    }

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        return ZStack {
            LinearGradient(
                colors: [
                    startColor.opacity(0.42),
                    endColor.opacity(0.26),
                    Color(nsColor: .windowBackgroundColor).opacity(0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.02))
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 10)

            VStack(spacing: 12) {
                headerBar
                messagesSection
                inputBar
            }
            .padding(12)
        }
        .frame(width: 360, height: 520)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Apple Intelligence") {
                    Button(action: { selectedProvider = "Apple Foundation" }) {
                        Label("Apple Foundation", systemImage: "apple.logo")
                    }
                }
                Section("API") {
                    Button(action: { selectedProvider = "Gemini API" }) {
                        Label("Gemini API", systemImage: "sparkles")
                    }
                    Button(action: { selectedProvider = "Ollama" }) {
                        Label("Ollama", systemImage: "laptopcomputer")
                    }
                    Button(action: { selectedProvider = "On-Device" }) {
                        Label("On-Device", systemImage: "iphone")
                    }
                    Button(action: { selectedProvider = "ChatGPT" }) {
                        Label("ChatGPT", systemImage: "message")
                    }
                }
                Section("Tools") {
                    Button(action: { selectedProvider = "Image Creation" }) {
                        Label("Image Creation", systemImage: "paintbrush")
                    }
                }
            } label: {
                HStack {
                    Image(systemName: getProviderIcon(selectedProvider))
                    Text(selectedProvider)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.1)],
                                startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 160)
            .focusEffectDisabled()
            .focusable(false)

            Spacer(minLength: 0)

            Button(action: {
                chatManager.createNewSession()
            }) {
                Label("New", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(8)
                    .background(
                        LinearGradient(
                            colors: [primaryColor.opacity(0.22), secondaryColor.opacity(0.2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .focusable(false)
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .background(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var messagesSection: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chatManager.getCurrentMessages()) { message in
                        MessageView(
                            message: message,
                            liveContent: streamBuffer[message.id],
                            liveThinking: streamThinkingBuffer[message.id],
                            maxBubbleWidth: 300
                        )
                    }
                }
                .padding()
                .padding(.bottom, 14)
            }
            .padding(.bottom, 14)
            .onChange(of: chatManager.getCurrentMessages().count) { _, _ in
                if let lastId = chatManager.getCurrentMessages().last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField(
                selectedProvider == "Image Creation" ? "Describe an image..." : "Ask anything...",
                text: $inputText, axis: .vertical
            )
            .textFieldStyle(.plain)
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .lineLimit(1...6)
            .onSubmit(sendMessage)
            .padding(.vertical, 10)

            if selectedProvider == "Image Creation" {
                // Style Picker
                Menu {
                    Section("Apple Intelligence") {
                        Button(action: { imageCreationStyle = "Animation" }) {
                            if imageCreationStyle == "Animation" {
                                Label("Animation", systemImage: "checkmark")
                            } else {
                                Text("Animation")
                            }
                        }
                        Button(action: { imageCreationStyle = "Illustration" }) {
                            if imageCreationStyle == "Illustration" {
                                Label("Illustration", systemImage: "checkmark")
                            } else {
                                Text("Illustration")
                            }
                        }
                        Button(action: { imageCreationStyle = "Sketch" }) {
                            if imageCreationStyle == "Sketch" {
                                Label("Sketch", systemImage: "checkmark")
                            } else {
                                Text("Sketch")
                            }
                        }
                    }
                    Divider()
                    Section("ChatGPT") {
                        Button(action: { imageCreationStyle = "ChatGPT" }) {
                            if imageCreationStyle == "ChatGPT" {
                                Label("ChatGPT (Default)", systemImage: "checkmark")
                            } else {
                                Text("ChatGPT (Default)")
                            }
                        }
                        Button(action: { imageCreationStyle = "Oil Painting (ChatGPT)" }) {
                            if imageCreationStyle == "Oil Painting (ChatGPT)" {
                                Label("Oil Painting", systemImage: "checkmark")
                            } else {
                                Text("Oil Painting")
                            }
                        }
                        Button(action: { imageCreationStyle = "Watercolor (ChatGPT)" }) {
                            if imageCreationStyle == "Watercolor (ChatGPT)" {
                                Label("Watercolor", systemImage: "checkmark")
                            } else {
                                Text("Watercolor")
                            }
                        }
                        Button(action: { imageCreationStyle = "Vector (ChatGPT)" }) {
                            if imageCreationStyle == "Vector (ChatGPT)" {
                                Label("Vector", systemImage: "checkmark")
                            } else {
                                Text("Vector")
                            }
                        }
                        Button(action: { imageCreationStyle = "Anime (ChatGPT)" }) {
                            if imageCreationStyle == "Anime (ChatGPT)" {
                                Label("Anime", systemImage: "checkmark")
                            } else {
                                Text("Anime")
                            }
                        }
                        Button(action: { imageCreationStyle = "Print (ChatGPT)" }) {
                            if imageCreationStyle == "Print (ChatGPT)" {
                                Label("Print", systemImage: "checkmark")
                            } else {
                                Text("Print")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 16))
                        .foregroundColor(imageCreationStyle.isEmpty ? .secondary : .orange)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Image Style")
            }

            if selectedProvider.contains("Ollama") {
                Menu {
                    Section("Favorites") {
                        ForEach(ollamaManager.favoriteModels, id: \.self) { model in
                            Button(action: { selectedOllamaModel = model }) {
                                if selectedOllamaModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }

                    Section("All Models") {
                        ForEach(
                            ollamaManager.availableModels.filter { !ollamaManager.isFavorite($0) },
                            id: \.self
                        ) { model in
                            Button(action: { selectedOllamaModel = model }) {
                                if selectedOllamaModel == model {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }

                    Divider()

                    Menu("Manage Favorites") {
                        ForEach(ollamaManager.availableModels, id: \.self) { model in
                            Button(action: { ollamaManager.toggleFavorite(model) }) {
                                if ollamaManager.isFavorite(model) {
                                    Label(model, systemImage: "star.fill")
                                } else {
                                    Label(model, systemImage: "star")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Select Ollama Model")
            }

            if thinkingMode != .none {
                Menu {
                    if thinkingMode == .binary {
                        Button {
                            thinkingLevel = "high"
                        } label: {
                            if thinkingLevel == "high" {
                                Label("Reasoning: On", systemImage: "checkmark")
                            } else {
                                Text("Reasoning: On")
                            }
                        }
                        Button {
                            thinkingLevel = "low"
                        } label: {
                            if thinkingLevel != "high" {
                                Label("Reasoning: Off", systemImage: "checkmark")
                            } else {
                                Text("Reasoning: Off")
                            }
                        }
                    } else {
                        Button {
                            thinkingLevel = "low"
                        } label: {
                            if thinkingLevel == "low" {
                                Label("Low", systemImage: "checkmark")
                            } else {
                                Text("Low")
                            }
                        }
                        Button {
                            thinkingLevel = "medium"
                        } label: {
                            if thinkingLevel == "medium" {
                                Label("Medium", systemImage: "checkmark")
                            } else {
                                Text("Medium")
                            }
                        }
                        Button {
                            thinkingLevel = "high"
                        } label: {
                            if thinkingLevel == "high" {
                                Label("High", systemImage: "checkmark")
                            } else {
                                Text("High")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 16))
                        .foregroundColor(
                            (thinkingLevel == "medium" && thinkingMode == .threeState)
                                || (thinkingLevel == "low" && thinkingMode == .binary)
                                ? .secondary : .primary
                        )
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Reasoning Effort")
            }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.primary)
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty || isLoading)
            .opacity(inputText.isEmpty || isLoading ? 0.5 : 1.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .background(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.12)],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
    }

    private var primaryColor: Color {
        if let color = derivePrimaryColor(from: backgroundImagePath) {
            return color
        }
        return Color.accentColor
    }

    private var secondaryColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private func derivePrimaryColor(from path: String) -> Color? {
        guard !path.isEmpty, let image = NSImage(contentsOfFile: path) else { return nil }
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }

        let width = max(1, min(40, bitmap.pixelsWide))
        let height = max(1, min(40, bitmap.pixelsHigh))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0

        for x in 0..<width {
            for y in 0..<height {
                let color = bitmap.colorAt(x: x, y: y) ?? .clear
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
            }
        }

        let count = CGFloat(width * height)
        return Color(
            red: red / count,
            green: green / count,
            blue: blue / count
        )
    }

    private func getProviderIcon(_ provider: String) -> String {
        switch provider {
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
        case "Image Creation": return "paintbrush"  // Fixed icon name
        case "ChatGPT": return "message"
        default: return "cpu"
        }
    }

    func sendMessage() {
        guard !inputText.isEmpty else { return }
        guard !isLoading else { return }
        let content = inputText
        inputText = ""

        let userMsg = Message(content: content, image: nil, isUser: true)
        chatManager.addMessage(userMsg)
        isLoading = true

        chatManager.currentTask = Task {
            if selectedProvider == "Apple Foundation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", model: "Apple Foundation", isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    var fullContent = ""
                    var lastUpdateTime = Date()

                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: chatManager.getCurrentMessages(),
                        systemPrompt: systemPrompt
                    ) {
                        fullContent += chunk

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentToUpdate = fullContent
                            DispatchQueue.main.async {
                                self.chatManager.updateMessage(
                                    id: aiMsgId, content: contentToUpdate, isStreaming: true)
                            }
                            lastUpdateTime = Date()
                        }
                    }

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: fullContent, isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Gemini API" {
                if !geminiKey.isEmpty {
                    let aiMsgId = UUID()
                    var aiMsg = Message(content: "", model: geminiModel, isUser: false)
                    aiMsg.id = aiMsgId
                    aiMsg.isStreaming = true

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk)
                            in geminiService.sendMessageStream(
                                history: chatManager.getCurrentMessages(), apiKey: geminiKey,
                                model: geminiModel, systemPrompt: systemPrompt, thinkingLevel: "low"
                            )
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentToUpdate = fullContent
                                let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.chatManager.updateMessage(
                                        id: aiMsgId, content: contentToUpdate,
                                        thinkingContent: thinkingToUpdate, isStreaming: true)
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: fullContent,
                                thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: "Error: \(error.localizedDescription)",
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Please set your API Key in the main app.", isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Ollama" {
                let aiMsgId = UUID()
                let activeModel = selectedOllamaModel
                var aiMsg = Message(content: "", model: activeModel, isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                    self.streamBuffer[aiMsgId] = ""
                    self.streamThinkingBuffer[aiMsgId] = ""
                }

                do {
                    var fullContent = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()

                    for try await (contentChunk, thinkingChunk) in ollamaService.sendMessageStream(
                        history: chatManager.getCurrentMessages(), endpoint: ollamaURL,
                        model: activeModel, systemPrompt: systemPrompt, thinkingLevel: thinkingLevel
                    ) {
                        fullContent += contentChunk
                        if let thinking = thinkingChunk {
                            fullThinking += thinking
                        }

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentSnapshot = fullContent
                            let thinkingSnapshot = fullThinking
                            DispatchQueue.main.async {
                                self.streamBuffer[aiMsgId] = contentSnapshot
                                if thinkingSnapshot.isEmpty {
                                    self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                                } else {
                                    self.streamThinkingBuffer[aiMsgId] = thinkingSnapshot
                                }
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: fullContent,
                            thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Image Creation" {
                let aiMsgId = UUID()
                var aiMsg = Message(content: "", isUser: false)
                aiMsg.isGeneratingImage = true
                aiMsg.id = aiMsgId

                // Capture current style
                let style = imageCreationStyle

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                }

                do {
                    // Only plain "ChatGPT" (no styles) uses the specialized ChatGPT shortcut
                    let targetShortcut =
                        (style == "ChatGPT") ? shortcutImageGenChatGPT : shortcutImageGen

                    let result = try await shortcutService.runShortcut(
                        name: targetShortcut, input: content, style: style, image: nil)

                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: result.0, image: result.1,
                            isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isGeneratingImage: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else {
                // Shortcuts
                let shortcutName: String
                let displayModelName: String
                switch selectedProvider {
                case "Private Cloud":
                    shortcutName = shortcutPrivateCloud
                    displayModelName = "Private Cloud Compute"
                case "On-Device":
                    shortcutName = shortcutOnDevice
                    displayModelName = "On-Device"
                case "ChatGPT":
                    shortcutName = shortcutChatGPT
                    displayModelName = "ChatGPT"
                default:
                    shortcutName = shortcutPrivateCloud
                    displayModelName = "Private Cloud Compute"
                }

                // Build transcript
                var transcript = "Please reply to the last message:\n\n"
                for msg in chatManager.getCurrentMessages().suffix(5) {
                    let role = msg.isUser ? "User" : "Assistant"
                    transcript += "\(role): \(msg.content)\n"
                }
                transcript += "Assistant:"

                do {
                    let result = try await shortcutService.runShortcut(
                        name: shortcutName, input: transcript, image: nil)
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: result.0, model: displayModelName, image: nil, isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        let aiMsg = Message(
                            content: "Error: \(error.localizedDescription)",
                            model: displayModelName,
                            isUser: false)
                        self.chatManager.addMessage(aiMsg)
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct ImageGalleryView: View {
    @ObservedObject var chatManager: ChatManager
    @Binding var showImageGallery: Bool
    @State private var selectedImageForPreview: NSImage? = nil

    var images: [(UUID, UUID, NSImage, String)] {
        var result: [(UUID, UUID, NSImage, String)] = []
        for session in chatManager.sessions {
            for message in session.messages {
                if let image = message.image {
                    result.append((session.id, message.id, image, message.content))
                }
            }
        }
        return result
    }

    let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)
    ]

    var body: some View {
        ZStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(images, id: \.1) { item in
                        ZStack {
                            Image(nsImage: item.2)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .cornerRadius(8)
                                .shadow(radius: 2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(16)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedImageForPreview = item.2
                            }
                        }
                        .contextMenu {
                            Button("Go to chat") {
                                showImageGallery = false
                                chatManager.currentSessionId = item.0
                            }
                            Button("Copy") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.writeObjects([item.2])
                            }
                            if #available(macOS 13.0, *) {
                                ShareLink(
                                    item: Image(nsImage: item.2),
                                    preview: SharePreview(item.3, image: Image(nsImage: item.2)))
                            } else {
                                Button("Share") {
                                    let picker = NSSharingServicePicker(items: [item.2])
                                    if let view = NSApp.keyWindow?.contentView {
                                        picker.show(
                                            relativeTo: .zero, of: view, preferredEdge: .minY)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Images")
            .blur(radius: selectedImageForPreview != nil ? 15 : 0)

            if let image = selectedImageForPreview {
                ZStack {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedImageForPreview = nil
                            }
                        }

                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(40)
                        .shadow(radius: 20)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedImageForPreview = nil
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                .zIndex(100)
            }
        }
    }
}
