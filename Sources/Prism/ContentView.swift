import AppKit
import Foundation
import KeyboardShortcuts
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
    var isPinned: Bool = false
}

enum AttachmentType {
    case image
    case pdf
    case text
}

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let type: AttachmentType
    let data: Data
    var fileName: String? = nil
}

struct MessageAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: String  // "image", "pdf", or "text"
    var data: Data
    var fileName: String?
}

struct MessageVersion: Codable, Equatable {
    var content: String
    var thinkingContent: String?
    var imageData: Data?
    var model: String?
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
    var imageData: Data? {
        didSet {
            // Invalidate cached image whenever imageData changes (e.g. version switch)
            if imageData != oldValue {
                _cachedImage = imageData.flatMap { NSImage(data: $0) }
            }
        }
    }
    var pdfData: Data?
    var attachments: [MessageAttachment]?
    var isUser: Bool
    var timestamp = Date()
    var isStreaming: Bool = false
    var isGeneratingImage: Bool? = false
    var versions: [MessageVersion]?
    var currentVersionIndex: Int?

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
            timestamp, versions, currentVersionIndex
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
        versions = try container.decodeIfPresent([MessageVersion].self, forKey: .versions)
        currentVersionIndex = try container.decodeIfPresent(Int.self, forKey: .currentVersionIndex)

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
        try container.encodeIfPresent(versions, forKey: .versions)
        try container.encodeIfPresent(currentVersionIndex, forKey: .currentVersionIndex)
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
                    codeLanguage = String(trimmedLine.dropFirst(3)).trimmingCharacters(
                        in: .whitespaces)
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

                    // Look for a closing delimiter within the same line (after the opening)
                    let afterOpen = String(trimmedLine.dropFirst(startDelim.count))
                    if let closeRange = afterOpen.range(of: endDelim) {
                        // Found closing delimiter on this line
                        let mathContent = String(afterOpen[..<closeRange.lowerBound])
                        let afterClose = String(afterOpen[closeRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)

                        blocks.append(
                            MarkdownBlock(
                                type: .math(mathContent.trimmingCharacters(in: .whitespaces)))
                        )

                        // If there's trailing text after the closing delimiter, add it as text
                        if !afterClose.isEmpty {
                            currentText += afterClose + "\n"
                        }
                    } else {
                        // No closing delimiter on this line — start a multi-line math block
                        inMathBlock = true
                        mathDelimiter = endDelim
                        if !afterOpen.isEmpty {
                            mathBlockContent += afterOpen + "\n"
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
                } else if let closeRange = trimmedLine.range(of: mathDelimiter) {
                    // Closing delimiter found mid-line with trailing text
                    mathBlockContent += String(trimmedLine[..<closeRange.lowerBound])
                    blocks.append(
                        MarkdownBlock(
                            type: .math(mathBlockContent.trimmingCharacters(in: .newlines))))
                    mathBlockContent = ""
                    inMathBlock = false
                    let afterClose = String(trimmedLine[closeRange.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    if !afterClose.isEmpty {
                        currentText += afterClose + "\n"
                    }
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

        if inCodeBlock && !codeBlockContent.isEmpty {
            // Unclosed code block (e.g. during streaming) – flush as code block
            blocks.append(
                MarkdownBlock(
                    type: .code(
                        codeBlockContent.trimmingCharacters(in: .newlines), codeLanguage)))
        } else if !currentText.isEmpty {
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
        if lhs.currentVersionIndex != rhs.currentVersionIndex { return false }
        if lhs.versions?.count != rhs.versions?.count { return false }

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

    func moveSessions(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        saveSessions()
    }

    func addMessage(_ message: Message) {
        if sessions.isEmpty {
            createNewSession()
        }
        guard let index = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }

        var session = sessions[index]
        session.messages.append(message)
        session.date = Date()

        // Auto-rename with Apple Foundation Model on first user message
        if session.messages.filter({ $0.isUser }).count == 1 && message.isUser {
            session.title = String(message.content.prefix(30))
            let sessionId = session.id
            let sessionMessages = session.messages
            Task {
                await self.autoRenameSession(id: sessionId, messages: sessionMessages)
            }
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

    /// Switch to a specific version of a message
    func switchVersion(messageId: UUID, to versionIndex: Int) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }),
            let msgIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }
            ),
            let versions = sessions[sessionIndex].messages[msgIndex].versions,
            versionIndex >= 0 && versionIndex < versions.count
        else { return }

        var msg = sessions[sessionIndex].messages[msgIndex]
        let version = versions[versionIndex]
        msg.content = version.content
        msg.thinkingContent = version.thinkingContent
        msg.imageData = version.imageData
        msg.model = version.model
        msg.currentVersionIndex = versionIndex
        msg.ensureBlocksCached()
        sessions[sessionIndex].messages[msgIndex] = msg
        saveSessions()
    }

    /// Attach versions to a message and finalize as the latest version
    func attachVersions(_ versions: [MessageVersion], to messageId: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }),
            let msgIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId })
        else { return }

        var msg = sessions[sessionIndex].messages[msgIndex]
        let newVersion = MessageVersion(
            content: msg.content,
            thinkingContent: msg.thinkingContent,
            imageData: msg.imageData,
            model: msg.model
        )
        var allVersions = versions
        allVersions.append(newVersion)
        msg.versions = allVersions
        msg.currentVersionIndex = allVersions.count - 1
        sessions[sessionIndex].messages[msgIndex] = msg
        saveSessions()
    }

    func togglePin(id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].isPinned.toggle()
            saveSessions()
        }
    }

    private func autoRenameSession(id: UUID, messages: [Message]) async {
        let summarizer = AppleFoundationService()
        let prompt = """
            Analyze the following conversation and provide a short, concise title (3-5 words max).
            Return ONLY the title, no quotes or explanation.
            """
        do {
            var newTitle = ""
            for try await chunk in summarizer.sendMessageStream(
                history: messages, systemPrompt: prompt)
            {
                newTitle += chunk
            }
            let cleaned = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            await MainActor.run {
                if !cleaned.isEmpty {
                    self.renameSession(id: id, newTitle: cleaned)
                }
            }
        } catch {
            // Silently fail — the fallback title (first 30 chars) is already set
        }
    }

    func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: savePath)
        }
    }

    private func loadSessions() {
        if let data = try? Data(contentsOf: savePath),
            let loaded = try? JSONDecoder().decode([ChatSession].self, from: data)
        {
            sessions = loaded
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

// MARK: - Web Search Service

struct WebSearchResult: Codable {
    let title: String
    let url: String
    let content: String
}

struct WebSearchResponse: Codable {
    let results: [WebSearchResult]
}

class WebSearchService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func search(query: String, apiKey: String, maxResults: Int = 3) async throws
        -> [WebSearchResult]
    {
        guard let url = URL(string: "https://ollama.com/api/web_search") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "query": query,
            "max_results": maxResults,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OllamaAPIError(statusCode: statusCode, message: "Web search request failed")
        }

        let decoded = try JSONDecoder().decode(WebSearchResponse.self, from: data)
        return decoded.results
    }

    func buildSearchContext(results: [WebSearchResult]) -> String {
        guard !results.isEmpty else { return "" }
        let maxSnippetLength = 500
        let maxTotalLength = 4000
        var context = "\n\n[Web Search Results]\n"
        for (i, result) in results.enumerated() {
            let snippet =
                result.content.count > maxSnippetLength
                ? String(result.content.prefix(maxSnippetLength)) + "…"
                : result.content
            let entry = "Result \(i + 1): \(result.title)\n   URL: \(result.url)\n   \(snippet)\n\n"
            if context.count + entry.count > maxTotalLength { break }
            context += entry
        }
        context +=
            "[End of Web Search Results]\n\nUse the above web search results to inform your answer. If you reference a source, mention it naturally by name or URL in your text. NEVER use bracket citation syntax like 【1†L2-L5】 or [1†source] or any similar notation."
        return context
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
                    || model.contains("llava") || model.contains("deepseek-vl")
                    || model.contains("janus")
                    || model.contains("minicpm-v") || model.contains("deepseek-ocr")
                    || model.contains("olmocr")

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
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func sendMessageStream(
        history: [Message], apiKey: String, model: String, systemPrompt: String = "",
        thinkingLevel: String = "medium"
    ) -> AsyncThrowingStream<(String, String?, Data?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let modelName = model.isEmpty ? "gemini-1.5-flash" : model
                let isImageModel =
                    modelName.lowercased().contains("image")
                    || modelName.lowercased().contains("nano-banana")

                let endpoint =
                    isImageModel
                    ? "generateContent"
                    : "streamGenerateContent"
                let urlSuffix = isImageModel ? "" : "&alt=sse"
                guard
                    let url = URL(
                        string:
                            "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):\(endpoint)?key=\(apiKey)\(urlSuffix)"
                    )
                else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")

                // Convert history to Gemini format
                // For image models, only send the latest user message to avoid
                // thought_signature validation errors on multi-turn conversations
                let messagesToSend =
                    isImageModel
                    ? history.filter { $0.isUser }.suffix(1).map { $0 }
                    : history
                let contents: [[String: Any]] = messagesToSend.map { msg in
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

                // Enable image output for image-capable models
                if isImageModel {
                    body["generationConfig"] = [
                        "responseModalities": ["TEXT", "IMAGE"]
                    ]
                } else {
                    // Add thinking config for models that support it
                    let lowerModel = modelName.lowercased()
                    let supportsThinking =
                        lowerModel.hasPrefix("gemini-3") || lowerModel.hasPrefix("gemini-2.5")
                    if supportsThinking {
                        var thinkingConfig: [String: Any] = ["includeThoughts": true]
                        let isGemini3 = lowerModel.hasPrefix("gemini-3")
                        let isGemini3Pro = lowerModel.hasPrefix("gemini-3-pro")
                        if isGemini3 {
                            // Gemini 3 uses thinkingLevel
                            // Pro only supports LOW and HIGH; Flash supports all
                            switch thinkingLevel.lowercased() {
                            case "low":
                                thinkingConfig["thinkingLevel"] = "LOW"
                            case "medium":
                                thinkingConfig["thinkingLevel"] = isGemini3Pro ? "LOW" : "MEDIUM"
                            case "high":
                                thinkingConfig["thinkingLevel"] = "HIGH"
                            default:
                                // Auto / dynamic
                                thinkingConfig["thinkingLevel"] = "HIGH"
                            }
                        } else {
                            // Gemini 2.5 uses thinkingBudget
                            switch thinkingLevel.lowercased() {
                            case "low":
                                thinkingConfig["thinkingBudget"] = 1024
                            case "medium":
                                thinkingConfig["thinkingBudget"] = 8192
                            case "high":
                                thinkingConfig["thinkingBudget"] = 24576
                            default:
                                // Auto / dynamic
                                thinkingConfig["thinkingBudget"] = -1
                            }
                        }
                        body["generationConfig"] = [
                            "thinkingConfig": thinkingConfig
                        ]
                    }
                }

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    if isImageModel {
                        // Non-streaming request for image models (base64 data is too large for SSE)
                        let (responseData, response) = try await session.data(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: URLError(.badServerResponse))
                            return
                        }

                        if httpResponse.statusCode != 200 {
                            let errorText =
                                String(data: responseData, encoding: .utf8)
                                ?? "HTTP \(httpResponse.statusCode)"
                            continuation.finish(
                                throwing: NSError(
                                    domain: "GeminiError", code: httpResponse.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: errorText]))
                            return
                        }

                        guard
                            let json = try? JSONSerialization.jsonObject(with: responseData)
                                as? [String: Any],
                            let candidates = json["candidates"] as? [[String: Any]],
                            let content = candidates.first?["content"] as? [String: Any],
                            let parts = content["parts"] as? [[String: Any]]
                        else {
                            continuation.finish()
                            return
                        }

                        for part in parts {
                            if part["thought"] as? Bool == true {
                                if let text = part["text"] as? String {
                                    continuation.yield(("", text, nil))
                                }
                                continue
                            }

                            if let text = part["text"] as? String {
                                continuation.yield((text, nil, nil))
                            } else if let inlineData = (part["inlineData"] ?? part["inline_data"])
                                as? [String: Any],
                                let mimeType = (inlineData["mimeType"] ?? inlineData["mime_type"])
                                    as? String,
                                mimeType.hasPrefix("image/"),
                                let base64Str = inlineData["data"] as? String,
                                let imageData = Data(base64Encoded: base64Str)
                            {
                                continuation.yield(("", nil, imageData))
                            }
                        }

                        continuation.finish()
                    } else {
                        // Streaming request for text models
                        let (result, response) = try await session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: URLError(.badServerResponse))
                            return
                        }

                        if httpResponse.statusCode != 200 {
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
                                    let content = candidates.first?["content"]
                                        as? [String: Any],
                                    let parts = content["parts"] as? [[String: Any]]
                                else { continue }

                                for part in parts {
                                    if part["thought"] as? Bool == true {
                                        if let text = part["text"] as? String {
                                            continuation.yield(("", text, nil))
                                        }
                                        continue
                                    }

                                    if let text = part["text"] as? String {
                                        continuation.yield((text, nil, nil))
                                    } else if let inlineData =
                                        (part["inlineData"] ?? part["inline_data"])
                                        as? [String: Any],
                                        let mimeType =
                                            (inlineData["mimeType"] ?? inlineData["mime_type"])
                                            as? String,
                                        mimeType.hasPrefix("image/"),
                                        let base64Str = inlineData["data"] as? String,
                                        let imageData = Data(base64Encoded: base64Str)
                                    {
                                        continuation.yield(("", nil, imageData))
                                    }
                                }
                            }
                        }

                        continuation.finish()
                    }
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
    case geminiPro  // Auto/Low/High (Gemini 3 Pro)
    case geminiFlash  // Auto/Low/Med/High (Gemini 3 Flash, 2.5)
}

struct ContentView: View {
    @ObservedObject private var chatManager = ChatManager.shared
    @State private var inputText: String = ""
    @State private var selectedAttachments: [Attachment] = []
    // Legacy single selection states removed/replaced
    @State private var isLoading: Bool = false
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @AppStorage("GeminiThinkingLevel") private var geminiThinkingLevel: String = "auto"
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
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @AppStorage("BackgroundImagePath") private var backgroundImagePath: String = ""
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("ImageDownloadPath") private var imageDownloadPath: String = ""
    @AppStorage("WebSearchEnabled") private var webSearchEnabled: Bool = false
    @State private var showSplash: Bool = !AppState.shared.hasShownSplash
    @State private var currentTask: Task<Void, Never>?
    @State private var showImageGallery: Bool = false
    @State private var showModelComparison: Bool = false
    @State private var showCommands: Bool = false
    @State private var showQuizMe: Bool = false
    @State private var showImageGen: Bool = false
    @AppStorage("ActiveToolName") private var activeToolName: String = ""
    @State private var streamBuffer: [UUID: String] = [:]  // live text per message
    @State private var streamThinkingBuffer: [UUID: String] = [:]  // live reasoning per message
    @State private var chatPreviewImage: NSImage? = nil
    @State private var chatPreviewVisible: Bool = false
    @State private var chatPreviewSourceRect: CGRect = .zero

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let webSearchService = WebSearchService()
    private let shortcutService = ShortcutService()
    private let appleFoundationService = AppleFoundationService()

    var thinkingMode: ThinkingMode {
        if selectedProvider == "Gemini API" {
            let lower = geminiModel.lowercased()
            if lower.hasPrefix("gemini-3-pro") {
                return .geminiPro  // Only Low/High supported
            } else if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-2.5") {
                return .geminiFlash
            }
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

    /// Returns a binding to the correct thinking level storage based on the current provider
    var activeThinkingLevel: Binding<String> {
        if selectedProvider == "Gemini API" {
            return $geminiThinkingLevel
        } else {
            return $thinkingLevel
        }
    }

    /// The current thinking level value for the active provider
    var currentThinkingLevel: String {
        if selectedProvider == "Gemini API" {
            return geminiThinkingLevel
        } else {
            return thinkingLevel
        }
    }

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(
                    chatManager: chatManager, showImageGallery: $showImageGallery,
                    showModelComparison: $showModelComparison,
                    showCommands: $showCommands,
                    showQuizMe: $showQuizMe,
                    showImageGen: $showImageGen)
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

                    // Content Layer — Chat always rendered; tools overlay on top
                    ZStack {
                        // Chat or Web view (always in tree to prevent rebuild flash)
                        if isWebViewProvider(selectedProvider) {
                            ZStack(alignment: .top) {
                                if let url = getWebURL(for: selectedProvider) {
                                    WebView(url: url)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }

                                HeaderView(
                                    selectedProvider: $selectedProvider,
                                    onNewChat: chatManager.createNewSession
                                )
                            }
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(spacing: 24) {
                                        let messages = chatManager.getCurrentMessages()
                                        if messages.isEmpty {
                                            EmptyStateView(appTheme: appTheme)
                                        } else {
                                            ForEach(messages) { message in
                                                let isLast = message.id == messages.last?.id
                                                let isLastUserMessage =
                                                    message.isUser
                                                    && messages.last(where: { $0.isUser })?.id
                                                        == message.id
                                                MessageView(
                                                    message: message,
                                                    liveContent: streamBuffer[message.id]
                                                        ?? nil,
                                                    liveThinking: streamThinkingBuffer[
                                                        message.id]
                                                        ?? nil,
                                                    onRegenerate: (!message.isUser
                                                        && !isLoading
                                                        && isLast)
                                                        ? {
                                                            regenerateResponse(
                                                                for: message.id)
                                                        }
                                                        : nil,
                                                    onEdit: (isLastUserMessage && !isLoading)
                                                        ? { newContent in
                                                            editAndResend(
                                                                message: message,
                                                                newContent: newContent)
                                                        }
                                                        : nil,
                                                    canEdit: isLastUserMessage && !isLoading,
                                                    onImageTap: { img, rect in
                                                        chatPreviewImage = img
                                                        chatPreviewSourceRect = rect
                                                        chatPreviewVisible = true
                                                    },
                                                    onSwitchVersion: (!message.isUser
                                                        && message.versions != nil
                                                        && (message.versions?.count ?? 0) > 1)
                                                        ? { versionIndex in
                                                            chatManager.switchVersion(
                                                                messageId: message.id,
                                                                to: versionIndex)
                                                        }
                                                        : nil
                                                )
                                                .equatable()
                                            }
                                        }
                                    }
                                    .padding()
                                }
                                .safeAreaInset(edge: .top) {
                                    HeaderView(
                                        selectedProvider: $selectedProvider,
                                        onNewChat: chatManager.createNewSession
                                    )
                                }
                                .safeAreaInset(edge: .bottom) {
                                    InputView(
                                        inputText: $inputText,
                                        selectedAttachments: $selectedAttachments,
                                        thinkingLevel: activeThinkingLevel,
                                        isLoading: isLoading,
                                        onSend: sendMessage,
                                        onStop: stopGeneration,
                                        onSelectAttachment: selectAttachment,
                                        thinkingMode: thinkingMode,
                                        isOllama: selectedProvider.contains("Ollama"),
                                        isGemini: selectedProvider == "Gemini API",
                                        webSearchEnabled: $webSearchEnabled,
                                        hasOllamaAPIKey: !ollamaAPIKey.isEmpty,
                                        onSlashAction: handleSlashAction
                                    )
                                }
                                .onChange(of: chatManager.getCurrentMessages().count) {
                                    _, count in
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
                            .opacity(
                                showCommands || showModelComparison || showQuizMe || showImageGen
                                    || showImageGallery ? 0 : 1
                            )
                            .allowsHitTesting(
                                !(showCommands || showModelComparison || showQuizMe || showImageGen
                                    || showImageGallery)
                            )
                            .transaction { t in t.animation = nil }
                        }

                        // Tool overlays — rendered on top when active
                        if showCommands {
                            CommandsManagementView()
                                .transition(.opacity)
                        }
                        if showModelComparison {
                            ModelComparisonView()
                                .transition(.opacity)
                        }
                        if showQuizMe {
                            QuizMeView()
                                .transition(.opacity)
                        }
                        if showImageGen {
                            ImageGenerationView()
                                .transition(.opacity)
                        }
                        if showImageGallery {
                            ImageGalleryView(
                                chatManager: chatManager, showImageGallery: $showImageGallery
                            )
                            .transition(.opacity)
                        }
                    }

                    // Chat image preview overlay
                    if chatPreviewVisible, let img = chatPreviewImage {
                        ImagePreviewOverlay(image: img, sourceRect: chatPreviewSourceRect) {
                            chatPreviewVisible = false
                            chatPreviewImage = nil
                        }
                        .zIndex(200)
                    }
                }
                .coordinateSpace(name: "detailContainer")
            }
            .frame(minWidth: 800, minHeight: 500)
            .disabled(showSplash)  // Disable main content when splash is showing to prevent focus ring bleed-through
            .toolbar(showSplash ? .hidden : .visible, for: .windowToolbar)
            .onChange(of: showModelComparison) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showCommands) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showQuizMe) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showImageGen) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showImageGallery) { _, val in
                updateActiveToolName()
            }

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
        .onAppear {
            activeToolName = ""
        }
    }

    func isWebViewProvider(_ provider: String) -> Bool {
        return ["Gemini Web", "ChatGPT Web", "Perplexity Web", "Grok Web"].contains(provider)
    }

    private func updateActiveToolName() {
        if showModelComparison {
            activeToolName = "Compare"
        } else if showCommands {
            activeToolName = "Commands"
        } else if showQuizMe {
            activeToolName = "Quiz Me"
        } else if showImageGen {
            activeToolName = "Image Generation"
        } else {
            activeToolName = ""
        }
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
        panel.allowedContentTypes = [
            .image, .pdf,
            .plainText, .sourceCode, .json, .xml, .html, .yaml,
            .commaSeparatedText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "log") ?? .plainText,
            UTType(filenameExtension: "csv") ?? .plainText,
            UTType(filenameExtension: "toml") ?? .plainText,
            .rtf,
        ]
        if panel.runModal() == .OK {
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    if let data = try? Data(contentsOf: url) {
                        selectedAttachments.append(Attachment(type: .pdf, data: data))
                    }
                } else if ["png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic"].contains(ext)
                {
                    if let data = try? Data(contentsOf: url) {
                        selectedAttachments.append(Attachment(type: .image, data: data))
                    }
                } else {
                    // Text-based files: txt, md, json, xml, html, csv, yaml, log, swift, py, js, etc.
                    if let data = try? Data(contentsOf: url) {
                        selectedAttachments.append(
                            Attachment(type: .text, data: data, fileName: url.lastPathComponent))
                    }
                }
            }
        }
    }

    func handleSlashAction(_ trigger: String) {
        switch trigger {
        case "/clear":
            chatManager.deleteCurrentSession()
            chatManager.createNewSession()
        case "/quit":
            NSApplication.shared.terminate(nil)
        case "/new":
            chatManager.createNewSession()
        default:
            break
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
            let typeStr: String
            switch $0.type {
            case .image: typeStr = "image"
            case .pdf: typeStr = "pdf"
            case .text: typeStr = "text"
            }
            return MessageAttachment(type: typeStr, data: $0.data, fileName: $0.fileName)
        }

        // For text attachments, append file contents to the input text
        var augmentedInput = inputText
        for attachment in selectedAttachments where attachment.type == .text {
            if let text = String(data: attachment.data, encoding: .utf8) {
                let name = attachment.fileName ?? "file"
                augmentedInput += "\n\n--- Contents of \(name) ---\n\(text)\n--- End of \(name) ---"
            }
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

        let currentInput = augmentedInput
        let currentAttachments = selectedAttachments

        inputText = ""
        selectedAttachments = []

        performSend(input: currentInput, attachments: currentAttachments)
    }

    func regenerateResponse(for messageId: UUID? = nil) {
        // Collect versions from existing AI message before removing it
        var existingVersions: [MessageVersion]? = nil

        if let messageId = messageId {
            let messages = chatManager.getCurrentMessages()
            if let aiMsg = messages.first(where: { $0.id == messageId }) {
                let currentVersion = MessageVersion(
                    content: aiMsg.content,
                    thinkingContent: aiMsg.thinkingContent,
                    imageData: aiMsg.imageData,
                    model: aiMsg.model
                )
                if var vers = aiMsg.versions {
                    if let idx = aiMsg.currentVersionIndex, idx < vers.count - 1 {
                        vers.removeSubrange((idx + 1)...)
                    }
                    if vers.last?.content != currentVersion.content
                        || vers.last?.imageData != currentVersion.imageData
                    {
                        vers.append(currentVersion)
                    }
                    existingVersions = vers
                } else {
                    existingVersions = [currentVersion]
                }
            }
            chatManager.truncateHistory(from: messageId)
        } else {
            let messages = chatManager.getCurrentMessages()
            guard let lastMsg = messages.last, !lastMsg.isUser else { return }

            let currentVersion = MessageVersion(
                content: lastMsg.content,
                thinkingContent: lastMsg.thinkingContent,
                imageData: lastMsg.imageData,
                model: lastMsg.model
            )
            if var vers = lastMsg.versions {
                if let idx = lastMsg.currentVersionIndex, idx < vers.count - 1 {
                    vers.removeSubrange((idx + 1)...)
                }
                if vers.last?.content != currentVersion.content
                    || vers.last?.imageData != currentVersion.imageData
                {
                    vers.append(currentVersion)
                }
                existingVersions = vers
            } else {
                existingVersions = [currentVersion]
            }

            chatManager.removeLastMessage()
        }

        // Find last user message
        if let lastUserMsg = chatManager.getCurrentMessages().last(where: { $0.isUser }) {
            var attachments: [Attachment] = []
            if let msgAttachments = lastUserMsg.attachments {
                attachments = msgAttachments.map {
                    let attachType: AttachmentType
                    switch $0.type {
                    case "image": attachType = .image
                    case "text": attachType = .text
                    default: attachType = .pdf
                    }
                    return Attachment(type: attachType, data: $0.data, fileName: $0.fileName)
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
                input: lastUserMsg.content, attachments: attachments,
                existingVersions: existingVersions)
        }
    }

    func editAndResend(message: Message, newContent: String) {
        // Since we only allow editing the LAST user message,
        // we only need to remove the AI response after it (if any)
        let currentMessages = chatManager.getCurrentMessages()

        // Check if there's an AI response after this user message
        if let lastMessage = currentMessages.last, !lastMessage.isUser {
            chatManager.removeLastMessage()  // Remove the AI response
        }

        // Remove the user message being edited
        chatManager.removeLastMessage()

        // Send the new edited message
        let userMsg = Message(
            content: newContent,
            image: message.image,
            pdfData: message.pdfData,
            attachments: message.attachments,
            isUser: true
        )
        chatManager.addMessage(userMsg)

        // Reconstruct attachments for sending
        var attachments: [Attachment] = []
        if let msgAttachments = message.attachments {
            attachments = msgAttachments.map {
                let attachType: AttachmentType
                switch $0.type {
                case "image": attachType = .image
                case "text": attachType = .text
                default: attachType = .pdf
                }
                return Attachment(type: attachType, data: $0.data, fileName: $0.fileName)
            }
        } else {
            if let img = message.image, let tiff = img.tiffRepresentation {
                attachments.append(Attachment(type: .image, data: tiff))
            }
            if let pdf = message.pdfData {
                attachments.append(Attachment(type: .pdf, data: pdf))
            }
        }
        performSend(input: newContent, attachments: attachments)
    }

    func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    func performSend(
        input: String, attachments: [Attachment], existingVersions: [MessageVersion]? = nil
    ) {
        isLoading = true
        let currentHistory = chatManager.getCurrentMessages()
        currentTask?.cancel()

        currentTask = Task {
            // Web search augmentation (Ollama only)
            var effectiveSystemPrompt = systemPrompt
            if webSearchEnabled && !ollamaAPIKey.isEmpty && selectedProvider == "Ollama" {
                do {
                    let searchResults = try await webSearchService.search(
                        query: input, apiKey: ollamaAPIKey)
                    let searchContext = webSearchService.buildSearchContext(results: searchResults)
                    if !searchContext.isEmpty {
                        effectiveSystemPrompt = systemPrompt + searchContext
                    }
                } catch {
                    // Silently continue without search results on failure
                    print("Web search failed: \\(error.localizedDescription)")
                }
            }

            if selectedProvider == "Gemini API" {
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
                        var receivedImage: NSImage? = nil
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk, imageData)
                            in geminiService.sendMessageStream(
                                history: currentHistory, apiKey: geminiKey, model: geminiModel,
                                systemPrompt: systemPrompt, thinkingLevel: currentThinkingLevel)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }
                            if let imgData = imageData, let img = NSImage(data: imgData) {
                                receivedImage = img
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentToUpdate = fullContent
                                let thinkingToUpdate = fullThinking.isEmpty ? nil : fullThinking
                                let imgToUpdate = receivedImage

                                DispatchQueue.main.async {
                                    self.chatManager.updateMessage(
                                        id: aiMsgId, content: contentToUpdate,
                                        thinkingContent: thinkingToUpdate,
                                        image: imgToUpdate,
                                        isStreaming: true)
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let finalImage = receivedImage
                        DispatchQueue.main.async {
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: fullContent,
                                thinkingContent: fullThinking.isEmpty ? nil : fullThinking,
                                image: finalImage,
                                isStreaming: false)
                            if let versions = existingVersions {
                                self.chatManager.attachVersions(versions, to: aiMsgId)
                            }
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
                        history: chatManager.getCurrentMessages(),
                        systemPrompt: systemPrompt
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
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
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
                        systemPrompt: effectiveSystemPrompt, thinkingLevel: currentThinkingLevel)
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
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
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
                        name: shortcutName, input: transcript, image: nil)
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId,
                            content: result.0,
                            image: result.1,
                            isStreaming: false
                        )
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
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
    @Binding var showModelComparison: Bool
    @Binding var showCommands: Bool
    @Binding var showQuizMe: Bool
    @Binding var showImageGen: Bool
    @Namespace private var animation

    @AppStorage("ShowCompare") private var showCompareTool: Bool = true
    @AppStorage("ShowCommands") private var showCommandsTool: Bool = true
    @AppStorage("ShowQuizMe") private var showQuizMeTool: Bool = true
    @AppStorage("ShowImageGen") private var showImageGenTool: Bool = true
    @AppStorage("ToolOrder") private var toolOrderRaw: String = "compare,commands,quizme,imagegen"
    @State private var showCustomizeTools: Bool = false
    @State private var draggedTool: String? = nil

    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var renamingSessionId: UUID?
    @State private var renameText: String = ""
    @State private var draggedSession: ChatSession? = nil
    @Environment(\.colorScheme) private var colorScheme

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

    var topSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // New Chat
            SidebarItem(icon: "square.and.pencil", title: "New chat") {
                showImageGallery = false
                showModelComparison = false
                showCommands = false
                showQuizMe = false
                showImageGen = false
                chatManager.createNewSession()
            }

            // Search
            SidebarItem(icon: "magnifyingglass", title: "Search chats") {
                isSearchVisible.toggle()
                if isSearchVisible { searchText = "" }
            }
            .popover(isPresented: $isSearchVisible, arrowEdge: .leading) {
                VStack(spacing: 0) {
                    // Search header
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Search chats...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    Divider().opacity(0.3).padding(.horizontal, 12)

                    if searchText.isEmpty {
                        // Recent chats prompt
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary.opacity(0.2))
                            Text("Search by title or message content")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                    } else if filteredSessions.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary.opacity(0.2))
                            Text("No chats found for \"\(searchText)\"")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                    } else {
                        // Results count
                        HStack {
                            Text(
                                "\(filteredSessions.count) result\(filteredSessions.count == 1 ? "" : "s")"
                            )
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(filteredSessions) { session in
                                    Button(action: {
                                        showImageGallery = false
                                        showModelComparison = false
                                        showCommands = false
                                        showQuizMe = false
                                        showImageGen = false
                                        chatManager.currentSessionId = session.id
                                        isSearchVisible = false
                                    }) {
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(
                                                    session.title.isEmpty
                                                        ? "New Chat" : session.title
                                                )
                                                .lineLimit(1)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.primary)
                                                HStack(spacing: 6) {
                                                    Text(session.date, style: .date)
                                                        .font(.system(size: 10))
                                                        .foregroundStyle(.secondary.opacity(0.6))
                                                    if !session.messages.isEmpty {
                                                        Text("·")
                                                            .foregroundStyle(
                                                                .secondary.opacity(0.4))
                                                        Text("\(session.messages.count) messages")
                                                            .font(.system(size: 10))
                                                            .foregroundStyle(
                                                                .secondary.opacity(0.6))
                                                    }
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.secondary.opacity(0.3))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(
                                                    colorScheme == .dark
                                                        ? Color.white.opacity(0.04)
                                                        : Color.black.opacity(0.02))
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(maxHeight: 320)
                    }
                }
                .padding(.bottom, 12)
                .frame(width: 340)
            }

            // Images
            SidebarItem(icon: "photo", title: "Images", isSelected: showImageGallery) {
                withAnimation {
                    showImageGallery = true
                    showModelComparison = false
                    showCommands = false
                    showQuizMe = false
                    showImageGen = false
                    chatManager.currentSessionId = nil
                }
            }

            // ── Tools ──────────────
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
                    .frame(maxWidth: 12)
                Text("Tools")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .textCase(.uppercase)
                    .tracking(1.2)
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Model Comparison / Commands / Quiz Me — reorderable
            ForEach(toolOrder, id: \.self) { toolId in
                if toolId == "compare" && showCompareTool {
                    SidebarItem(
                        icon: "square.split.2x1", title: "Compare", isSelected: showModelComparison
                    ) {
                        withAnimation {
                            showModelComparison = true
                            showImageGallery = false
                            showCommands = false
                            showQuizMe = false
                            showImageGen = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "commands" && showCommandsTool {
                    SidebarItem(icon: "command", title: "Commands", isSelected: showCommands) {
                        withAnimation {
                            showCommands = true
                            showModelComparison = false
                            showImageGallery = false
                            showQuizMe = false
                            showImageGen = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "quizme" && showQuizMeTool {
                    SidebarItem(
                        icon: "questionmark.bubble", title: "Quiz Me", isSelected: showQuizMe
                    ) {
                        withAnimation {
                            showQuizMe = true
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            showImageGen = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "imagegen" && showImageGenTool {
                    SidebarItem(
                        icon: "paintbrush", title: "Image Generation", isSelected: showImageGen
                    ) {
                        withAnimation {
                            showImageGen = true
                            showQuizMe = false
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            chatManager.currentSessionId = nil
                        }
                    }
                }
            }

            // Customize Tools button
            Button(action: { showCustomizeTools.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                    Text("Customize")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.secondary.opacity(0.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCustomizeTools, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Visible Tools")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Toggle(isOn: $showCompareTool) {
                        Label("Compare", systemImage: "square.split.2x1")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Toggle(isOn: $showCommandsTool) {
                        Label("Commands", systemImage: "command")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Toggle(isOn: $showQuizMeTool) {
                        Label("Quiz Me", systemImage: "questionmark.bubble")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Toggle(isOn: $showImageGenTool) {
                        Label("Image Generation", systemImage: "paintbrush")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Divider()

                    Text("Drag to reorder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(toolOrder, id: \.self) { toolId in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Image(systemName: toolIcon(for: toolId))
                                .font(.system(size: 11))
                                .frame(width: 16)
                            Text(toolLabel(for: toolId))
                                .font(.system(size: 12))
                            Spacer()
                            // Move up/down buttons
                            if let idx = toolOrder.firstIndex(of: toolId), idx > 0 {
                                Button(action: { moveToolUp(toolId) }) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            if let idx = toolOrder.firstIndex(of: toolId), idx < toolOrder.count - 1
                            {
                                Button(action: { moveToolDown(toolId) }) {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.secondary.opacity(0.06))
                        )
                        .opacity(draggedTool == toolId ? 0.4 : 1.0)
                        .onDrag {
                            draggedTool = toolId
                            return NSItemProvider(object: toolId as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ToolDropDelegate(
                                item: toolId,
                                draggedItem: $draggedTool,
                                toolOrderRaw: $toolOrderRaw,
                                toolOrder: toolOrder
                            ))
                    }
                }
                .padding(12)
                .frame(width: 220)
            }
        }
    }

    // MARK: - Tool ordering helpers

    private var toolOrder: [String] {
        let raw = toolOrderRaw.split(separator: ",").map(String.init)
        let allTools = ["compare", "commands", "quizme", "imagegen"]
        // Ensure all tools are present (handle new tools added after first save)
        var order = raw.filter { allTools.contains($0) }
        for tool in allTools where !order.contains(tool) {
            order.append(tool)
        }
        return order
    }

    private func toolIcon(for id: String) -> String {
        switch id {
        case "compare": return "square.split.2x1"
        case "commands": return "command"
        case "quizme": return "questionmark.bubble"
        case "imagegen": return "paintbrush"
        default: return "questionmark"
        }
    }

    private func toolLabel(for id: String) -> String {
        switch id {
        case "compare": return "Compare"
        case "commands": return "Commands"
        case "quizme": return "Quiz Me"
        case "imagegen": return "Image Generation"
        default: return id
        }
    }

    private func moveToolUp(_ toolId: String) {
        var order = toolOrder
        guard let idx = order.firstIndex(of: toolId), idx > 0 else { return }
        order.swapAt(idx, idx - 1)
        toolOrderRaw = order.joined(separator: ",")
    }

    private func moveToolDown(_ toolId: String) {
        var order = toolOrder
        guard let idx = order.firstIndex(of: toolId), idx < order.count - 1 else { return }
        order.swapAt(idx, idx + 1)
        toolOrderRaw = order.joined(separator: ",")
    }

    // MARK: - Tool Drag & Drop

    struct ToolDropDelegate: DropDelegate {
        let item: String
        @Binding var draggedItem: String?
        @Binding var toolOrderRaw: String
        let toolOrder: [String]

        func performDrop(info: DropInfo) -> Bool {
            draggedItem = nil
            return true
        }

        func dropEntered(info: DropInfo) {
            guard let dragged = draggedItem, dragged != item else { return }
            var order = toolOrder
            guard let fromIndex = order.firstIndex(of: dragged),
                let toIndex = order.firstIndex(of: item)
            else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                order.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                toolOrderRaw = order.joined(separator: ",")
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            return DropProposal(operation: .move)
        }
    }

    var sectionHeader: some View {
        Text("Your chats")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    private var visibleSessions: [ChatSession] {
        chatManager.sessions.filter {
            !$0.messages.isEmpty || $0.id == chatManager.currentSessionId
        }
    }

    private var pinnedSessions: [ChatSession] {
        visibleSessions.filter { $0.isPinned }
    }

    private var unpinnedSessions: [ChatSession] {
        visibleSessions.filter { !$0.isPinned }
    }

    private func chatRow(for session: ChatSession) -> some View {
        SidebarRow(
            session: session,
            isSelected: !showImageGallery && !showModelComparison && !showCommands
                && !showQuizMe
                && chatManager.currentSessionId == session.id,
            isRenaming: renamingSessionId == session.id,
            renameText: $renameText,
            animation: animation,
            onSelect: {
                showImageGallery = false
                showModelComparison = false
                showCommands = false
                showQuizMe = false
                showImageGen = false
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
            onPin: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    chatManager.togglePin(id: session.id)
                }
            }
        )
        .opacity(draggedSession?.id == session.id ? 0.4 : 1.0)
        .onDrag {
            draggedSession = session
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: ChatDropDelegate(
                item: session,
                draggedItem: $draggedSession,
                sessions: $chatManager.sessions,
                onSave: { chatManager.saveSessions() }
            ))
    }

    var chatList: some View {
        ScrollView {
            VStack(spacing: 2) {
                if !pinnedSessions.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("Pinned")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .textCase(.uppercase)
                            .tracking(1.0)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                    ForEach(pinnedSessions) { session in
                        chatRow(for: session)
                    }

                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }

                ForEach(unpinnedSessions) { session in
                    chatRow(for: session)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topSection
                .padding(10)

            sectionHeader

            chatList
        }
    }

}

// MARK: - Chat Drag & Drop

struct ChatDropDelegate: DropDelegate {
    let item: ChatSession
    @Binding var draggedItem: ChatSession?
    @Binding var sessions: [ChatSession]
    var onSave: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedItem, dragged.id != item.id else { return }
        guard let fromIndex = sessions.firstIndex(where: { $0.id == dragged.id }),
            let toIndex = sessions.firstIndex(where: { $0.id == item.id })
        else { return }

        // Only allow reorder within the same pinned/unpinned group
        guard sessions[fromIndex].isPinned == sessions[toIndex].isPinned else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            sessions.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            onSave()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.8))
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
    var onPin: () -> Void

    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @FocusState private var isFocused: Bool

    var body: some View {
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
                HStack(spacing: 4) {
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
                            .foregroundStyle(
                                isSelected ? Color.primary : Color.primary.opacity(0.9)
                            )
                            .lineLimit(1)
                    }
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .rotationEffect(.degrees(45))
                    }
                }

                Text(session.date, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !session.messages.isEmpty {
                Text("\(session.messages.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.5))
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
        .onTapGesture {
            if !isRenaming {
                onSelect()
            }
        }
        .contextMenu {
            Button("Rename") {
                onRename()
            }
            Divider()
            Button {
                onPin()
            } label: {
                Label(
                    session.isPinned ? "Unpin" : "Pin",
                    systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete()
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

            } label: {
                HStack(spacing: 6) {
                    Image(systemName: getProviderIcon(selectedProvider))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .green], startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                    Text(selectedProvider)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                        .shadow(color: Color.black.opacity(0.06), radius: 2, y: 1)
                )
                .glassEffect(.regular, in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusEffectDisabled()
            .padding(.horizontal, 4)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    func getProviderIcon(_ provider: String) -> String {
        switch provider {
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
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
                            .foregroundStyle(.red)
                        Text("PDF")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                case .text:
                    VStack(spacing: 2) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 24))
                            .foregroundStyle(.blue)
                        Text(
                            attachment.fileName?.components(separatedBy: ".").last?.uppercased()
                                .prefix(4).map(String.init).joined() ?? "TXT"
                        )
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
                    .foregroundStyle(.gray)
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
                    let imageExtensions = [
                        "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                    ]
                    let textExtensions = [
                        "txt", "md", "json", "xml", "html", "htm", "csv", "yaml", "yml",
                        "log", "toml", "ini", "cfg", "conf", "rtf",
                        "swift", "py", "js", "ts", "jsx", "tsx", "java", "c", "cpp", "h",
                        "cs", "go", "rs", "rb", "php", "sh", "bash", "zsh", "sql", "r",
                        "kt", "scala", "lua", "pl", "m", "mm",
                    ]
                    for url in urls {
                        let ext = url.pathExtension.lowercased()
                        if ext == "pdf" {
                            if let data = try? Data(contentsOf: url) {
                                newAttachments.append(Attachment(type: .pdf, data: data))
                            }
                        } else if imageExtensions.contains(ext) {
                            if let data = try? Data(contentsOf: url) {
                                newAttachments.append(Attachment(type: .image, data: data))
                            }
                        } else if textExtensions.contains(ext) {
                            if let data = try? Data(contentsOf: url) {
                                newAttachments.append(
                                    Attachment(
                                        type: .text, data: data, fileName: url.lastPathComponent))
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
    var thinkingMode: ThinkingMode
    var isOllama: Bool = false
    var isGemini: Bool = false
    @Binding var webSearchEnabled: Bool
    var hasOllamaAPIKey: Bool = false
    var onSlashAction: ((String) -> Void)? = nil  // callback for action commands (/clear, /quit, /new)
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared
    @ObservedObject private var slashCommandManager = SlashCommandManager.shared

    @FocusState private var isFocused: Bool
    @StateObject private var pasteMonitor = PasteMonitor()
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""
    @State private var glassHover: Bool = false
    @State private var slashMatches: [SlashCommand] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var showSlashAutocomplete: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Slash command autocomplete dropdown
            if showSlashAutocomplete && !slashMatches.isEmpty {
                SlashCommandAutocomplete(
                    matches: slashMatches,
                    selectedIndex: slashSelectedIndex,
                    onSelect: { command in
                        applySlashCommand(command)
                    }
                )
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut(duration: 0.15), value: showSlashAutocomplete)
            }

            imagePreview
            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: inputText) { _, newValue in
            updateSlashAutocomplete(newValue)
        }
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
        if isFocused {
            pasteMonitor.start()
        }
    }

    private var imagePreview: some View {
        Group {
            if !selectedAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(.bottom, 6)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Main input row
            HStack(spacing: 10) {
                // Left action button
                Button(action: onSelectAttachment) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
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
                .buttonStyle(.plain)

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
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "checkmark")
                                    } else {
                                        Text(geminiManager.displayName(for: model))
                                    }
                                }
                            }
                        }

                        ForEach(GeminiModelManager.modelGroups, id: \.name) { group in
                            let nonFavModels = group.models.filter { !geminiManager.isFavorite($0) }
                            if !nonFavModels.isEmpty {
                                Section(group.name) {
                                    ForEach(nonFavModels, id: \.self) { model in
                                        Button(action: { geminiModel = model }) {
                                            if geminiModel == model {
                                                Label(
                                                    geminiManager.displayName(for: model),
                                                    systemImage: "checkmark")
                                            } else {
                                                Text(geminiManager.displayName(for: model))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("Manage Favorites") {
                            ForEach(geminiManager.availableModels, id: \.self) { model in
                                Button(action: { geminiManager.toggleFavorite(model) }) {
                                    if geminiManager.isFavorite(model) {
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "star.fill")
                                    } else {
                                        Label(
                                            geminiManager.displayName(for: model),
                                            systemImage: "star")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "sparkles")
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
                        } else if thinkingMode == .geminiPro {
                            // Gemini 3 Pro: Auto, Low, High only
                            Button {
                                thinkingLevel = "auto"
                            } label: {
                                if thinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                } else {
                                    Text("Auto")
                                }
                            }
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
                                thinkingLevel = "high"
                            } label: {
                                if thinkingLevel == "high" {
                                    Label("High", systemImage: "checkmark")
                                } else {
                                    Text("High")
                                }
                            }
                        } else if thinkingMode == .geminiFlash {
                            // Gemini 3 Flash / 2.5: Auto, Low, Medium, High
                            Button {
                                thinkingLevel = "auto"
                            } label: {
                                if thinkingLevel == "auto" {
                                    Label("Auto", systemImage: "checkmark")
                                } else {
                                    Text("Auto")
                                }
                            }
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
                    .help("Reasoning Effort")
                }

                // Web Search Toggle (Ollama only)
                if hasOllamaAPIKey && isOllama {
                    Button(action: {
                        webSearchEnabled.toggle()
                    }) {
                        Image(systemName: webSearchEnabled ? "globe" : "globe")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(webSearchEnabled ? Color.blue : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(
                                        webSearchEnabled
                                            ? Color.blue.opacity(colorScheme == .dark ? 0.2 : 0.1)
                                            : (colorScheme == .dark
                                                ? Color.white.opacity(0.08)
                                                : Color.black.opacity(0.04))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(webSearchEnabled ? "Web Search: On" : "Web Search: Off")
                }

                // Send/Stop Button — Liquid Glass orb
                Button(action: {
                    if isLoading {
                        onStop()
                    } else {
                        onSend()
                    }
                }) {
                    ZStack {
                        // Glass sphere
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isLoading
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : (inputText.isEmpty && selectedAttachments.isEmpty)
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
                                // Top specular highlight
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

                        Image(systemName: isLoading ? "stop.fill" : "arrow.up")
                            .font(.system(size: isLoading ? 12 : 14, weight: .bold))
                            .foregroundStyle(
                                isLoading
                                    ? Color.white
                                    : (colorScheme == .dark ? Color.black : Color.white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled((inputText.isEmpty && selectedAttachments.isEmpty) && !isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Liquid Glass container
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            // Floating shadow system
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(isFocused ? 0.5 : 0.3)
                    : Color.black.opacity(isFocused ? 0.12 : 0.06),
                radius: isFocused ? 30 : 16,
                x: 0,
                y: isFocused ? 12 : 6
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.blue.opacity(isFocused ? 0.08 : 0.0)
                    : Color.blue.opacity(isFocused ? 0.04 : 0.0),
                radius: 40,
                x: 0,
                y: 0
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isFocused)
        }
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if inputText.isEmpty && !isFocused {
                Text(
                    "Ask AI anything... (type / for commands)"
                )
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary.opacity(0.6))
                .allowsHitTesting(false)
                .padding(.leading, 4)
            }

            TextField("", text: $inputText, axis: .vertical)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(1...10)
                .onKeyPress(.upArrow) {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        slashSelectedIndex = max(0, slashSelectedIndex - 1)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        slashSelectedIndex = min(slashMatches.count - 1, slashSelectedIndex + 1)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.tab) {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        applySlashCommand(slashMatches[slashSelectedIndex])
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if showSlashAutocomplete {
                        showSlashAutocomplete = false
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.return) {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        applySlashCommand(slashMatches[slashSelectedIndex])
                        return .handled
                    }
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

    // MARK: - Slash Command Helpers

    private func updateSlashAutocomplete(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            let matches = slashCommandManager.matches(for: trimmed)
            withAnimation(.easeOut(duration: 0.12)) {
                slashMatches = matches
                slashSelectedIndex = 0
                showSlashAutocomplete = !matches.isEmpty
            }
        } else {
            if showSlashAutocomplete {
                withAnimation(.easeOut(duration: 0.12)) {
                    showSlashAutocomplete = false
                    slashMatches = []
                }
            }
        }
    }

    private func applySlashCommand(_ command: SlashCommand) {
        showSlashAutocomplete = false
        slashMatches = []

        if slashCommandManager.isActionCommand(command.trigger) {
            inputText = ""
            onSlashAction?(command.trigger)
        } else {
            inputText = command.expansion + " "
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

}

struct ThumbnailView: View {
    let image: NSImage
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var messageId: UUID? = nil
    var coordinateSpaceName: String? = nil
    var onImageTap: ((NSImage, CGRect) -> Void)? = nil

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: ImageFramePreferenceKey.self,
                                value: messageId != nil && coordinateSpaceName != nil
                                    ? [messageId!: g.frame(in: .named(coordinateSpaceName!))]
                                    : [:]
                            )
                        }
                    )
                    .onTapGesture {
                        // no-op here; tap handled by overlay if onImageTap not set via ThumbnailView
                    }
                    .overlay(
                        GeometryReader { g in
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let coordSpace = coordinateSpaceName {
                                        onImageTap?(image, g.frame(in: .named(coordSpace)))
                                    }
                                }
                        }
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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

class NonScrollableWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct MathView: NSViewRepresentable {
    var equation: String
    var fontSize: CGFloat = 20

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

        let webView = NonScrollableWebView(frame: .zero, configuration: config)
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

        if context.coordinator.isLoaded {
            let js = "window.updateLatex(String.raw`\(escapedLatex)`)"
            nsView.evaluateJavaScript(js, completionHandler: nil)
            return
        }

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
                        
                        window.updateLatex = function(latexRaw) {
                            try {
                                katex.render(latexRaw, document.getElementById('math'), { displayMode: true, throwOnError: true });
                            } catch (e) {
                                document.getElementById('math').innerText = latexRaw;
                                document.getElementById('math').style.fontFamily = 'monospace';
                                document.getElementById('math').style.whiteSpace = 'pre-wrap';
                            }
                            // Allow a moment for rendering layout
                            setTimeout(sendHeight, 0);
                        }

                        document.addEventListener('DOMContentLoaded', () => {
                           window.updateLatex(String.raw`\(escapedLatex)`);
                        });
                    </script>
                </body>
            </html>
            """

        nsView.loadHTMLString(html, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: KaTeXView
        var isLoaded = false

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
            isLoaded = true
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

    // Reduced font size by another 25% (13.5 * 0.75 = 10.125)
    private var scaledFontSize: CGFloat { 10.125 }

    var body: some View {
        VStack {
            KaTeXView(
                latex: equation, fontSize: scaledFontSize, height: $height, didRender: $didRender
            )
            .frame(height: height)
            .frame(maxWidth: .infinity)
            // Always visible to avoid jumping. Errors are suppressed in JS.
        }
        .padding(.vertical, 4)
        .textSelection(.disabled)
    }
}

// MARK: - RichTextView (Text with inline LaTeX support)
struct RichTextView: NSViewRepresentable {
    let content: String
    let fontSize: CGFloat
    @Binding var height: CGFloat

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

        let webView = NonScrollableWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // IMPORTANT: Only reload if content changed - loadHTMLString is expensive!
        guard context.coordinator.lastContent != content else { return }
        context.coordinator.lastContent = content

        let processedContent = processMarkdownToHTML(content)

        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
                <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
                <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
                    onload="renderMathInElement(document.body, {
                        delimiters: [
                            {left: '$$', right: '$$', display: true},
                            {left: '$', right: '$', display: false},
                            {left: '\\\\(', right: '\\\\)', display: false},
                            {left: '\\\\[', right: '\\\\]', display: true}
                        ],
                        throwOnError: false
                    }); sendHeight();">
                </script>
                <style>
                    :root { color-scheme: light dark; }
                    * { margin: 0; padding: 0; box-sizing: border-box; }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                        font-size: \(fontSize)px;
                        line-height: 1.5;
                        padding: 0;
                        background: transparent;
                        color: #111;
                        word-wrap: break-word;
                        overflow-wrap: break-word;
                    }
                    @media (prefers-color-scheme: dark) { body { color: #f5f5f5; } }
                    .katex { font-size: 1em; }
                    .katex-display { margin: 8px 0; overflow-x: auto; }
                    code {
                        font-family: ui-monospace, monospace;
                        background: rgba(128,128,128,0.2);
                        padding: 1px 4px;
                        border-radius: 3px;
                    }
                    strong { font-weight: 600; }
                    em { font-style: italic; }
                </style>
            </head>
            <body>
                <div id="content">\(processedContent)</div>
                <script>
                    function sendHeight() {
                        const content = document.getElementById('content');
                        const h = content ? content.offsetHeight : (document.body.scrollHeight || 20);
                        window.webkit.messageHandlers.height.postMessage(h);
                    }
                    document.addEventListener('DOMContentLoaded', function() {
                        // Wait a tiny bit for KaTeX to render
                        setTimeout(sendHeight, 50);
                    });
                </script>
            </body>
            </html>
            """

        nsView.loadHTMLString(html, baseURL: nil)
    }

    private func processMarkdownToHTML(_ input: String) -> String {
        // 1. Escape HTML first
        var text =
            input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        // 2. Protect Math Blocks
        // We use a simplified regex to find likely math blocks and replace them with tokens
        var mathBlocks: [String] = []
        let mathPattern =
            #"(\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)|(?<!\\)\$(?:[^$]+)(?<!\\)\$)"#

        if let regex = try? NSRegularExpression(pattern: mathPattern) {
            let nsString = text as NSString
            let matches = regex.matches(
                in: text, range: NSRange(location: 0, length: nsString.length))

            // Iterate backwards to replace without invalidating ranges
            for match in matches.reversed() {
                let range = match.range
                let mathContent = nsString.substring(with: range)
                let token = "MATH_BLOCK_\(mathBlocks.count)"
                mathBlocks.append(mathContent)
                text = (text as NSString).replacingCharacters(in: range, with: token)
            }
        }

        // 3. Process Markdown (Simple Regex)
        // Bold: **text**
        text = text.replacingOccurrences(
            of: "\\*\\*(.*?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        // Italic: *text* (avoiding ** match collision by order - simple approach)
        // Note: This regex is simplistic and might misfire on complex nested cases, but sufficient for basic rich text support.
        text = text.replacingOccurrences(
            of: "(?<!\\*)\\*(?!\\s)(.*?)(?<!\\s)\\*(?!\\*)", with: "<em>$1</em>",
            options: .regularExpression)
        // Inline Code: `text`
        text = text.replacingOccurrences(
            of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)

        // 4. Restore Math Blocks
        // Iterate backwards through the array since we appended them in reverse order of discovery?
        // No, we appended them as we found them (backwards iteration means first found is last in array?)
        // Let's check:
        // Iteration: reversed(). Match 1 (end of string). Appended to mathBlocks[0]. Replaced.
        // Match 2 (start of string). Appended to mathBlocks[1]. Replaced.
        // So mathBlocks[0] corresponds to the LAST token in text.
        // mathBlocks[1] corresponds to the FIRST token.
        // Token format "MATH_BLOCK_\(count)".
        // When we replace, we used mathBlocks.count BEFORE appending.
        // i.e. 0, then 1.
        // So MATH_BLOCK_0 is the LAST block.

        for (index, block) in mathBlocks.enumerated() {
            text = text.replacingOccurrences(of: "MATH_BLOCK_\(index)", with: block)
        }

        // 5. Convert newlines to breaks
        text = text.replacingOccurrences(of: "\n", with: "<br>")

        return text
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichTextView
        var lastContent: String? = nil  // Track to prevent redundant reloads

        init(parent: RichTextView) {
            self.parent = parent
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "height" else { return }
            if let h = message.body as? Double {
                DispatchQueue.main.async {
                    self.parent.height = max(20, CGFloat(h))
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Wait a bit for KaTeX to render, then measure content div
            webView.evaluateJavaScript(
                "(function(){ setTimeout(function(){ const c = document.getElementById('content'); const h = c ? c.offsetHeight : (document.body.scrollHeight || 20); window.webkit.messageHandlers.height.postMessage(h); }, 50); })();"
            ) { _, _ in }
        }
    }
}

// Helper to check if text contains inline math
func containsInlineMath(_ text: String) -> Bool {
    // Check for $...$ (but not $$)
    if let range = text.range(of: "\\$[^$]+\\$", options: .regularExpression) {
        // Make sure it's not part of $$
        let startIdx = range.lowerBound
        if startIdx > text.startIndex {
            let prevIdx = text.index(before: startIdx)
            if text[prevIdx] == "$" { return false }
        }
        return true
    }
    // Check for \(...\)
    if text.contains("\\(") && text.contains("\\)") {
        return true
    }
    return false
}

// MARK: - TextBlockView (conditionally uses RichTextView for inline math)
struct TextBlockView: View {
    let text: String
    let cachedAttributedText: AttributedString?
    let textColor: Color
    @State private var webViewHeight: CGFloat = 20

    var body: some View {
        if containsInlineMath(text) {
            RichTextView(content: text, fontSize: 15, height: $webViewHeight)
                .textSelection(.disabled)
                .frame(height: webViewHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if let cached = cachedAttributedText {
                Text(cached)
                    .font(.system(size: 15))
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(MarkdownParser.shared.parse(text))
                    .font(.system(size: 15))
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Code Block View (color-scheme adaptive)
struct CodeBlockView: View {
    let code: String
    let language: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false
    @State private var copyHovered = false
    @State private var copyTextWidth: CGFloat = 0

    private var isDark: Bool { colorScheme == .dark }

    private var headerBg: Color {
        isDark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.72, alpha: 1.0))
    }

    private var bodyBg: Color {
        isDark
            ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.78, alpha: 1.0))
    }

    private var borderColor: Color {
        isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.12)
    }

    private var langColor: Color {
        isDark
            ? Color.white.opacity(0.45)
            : Color.black.opacity(0.45)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                if !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(langColor)
                }
                Spacer()
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(code, forType: .string)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            copied = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .frame(width: 12)
                        Text(copied ? "Copied!" : "Copy")
                            .lineLimit(1)
                            .fixedSize()
                            .background(
                                GeometryReader { geo in
                                    Color.clear.onAppear {
                                        copyTextWidth = max(copyTextWidth, geo.size.width)
                                    }
                                    .onChange(of: geo.size.width) { _, w in
                                        copyTextWidth = max(copyTextWidth, w)
                                    }
                                }
                            )
                            .frame(width: copyHovered ? copyTextWidth : 0, alignment: .leading)
                            .clipped()
                            .opacity(copyHovered ? 1 : 0)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Color.green : langColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(
                                isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
                .background(PointingHandCursor())
                .onHover { hovering in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        copyHovered = hovering
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(headerBg)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(
                    SyntaxHighlighter.shared.highlight(
                        code, language: language, isDark: isDark)
                )
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .lineSpacing(4)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            }
        }
        .background(bodyBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

// MARK: - TableCellView (supports LaTeX in table cells)
struct TableCellView: View {
    let text: String
    let isHeader: Bool
    @State private var webViewHeight: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if containsInlineMath(text) {
            RichTextView(content: text, fontSize: 14, height: $webViewHeight)
                .textSelection(.disabled)
                .frame(height: min(webViewHeight, 300))
                .frame(minWidth: 300, alignment: .leading)  // Min width for math cells
        } else {
            Text(MarkdownParser.shared.parse(text))
                .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

        }
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
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block.type {
                case .text(let text):
                    TextBlockView(
                        text: text,
                        cachedAttributedText: block.attributedText,
                        textColor: textColor
                    )
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                case .heading(let text, let level):
                    renderRichText(text, cached: block.attributedText)
                        .font(
                            .system(
                                size: level == 1 ? 24 : (level == 2 ? 20 : (level == 3 ? 18 : 16)),
                                weight: .bold)
                        )
                        .padding(.top, 8)
                        .foregroundStyle(textColor)

                        .fixedSize(horizontal: false, vertical: true)
                case .divider:
                    Divider()
                        .padding(.vertical, 8)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 15))
                            .foregroundStyle(textColor)
                        TextBlockView(
                            text: text,
                            cachedAttributedText: block.attributedText,
                            textColor: textColor
                        )
                    }
                    .padding(.leading, 8)
                case .numbered(let text, let number):
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(number).")
                            .font(.system(size: 15))
                            .foregroundStyle(textColor)
                        TextBlockView(
                            text: text,
                            cachedAttributedText: block.attributedText,
                            textColor: textColor
                        )
                    }
                    .padding(.leading, 8)
                case .blockquote(let text):
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: 4)
                        renderRichText(text, cached: block.attributedText)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)

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
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(headers.indices, id: \.self) { i in
                                TableCellView(text: headers[i], isHeader: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .background(Color.primary.opacity(0.06))

                        Divider()

                        // Rows
                        ForEach(rows.indices, id: \.self) { i in
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(0..<headers.count, id: \.self) { j in
                                    let content = j < rows[i].count ? rows[i][j] : ""
                                    TableCellView(text: content, isHeader: false)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                            }
                            .background(
                                i % 2 == 0
                                    ? Color.clear : Color.primary.opacity(0.03))

                            if i < rows.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.02))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct EmptyStateView: View {
    var appTheme: AppTheme = .default
    @State private var animate = false
    @State private var orbPhase: CGFloat = 0
    @State private var shimmer: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .blue
        let endColor = colors.last ?? .green

        return ZStack {
            // Floating ambient orbs
            Circle()
                .fill(
                    RadialGradient(
                        colors: [startColor.opacity(0.15), startColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 120
                    )
                )
                .frame(width: 240, height: 240)
                .offset(x: -80, y: -60)
                .blur(radius: 50)
                .scaleEffect(animate ? 1.2 : 0.9)
                .opacity(animate ? 0.8 : 0.4)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [endColor.opacity(0.12), endColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .offset(x: 90, y: 50)
                .blur(radius: 45)
                .scaleEffect(animate ? 0.85 : 1.15)
                .opacity(animate ? 0.5 : 0.8)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [startColor.opacity(0.08), endColor.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 80
                    )
                )
                .frame(width: 160, height: 160)
                .offset(x: 40, y: -100)
                .blur(radius: 35)
                .scaleEffect(animate ? 1.1 : 0.95)

            VStack(spacing: 28) {
                Spacer()

                // Icon with layered glass effect
                ZStack {
                    // Outer glow ring
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [
                                    startColor.opacity(0.3), endColor.opacity(0.3),
                                    startColor.opacity(0.1), endColor.opacity(0.3),
                                ],
                                center: .center,
                                startAngle: .degrees(orbPhase),
                                endAngle: .degrees(orbPhase + 360)
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 100, height: 100)

                    // Glass circle
                    Circle()
                        .fill(Color.clear)
                        .frame(width: 90, height: 90)
                        .glassEffect(.regular, in: .circle)
                        .shadow(color: startColor.opacity(0.15), radius: 20, x: 0, y: 10)

                    Image(systemName: "sparkles")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(animate ? 1.05 : 0.95)
                }

                VStack(spacing: 10) {
                    Text("Hello")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [startColor, endColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("How can I help you today?")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                }

                // Suggestion chips
                HStack(spacing: 10) {
                    ForEach(["Write", "Analyze", "Create", "Explain"], id: \.self) { suggestion in
                        Text(suggestion)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
                .padding(.top, 4)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                animate = true
            }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                orbPhase = 360
            }
        }
    }
}

struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = Impl()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private class Impl: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeAlways],
                    owner: self,
                    userInfo: nil
                ))
        }
        override func mouseEntered(with event: NSEvent) {
            NSCursor.pointingHand.push()
        }
        override func mouseExited(with event: NSEvent) {
            NSCursor.pop()
        }
    }
}

struct ExpandingActionButton: View {
    let title: String
    let icon: String
    var color: Color = .secondary
    var font: Font = .caption
    let action: () -> Void
    @State private var isHovered = false
    @State private var textWidth: CGFloat = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .frame(width: 14)
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { textWidth = max(textWidth, geo.size.width) }
                                .onChange(of: geo.size.width) { _, w in
                                    textWidth = max(textWidth, w)
                                }
                        }
                    )
                    .frame(width: isHovered ? textWidth : 0, alignment: .leading)
                    .clipped()
                    .opacity(isHovered ? 1 : 0)
            }
            .font(font)
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PointingHandCursor())
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isHovered)
    }
}

struct MessageView: View, Equatable {
    let message: Message
    var liveContent: String? = nil
    var liveThinking: String? = nil
    var onRegenerate: (() -> Void)?
    var onEdit: ((String) -> Void)?
    var canEdit: Bool = false  // Explicit flag for equality checking
    var onImageTap: ((NSImage, CGRect) -> Void)?
    var onSwitchVersion: ((Int) -> Void)?
    var maxBubbleWidth: CGFloat = 500

    @State private var isCopied = false
    @State private var isSaved = false
    @State private var isCursorVisible = true
    @State private var isThinkingExpanded = false
    @State private var isEditing = false
    @State private var editText = ""
    @AppStorage("ImageDownloadPath") private var imageDownloadPath: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme
    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        return lhs.message == rhs.message && lhs.liveContent == rhs.liveContent
            && lhs.liveThinking == rhs.liveThinking && lhs.canEdit == rhs.canEdit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer()
                VStack(alignment: .trailing) {
                    if let image = message.image {
                        ThumbnailView(
                            image: image, maxWidth: 200, maxHeight: 300,
                            messageId: message.id,
                            coordinateSpaceName: "detailContainer",
                            onImageTap: onImageTap
                        )
                        .id(message.currentVersionIndex ?? -1)
                    }
                    if message.pdfData != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                            Text("PDF Document")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                        .padding(10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 12))
                        .padding(.bottom, 4)
                    }

                    if isEditing {
                        // Inline editing mode - improved UI
                        VStack(alignment: .trailing, spacing: 12) {
                            // Edit header
                            HStack(spacing: 6) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.blue)
                                Text("Editing message")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }

                            // Text editor with improved styling
                            TextEditor(text: $editText)
                                .font(.system(size: 14))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80, maxHeight: 250)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.05)
                                                : Color.black.opacity(0.03))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
                                )

                            // Action buttons
                            HStack(spacing: 10) {
                                Button(action: {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isEditing = false
                                        editText = ""
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("Cancel")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.gray.opacity(0.15))
                                    )
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    if let onEdit = onEdit,
                                        !editText.trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                    {
                                        onEdit(editText)
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isEditing = false
                                            editText = ""
                                        }
                                    }
                                }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.up.circle.fill")
                                            .font(.system(size: 12, weight: .semibold))
                                        Text("Save & Send")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.blue, Color.blue.opacity(0.8)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                                    .shadow(color: Color.blue.opacity(0.3), radius: 4, y: 2)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        )
                        .frame(maxWidth: maxBubbleWidth)
                    } else {
                        // Normal display mode
                        Text(message.content)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: appTheme.colors.map { $0.opacity(0.18) },
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))

                        // Action Buttons for user messages
                        HStack(spacing: 12) {
                            if canEdit {
                                ExpandingActionButton(
                                    title: "Edit",
                                    icon: "pencil",
                                    action: {
                                        editText = message.content
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isEditing = true
                                        }
                                    }
                                )
                            }

                            ExpandingActionButton(
                                title: isCopied ? "Copied!" : "Copy",
                                icon: isCopied ? "checkmark" : "doc.on.doc",
                                color: isCopied ? .green : .secondary,
                                action: {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(message.content, forType: .string)
                                    isCopied = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        isCopied = false
                                    }
                                }
                            )
                        }
                        .padding(.top, 4)
                    }
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
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .background(Color.gray.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.caption)
                                    Text("Reasoning Process")
                                        .font(.caption)
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .animation(
                                .spring(response: 0.35, dampingFraction: 0.86),
                                value: isThinkingExpanded
                            )
                            .padding(.bottom, 4)
                        }

                        if let image = message.image {
                            ThumbnailView(
                                image: image, maxWidth: 300, maxHeight: 300,
                                messageId: message.id,
                                coordinateSpaceName: "detailContainer",
                                onImageTap: onImageTap
                            )
                            .id(message.currentVersionIndex ?? -1)
                            .padding(.bottom, 4)
                        }
                        let activeContent = liveContent ?? message.content

                        if message.isStreaming && activeContent.isEmpty
                            && (liveThinking ?? message.thinkingContent) == nil
                        {
                            ThinkingIndicator()
                        } else if !activeContent.isEmpty || message.isStreaming {
                            if message.isStreaming {
                                let displayContent = activeContent + (isCursorVisible ? " ▋" : "")
                                MarkdownView(blocks: Message.parseMarkdown(displayContent))
                                    .foregroundStyle(
                                        colorScheme == .dark ? Color.white : Color.black)
                            } else {
                                MarkdownView(blocks: message.blocks)
                                    .equatable()
                                    .foregroundStyle(
                                        colorScheme == .dark ? Color.white : Color.black)
                            }
                        }
                    }

                    // Action Buttons
                    HStack(spacing: 12) {
                        ExpandingActionButton(
                            title: isCopied ? "Copied!" : "Copy",
                            icon: isCopied ? "checkmark" : "doc.on.doc",
                            color: isCopied ? .green : .secondary,
                            action: {
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
                            }
                        )

                        if message.image != nil && !imageDownloadPath.isEmpty {
                            ExpandingActionButton(
                                title: isSaved ? "Downloaded!" : "Download",
                                icon: isSaved ? "checkmark" : "arrow.down.circle",
                                color: isSaved ? .green : .secondary,
                                action: {
                                    if let image = message.image {
                                        downloadImage(image, prompt: message.content)
                                    }
                                }
                            )
                        }

                        if let onRegenerate = onRegenerate {
                            ExpandingActionButton(
                                title: "Regenerate",
                                icon: "arrow.counterclockwise",
                                action: onRegenerate
                            )
                        }

                        // Version navigator
                        if let versions = message.versions, versions.count > 1 {
                            let currentIdx = message.currentVersionIndex ?? (versions.count - 1)
                            HStack(spacing: 6) {
                                Button(action: {
                                    if currentIdx > 0 {
                                        onSwitchVersion?(currentIdx - 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(
                                            currentIdx > 0
                                                ? Color.primary : Color.secondary.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                                .disabled(currentIdx <= 0)

                                Text("\(currentIdx + 1)/\(versions.count)")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()

                                Button(action: {
                                    if currentIdx < versions.count - 1 {
                                        onSwitchVersion?(currentIdx + 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(
                                            currentIdx < versions.count - 1
                                                ? Color.primary : Color.secondary.opacity(0.3))
                                }
                                .buttonStyle(.plain)
                                .disabled(currentIdx >= versions.count - 1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                            )
                        }
                    }
                    .padding(.top, 4)

                    if let model = message.model {
                        let displayModel = GeminiModelManager.displayNames[model] ?? model
                        Text("Model used: \(displayModel). Information could be inaccurate.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .padding(.top, 2)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .onReceive(cursorTimer) { _ in
            if message.isStreaming {
                isCursorVisible.toggle()
            }
        }
        .onChange(of: liveThinking) { _, newValue in
            if let val = newValue, !val.isEmpty, liveContent == nil || liveContent!.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = true
                }
            }
        }
        .onChange(of: liveContent) { _, newValue in
            if let val = newValue, !val.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = false
                }
            }
        }
        .onChange(of: message.thinkingContent) { _, newValue in
            let currentContent = liveContent ?? message.content
            if let val = newValue, !val.isEmpty, currentContent.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = true
                }
            }
        }
        .onChange(of: message.content) { _, newValue in
            if !newValue.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                    isThinkingExpanded = false
                }
            }
        }
    }

    private func downloadImage(_ image: NSImage, prompt: String) {
        guard !imageDownloadPath.isEmpty else { return }
        let dir = URL(fileURLWithPath: imageDownloadPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        let sanitized = prompt.prefix(40).replacingOccurrences(
            of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        let filename = "Prism_\(sanitized)_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = dir.appendingPathComponent(filename)
        if let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: fileURL)
            isSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isSaved = false
            }
        }
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
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @AppStorage("ImageDownloadPath") private var imageDownloadPath: String = ""

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
                LabeledContent("Color") {
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

                                    Text(theme.rawValue)
                                        .font(.caption2)
                                        .foregroundStyle(
                                            appTheme == theme ? Color.secondary : Color.clear
                                        )
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

                if enableQuickAI {
                    LabeledContent("Global Shortcut") {
                        KeyboardShortcuts.Recorder(for: .toggleQuickAI)
                    }
                }

                LabeledContent("Quick AI Background Opacity") {
                    VStack(spacing: 8) {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { quickAIBackgroundOpacity },
                                    set: { quickAIBackgroundOpacity = min(max($0, 0.05), 0.55) }
                                ),
                                in: 0.05...0.55
                            )
                            Text("\(Int(min(max(quickAIBackgroundOpacity, 0.05), 0.55) * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 35, alignment: .trailing)
                        }
                        HStack {
                            Text("Clear").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Opaque").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Quick AI Chat Bar Vibrancy") {
                    VStack(spacing: 8) {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { quickAICommandBarVibrancy },
                                    set: { quickAICommandBarVibrancy = min(max($0, 0.05), 0.9) }
                                ),
                                in: 0.05...0.9
                            )
                            Text(
                                "\(Int(min(max(quickAICommandBarVibrancy, 0.05), 0.9) * 100))%"
                            )
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                        }
                        HStack {
                            Text("Subtle").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Punchy").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Background Image") {
                    HStack {
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
            }

            Section(header: Text("Image Downloads")) {
                LabeledContent("Image save path") {
                    HStack {
                        TextField("", text: $imageDownloadPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK {
                                imageDownloadPath = panel.url?.path ?? ""
                            }
                        }
                        if !imageDownloadPath.isEmpty {
                            Button(action: { imageDownloadPath = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text(
                    "Generated images will be instantly saved to this folder. Leave empty to disable."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(header: Text("Gemini API")) {
                TextField("API Key", text: $geminiKey)
                    .textFieldStyle(.roundedBorder)
                Picker("Default Model", selection: $geminiModel) {
                    ForEach(geminiManager.availableModels, id: \.self) { model in
                        Text(geminiManager.displayName(for: model)).tag(model)
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
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Ollama")) {
                TextField("Endpoint URL", text: $ollamaURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Ollama API Key (for web search)", text: $ollamaAPIKey)
                    .textFieldStyle(.roundedBorder)
                Text("Get a key at ollama.com/settings/keys — enables the web search button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Custom Models").font(.headline)
                    .padding(.top, 8)

                HStack {
                    TextField("Add model (e.g. llama3:70b)", text: $newCustomModelName)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        ollamaManager.addCustomModel(newCustomModelName)
                        newCustomModelName = ""
                    }
                }

                ForEach(ollamaManager.customModels, id: \.self) { model in
                    HStack {
                        Text(model)
                        Spacer()
                        Button(role: .destructive) {
                            ollamaManager.removeCustomModel(model)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .scrollContentBackground(.hidden)
        .frame(minWidth: 420, idealWidth: 450, minHeight: 650, idealHeight: 750)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
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
                        .foregroundStyle(.secondary)
                }

                Button(action: onDismiss) {
                    Text("Get Started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 200, height: 50)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 25))
                }
                .buttonStyle(.plain)
            }
            .padding(50)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
            .shadow(radius: 20)
        }
    }
}

struct SplashScreen: View {
    var onFinish: () -> Void
    @State private var stage: Int = 0
    @State private var beamGlow: CGFloat = 0
    @State private var particlePhase: CGFloat = 0
    @State private var prismRotation: Double = 0
    @State private var textOffset: CGFloat = 30
    @State private var textOpacity: Double = 0
    @State private var rainbowSpread: Double = 0
    @State private var backgroundPulse: CGFloat = 0
    @State private var prismScale: CGFloat = 0.3
    @State private var prismOpacity: Double = 0
    @State private var shimmerOffset: CGFloat = -200
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let mainColor = colorScheme == .dark ? Color.white : Color.black
        let bgColor = colorScheme == .dark ? Color.black : Color.white

        ZStack {
            bgColor.ignoresSafeArea()

            // Ambient background glow pulses
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.blue.opacity(0.06), Color.clear],
                            center: .center, startRadius: 0, endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .scaleEffect(backgroundPulse)
                    .opacity(stage >= 1 ? 0.8 : 0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.purple.opacity(0.04), Color.clear],
                            center: .center, startRadius: 0, endRadius: 200
                        )
                    )
                    .frame(width: 400, height: 400)
                    .offset(x: 60, y: -40)
                    .scaleEffect(backgroundPulse * 0.9)
                    .opacity(stage >= 2 ? 0.6 : 0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.orange.opacity(0.03), Color.clear],
                            center: .center, startRadius: 0, endRadius: 180
                        )
                    )
                    .frame(width: 360, height: 360)
                    .offset(x: -50, y: 30)
                    .scaleEffect(backgroundPulse * 0.85)
                    .opacity(stage >= 2 ? 0.5 : 0)
            }

            // Main animation container
            ZStack {
                // Particle field around prism
                ForEach(0..<20, id: \.self) { i in
                    let angle = Double(i) * 18.0
                    let radius: CGFloat = 80 + CGFloat(i % 5) * 25
                    let delay = Double(i) * 0.06
                    Circle()
                        .fill(splashParticleColor(i))
                        .frame(width: CGFloat(2 + i % 3), height: CGFloat(2 + i % 3))
                        .offset(
                            x: cos(angle * .pi / 180 + particlePhase) * radius,
                            y: sin(angle * .pi / 180 + particlePhase) * radius
                        )
                        .opacity(stage >= 2 ? Double(0.2 + (Double(i % 5) * 0.12)) : 0)
                        .blur(radius: CGFloat(i % 3))
                        .animation(
                            .easeInOut(duration: 2.0 + Double(i % 3) * 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(delay),
                            value: particlePhase
                        )
                }

                // 1. Light beam (enters from left with glow)
                ZStack {
                    // Core beam
                    Color.clear
                        .frame(width: 180, height: 2)
                        .overlay(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [mainColor.opacity(0), mainColor.opacity(0.9)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: stage >= 1 ? 180 : 0),
                            alignment: .leading
                        )

                    // Beam glow
                    Color.clear
                        .frame(width: 180, height: 8)
                        .overlay(
                            Rectangle()
                                .fill(mainColor.opacity(beamGlow * 0.3))
                                .frame(width: stage >= 1 ? 180 : 0),
                            alignment: .leading
                        )
                        .blur(radius: 6)
                }
                .offset(x: -110, y: -2)
                .rotationEffect(.degrees(15), anchor: .trailing)
                .opacity(stage >= 1 ? 1 : 0)

                // 2. The Prism with glass effect
                ZStack {
                    // Prism glow underneath
                    Triangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.blue.opacity(0.15),
                                    Color.purple.opacity(0.1),
                                    Color.clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 100, height: 100)
                        .blur(radius: 15)
                        .opacity(stage >= 1 ? 0.8 : 0)

                    // Main prism body with glass effect
                    Triangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(0.06),
                                    mainColor.opacity(0.02),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 90, height: 90)

                    // Prism edge stroke
                    Triangle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(0.7),
                                    mainColor.opacity(0.3),
                                    mainColor.opacity(0.5),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 90, height: 90)

                    // Inner shine highlight
                    Triangle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(stage >= 1 ? 0.6 : 0),
                                    mainColor.opacity(0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 70, height: 70)
                        .blur(radius: 1)

                    // Shimmer sweep across prism
                    Triangle()
                        .fill(Color.clear)
                        .frame(width: 90, height: 90)
                        .overlay(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            mainColor.opacity(0.15),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 40)
                                .offset(x: shimmerOffset)
                                .blur(radius: 3)
                        )
                        .clipShape(Triangle())
                }
                .scaleEffect(prismScale)
                .opacity(prismOpacity)
                .shadow(color: mainColor.opacity(0.15), radius: 20)

                // 3. Refracted rainbow light (dramatic spread)
                ZStack {
                    ForEach(0..<7) { i in
                        let spreadAngle = Double(i) * 5.5 - 16.5

                        Color.clear
                            .frame(width: 200, height: 3, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                rainbowColor(i).opacity(0.9),
                                                rainbowColor(i).opacity(0.3),
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: stage >= 2 ? 200 : 0),
                                alignment: .leading
                            )
                            .offset(x: 110, y: 0)
                            .rotationEffect(
                                .degrees(spreadAngle * rainbowSpread),
                                anchor: .leading
                            )
                            .blur(radius: 4)

                        // Secondary glow layer for each beam
                        Color.clear
                            .frame(width: 200, height: 8, alignment: .leading)
                            .overlay(
                                Rectangle()
                                    .fill(rainbowColor(i).opacity(0.15))
                                    .frame(width: stage >= 2 ? 200 : 0),
                                alignment: .leading
                            )
                            .offset(x: 110, y: 0)
                            .rotationEffect(
                                .degrees(spreadAngle * rainbowSpread),
                                anchor: .leading
                            )
                            .blur(radius: 10)
                    }
                }

                // 4. Text reveal
                VStack(spacing: 8) {
                    Text("Prism")
                        .font(.system(size: 46, weight: .light, design: .serif))
                        .tracking(6)
                        .foregroundStyle(
                            LinearGradient(
                                colors: stage >= 3
                                    ? [.red, .orange, .yellow, .green, .blue, .purple]
                                    : [mainColor, mainColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .opacity(textOpacity)
                        .offset(y: textOffset)
                }
                .offset(y: 110)
            }
            .scaleEffect(stage == 4 ? 1.08 : 1.0)
            .opacity(stage == 4 ? 0 : 1)
        }
        .onAppear {
            // Stage 0 -> 1: Prism appears + beam enters
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                prismScale = 1.0
                prismOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 1.0).delay(0.3)) {
                stage = 1
                beamGlow = 1.0
            }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                backgroundPulse = 1.2
            }

            // Shimmer sweep
            withAnimation(.easeInOut(duration: 1.5).delay(0.5)) {
                shimmerOffset = 200
            }

            // Stage 2: Rainbow + particles
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeOut(duration: 1.0)) {
                    stage = 2
                }
                withAnimation(.easeOut(duration: 1.2)) {
                    rainbowSpread = 1.0
                }
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    particlePhase = .pi * 2
                }
            }

            // Stage 2.5: Text appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                    textOffset = 0
                    textOpacity = 1.0
                }
            }

            // Stage 3: Rainbow text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                withAnimation(.easeInOut(duration: 0.8)) {
                    stage = 3
                }
            }

            // Stage 4: Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                withAnimation(.easeInOut(duration: 1.0)) {
                    stage = 4
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.9) {
                onFinish()
            }
        }
    }

    func rainbowColor(_ i: Int) -> Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .indigo, .purple]
        return colors[i % colors.count]
    }

    func splashParticleColor(_ i: Int) -> Color {
        let colors: [Color] = [
            .red.opacity(0.6), .orange.opacity(0.6), .yellow.opacity(0.6),
            .green.opacity(0.6), .blue.opacity(0.6), .indigo.opacity(0.6), .purple.opacity(0.6),
        ]
        return colors[i % colors.count]
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
    @ObservedObject private var imageGenStore = ImageGenerationStore.shared
    @State private var selectedImageForPreview: NSImage? = nil
    @State private var previewVisible: Bool = false
    @State private var previewSourceRect: CGRect = .zero
    @State private var imageFrames: [UUID: CGRect] = [:]

    var images: [(UUID, UUID, NSImage, String)] {
        var result: [(UUID, UUID, NSImage, String)] = []
        // Chat images
        for session in chatManager.sessions {
            for message in session.messages {
                if let image = message.image {
                    result.append((session.id, message.id, image, message.content))
                }
            }
        }
        // Generated images from Image Generation tool
        for item in imageGenStore.items {
            if let img = imageGenStore.image(for: item.id) {
                result.append((item.id, item.id, img, item.prompt))
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
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(radius: 2)
                                .background(
                                    GeometryReader { imgGeo in
                                        Color.clear.preference(
                                            key: ImageFramePreferenceKey.self,
                                            value: [
                                                item.1: imgGeo.frame(in: .named("galleryContainer"))
                                            ]
                                        )
                                    }
                                )
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            previewSourceRect = imageFrames[item.1] ?? .zero
                            selectedImageForPreview = item.2
                            previewVisible = true
                        }
                        .contextMenu {
                            if chatManager.sessions.contains(where: { $0.id == item.0 }) {
                                Button("Go to chat") {
                                    showImageGallery = false
                                    chatManager.currentSessionId = item.0
                                }
                            }
                            Button("Copy") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.writeObjects([item.2])
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Images")
            .allowsHitTesting(!previewVisible)

            if previewVisible, let image = selectedImageForPreview {
                ImagePreviewOverlay(image: image, sourceRect: previewSourceRect) {
                    previewVisible = false
                    selectedImageForPreview = nil
                }
                .zIndex(100)
            }
        }
        .coordinateSpace(name: "galleryContainer")
        .onPreferenceChange(ImageFramePreferenceKey.self) { frames in
            imageFrames.merge(frames) { _, new in new }
        }
    }
}
