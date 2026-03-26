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

struct CustomWebView: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var icon: String? = nil
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
            _cachedBlocks = Message.parseMarkdown(content)
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
                    // Skip agent-action blocks entirely — they are internal
                    // browser automation instructions, not user-visible code
                    if codeLanguage != "agent-action" {
                        blocks.append(
                            MarkdownBlock(
                                type: .code(
                                    codeBlockContent.trimmingCharacters(in: .newlines), codeLanguage
                                )))
                    }
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
            } else if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
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
                    if nextLine.hasPrefix("|") && isMarkdownTableSeparator(nextLine) {
                        // It is a table
                        let headers = parseMarkdownTableRow(trimmedLine)
                        var rows: [[String]] = []

                        // Skip header and separator
                        i += 2

                        while i < lines.count {
                            let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                            if !rowLine.hasPrefix("|") {
                                i -= 1  // Backtrack so main loop processes this line
                                break
                            }
                            let cells = parseMarkdownTableRow(rowLine)
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

    // Parses a markdown table row while preserving empty cells and escaped pipes.
    private static func parseMarkdownTableRow(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var escaping = false

        for ch in normalized {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }

            if ch == "\\" {
                escaping = true
                continue
            }

            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }

        if escaping {
            current.append("\\")
        }

        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // Matches separator rows like |---|:---:|---:| used in markdown tables.
    private static func isMarkdownTableSeparator(_ line: String) -> Bool {
        let cells = parseMarkdownTableRow(line)
        guard !cells.isEmpty else { return false }

        for cell in cells {
            let token = cell.replacingOccurrences(of: " ", with: "")
            if token.isEmpty { return false }
            if token.range(of: "^:?-{3,}:?$", options: .regularExpression) == nil {
                return false
            }
        }
        return true
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
        let currentSessions = sessions
        let url = savePath
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(currentSessions) {
                try? data.write(to: url)
            }
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
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func search(query: String, maxResults: Int = 5) async throws
        -> [WebSearchResult]
    {
        // Use DuckDuckGo Instant Answer API (free, no API key required)
        guard
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(
                string:
                    "https://api.duckduckgo.com/?q=\(encodedQuery)&format=json&no_html=1&skip_disambig=1"
            )
        else {
            throw URLError(.badURL)
        }

        let (data, _) = try await session.data(for: URLRequest(url: url))

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var results: [WebSearchResult] = []

        // Add abstract if available
        if let abstract = json["AbstractText"] as? String, !abstract.isEmpty,
            let source = json["AbstractSource"] as? String,
            let abstractURL = json["AbstractURL"] as? String
        {
            results.append(WebSearchResult(title: source, url: abstractURL, content: abstract))
        }

        // Add direct answer if available
        if let answer = json["Answer"] as? String, !answer.isEmpty {
            results.append(WebSearchResult(title: "Direct Answer", url: "", content: answer))
        }

        // Add related topics
        if let topics = json["RelatedTopics"] as? [[String: Any]] {
            for topic in topics where results.count < maxResults {
                if let text = topic["Text"] as? String, !text.isEmpty,
                    let firstURL = topic["FirstURL"] as? String
                {
                    let title = String(text.prefix(100))
                    results.append(WebSearchResult(title: title, url: firstURL, content: text))
                }
            }
        }

        // If instant answers didn't return enough, try HTML search
        if results.isEmpty
            || (results.count < 2 && results.first.map({ $0.content.count < 50 }) ?? true)
        {
            let htmlResults = try await searchHTML(query: query, maxResults: maxResults)
            results.append(contentsOf: htmlResults)
        }

        return Array(results.prefix(maxResults))
    }

    /// Fallback: fetch search results from DuckDuckGo's HTML endpoint
    private func searchHTML(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        guard
            let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encodedQuery)")
        else { return [] }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)",
            forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        else { return [] }

        var results: [WebSearchResult] = []

        // Parse result links: <a ... class="result__a" href="URL">Title</a>
        let linkPattern = try NSRegularExpression(
            pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            options: [])
        // Parse snippets: <a ... class="result__snippet" ...>Snippet</a>
        let snippetPattern = try NSRegularExpression(
            pattern: #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators])

        let range = NSRange(html.startIndex..., in: html)
        let linkMatches = linkPattern.matches(in: html, range: range)
        let snippetMatches = snippetPattern.matches(in: html, range: range)

        for (i, match) in linkMatches.prefix(maxResults).enumerated() {
            guard let urlRange = Range(match.range(at: 1), in: html),
                let titleRange = Range(match.range(at: 2), in: html)
            else { continue }

            let resultUrl = String(html[urlRange])
            let rawTitle = String(html[titleRange])
            let title =
                rawTitle
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            var snippet = title
            if i < snippetMatches.count,
                let snippetRange = Range(snippetMatches[i].range(at: 1), in: html)
            {
                let rawSnippet = String(html[snippetRange])
                let cleaned =
                    rawSnippet
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { snippet = cleaned }
            }

            if !title.isEmpty {
                results.append(WebSearchResult(title: title, url: resultUrl, content: snippet))
            }
        }

        return results
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
            "[End of Web Search Results]\n\nUse the above web search results to inform your answer. If you reference a source, mention it naturally by name or URL in your text. NEVER use bracket citation syntax like 【1†L2-L5】 or [1†source] or any similar notation. Do NOT attempt to call any functions or tools — the search results above are all you need."
        return context
    }
}

class OllamaService {
    private let session: URLSession

    /// Known model name patterns that indicate image generation (use /api/generate, not /api/chat).
    static func isImageGenerationModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        // Match known image generation model families
        return lower.contains("flux")
            || lower.contains("z-image")
            || lower.contains("stable-diffusion")
            || lower.contains("sdxl")
            || lower.contains("sd3")
            || lower.hasPrefix("x/")
    }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Generate an image using Ollama's /api/generate endpoint.
    /// Returns an AsyncThrowingStream that yields progress strings and then the final image data.
    func generateImage(
        prompt: String, endpoint: String, model: String
    ) -> AsyncThrowingStream<(String?, Data?), Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let baseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let url = URL(string: "\(baseURL)/api/generate") else {
                    continuation.finish(throwing: URLError(.badURL))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 300

                let body: [String: Any] = [
                    "model": model,
                    "prompt": prompt,
                    "stream": true,
                ]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (result, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }

                    if httpResponse.statusCode != 200 {
                        var errorMsg = ""
                        for try await line in result.lines {
                            errorMsg += line
                        }
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

                        // Check for progress updates
                        if let completed = json["completed"] as? Int,
                            let total = json["total"] as? Int,
                            total > 0
                        {
                            let progress = "Generating image... \(completed)/\(total)"
                            continuation.yield((progress, nil))
                        }

                        // Check for final image
                        if let done = json["done"] as? Bool, done {
                            if let base64Image = json["image"] as? String,
                                let imageData = Data(base64Encoded: base64Image)
                            {
                                continuation.yield((nil, imageData))
                            }
                            break
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Compress and resize image data to fit within Ollama's request body limits.
    /// Returns a JPEG-compressed base64 string, downscaled if needed.
    private func compressImageForOllama(_ data: Data, maxDimension: CGFloat = 1024) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return nil }

        // Calculate scale factor to fit within maxDimension
        let scale = min(1.0, min(maxDimension / size.width, maxDimension / size.height))
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        // Draw resized image
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy, fraction: 1.0)
        resized.unlockFocus()

        // Convert to JPEG
        guard let tiff = resized.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { return nil }

        return jpeg.base64EncodedString()
    }

    func sendMessageStream(
        history: [Message], endpoint: String, model: String, systemPrompt: String = "",
        thinkingLevel: String = "medium",
        webSearchEnabled: Bool = false,
        webSearchService: WebSearchService? = nil
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
                    messages.append([
                        "role": "system",
                        "content":
                            "You are a helpful AI assistant. Please think and respond in English.",
                    ])
                }

                messages.append(
                    contentsOf: history.map { msg in
                        var content = msg.content
                        var images: [String] = []

                        // Only attach images for user messages — Ollama rejects images on assistant role
                        if msg.isUser {
                            if let data = msg.imageData,
                                let compressed = self.compressImageForOllama(data)
                            {
                                images.append(compressed)
                            }

                            // Also read from attachments array (used by extension screenshots)
                            if let attachments = msg.attachments {
                                for att in attachments where att.type == "image" {
                                    if let compressed = self.compressImageForOllama(att.data) {
                                        images.append(compressed)
                                    }
                                }
                            }
                        }

                        // Extract text from PDFs rather than sending raw bytes (Ollama expects image formats, not PDF)
                        if let pdfData = msg.pdfData {
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

                        var message: [String: Any] = [
                            "role": msg.isUser ? "user" : "assistant",
                            "content": content,
                        ]

                        if !images.isEmpty {
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

                // Add web search tool definition when enabled
                if webSearchEnabled && webSearchService != nil {
                    body["tools"] = [
                        [
                            "type": "function",
                            "function": [
                                "name": "web_search",
                                "description":
                                    "Search the web for current information about any topic",
                                "parameters": [
                                    "type": "object",
                                    "properties": [
                                        "query": [
                                            "type": "string",
                                            "description": "The search query",
                                        ]
                                    ],
                                    "required": ["query"],
                                ],
                            ] as [String: Any],
                        ] as [String: Any]
                    ]
                }

                // Apply native thinking parameter
                if lowerModel.contains("gpt-oss") {
                    body["think"] = thinkingLevel
                } else if lowerModel.contains("deepseek") || lowerModel.contains("r1") {
                    // Note: We removed 'qwen' from here as qwen models (like qwen3-coder) generally don't support top-level 'think' param in Ollama
                    // and sending it causes a 400 Bad Request.
                    if thinkingLevel == "high" {
                        body["think"] = true
                    }
                }

                // Tool calling loop — allows up to 3 rounds of tool use
                var toolRound = 0
                let maxToolRounds = 3

                do {
                    while toolRound < maxToolRounds {
                        toolRound += 1

                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (result, response) = try await self.session.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: URLError(.badServerResponse))
                            return
                        }

                        if httpResponse.statusCode != 200 {
                            var errorMsg = ""
                            for try await line in result.lines {
                                errorMsg += line
                            }
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

                        var pendingToolCalls: [[String: Any]]? = nil

                        for try await line in result.lines {
                            guard let data = line.data(using: .utf8),
                                let json = try? JSONSerialization.jsonObject(with: data)
                                    as? [String: Any]
                            else { continue }

                            if let done = json["done"] as? Bool, done {
                                if let message = json["message"] as? [String: Any] {
                                    // Check for tool calls on the final message
                                    if let calls = message["tool_calls"] as? [[String: Any]],
                                        !calls.isEmpty
                                    {
                                        pendingToolCalls = calls
                                    }
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

                            // Check for tool calls in streaming chunks
                            if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty
                            {
                                if pendingToolCalls != nil {
                                    pendingToolCalls!.append(contentsOf: calls)
                                } else {
                                    pendingToolCalls = calls
                                }
                            }

                            let content = message["content"] as? String
                            let thinking = message["thinking"] as? String

                            if let thinking = thinking, !thinking.isEmpty {
                                continuation.yield(("", thinking))
                            }
                            if let content = content, !content.isEmpty {
                                continuation.yield((content, nil))
                            }
                        }

                        // If no tool calls or no search service, we're done
                        guard let toolCalls = pendingToolCalls,
                            let searchService = webSearchService,
                            webSearchEnabled
                        else {
                            break
                        }

                        // Execute tool calls and build tool response messages
                        messages.append([
                            "role": "assistant",
                            "content": "",
                            "tool_calls": toolCalls,
                        ])

                        for call in toolCalls {
                            guard let function = call["function"] as? [String: Any],
                                let name = function["name"] as? String,
                                name == "web_search"
                            else { continue }

                            // Parse arguments (may be dict or JSON string)
                            let args: [String: Any]
                            if let a = function["arguments"] as? [String: Any] {
                                args = a
                            } else if let argsStr = function["arguments"] as? String,
                                let argsData = argsStr.data(using: .utf8),
                                let a = try? JSONSerialization.jsonObject(with: argsData)
                                    as? [String: Any]
                            {
                                args = a
                            } else {
                                continue
                            }

                            if let query = args["query"] as? String {
                                do {
                                    let results = try await searchService.search(query: query)
                                    let context = searchService.buildSearchContext(results: results)
                                    messages.append([
                                        "role": "tool",
                                        "content": context.isEmpty
                                            ? "No results found for: \(query)" : context,
                                    ])
                                } catch {
                                    messages.append([
                                        "role": "tool",
                                        "content":
                                            "Web search failed: \(error.localizedDescription)",
                                    ])
                                }
                            }
                        }

                        // Update body with extended messages; remove tools on last round
                        body["messages"] = messages
                        if toolRound >= maxToolRounds - 1 {
                            body.removeValue(forKey: "tools")
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
        thinkingLevel: String = "medium", imageResolution: String = "1K",
        imageAspectRatio: String = ""
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

                    var finalContent = msg.content
                    if isImageModel && !systemPrompt.isEmpty {
                        finalContent = systemPrompt + "\n\n" + msg.content
                    }

                    if !finalContent.isEmpty {
                        parts.append(["text": finalContent])
                    }

                    // Add all attachments (images and PDFs)
                    if let attachments = msg.attachments, !attachments.isEmpty {
                        for att in attachments {
                            if att.type == "image", NSImage(data: att.data) != nil {
                                let base64 = att.data.base64EncodedString()
                                parts.append([
                                    "inline_data": [
                                        "mime_type": "image/jpeg",
                                        "data": base64,
                                    ]
                                ])
                            } else if att.type == "pdf" {
                                let base64 = att.data.base64EncodedString()
                                parts.append([
                                    "inline_data": [
                                        "mime_type": "application/pdf",
                                        "data": base64,
                                    ]
                                ])
                            }
                        }
                    } else {
                        // Legacy fallback for messages without attachments array
                        if let data = msg.imageData, NSImage(data: data) != nil {
                            let base64 = data.base64EncodedString()
                            parts.append([
                                "inline_data": [
                                    "mime_type": "image/jpeg",
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

                if !systemPrompt.isEmpty && !isImageModel {
                    body["system_instruction"] = [
                        "parts": [
                            ["text": systemPrompt]
                        ]
                    ]
                }

                // Enable image output for image-capable models
                if isImageModel {
                    var imageGenConfig: [String: Any] = [
                        "responseModalities": ["TEXT", "IMAGE"]
                    ]
                    // Build imageConfig with resolution and aspect ratio
                    var imageConfig: [String: Any] = [:]
                    let resolutionMap: [String: String] = [
                        "0.5K": "512px", "1K": "1K", "2K": "2K", "4K": "4K",
                    ]
                    if let res = resolutionMap[imageResolution] {
                        imageConfig["imageSize"] = res
                    }
                    if !imageAspectRatio.isEmpty && imageAspectRatio != "Default"
                        && modelName != "gemini-2.0-flash-exp-image-generation"
                    {
                        imageConfig["aspectRatio"] = imageAspectRatio
                    }
                    if !imageConfig.isEmpty {
                        imageGenConfig["imageConfig"] = imageConfig
                    }
                    // Add thinking config for image models
                    let lowerImg = modelName.lowercased()
                    if lowerImg.contains("3.1-flash-image") {
                        // Gemini 3.1 Flash Image supports minimal/high
                        let level = (thinkingLevel.lowercased() == "high") ? "HIGH" : "MINIMAL"
                        imageGenConfig["thinkingConfig"] =
                            [
                                "thinkingLevel": level,
                                "includeThoughts": true,
                            ] as [String: Any]
                    } else if lowerImg.contains("3-pro-image") {
                        // Gemini 3 Pro Image: thinking always on
                        imageGenConfig["thinkingConfig"] =
                            [
                                "includeThoughts": true
                            ] as [String: Any]
                    }
                    body["generationConfig"] = imageGenConfig
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

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection

            if let window = webView.window {
                openPanel.beginSheetModal(for: window) { response in
                    if response == .OK {
                        completionHandler(openPanel.urls)
                    } else {
                        completionHandler(nil)
                    }
                }
            } else {
                let response = openPanel.runModal()
                if response == .OK {
                    completionHandler(openPanel.urls)
                } else {
                    completionHandler(nil)
                }
            }
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

private enum WebViewPillSnapPoint: String, CaseIterable {
    case topLeading
    case top
    case topTrailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading:
            return .topLeading
        case .top:
            return .top
        case .topTrailing:
            return .topTrailing
        case .bottomLeading:
            return .bottomLeading
        case .bottom:
            return .bottom
        case .bottomTrailing:
            return .bottomTrailing
        }
    }

    func edgeInsets(base: CGFloat) -> EdgeInsets {
        switch self {
        case .topLeading:
            return EdgeInsets(top: base, leading: base, bottom: 0, trailing: 0)
        case .top:
            return EdgeInsets(top: base, leading: 0, bottom: 0, trailing: 0)
        case .topTrailing:
            return EdgeInsets(top: base, leading: 0, bottom: 0, trailing: base)
        case .bottomLeading:
            return EdgeInsets(top: 0, leading: base, bottom: base, trailing: 0)
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: base, trailing: 0)
        case .bottomTrailing:
            return EdgeInsets(top: 0, leading: 0, bottom: base, trailing: base)
        }
    }
}

struct ContentView: View {
    @ObservedObject private var chatManager = ChatManager.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var inputText: String = ""
    @State private var selectedAttachments: [Attachment] = []
    // Legacy single selection states removed/replaced
    @State private var isLoading: Bool = false
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @AppStorage("GeminiThinkingLevel") private var geminiThinkingLevel: String = "auto"
    @AppStorage("GeminiImageResolution") private var geminiImageResolution: String = "1K"
    @AppStorage("GeminiImageAspectRatio") private var geminiImageAspectRatio: String = "Default"
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
    @AppStorage("ShowSplashScreen") private var showSplashScreenPref: Bool = true
    @State private var showSplash: Bool =
        !AppState.shared.hasShownSplash
        && UserDefaults.standard.object(forKey: "ShowSplashScreen") as? Bool ?? true
    @State private var currentTask: Task<Void, Never>?
    @State private var showImageGallery: Bool = false
    @State private var showModelComparison: Bool = false
    @State private var showCommands: Bool = false
    @State private var showQuizMe: Bool = false
    @State private var showImageGen: Bool = false
    @State private var showFileCreator: Bool = false
    @State private var showFolderContext: Bool = false
    @State private var showWebView: Bool = false
    @State private var showBrowserAutomation: Bool = false
    @AppStorage("ToolSelectedWebView") private var toolSelectedWebView: String = "ChatGPT Web"
    @AppStorage("WebViewPillSnapPoint") private var webViewPillSnapPointRaw: String =
        WebViewPillSnapPoint.topTrailing.rawValue
    @AppStorage("ActiveToolName") private var activeToolName: String = ""
    @AppStorage("CustomWebViews") private var customWebViewsJSON: String = "[]"
    @AppStorage("SelectedCustomWebViewURL") private var selectedCustomWebViewURL: String = ""
    @State private var webViewPillSize: CGSize = .zero
    @GestureState private var webViewPillDragOffset: CGSize = .zero
    @State private var streamBuffer: [UUID: String] = [:]  // live text per message
    @State private var streamThinkingBuffer: [UUID: String] = [:]  // live reasoning per message
    @State private var streamingMessageId: UUID? = nil  // currently streaming message for scroll tracking
    @State private var chatPreviewImage: NSImage? = nil
    @State private var chatPreviewVisible: Bool = false
    @State private var chatPreviewSourceRect: CGRect = .zero
    @State private var scrollWorkItem: DispatchWorkItem?  // throttle streaming scroll

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let nvidiaService = NvidiaService()
    private let webSearchService = WebSearchService()
    private let shortcutService = ShortcutService()
    private let appleFoundationService = AppleFoundationService()

    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String =
        "llama-3.1-70b-instruct"
    @AppStorage("SelectedCopilotModel") private var selectedCopilotModel: String = "gpt-4o"
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared

    var thinkingMode: ThinkingMode {
        if selectedProvider == "Gemini API" || selectedProvider.hasPrefix("Gemini API|") {
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
        } else if selectedProvider == "NVIDIA API" || selectedProvider.hasPrefix("NVIDIA API|") {
            let lower = selectedNvidiaModel.lowercased()
            if lower.contains("deepseek") || lower.contains("glm") {
                return .binary  // On/Off
            }
            return .none
        }
        return .none
    }

    /// Returns a binding to the correct thinking level storage based on the current provider
    var activeThinkingLevel: Binding<String> {
        if selectedProvider == "Gemini API" || selectedProvider.hasPrefix("Gemini API|") {
            return $geminiThinkingLevel
        } else {
            return $thinkingLevel
        }
    }

    private var webViewPillSnapPoint: WebViewPillSnapPoint {
        get {
            WebViewPillSnapPoint(rawValue: webViewPillSnapPointRaw) ?? .topTrailing
        }
        nonmutating set {
            webViewPillSnapPointRaw = newValue.rawValue
        }
    }

    /// The current thinking level value for the active provider
    var currentThinkingLevel: String {
        if selectedProvider == "Gemini API" || selectedProvider.hasPrefix("Gemini API|") {
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
                    showImageGen: $showImageGen,
                    showFileCreator: $showFileCreator,
                    showFolderContext: $showFolderContext,
                    showWebView: $showWebView,
                    showBrowserAutomation: $showBrowserAutomation)
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
                        // Chat view (always in tree to prevent rebuild flash)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 24) {
                                    let messages = chatManager.getCurrentMessages()
                                    if messages.isEmpty {
                                        EmptyStateView(appTheme: appTheme)
                                    } else {
                                        let lastMessageId = messages.last?.id
                                        let lastUserMessageId = messages.last(where: {
                                            $0.isUser
                                        })?.id
                                        ForEach(messages) { message in
                                            MessageView(
                                                message: message,
                                                liveContent: streamBuffer[message.id]
                                                    ?? nil,
                                                liveThinking: streamThinkingBuffer[
                                                    message.id]
                                                    ?? nil,
                                                onRegenerate: (!message.isUser
                                                    && !isLoading
                                                    && message.id == lastMessageId)
                                                    ? {
                                                        regenerateResponse(
                                                            for: message.id)
                                                    }
                                                    : nil,
                                                onEdit: (message.id == lastUserMessageId
                                                    && !isLoading)
                                                    ? { newContent in
                                                        editAndResend(
                                                            message: message,
                                                            newContent: newContent)
                                                    }
                                                    : nil,
                                                canEdit: message.id == lastUserMessageId
                                                    && !isLoading,
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
                                    onNewChat: chatManager.createNewSession,
                                    chatManager: chatManager,
                                    columnVisibility: columnVisibility
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
                                    isGemini: selectedProvider == "Gemini API"
                                        || selectedProvider.hasPrefix("Gemini API|"),
                                    isCopilot: selectedProvider == "GitHub Copilot"
                                        || selectedProvider.hasPrefix("GitHub Copilot|"),
                                    isNvidia: selectedProvider == "NVIDIA API"
                                        || selectedProvider.hasPrefix("NVIDIA API|"),
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
                            .onChange(of: streamingMessageId) { _, newId in
                                // Initial scroll when a new streaming message appears
                                guard let msgId = newId, isLoading else { return }
                                scrollWorkItem?.cancel()
                                let work = DispatchWorkItem {
                                    proxy.scrollTo(msgId, anchor: .bottom)
                                }
                                scrollWorkItem = work
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.05, execute: work)
                            }
                            .onChange(of: streamBuffer) { _, _ in
                                // Throttled scroll during streaming — no animation to avoid layout loops
                                guard isLoading, let msgId = streamingMessageId else { return }
                                scrollWorkItem?.cancel()
                                let work = DispatchWorkItem {
                                    proxy.scrollTo(msgId, anchor: .bottom)
                                }
                                scrollWorkItem = work
                                DispatchQueue.main.asyncAfter(
                                    deadline: .now() + 0.3, execute: work)
                            }
                            .onChange(of: isLoading) { _, loading in
                                scrollWorkItem?.cancel()
                                if !loading {
                                    // Generation finished — final scroll with animation
                                    let messages = chatManager.getCurrentMessages()
                                    if let lastId = messages.last?.id {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                proxy.scrollTo(lastId, anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .opacity(
                            showCommands || showModelComparison || showQuizMe || showImageGen
                                || showFileCreator || showFolderContext || showImageGallery || showWebView
                                || showBrowserAutomation ? 0 : 1
                        )
                        .allowsHitTesting(
                            !(showCommands || showModelComparison || showQuizMe || showImageGen
                                || showFileCreator || showFolderContext || showImageGallery || showWebView
                                || showBrowserAutomation)
                        )
                        .transaction { t in t.animation = nil }

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
                        if showFileCreator {
                            FileCreatorView()
                                .transition(.opacity)
                        }
                        if showFolderContext {
                            FolderContextView()
                                .transition(.opacity)
                        }
                        if showImageGallery {
                            ImageGalleryView(
                                chatManager: chatManager, showImageGallery: $showImageGallery
                            )
                            .transition(.opacity)
                        }
                        if showWebView {
                            GeometryReader { webGeometry in
                                ZStack {
                                    // Web content fills underneath
                                    ZStack(alignment: .top) {
                                        if let url = getWebURL(for: toolSelectedWebView) {
                                            WebView(url: url)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        } else {
                                            VStack(spacing: 16) {
                                                Image(systemName: "globe")
                                                    .font(.system(size: 48))
                                                    .foregroundStyle(.secondary.opacity(0.3))
                                                Text(
                                                    "Valid Web View URL not found"
                                                )
                                                .font(.system(size: 14))
                                                .foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        }
                                    }
                                    webViewPickerPill
                                        .frame(
                                            maxWidth: .infinity,
                                            maxHeight: .infinity,
                                            alignment: webViewPillSnapPoint.alignment
                                        )
                                        .padding(webViewPillSnapPoint.edgeInsets(base: 16))
                                        .offset(webViewPillDragOffset)
                                        .simultaneousGesture(
                                            webViewPillDragGesture(in: webGeometry.size)
                                        )
                                        .zIndex(10)
                                }
                                .coordinateSpace(name: "WebViewToolSpace")
                            }
                            .transition(.opacity)
                        }
                        if showBrowserAutomation {
                            BrowserAutomationView()
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
            .onChange(of: showFileCreator) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showFolderContext) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showWebView) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showImageGallery) { _, val in
                updateActiveToolName()
            }
            .onChange(of: showBrowserAutomation) { _, val in
                updateActiveToolName()
            }

            // Auto-activate web view tool when Custom or Web provider is selected
            .onChange(of: selectedProvider) { _, newProvider in
                updateOllamaModels()
                if isWebViewProvider(newProvider) {
                    toolSelectedWebView = newProvider
                    withAnimation {
                        showWebView = true
                        showFileCreator = false
                        showFolderContext = false
                        showImageGen = false
                        showQuizMe = false
                        showCommands = false
                        showModelComparison = false
                        showImageGallery = false
                        showBrowserAutomation = false
                    }
                }
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

            if updateManager.showUpdateOverlay {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()

                    UpdateView()
                        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                }
                .transition(.opacity)
                .zIndex(300)
            }
        }
        .onAppear {
            activeToolName = ""
            updateOllamaModels()
        }
    }

    private func updateOllamaModels() {
        if selectedProvider == "Ollama" || selectedProvider.hasPrefix("Ollama|") {
            var activeURL = ollamaURL
            if selectedProvider.contains("|"),
                let uuidStr = selectedProvider.split(separator: "|").last.map(String.init),
                let uuid = UUID(uuidString: uuidStr),
                let account = accountManager.accounts.first(where: { $0.id == uuid })
            {
                activeURL = account.endpoint.isEmpty ? ollamaURL : account.endpoint
            }
            OllamaModelManager.shared.fetchInstalledModels(endpoint: activeURL)
        }
    }

    private var webViewPickerPill: some View {
        Picker("Web View", selection: $toolSelectedWebView) {
            Label("ChatGPT", systemImage: "bubble.left.and.bubble.right")
                .tag("ChatGPT Web")
            Label("Claude", systemImage: "brain.head.profile")
                .tag("Claude Web")
            Label("Gemini", systemImage: "sparkles")
                .tag("Gemini Web")
            Label("Perplexity", systemImage: "magnifyingglass")
                .tag("Perplexity Web")
            Label("Grok", systemImage: "bolt.horizontal")
                .tag("Grok Web")

            Divider()

            ForEach(customWebViews()) { webView in
                Label(
                    webView.name.isEmpty ? webView.url : webView.name,
                    systemImage: webView.icon ?? "globe"
                )
                .tag("CustomWebView:\(webView.url)")
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .glassEffect(.regular, in: .capsule)
        .overlay(
            Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .background {
            GeometryReader { pillGeometry in
                Color.clear
                    .onAppear {
                        webViewPillSize = pillGeometry.size
                    }
                    .onChange(of: pillGeometry.size) { _, newSize in
                        webViewPillSize = newSize
                    }
            }
        }
    }

    private func webViewPillDragGesture(in containerSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("WebViewToolSpace"))
            .updating($webViewPillDragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let snappedPoint = nearestWebViewPillSnapPoint(
                    to: value.location, in: containerSize)
                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                    webViewPillSnapPoint = snappedPoint
                }
            }
    }

    private func nearestWebViewPillSnapPoint(to location: CGPoint, in containerSize: CGSize)
        -> WebViewPillSnapPoint
    {
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 16
        let resolvedPillSize = CGSize(
            width: max(webViewPillSize.width, 150),
            height: max(webViewPillSize.height, 32)
        )

        let topY = verticalInset + (resolvedPillSize.height / 2)
        let bottomY = max(
            topY, containerSize.height - verticalInset - (resolvedPillSize.height / 2))
        let leftX = horizontalInset + (resolvedPillSize.width / 2)
        let midX = containerSize.width / 2
        let rightX = max(
            leftX, containerSize.width - horizontalInset - (resolvedPillSize.width / 2))

        let candidates: [(WebViewPillSnapPoint, CGPoint)] = [
            (.topLeading, CGPoint(x: leftX, y: topY)),
            (.top, CGPoint(x: midX, y: topY)),
            (.topTrailing, CGPoint(x: rightX, y: topY)),
            (.bottomLeading, CGPoint(x: leftX, y: bottomY)),
            (.bottom, CGPoint(x: midX, y: bottomY)),
            (.bottomTrailing, CGPoint(x: rightX, y: bottomY)),
        ]

        return candidates.min(by: { lhs, rhs in
            let lhsDistance = hypot(lhs.1.x - location.x, lhs.1.y - location.y)
            let rhsDistance = hypot(rhs.1.x - location.x, rhs.1.y - location.y)
            return lhsDistance < rhsDistance
        })?.0 ?? .topTrailing
    }

    func isWebViewProvider(_ provider: String) -> Bool {
        return ["Gemini Web", "ChatGPT Web", "Perplexity Web", "Grok Web", "Claude Web"]
            .contains(provider) || provider.hasPrefix("CustomWebView:")
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
        } else if showFileCreator {
            activeToolName = "File Creator"
        } else if showFolderContext {
            activeToolName = "Folder Context"
        } else if showWebView {
            activeToolName = "Web View"
        } else if showBrowserAutomation {
            activeToolName = "Browser Automation"
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
        case "Claude Web": return URL(string: "https://claude.ai")
        default:
            if provider.hasPrefix("CustomWebView:") {
                let urlStr = String(provider.dropFirst("CustomWebView:".count))
                return normalizedWebURL(from: urlStr)
            }
            return nil
        }
    }

    private func customWebViews() -> [CustomWebView] {
        guard let data = customWebViewsJSON.data(using: .utf8),
            let views = try? JSONDecoder().decode([CustomWebView].self, from: data)
        else { return [] }
        return views
    }

    private func getCustomWebURL(for provider: String) -> URL? {
        if provider.hasPrefix("CustomWebView:") {
            let urlStr = String(provider.dropFirst("CustomWebView:".count))
            return normalizedWebURL(from: urlStr)
        }
        return nil
    }

    private func resolvedCustomWebViewURL() -> URL? {
        let views = customWebViews()
        guard !views.isEmpty else { return nil }
        // Use the selected one, or fall back to the first
        if !selectedCustomWebViewURL.isEmpty,
            let url = normalizedWebURL(from: selectedCustomWebViewURL)
        {
            return url
        }
        return normalizedWebURL(from: views[0].url)
    }

    private func normalizedWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let withScheme = URL(string: trimmed),
            let scheme = withScheme.scheme,
            scheme == "http" || scheme == "https"
        {
            return withScheme
        }

        return URL(string: "https://\(trimmed)")
    }

    func handleScroll(proxy: ScrollViewProxy, newCount: Int? = nil) {
        let messages = chatManager.getCurrentMessages()
        let currentCount = newCount ?? messages.count
        guard currentCount > 0 else { return }

        if chatManager.currentSessionId != lastSessionId {
            // Session Switch
            lastSessionId = chatManager.currentSessionId
            lastMessageCount = currentCount

            // Jump to bottom (No Animation) to prevent freeze on large lists
            if let lastId = messages.last?.id {
                DispatchQueue.main.async {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        } else {
            // Same Session
            if currentCount > lastMessageCount {
                // New Message — no animation to avoid LazyVStack layout loops
                if let lastId = messages.last?.id {
                    DispatchQueue.main.async {
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
        // Don't send to AI when a tool is active
        guard
            !showCommands && !showModelComparison && !showQuizMe && !showImageGen
                && !showFileCreator && !showFolderContext && !showWebView && !showImageGallery
        else { return }
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
            // Web search augmentation
            var effectiveSystemPrompt = systemPrompt
            if webSearchEnabled
                && (selectedProvider == "Ollama" || selectedProvider.hasPrefix("Ollama|"))
            {
                do {
                    let searchResults = try await webSearchService.search(query: input)
                    let searchContext = webSearchService.buildSearchContext(results: searchResults)
                    if !searchContext.isEmpty {
                        effectiveSystemPrompt = systemPrompt + searchContext
                    }
                } catch {
                    // Silently continue without search results on failure
                    print("Web search failed: \(error.localizedDescription)")
                }
            }

            if selectedProvider == "Gemini API" || selectedProvider.hasPrefix("Gemini API|") {
                // Resolve API key for multi-account
                var apiKey = geminiKey
                if selectedProvider.contains("|"),
                    let uuidStr = selectedProvider.split(separator: "|").last.map(String.init),
                    let uuid = UUID(uuidString: uuidStr),
                    let account = accountManager.accounts.first(where: { $0.id == uuid })
                {
                    apiKey = account.apiKey
                }
                if !apiKey.isEmpty {
                    let aiMsgId = UUID()
                    // Store model name
                    var aiMsg = Message(content: "", model: geminiModel, isUser: false)
                    aiMsg.id = aiMsgId
                    aiMsg.isStreaming = true

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                        self.streamBuffer[aiMsgId] = ""
                        self.streamingMessageId = aiMsgId
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var receivedImage: NSImage? = nil
                        var lastUpdateTime = Date()

                        let stream = await Task.detached {
                            return await geminiService.sendMessageStream(
                                history: chatManager.getCurrentMessages(), apiKey: apiKey,
                                model: geminiModel,
                                systemPrompt: systemPrompt,
                                thinkingLevel: geminiThinkingLevel,
                                imageResolution: geminiImageResolution,
                                imageAspectRatio: geminiImageAspectRatio)
                        }.value

                        for try await (contentChunk, thinkingChunk, imageData) in stream {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }
                            if let imgData = imageData, let img = NSImage(data: imgData) {
                                receivedImage = img
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentSnapshot = fullContent
                                let thinkingSnapshot = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.streamBuffer[aiMsgId] = contentSnapshot
                                    if let t = thinkingSnapshot {
                                        self.streamThinkingBuffer[aiMsgId] = t
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let finalImage = receivedImage
                        DispatchQueue.main.async {
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
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
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
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
                    self.streamBuffer[aiMsgId] = ""
                    self.streamingMessageId = aiMsgId
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
                            let contentSnapshot = accumulatedContent
                            DispatchQueue.main.async {
                                self.streamBuffer[aiMsgId] = contentSnapshot
                            }
                            lastUpdateTime = Date()
                        }
                    }

                    DispatchQueue.main.async {
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamingMessageId = nil
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
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamingMessageId = nil
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "Ollama" || selectedProvider.hasPrefix("Ollama|") {
                // Resolve URL for multi-account
                var activeURL = ollamaURL
                if selectedProvider.contains("|"),
                    let uuidStr = selectedProvider.split(separator: "|").last.map(String.init),
                    let uuid = UUID(uuidString: uuidStr),
                    let account = accountManager.accounts.first(where: { $0.id == uuid })
                {
                    activeURL = account.endpoint.isEmpty ? ollamaURL : account.endpoint
                }

                let aiMsgId = UUID()
                let activeModel = selectedOllamaModel
                var aiMsg = Message(content: "", model: activeModel, isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                    self.streamBuffer[aiMsgId] = ""
                    self.streamingMessageId = aiMsgId
                }

                // Check if this is an image generation model
                if OllamaService.isImageGenerationModel(activeModel) {
                    // Use /api/generate for image gen models
                    let userPrompt = currentHistory.last(where: { $0.isUser })?.content ?? input
                    DispatchQueue.main.async {
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Generating image...",
                            isStreaming: true, isGeneratingImage: true)
                    }

                    do {
                        var receivedImage: NSImage? = nil
                        var progressText = "Generating image..."

                        for try await (progress, imageData) in ollamaService.generateImage(
                            prompt: userPrompt, endpoint: activeURL, model: activeModel)
                        {
                            if let progress = progress {
                                progressText = progress
                                let snapshot = progressText
                                DispatchQueue.main.async {
                                    self.streamBuffer[aiMsgId] = snapshot
                                }
                            }
                            if let imgData = imageData, let img = NSImage(data: imgData) {
                                receivedImage = img
                            }
                        }

                        let finalImage = receivedImage
                        DispatchQueue.main.async {
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
                            self.chatManager.updateMessage(
                                id: aiMsgId,
                                content: finalImage != nil ? "" : "No image was generated.",
                                image: finalImage,
                                isStreaming: false,
                                isGeneratingImage: false)
                            if let versions = existingVersions {
                                self.chatManager.attachVersions(versions, to: aiMsgId)
                            }
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: "Error: \(error.localizedDescription)",
                                isStreaming: false, isGeneratingImage: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    }
                } else {
                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk)
                            in ollamaService.sendMessageStream(
                                history: currentHistory, endpoint: activeURL, model: activeModel,
                                systemPrompt: effectiveSystemPrompt,
                                thinkingLevel: currentThinkingLevel,
                                webSearchEnabled: webSearchEnabled,
                                webSearchService: webSearchEnabled ? webSearchService : nil)
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentSnapshot = fullContent
                                let thinkingSnapshot = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.streamBuffer[aiMsgId] = contentSnapshot
                                    if let t = thinkingSnapshot {
                                        self.streamThinkingBuffer[aiMsgId] = t
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        DispatchQueue.main.async {
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
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
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
                            self.chatManager.updateMessage(
                                id: aiMsgId, content: "Error: \(error.localizedDescription)",
                                isStreaming: false)
                            self.chatManager.finalizeMessageUpdate()
                            self.isLoading = false
                        }
                    }
                }
            } else if selectedProvider == "GitHub Copilot"
                || selectedProvider.hasPrefix("GitHub Copilot|")
            {
                // GitHub Copilot
                let copilotModel =
                    UserDefaults.standard.string(forKey: "SelectedCopilotModel") ?? "gpt-4o"
                // Extract account UUID if multi-account
                var copilotAccountId: String? = nil
                if selectedProvider.contains("|"),
                    let uuidStr = selectedProvider.split(separator: "|").last.map(String.init)
                {
                    copilotAccountId = uuidStr
                }
                let aiMsgId = UUID()
                var aiMsg = Message(
                    content: "",
                    model:
                        "Copilot: \(GitHubCopilotModelManager.shared.displayName(for: copilotModel))",
                    isUser: false)
                aiMsg.id = aiMsgId
                aiMsg.isStreaming = true

                DispatchQueue.main.async {
                    self.chatManager.addMessage(aiMsg)
                    self.streamBuffer[aiMsgId] = ""
                    self.streamingMessageId = aiMsgId
                }

                do {
                    var fullContent = ""
                    var lastUpdateTime = Date()

                    for try await (contentChunk, _) in GitHubCopilotService.shared
                        .sendMessageStream(
                            history: currentHistory, model: copilotModel,
                            systemPrompt: systemPrompt,
                            accountId: copilotAccountId
                        )
                    {
                        fullContent += contentChunk

                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let contentSnapshot = fullContent
                            DispatchQueue.main.async {
                                self.streamBuffer[aiMsgId] = contentSnapshot
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    DispatchQueue.main.async {
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamingMessageId = nil
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: fullContent, isStreaming: false)
                        if let versions = existingVersions {
                            self.chatManager.attachVersions(versions, to: aiMsgId)
                        }
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.streamBuffer.removeValue(forKey: aiMsgId)
                        self.streamingMessageId = nil
                        self.chatManager.updateMessage(
                            id: aiMsgId, content: "Error: \(error.localizedDescription)",
                            isStreaming: false)
                        self.chatManager.finalizeMessageUpdate()
                        self.isLoading = false
                    }
                }
            } else if selectedProvider == "NVIDIA API"
                || selectedProvider.hasPrefix("NVIDIA API|")
            {
                // Resolve API key for multi-account
                var apiKey = nvidiaKey
                if selectedProvider.contains("|"),
                    let uuidStr = selectedProvider.split(separator: "|").last.map(String.init),
                    let uuid = UUID(uuidString: uuidStr),
                    let account = accountManager.accounts.first(where: { $0.id == uuid })
                {
                    apiKey = account.apiKey
                }
                if !apiKey.isEmpty {
                    let aiMsgId = UUID()
                    let activeModel = selectedNvidiaModel
                    var aiMsg = Message(
                        content: "",
                        model: "NVIDIA: \(NvidiaModelManager.shared.displayName(for: activeModel))",
                        isUser: false)
                    aiMsg.id = aiMsgId
                    aiMsg.isStreaming = true

                    DispatchQueue.main.async {
                        self.chatManager.addMessage(aiMsg)
                        self.streamBuffer[aiMsgId] = ""
                        self.streamingMessageId = aiMsgId
                    }

                    do {
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()

                        for try await (contentChunk, thinkingChunk)
                            in nvidiaService
                            .sendMessageStream(
                                history: currentHistory, apiKey: apiKey,
                                model: activeModel,
                                systemPrompt: effectiveSystemPrompt,
                                enableThinking: thinkingLevel == "high")
                        {
                            fullContent += contentChunk
                            if let thinking = thinkingChunk {
                                fullThinking += thinking
                            }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let contentSnapshot = fullContent
                                let thinkingSnapshot = fullThinking.isEmpty ? nil : fullThinking

                                DispatchQueue.main.async {
                                    self.streamBuffer[aiMsgId] = contentSnapshot
                                    if let t = thinkingSnapshot {
                                        self.streamThinkingBuffer[aiMsgId] = t
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        DispatchQueue.main.async {
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
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
                            self.streamBuffer.removeValue(forKey: aiMsgId)
                            self.streamThinkingBuffer.removeValue(forKey: aiMsgId)
                            self.streamingMessageId = nil
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
                            content: "Please enter your NVIDIA API Key in settings.", isUser: false)
                        self.chatManager.addMessage(aiMsg)
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

                let lastUserImage = currentHistory.last(where: { $0.isUser })?.image

                do {
                    let result = try await shortcutService.runShortcut(
                        name: shortcutName, input: transcript, image: lastUserImage)
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
    @Binding var showFileCreator: Bool
    @Binding var showFolderContext: Bool
    @Binding var showWebView: Bool
    @Binding var showBrowserAutomation: Bool
    @Namespace private var animation

    @AppStorage("ShowCompare") private var showCompareTool: Bool = true
    @AppStorage("ShowCommands") private var showCommandsTool: Bool = true
    @AppStorage("ShowQuizMe") private var showQuizMeTool: Bool = true
    @AppStorage("ShowImageGen") private var showImageGenTool: Bool = true
    @AppStorage("ShowFileCreator") private var showFileCreatorTool: Bool = true
    @AppStorage("ShowFolderContext") private var showFolderContextTool: Bool = true
    @AppStorage("ShowWebView") private var showWebViewTool: Bool = true
    @AppStorage("ShowBrowserAutomation") private var showBrowserAutomationTool: Bool = true
    @AppStorage("ToolOrder") private var toolOrderRaw: String =
        "compare,commands,quizme,imagegen,filecreator,foldercontext,webview,browserautomation"

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
                showFileCreator = false
                showFolderContext = false
                showWebView = false
                showBrowserAutomation = false
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
                                        showFileCreator = false
                                        showFolderContext = false
                                        showWebView = false
                                        showBrowserAutomation = false
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
                    showFileCreator = false
                    showFolderContext = false
                    showWebView = false
                    showBrowserAutomation = false
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
                            showFileCreator = false
                            showFolderContext = false
                            showWebView = false
                            showBrowserAutomation = false
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
                            showFileCreator = false
                            showFolderContext = false
                            showWebView = false
                            showBrowserAutomation = false
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
                            showFileCreator = false
                            showFolderContext = false
                            showWebView = false
                            showBrowserAutomation = false
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
                            showFileCreator = false
                            showFolderContext = false
                            showWebView = false
                            showBrowserAutomation = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "filecreator" && showFileCreatorTool {
                    SidebarItem(
                        icon: "doc.richtext", title: "File Creator", isSelected: showFileCreator
                    ) {
                        withAnimation {
                            showFileCreator = true
                            showImageGen = false
                            showQuizMe = false
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            showFolderContext = false
                            showWebView = false
                            showBrowserAutomation = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "foldercontext" && showFolderContextTool {
                    SidebarItem(
                        icon: "folder.badge.questionmark",
                        title: "Folder Context",
                        isSelected: showFolderContext
                    ) {
                        withAnimation {
                            showFolderContext = true
                            showFileCreator = false
                            showImageGen = false
                            showQuizMe = false
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            showWebView = false
                            showBrowserAutomation = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "webview" && showWebViewTool {
                    SidebarItem(
                        icon: "globe", title: "Web View", isSelected: showWebView
                    ) {
                        withAnimation {
                            showWebView = true
                            showFileCreator = false
                            showFolderContext = false
                            showImageGen = false
                            showQuizMe = false
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            showBrowserAutomation = false
                            chatManager.currentSessionId = nil
                        }
                    }
                } else if toolId == "browserautomation" && showBrowserAutomationTool {
                    SidebarItem(
                        icon: "cursorarrow.motionlines.click",
                        title: "Browser Automation",
                        isSelected: showBrowserAutomation
                    ) {
                        withAnimation {
                            showBrowserAutomation = true
                            showWebView = false
                            showFileCreator = false
                            showFolderContext = false
                            showImageGen = false
                            showQuizMe = false
                            showCommands = false
                            showModelComparison = false
                            showImageGallery = false
                            chatManager.currentSessionId = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tool ordering helpers

    private var toolOrder: [String] {
        let raw = toolOrderRaw.split(separator: ",").map(String.init)
        let allTools = [
            "compare", "commands", "quizme", "imagegen", "filecreator", "foldercontext", "webview",
            "browserautomation",
        ]
        // Ensure all tools are present (handle new tools added after first save)
        var order = raw.filter { allTools.contains($0) }
        for tool in allTools where !order.contains(tool) {
            order.append(tool)
        }
        return order
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
                && !showQuizMe && !showFileCreator && !showFolderContext && !showWebView
                && !showBrowserAutomation
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
                showFileCreator = false
                showFolderContext = false
                showWebView = false
                showBrowserAutomation = false
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
            },
            onExportMarkdown: {
                ExportHelper.exportAsMarkdown(messages: session.messages, title: session.title)
            },
            onExportPDF: {
                ExportHelper.exportAsPDF(messages: session.messages, title: session.title)
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
    var onExportMarkdown: () -> Void = {}
    var onExportPDF: () -> Void = {}

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
            if !session.messages.isEmpty {
                Menu("Export Chat") {
                    Button {
                        onExportMarkdown()
                    } label: {
                        Label("Export as Markdown", systemImage: "doc.text")
                    }
                    Button {
                        onExportPDF()
                    } label: {
                        Label("Export as PDF", systemImage: "doc.richtext")
                    }
                }
                Divider()
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }
}

struct HeaderView: View {
    @Binding var selectedProvider: String
    var onNewChat: () -> Void
    @ObservedObject var chatManager: ChatManager
    var columnVisibility: NavigationSplitViewVisibility = .automatic
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @AppStorage("CustomWebViews") private var customWebViewsJSON: String = "[]"
    @State private var isProviderMenuOpen: Bool = false

    private var customWebViews: [CustomWebView] {
        guard let data = customWebViewsJSON.data(using: .utf8),
            let views = try? JSONDecoder().decode([CustomWebView].self, from: data)
        else { return [] }
        return views
    }

    var body: some View {
        HStack {
            Menu {
                Section("Apple Intelligence") {
                    Button(action: { selectedProvider = "Apple Foundation" }) {
                        Label("Apple Foundation", systemImage: getProviderIcon("Apple Foundation"))
                    }
                }

                // Only show Gemini if there are configured accounts with API keys
                let geminiAccounts = accountManager.geminiAccounts().filter { !$0.apiKey.isEmpty }
                if !geminiAccounts.isEmpty {
                    Section("Gemini API") {
                        ForEach(Array(geminiAccounts.enumerated()), id: \.element.id) {
                            index, account in
                            Button(action: {
                                selectedProvider = "Gemini API|\(account.id.uuidString)"
                            }) {
                                Label(
                                    account.displayName,
                                    systemImage: getProviderIcon("Gemini API"))
                            }
                        }
                    }
                }

                // Only show Ollama if there are configured accounts
                let ollamaAccounts = accountManager.ollamaAccounts()
                if !ollamaAccounts.isEmpty {
                    Section("Ollama") {
                        ForEach(Array(ollamaAccounts.enumerated()), id: \.element.id) {
                            index, account in
                            Button(action: {
                                selectedProvider = "Ollama|\(account.id.uuidString)"
                            }) {
                                Label(
                                    account.displayName, systemImage: getProviderIcon("Ollama"))
                            }
                        }
                    }
                }

                // Only show NVIDIA if there are configured accounts with API keys
                let nvidiaAccounts = accountManager.nvidiaAccounts().filter { !$0.apiKey.isEmpty }
                if !nvidiaAccounts.isEmpty {
                    Section("NVIDIA API") {
                        ForEach(Array(nvidiaAccounts.enumerated()), id: \.element.id) {
                            index, account in
                            Button(action: {
                                selectedProvider = "NVIDIA API|\(account.id.uuidString)"
                            }) {
                                Label(
                                    account.displayName,
                                    systemImage: getProviderIcon("NVIDIA API"))
                            }
                        }
                    }
                }

                // Only show GitHub Copilot if signed in
                if copilotService.isAuthenticated {
                    let copilotAccounts = accountManager.copilotAccounts()
                    Section("GitHub Copilot") {
                        ForEach(copilotAccounts) { account in
                            let ghUser =
                                copilotService.accountAuthState[account.id]?.userName ?? ""
                            let label =
                                ghUser.isEmpty ? account.displayName : "GitHub Copilot (\(ghUser))"
                            Button(action: {
                                selectedProvider = "GitHub Copilot|\(account.id.uuidString)"
                            }) {
                                Label(
                                    label,
                                    systemImage: getProviderIcon("GitHub Copilot"))
                            }
                        }
                    }
                }

                Section("Web View") {
                    Button(action: { selectedProvider = "ChatGPT Web" }) {
                        Label("ChatGPT Web", systemImage: getProviderIcon("ChatGPT Web"))
                    }
                    Button(action: { selectedProvider = "Claude Web" }) {
                        Label("Claude Web", systemImage: getProviderIcon("Claude Web"))
                    }
                    Button(action: { selectedProvider = "Gemini Web" }) {
                        Label("Gemini Web", systemImage: getProviderIcon("Gemini Web"))
                    }
                    Button(action: { selectedProvider = "Perplexity Web" }) {
                        Label("Perplexity Web", systemImage: getProviderIcon("Perplexity Web"))
                    }
                    Button(action: { selectedProvider = "Grok Web" }) {
                        Label("Grok Web", systemImage: getProviderIcon("Grok Web"))
                    }

                    if !customWebViews.isEmpty {
                        Divider()
                        ForEach(customWebViews) { webView in
                            let provider = "CustomWebView:\(webView.url)"
                            Button(action: { selectedProvider = provider }) {
                                Label(
                                    webView.name.isEmpty ? webView.url : webView.name,
                                    systemImage: getProviderIcon(provider)
                                )
                            }
                        }
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
                    Text(headerDisplayName(selectedProvider))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: isProviderMenuOpen ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
                .glassEffect(.regular, in: .capsule)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .focusEffectDisabled()
            .padding(.horizontal, 4)
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isProviderMenuOpen.toggle()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isProviderMenuOpen = false
                        }
                    }
                })

            Spacer()

            if columnVisibility == .detailOnly {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(
                            Circle()
                                .fill(.ultraThinMaterial)
                        )
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help("New Chat")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    func headerDisplayName(_ provider: String) -> String {
        // Handle multi-account provider strings like "Gemini API|uuid"
        if provider.contains("|") {
            let parts = provider.split(separator: "|")
            let base = parts.first.map(String.init) ?? provider
            if let uuidStr = parts.last, let uuid = UUID(uuidString: String(uuidStr)) {
                // For Copilot, prefer the GitHub username
                if base == "GitHub Copilot",
                    let ghUser = GitHubCopilotService.shared.accountAuthState[uuid]?.userName,
                    !ghUser.isEmpty
                {
                    return "GitHub Copilot (\(ghUser))"
                }
                if let account = accountManager.accounts.first(where: { $0.id == uuid }) {
                    return account.displayName
                }
            }
        }
        if provider.hasPrefix("CustomWebView:") {
            let urlStr = String(provider.dropFirst("CustomWebView:".count))
            if let wv = customWebViews.first(where: { $0.url == urlStr }), !wv.name.isEmpty {
                return wv.name
            }
            return urlStr
        }
        return provider
    }

    func getProviderIcon(_ provider: String) -> String {
        let base = provider.split(separator: "|").first.map(String.init) ?? provider
        switch base {
        case "Apple Foundation": return "apple.logo"
        case "On-Device": return "iphone"
        case "Private Cloud": return "lock.icloud"
        case "Gemini API": return "sparkles"
        case "Ollama", "Ollama 1", "Ollama 2": return "laptopcomputer"
        case "ChatGPT": return "message"
        case "GitHub Copilot": return "chevron.left.forwardslash.chevron.right"
        case "NVIDIA API": return "bolt.fill"
        case "Gemini Web": return "sparkles"
        case "ChatGPT Web": return "bubble.left.and.bubble.right"
        case "Perplexity Web": return "magnifyingglass"
        case "Grok Web": return "bolt.horizontal"
        case "Claude Web": return "brain.head.profile"
        default:
            if base.hasPrefix("CustomWebView:") {
                let urlStr = String(base.dropFirst("CustomWebView:".count))
                return customWebViews.first(where: { $0.url == urlStr })?.icon ?? "globe"
            }
            return "cpu"
        }
    }

    // MARK: - Export (delegates to ExportHelper)
}

// MARK: - Export Helper

enum ExportHelper {

    static func exportAsMarkdown(
        messages: [Message], title: String, completion: (() -> Void)? = nil
    ) {
        let md = buildMarkdown(messages: messages, title: title)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeFilename(title)).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            completion?()
        } catch {}
    }

    static func exportAsPDF(messages: [Message], title: String, completion: (() -> Void)? = nil) {
        let md = buildMarkdown(messages: messages, title: title)

        let attributed = renderMarkdownToAttributed(md)
        let printInfo = NSPrintInfo.shared
        printInfo.topMargin = 50
        printInfo.bottomMargin = 50
        printInfo.leftMargin = 50
        printInfo.rightMargin = 50
        let pageWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let headerHeight: CGFloat = 30  // space reserved for branding header
        let pageHeight =
            printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin - headerHeight

        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: pageWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let textBounds = layoutManager.usedRect(for: textContainer)
        let totalHeight = textBounds.height
        let pageCount = max(1, Int(ceil(totalHeight / pageHeight)))

        let pdfData = NSMutableData()
        var mediaBox = CGRect(
            x: 0, y: 0, width: printInfo.paperSize.width, height: printInfo.paperSize.height)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
            let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return }

        // Get app icon for branding
        let appIcon = NSApp.applicationIconImage

        for page in 0..<pageCount {
            pdfContext.beginPDFPage(nil)

            // Flip CG context so origin is top-left (required by NSLayoutManager/NSAttributedString)
            pdfContext.saveGState()
            pdfContext.translateBy(x: 0, y: printInfo.paperSize.height)
            pdfContext.scaleBy(x: 1.0, y: -1.0)

            let nsContext = NSGraphicsContext(cgContext: pdfContext, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext

            // Draw branding header in top-right (flipped coords: y=0 is top)
            let iconSize: CGFloat = 16
            let brandAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.gray,
            ]
            let brandStr = NSAttributedString(string: "Prism Chat", attributes: brandAttrs)
            let brandSize = brandStr.size()
            let brandX = printInfo.paperSize.width - printInfo.rightMargin - brandSize.width
            let brandY: CGFloat = (printInfo.topMargin - iconSize) / 2
            let brandTextY = brandY + (iconSize - brandSize.height) / 2
            brandStr.draw(at: NSPoint(x: brandX, y: brandTextY))

            if let icon = appIcon {
                let iconX = brandX - iconSize - 4
                let iconRect = NSRect(x: iconX, y: brandY, width: iconSize, height: iconSize)
                icon.draw(
                    in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                    respectFlipped: true, hints: nil)
            }

            // Draw text content
            let yOffset = CGFloat(page) * pageHeight
            let drawOrigin = NSPoint(
                x: printInfo.leftMargin, y: printInfo.topMargin + headerHeight - yOffset)

            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: NSRect(x: 0, y: yOffset, width: pageWidth, height: pageHeight),
                in: textContainer)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: drawOrigin)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: drawOrigin)

            NSGraphicsContext.restoreGraphicsState()
            pdfContext.restoreGState()
            pdfContext.endPDFPage()
        }
        pdfContext.closePDF()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeFilename(title)).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pdfData.write(to: url, atomically: true)
        completion?()
    }

    static func buildMarkdown(messages: [Message], title: String) -> String {
        var md = "# \(title)\n\n"
        md += "_Exported from Prism Chat_\n\n---\n\n"

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        for message in messages {
            let role = message.isUser ? "You" : (message.model ?? "AI")
            let time = dateFormatter.string(from: message.timestamp)
            md += "### \(role)\n"
            md += "_\(time)_\n\n"

            if let thinking = message.thinkingContent, !thinking.isEmpty {
                md += "<details>\n<summary>Thinking</summary>\n\n\(thinking)\n\n</details>\n\n"
            }

            md += "\(message.content)\n\n"

            if let attachments = message.attachments {
                for att in attachments {
                    if att.type == "text", let text = String(data: att.data, encoding: .utf8) {
                        let name = att.fileName ?? "attachment"
                        md += "**Attached: \(name)**\n```\n\(text)\n```\n\n"
                    } else if att.type == "image" {
                        md += "_(image attachment)_\n\n"
                    } else if att.type == "pdf" {
                        md += "_(PDF attachment)_\n\n"
                    }
                }
            }

            md += "---\n\n"
        }
        return md
    }

    static func renderMarkdownToAttributed(_ md: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultFont = NSFont.systemFont(ofSize: 13)
        let boldFont = NSFont.boldSystemFont(ofSize: 13)
        let h1Font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let h3Font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let defaultColor = NSColor.black
        let secondaryColor = NSColor.darkGray
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        let lines = md.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBuffer = ""

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeAttrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont, .foregroundColor: defaultColor,
                        .paragraphStyle: paragraphStyle,
                        .backgroundColor: NSColor(white: 0.93, alpha: 1.0),
                    ]
                    result.append(
                        NSAttributedString(string: codeBuffer + "\n", attributes: codeAttrs))
                    codeBuffer = ""
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                codeBuffer += (codeBuffer.isEmpty ? "" : "\n") + line
                continue
            }

            if line.hasPrefix("# ") {
                let text = String(line.dropFirst(2))
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: h1Font, .foregroundColor: defaultColor,
                            .paragraphStyle: paragraphStyle,
                        ]))
            } else if line.hasPrefix("### ") {
                let text = String(line.dropFirst(4))
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: h3Font, .foregroundColor: defaultColor,
                            .paragraphStyle: paragraphStyle,
                        ]))
            } else if line.hasPrefix("---") {
                let dividerStyle = NSMutableParagraphStyle()
                dividerStyle.paragraphSpacing = 12
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: [.font: defaultFont, .paragraphStyle: dividerStyle]))
            } else if line.hasPrefix("_") && line.hasSuffix("_") && line.count > 2 {
                let text = String(line.dropFirst().dropLast())
                result.append(
                    NSAttributedString(
                        string: text + "\n",
                        attributes: [
                            .font: NSFontManager.shared.convert(
                                defaultFont, toHaveTrait: .italicFontMask),
                            .foregroundColor: secondaryColor, .paragraphStyle: paragraphStyle,
                        ]))
            } else if line.hasPrefix("**") && line.contains("**") {
                result.append(
                    NSAttributedString(
                        string: line.replacingOccurrences(of: "**", with: "") + "\n",
                        attributes: [
                            .font: boldFont, .foregroundColor: defaultColor,
                            .paragraphStyle: paragraphStyle,
                        ]))
            } else if line.isEmpty {
                // In Markdown, an empty line usually separates paragraphs.
                // We don't need to append an explicit newline because `paragraphSpacing`
                // on the previous line's paragraph style already adds separation.
                continue
            } else {
                result.append(
                    NSAttributedString(
                        string: line + "\n",
                        attributes: [
                            .font: defaultFont, .foregroundColor: defaultColor,
                            .paragraphStyle: paragraphStyle,
                        ]))
            }
        }
        return result
    }

    static func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
}

struct AttachmentPreview: View {
    let attachment: Attachment
    var onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

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
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 20, height: 20)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(
                            colorScheme == .dark ? .white.opacity(0.8) : .black.opacity(0.6))
                }
                .contentShape(Circle().scale(1.5))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
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
                // Skip if the event targets the QuickAI panel or Web Overlay panel
                if event.window is QuickAIPanel || event.window is WebOverlayPanel { return event }
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
    var isCopilot: Bool = false
    var isNvidia: Bool = false
    @Binding var webSearchEnabled: Bool
    var hasOllamaAPIKey: Bool = false
    var onSlashAction: ((String) -> Void)? = nil  // callback for action commands (/clear, /quit, /new)
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("GeminiImageResolution") private var geminiImageResolution: String = "1K"
    @AppStorage("GeminiImageAspectRatio") private var geminiImageAspectRatio: String = "Default"
    @AppStorage("SelectedCopilotModel") private var selectedCopilotModel: String = "gpt-4o"
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String =
        "llama-3.1-70b-instruct"
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared
    @ObservedObject var apiProviderModelStore = APIProviderModelStore.shared
    @ObservedObject var copilotModelManager = GitHubCopilotModelManager.shared
    @ObservedObject var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var slashCommandManager = SlashCommandManager.shared

    @State private var isFocused: Bool = false
    @StateObject private var pasteMonitor = PasteMonitor()
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""
    @State private var showAddCustomGeminiModel = false
    @State private var newCustomGeminiModelName = ""
    @State private var showAddCustomNvidiaModel = false
    @State private var newCustomNvidiaModelName = ""
    @State private var glassHover: Bool = false
    @State private var slashMatches: [SlashCommand] = []
    @State private var slashSelectedIndex: Int = 0
    @State private var showSlashAutocomplete: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var geminiDropdownModels: [String] {
        guard let provider = APIProviderRegistry.provider(for: "gemini") else {
            return geminiManager.sortedModels
        }
        let models = apiProviderModelStore.enabledModels(for: provider)
        return models.isEmpty ? geminiManager.sortedModels : models
    }

    private var nvidiaDropdownModels: [String] {
        guard let provider = APIProviderRegistry.provider(for: "nvidia") else {
            return nvidiaManager.sortedModels
        }
        let models = apiProviderModelStore.enabledModels(for: provider)
        return models.isEmpty ? nvidiaManager.sortedModels : models
    }

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
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedAttachments.removeAll { $0.id == attachment.id }
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
                        if !ollamaManager.favoriteModels.isEmpty {
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
                        }

                        // Show installed models from the active Ollama server
                        let installedNonFav = ollamaManager.installedModels
                            .filter { !ollamaManager.isFavorite($0) }
                            .sorted()
                        if !installedNonFav.isEmpty {
                            Section("Installed") {
                                ForEach(installedNonFav, id: \.self) { model in
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

                        // Show custom models that aren't installed or favorited
                        let installedSet = Set(ollamaManager.installedModels)
                        let customNonInstalled = ollamaManager.customModels
                            .filter { !ollamaManager.isFavorite($0) }
                            .filter { !installedSet.contains($0) }
                            .sorted()
                        if !customNonInstalled.isEmpty {
                            Section("Custom") {
                                ForEach(customNonInstalled, id: \.self) { model in
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
                        let favoriteModels = geminiManager.favoriteModels.filter {
                            geminiDropdownModels.contains($0)
                        }
                        if !favoriteModels.isEmpty {
                            Section("Favorites") {
                                ForEach(favoriteModels, id: \.self) { model in
                                    Button(action: { geminiModel = model }) {
                                        if geminiModel == model {
                                            Label(
                                                geminiManager.displayName(for: model),
                                                systemImage: "checkmark")
                                        } else {
                                            Text(GeminiModelManager.shared.displayName(for: model))
                                        }
                                    }
                                }
                            }
                        }

                        let availableModels = geminiDropdownModels.filter {
                            !favoriteModels.contains($0)
                        }
                        if !availableModels.isEmpty {
                            Section("Available") {
                                ForEach(availableModels, id: \.self) { model in
                                    Button(action: { geminiModel = model }) {
                                        if geminiModel == model {
                                            Label(
                                                geminiManager.displayName(for: model),
                                                systemImage: "checkmark")
                                        } else {
                                            Text(
                                                GeminiModelManager.shared.displayName(for: model))
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("Manage Favorites") {
                            ForEach(geminiDropdownModels, id: \.self) {
                                model in
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

                        Button(action: { showAddCustomGeminiModel = true }) {
                            Label("Add Custom Model...", systemImage: "plus")
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
                    .alert("Add Custom Gemini Model", isPresented: $showAddCustomGeminiModel) {
                        TextField(
                            "Model Name (e.g., gemini-3.1-pro-preview)",
                            text: $newCustomGeminiModelName)
                        Button("Add") {
                            geminiManager.addCustomModel(newCustomGeminiModelName)
                            geminiModel = newCustomGeminiModelName
                            newCustomGeminiModelName = ""
                        }
                        Button("Cancel", role: .cancel) {
                            newCustomGeminiModelName = ""
                        }
                    } message: {
                        Text("Enter the name of the model as it appears in the Gemini API.")
                    }
                }

                if isCopilot {
                    Menu {
                        let providers = ["Anthropic", "OpenAI", "Google", "xAI", "Other"]
                        ForEach(providers, id: \.self) { provider in
                            let models = copilotModelManager.chatModels.filter {
                                copilotModelManager.getProvider(for: $0) == provider
                            }
                            if !models.isEmpty {
                                Section(provider) {
                                    ForEach(models, id: \.self) { model in
                                        Button(action: { selectedCopilotModel = model }) {
                                            if selectedCopilotModel == model {
                                                Label(
                                                    copilotModelManager.displayName(for: model),
                                                    systemImage: "checkmark")
                                            } else {
                                                Text(copilotModelManager.displayName(for: model))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
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
                    .help("Select Copilot Model")
                }

                if isNvidia {
                    Menu {
                        let favoriteModels = nvidiaManager.favoriteModels.filter {
                            nvidiaDropdownModels.contains($0)
                        }
                        if !favoriteModels.isEmpty {
                            Section("Favorites") {
                                ForEach(favoriteModels, id: \.self) { model in
                                    Button(action: { selectedNvidiaModel = model }) {
                                        if selectedNvidiaModel == model {
                                            Label(
                                                nvidiaManager.displayName(for: model),
                                                systemImage: "checkmark")
                                        } else {
                                            Text(nvidiaManager.displayName(for: model))
                                        }
                                    }
                                }
                            }
                        }

                        let availableModels = nvidiaDropdownModels.filter {
                            !favoriteModels.contains($0)
                        }
                        if !availableModels.isEmpty {
                            Section("Available") {
                                ForEach(availableModels, id: \.self) { model in
                                    Button(action: { selectedNvidiaModel = model }) {
                                        if selectedNvidiaModel == model {
                                            Label(
                                                nvidiaManager.displayName(for: model),
                                                systemImage: "checkmark")
                                        } else {
                                            Text(nvidiaManager.displayName(for: model))
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Menu("Manage Favorites") {
                            ForEach(nvidiaDropdownModels, id: \.self) {
                                model in
                                Button(action: { nvidiaManager.toggleFavorite(model) }) {
                                    if nvidiaManager.isFavorite(model) {
                                        Label(
                                            nvidiaManager.displayName(for: model),
                                            systemImage: "star.fill")
                                    } else {
                                        Label(
                                            nvidiaManager.displayName(for: model),
                                            systemImage: "star")
                                    }
                                }
                            }
                        }

                        Button(action: { showAddCustomNvidiaModel = true }) {
                            Label("Add Custom Model...", systemImage: "plus")
                        }
                    } label: {
                        Image(systemName: "bolt.fill")
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
                    .help("Select NVIDIA Model")
                    .alert("Add Custom NVIDIA Model", isPresented: $showAddCustomNvidiaModel) {
                        TextField(
                            "Model Name (e.g., nvidia/model-name)",
                            text: $newCustomNvidiaModelName)
                        Button("Add") {
                            nvidiaManager.addCustomModel(newCustomNvidiaModelName)
                            selectedNvidiaModel = newCustomNvidiaModelName
                            newCustomNvidiaModelName = ""
                        }
                        Button("Cancel", role: .cancel) {
                            newCustomNvidiaModelName = ""
                        }
                    } message: {
                        Text("Enter the model name as it appears in the NVIDIA API.")
                    }
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

                // Image Resolution & Aspect Ratio pickers (Gemini image models only)
                if isGemini
                    && (geminiModel.lowercased().contains("image")
                        || geminiModel.lowercased().contains("nano-banana"))
                {
                    Menu {
                        ForEach(["0.5K", "1K", "2K", "4K"], id: \.self) { res in
                            // 0.5K (512px) only available on Gemini 3.1 Flash Image
                            let is31Flash = geminiModel.lowercased().contains("3.1-flash-image")
                            if res != "0.5K" || is31Flash {
                                Button {
                                    geminiImageResolution = res
                                } label: {
                                    if geminiImageResolution == res {
                                        Label(res, systemImage: "checkmark")
                                    } else {
                                        Text(res)
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .medium))
                            Text(geminiImageResolution)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.04))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .help("Output Resolution")

                    Menu {
                        ForEach(
                            [
                                "Default", "1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4",
                                "9:16", "16:9", "21:9", "1:4", "4:1", "1:8", "8:1",
                            ], id: \.self
                        ) { ratio in
                            Button {
                                geminiImageAspectRatio = ratio
                            } label: {
                                if geminiImageAspectRatio == ratio {
                                    Label(ratio, systemImage: "checkmark")
                                } else {
                                    Text(ratio)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "aspectratio")
                                .font(.system(size: 10, weight: .medium))
                            Text(
                                geminiImageAspectRatio == "Default"
                                    ? "Ratio" : geminiImageAspectRatio
                            )
                            .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08)
                                        : Color.black.opacity(0.04))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .help("Aspect Ratio")
                }

                // Web Search Toggle (Ollama only)
                if isOllama {
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
        }
    }

    private var inputField: some View {
        ZStack(alignment: .leading) {
            if inputText.isEmpty && !isFocused {
                Text(
                    "Ask AI anything... (type / for commands)"
                )
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
                text: $inputText,
                isFocused: $isFocused,
                font: .systemFont(ofSize: 15),
                textColor: colorScheme == .dark ? .white : .labelColor,
                maxLines: 10,
                onCommit: {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        applySlashCommand(slashMatches[slashSelectedIndex])
                    } else {
                        onSend()
                    }
                },
                onEscape: {
                    if showSlashAutocomplete {
                        showSlashAutocomplete = false
                    }
                },
                onArrowUp: {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        slashSelectedIndex = max(0, slashSelectedIndex - 1)
                        return true
                    }
                    return false
                },
                onArrowDown: {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        slashSelectedIndex = min(slashMatches.count - 1, slashSelectedIndex + 1)
                        return true
                    }
                    return false
                },
                onTab: {
                    if showSlashAutocomplete && !slashMatches.isEmpty {
                        applySlashCommand(slashMatches[slashSelectedIndex])
                        return true
                    }
                    return false
                },
                onFocusChange: { focused in
                    if focused {
                        pasteMonitor.start()
                    } else {
                        pasteMonitor.stop()
                    }
                }
            )
            .fixedSize(horizontal: false, vertical: true)
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

        let webView = NonScrollableWebView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 20), configuration: config)
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
                           new ResizeObserver(() => sendHeight()).observe(document.body);
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

        let webView = NonScrollableWebView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 20), configuration: config)
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
                        new ResizeObserver(() => sendHeight()).observe(document.body);
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @FocusState private var isEditFocused: Bool
    @State private var cachedStreamingBlocks: [MarkdownBlock] = []
    @State private var cachedStreamingContent: String = ""
    @AppStorage("ImageDownloadPath") private var imageDownloadPath: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme
    // private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect() // removed to prevent layout loops

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        return lhs.message == rhs.message && lhs.liveContent == rhs.liveContent
            && lhs.liveThinking == rhs.liveThinking && lhs.canEdit == rhs.canEdit
    }

    /// Appends a blinking cursor to the last block for streaming display.
    private func blocksWithCursor(_ blocks: [MarkdownBlock], showCursor: Bool) -> [MarkdownBlock] {
        guard showCursor, let lastBlock = blocks.last else { return blocks }
        let modifiedType: MarkdownBlockType
        switch lastBlock.type {
        case .text(let t):
            modifiedType = .text(t + " ▋")
        case .code(let lang, let code):
            modifiedType = .code(lang, code + " ▋")
        default:
            modifiedType = lastBlock.type
        }
        let cursorBlock = MarkdownBlock(type: modifiedType)
        return Array(blocks.dropLast()) + [cursorBlock]
    }

    /// Renders streaming content using cached markdown blocks.
    @ViewBuilder
    private func streamingContentView(activeContent: String) -> some View {
        let blocks =
            cachedStreamingBlocks.isEmpty
            ? Message.parseMarkdown(activeContent)
            : cachedStreamingBlocks
        let displayBlocks = blocksWithCursor(blocks, showCursor: isCursorVisible)
        MarkdownView(blocks: displayBlocks)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser {
                Spacer()
                VStack(alignment: .trailing) {
                    // Show all image attachments
                    if let attachments = message.attachments {
                        let imageAttachments = attachments.filter { $0.type == "image" }
                        if !imageAttachments.isEmpty {
                            ForEach(Array(imageAttachments.enumerated()), id: \.element.id) {
                                index, att in
                                if let image = NSImage(data: att.data) {
                                    ThumbnailView(
                                        image: image, maxWidth: 200, maxHeight: 300,
                                        messageId: message.id,
                                        coordinateSpaceName: "detailContainer",
                                        onImageTap: onImageTap
                                    )
                                    .id("\(message.currentVersionIndex ?? -1)_\(index)")
                                }
                            }
                        }
                    } else if let image = message.image {
                        // Legacy fallback for messages without attachments array
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
                        // Inline editing mode - themed style
                        VStack(alignment: .trailing, spacing: 0) {
                            // Text editor area
                            ZStack(alignment: .topLeading) {
                                if editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    Text("Edit your message…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                }
                                TextEditor(text: $editText)
                                    .font(.system(size: 13))
                                    .scrollContentBackground(.hidden)
                                    .focused($isEditFocused)
                                    .frame(minHeight: 60, maxHeight: 200)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                            }

                            // Inline action bar
                            HStack(spacing: 6) {
                                // Theme accent indicator
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: appTheme.colors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 8, height: 8)
                                    Text("Editing")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isEditing = false
                                        editText = ""
                                    }
                                } label: {
                                    Text("Cancel")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.escape, modifiers: [])

                                Button {
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
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("Send")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(
                                                LinearGradient(
                                                    colors: appTheme.colors,
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .keyboardShortcut(.return, modifiers: [.command])
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                            .padding(.top, 2)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: appTheme.colors.map { $0.opacity(0.08) },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    LinearGradient(
                                        colors: appTheme.colors.map {
                                            $0.opacity(isEditFocused ? 0.5 : 0.2)
                                        },
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: isEditFocused ? 1.5 : 1
                                )
                        )
                        .frame(maxWidth: maxBubbleWidth)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                isEditFocused = true
                            }
                        }
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
                        let isActivelyStreaming = liveContent != nil || message.isStreaming

                        if isActivelyStreaming && activeContent.isEmpty
                            && (liveThinking ?? message.thinkingContent) == nil
                        {
                            ThinkingIndicator()
                        } else if !activeContent.isEmpty || isActivelyStreaming {
                            if isActivelyStreaming {
                                streamingContentView(activeContent: activeContent)
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
                // Cache parsed markdown blocks to avoid re-parsing on cursor blinks
                cachedStreamingContent = val
                cachedStreamingBlocks = Message.parseMarkdown(val)
            } else if newValue == nil {
                // Streaming ended, clear cache
                cachedStreamingBlocks = []
                cachedStreamingContent = ""
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

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case sidebarTools = "Sidebar Tools"
    case appearance = "Appearance"
    case quickAI = "Quick AI"
    case quickTools = "Quick Tools"
    case webOverlay = "Web Overlay"
    case apis = "APIs"
    case cli = "CLI"
    case customWebViews = "Custom Web Views"
    case systemPrompt = "System Prompt"
    case autocomplete = "Autocomplete"
    case downloads = "Downloads"
    case browserAutomation = "Browser Automation"
    case shortcuts = "Shortcuts"
    case updates = "Updates"
    case dataPrivacy = "Data & Privacy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .sidebarTools: return "slider.horizontal.3"
        case .appearance: return "paintbrush"
        case .quickAI: return "window.shade.open"
        case .quickTools: return "briefcase"
        case .webOverlay: return "macwindow.on.rectangle"
        case .apis: return "key.horizontal"
        case .cli: return "terminal"
        case .customWebViews: return "macwindow"
        case .systemPrompt: return "text.quote"
        case .autocomplete: return "text.cursor"
        case .downloads: return "arrow.down.doc"
        case .browserAutomation: return "play.desktopcomputer"
        case .shortcuts: return "command"
        case .updates: return "arrow.triangle.2.circlepath"
        case .dataPrivacy: return "externaldrive"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .sidebarTools: return .yellow
        case .appearance: return .pink
        case .quickAI: return .blue
        case .quickTools: return .orange
        case .webOverlay: return .purple
        case .apis: return .blue
        case .cli: return .green
        case .customWebViews: return .teal
        case .systemPrompt: return .yellow
        case .autocomplete: return .mint
        case .downloads: return .blue
        case .browserAutomation: return .orange
        case .shortcuts: return .gray
        case .updates: return .green
        case .dataPrivacy: return .red
        }
    }

    enum Category: String, CaseIterable {
        case app = ""
        case overlays = "Overlays"
        case providers = "Providers"
        case web = "Web"
        case advanced = "Advanced"
    }

    var category: Category {
        switch self {
        case .general, .sidebarTools, .appearance: return .app
        case .quickAI, .quickTools, .webOverlay: return .overlays
        case .apis, .cli: return .providers
        case .customWebViews: return .web
        case .systemPrompt, .autocomplete, .downloads, .browserAutomation, .shortcuts, .updates,
            .dataPrivacy:
            return .advanced
        }
    }

    static func tabs(for category: Category) -> [SettingsTab] {
        allCases.filter { $0.category == category }
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
    @AppStorage("MenuBarClickAction") private var menuBarClickAction: String = "quickAI"
    @AppStorage("MenuBarRightClickAction") private var menuBarRightClickAction: String = "off"
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("EnableQuickAI") private var enableQuickAI = true
    @AppStorage("QuickAIBackgroundOpacity") private var quickAIBackgroundOpacity: Double = 0.18
    @AppStorage("QuickAICommandBarVibrancy") private var quickAICommandBarVibrancy: Double = 0.55
    @AppStorage("QuickAITintIntensity") private var quickAITintIntensity: Double = 0.5
    @AppStorage("QuickAIChatBarTintIntensity") private var quickAIChatBarTintIntensity: Double = 0.5
    @AppStorage("BackgroundImagePath") private var backgroundImagePath: String = ""
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String =
        "llama-3.1-70b-instruct"
    @AppStorage("ImageDownloadPath") private var imageDownloadPath: String = ""
    @AppStorage("BrowserAutomationPath") private var browserAutomationPath: String = ""

    // AI Autocomplete settings
    @AppStorage("EnableAIAutocomplete") private var enableAutocomplete: Bool = false
    @AppStorage("AIAutocompleteBackend") private var autocompleteBackend: String = "Ollama"
    @AppStorage("AIAutocompleteModel") private var autocompleteModel: String = ""
    @AppStorage("AIAutocompleteDebounceMs") private var autocompleteDebounceMs: Int = 500
    @AppStorage("AIAutocompleteCustomInstruction") private var autocompletePersona: String = ""
    @AppStorage("AIAutocompleteBlacklist") private var autocompleteBlacklist: String = "[]"
    @AppStorage("AIAutocompleteMemoryEnabled") private var autocompleteMemory: Bool = true
    @AppStorage("AIAutocompleteCompletionLength") private var autocompleteCompletionLength: String =
        "Medium (~ 2 - 4 words)"
    @AppStorage("EnablePreReleaseUpdates") private var enablePreRelease: Bool = false
    @AppStorage("EnableWebOverlay") private var enableWebOverlay: Bool = true
    @AppStorage("QuickAIClickOutsideCloses") private var quickAIClickOutsideCloses: Bool = false
    @AppStorage("WebOverlayClickOutsideCloses") private var webOverlayClickOutsideCloses: Bool =
        false
    @AppStorage("EnableQuickTools") private var enableQuickTools: Bool = true
    @AppStorage("QuickToolsClickOutsideCloses") private var quickToolsClickOutsideCloses: Bool =
        false
    @AppStorage("QuickToolsBackgroundOpacity") private var quickToolsBackgroundOpacity: Double =
        0.25
    @AppStorage("QuickToolsTintIntensity") private var quickToolsTintIntensity: Double = 0.5
    @AppStorage("WebOverlayBackgroundOpacity") private var webOverlayBackgroundOpacity: Double =
        0.25
    @AppStorage("WebOverlayTintIntensity") private var webOverlayTintIntensity: Double = 0.5
    @AppStorage("ShowCompare") private var showCompareTool: Bool = true
    @AppStorage("ShowCommands") private var showCommandsTool: Bool = true
    @AppStorage("ShowQuizMe") private var showQuizMeTool: Bool = true
    @AppStorage("ShowImageGen") private var showImageGenTool: Bool = true
    @AppStorage("ShowFileCreator") private var showFileCreatorTool: Bool = true
    @AppStorage("ShowFolderContext") private var showFolderContextTool: Bool = true
    @AppStorage("ShowWebView") private var showWebViewTool: Bool = true
    @AppStorage("ShowBrowserAutomation") private var showBrowserAutomationTool: Bool = true
    @AppStorage("ToolOrder") private var toolOrderRaw: String =
        "compare,commands,quizme,imagegen,filecreator,foldercontext,webview,browserautomation"
    @State private var draggedTool: String? = nil

    @EnvironmentObject var chatManager: ChatManager
    @ObservedObject var ollamaManager = OllamaModelManager.shared
    @ObservedObject var geminiManager = GeminiModelManager.shared
    @ObservedObject var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject var accountManager = AccountManager.shared
    @ObservedObject var copilotService = GitHubCopilotService.shared
    @ObservedObject var updateManager = UpdateManager.shared
    @ObservedObject var webOverlayManager = WebOverlayManager.shared
    @ObservedObject var apiProviderModelStore = APIProviderModelStore.shared
    @State private var showAddCustomOllamaModel = false
    @State private var newCustomModelName = ""
    @State private var showAddCustomGeminiModel = false
    @State private var newCustomGeminiModelName = ""
    @State private var newCustomNvidiaModelName = ""
    @State private var editingAccountId: UUID? = nil
    @State private var editingAccountName: String = ""
    @State private var customModelProviderID: String? = nil
    @State private var draftCustomProviderModel: String = ""
    @State private var addAPIProviderID: String? = nil
    @State private var draftAPIKey: String = ""
    @State private var draftAPIEndpoint: String = ""
    @State private var draftProviderPresetModel: String = ""
    @State private var draftProviderCustomModel: String = ""
    @State private var draftModelChoiceMode: String = "preset"
    @State private var expandedModelProviders: Set<String> = []
    @State private var fetchingProviders: Set<String> = []

    // Custom web views
    @AppStorage("CustomWebViews") private var customWebViewsJSON: String = "[]"
    @State private var showAddCustomWebView = false
    @State private var newWebViewName = ""
    @State private var newWebViewURL = ""
    @State private var newWebViewIcon = "globe"

    // MARK: - Updates Section

    @ViewBuilder
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Software Update",
                systemImage: "arrow.triangle.2.circlepath",
                tint: .green,
                description: "Version checks, release channel, and extension update paths."
            ) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Version")
                    Text(updateManager.currentVersion)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if updateManager.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if updateManager.updateAvailable {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("v\(updateManager.latestVersion) available")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                }
            }

            Toggle(isOn: $enablePreRelease) {
                Label("Include Pre-Releases", systemImage: "flask")
            }
            .toggleStyle(.switch)
            .onChange(of: enablePreRelease) {
                Task { await updateManager.checkForUpdates() }
            }

            LabeledContent {
                HStack {
                    TextField("Path", text: $updateManager.chromeExtensionPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message =
                            "Select the folder containing your unpacked Chrome extension"
                        if panel.runModal() == .OK {
                            updateManager.chromeExtensionPath = panel.url?.path ?? ""
                        }
                    }
                    if !updateManager.chromeExtensionPath.isEmpty {
                        Button(action: { updateManager.chromeExtensionPath = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Label("Chrome Extension Folder", systemImage: "puzzlepiece.extension")
            }
            Text("The unpacked Chrome extension folder. Used to auto-update the extension.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent {
                HStack {
                    TextField("Path", text: $updateManager.safariExtensionPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message =
                            "Select the folder containing your Safari extension"
                        if panel.runModal() == .OK {
                            updateManager.safariExtensionPath = panel.url?.path ?? ""
                        }
                    }
                    if !updateManager.safariExtensionPath.isEmpty {
                        Button(action: { updateManager.safariExtensionPath = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Label("Safari Extension Folder", systemImage: "safari")
            }
            Text("The Safari extension folder. Used to auto-update the extension.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                AppDelegate.shared?.showUpdateWindow()
                Task { await updateManager.checkForUpdates() }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }

            if let error = updateManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Appearance Section

    @AppStorage("ShowSplashScreen") private var showSplashScreen: Bool = true

    @ViewBuilder
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Appearance",
                systemImage: "paintbrush",
                tint: .pink,
                description: "Theme, launch visuals, and background image."
            ) {
            Toggle(isOn: $showSplashScreen) {
                Label("Show Splash Screen on Launch", systemImage: "sparkles.rectangle.stack")
            }
            .toggleStyle(.switch)
            LabeledContent {
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
            } label: {
                Label("Theme Color", systemImage: "circle.lefthalf.filled")
            }

            LabeledContent {
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
                    if !backgroundImagePath.isEmpty {
                        Button(action: { backgroundImagePath = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Label("Background Image", systemImage: "photo")
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - General Section

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "General",
                systemImage: "gear",
                tint: .gray,
                description: "Menu bar presence and click behavior."
            ) {
            Toggle(isOn: $showMenuBar) {
                Label("Show Menu Bar Icon", systemImage: "menubar.rectangle")
            }
            .toggleStyle(.switch)

            if showMenuBar {
                Picker("Menu Bar Click Action", selection: $menuBarClickAction) {
                    Text("Toggle Quick AI").tag("quickAI")
                    Text("Toggle Quick Tools").tag("quickTools")
                    Text("Toggle Web Overlay").tag("webOverlay")
                }
                .pickerStyle(.menu)

                Picker("Menu Bar Right Click", selection: $menuBarRightClickAction) {
                    Text("Off").tag("off")
                    Text("Toggle Quick AI").tag("quickAI")
                    Text("Toggle Quick Tools").tag("quickTools")
                    Text("Toggle Web Overlay").tag("webOverlay")
                }
                .pickerStyle(.menu)
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private var sidebarToolsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Sidebar Tools",
                systemImage: "slider.horizontal.3",
                tint: .yellow,
                description: "Choose which tools appear in the app sidebar and reorder them."
            ) {
            Toggle(isOn: $showCompareTool) {
                Label("Compare", systemImage: "square.split.2x1")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showCommandsTool) {
                Label("Commands", systemImage: "command")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showQuizMeTool) {
                Label("Quiz Me", systemImage: "questionmark.bubble")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showImageGenTool) {
                Label("Image Generation", systemImage: "paintbrush")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showFileCreatorTool) {
                Label("File Creator", systemImage: "doc.richtext")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showFolderContextTool) {
                Label("Folder Context", systemImage: "folder.badge.questionmark")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showWebViewTool) {
                Label("Web View", systemImage: "globe")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $showBrowserAutomationTool) {
                Label("Browser Automation", systemImage: "cursorarrow.motionlines.click")
            }
            .toggleStyle(.switch)

            Divider()

            Text("Drag To Reorder")
                .font(.callout.weight(.semibold))

            ForEach(toolOrder, id: \.self) { toolId in
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Image(systemName: toolIcon(for: toolId))
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundStyle(.secondary)

                    Text(toolLabel(for: toolId))
                        .font(.callout)

                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .opacity(draggedTool == toolId ? 0.45 : 1.0)
                .onDrag {
                    draggedTool = toolId
                    return NSItemProvider(object: toolId as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: SettingsToolDropDelegate(
                        item: toolId,
                        draggedItem: $draggedTool,
                        toolOrderRaw: $toolOrderRaw,
                        toolOrder: toolOrder
                    ))
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Sidebar Tools Preferences

    private var toolOrder: [String] {
        let raw = toolOrderRaw.split(separator: ",").map(String.init)
        let allTools = [
            "compare", "commands", "quizme", "imagegen", "filecreator", "foldercontext", "webview",
            "browserautomation",
        ]
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
        case "filecreator": return "doc.richtext"
        case "foldercontext": return "folder.badge.questionmark"
        case "webview": return "globe"
        case "browserautomation": return "cursorarrow.motionlines.click"
        default: return "questionmark"
        }
    }

    private func toolLabel(for id: String) -> String {
        switch id {
        case "compare": return "Compare"
        case "commands": return "Commands"
        case "quizme": return "Quiz Me"
        case "imagegen": return "Image Generation"
        case "filecreator": return "File Creator"
        case "foldercontext": return "Folder Context"
        case "webview": return "Web View"
        case "browserautomation": return "Browser Automation"
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

    // MARK: - Sidebar Tools Drag & Drop

    struct SettingsToolDropDelegate: DropDelegate {
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

            withAnimation(.easeInOut(duration: 0.18)) {
                order.move(
                    fromOffsets: IndexSet(integer: fromIndex),
                    toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                toolOrderRaw = order.joined(separator: ",")
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            DropProposal(operation: .move)
        }
    }

    // MARK: - Web Overlay Section

    @ViewBuilder
    private var webOverlaySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Web Overlay",
                systemImage: "macwindow.on.rectangle",
                tint: .purple,
                description: "Floating browser panel behavior, shortcut, and enabled services."
            ) {
            Toggle(isOn: $enableWebOverlay) {
                Label("Enable Web Overlay Hotkey", systemImage: "globe")
            }
            .toggleStyle(.switch)

            Toggle(isOn: $webOverlayClickOutsideCloses) {
                Label("Click Outside Closes Web Overlay", systemImage: "cursorarrow.click")
            }
            .toggleStyle(.switch)

            if enableWebOverlay {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .toggleWebOverlay)
                } label: {
                    Label("Open Web Overlay", systemImage: "command")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Enabled Services", systemImage: "checklist")
                        .font(.headline)

                    ForEach(WebOverlayService.allCases) { service in
                        Toggle(
                            isOn: Binding(
                                get: { webOverlayManager.isServiceEnabled(service) },
                                set: { webOverlayManager.setServiceEnabled(service, enabled: $0) }
                            )
                        ) {
                            Label(service.rawValue, systemImage: service.icon)
                        }
                        .toggleStyle(.switch)
                    }
                }
                .padding(.vertical, 4)

                Text(
                    "Toggle a floating web panel for AI chat services. The overlay stays on top and remembers your sessions."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            }

            if enableWebOverlay {
                settingsCard(
                    "Web Overlay Appearance",
                    systemImage: "paintbrush",
                    tint: .indigo,
                    description: "Control the glass treatment and theme tint strength."
                ) {
                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { webOverlayBackgroundOpacity },
                                set: { webOverlayBackgroundOpacity = min(max($0, 0.05), 1.0) }
                            ),
                            in: 0.05...1.0
                        )
                        Text("\(Int(min(max(webOverlayBackgroundOpacity, 0.05), 1.0) * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                } label: {
                    Label("Glass Opacity", systemImage: "circle.dotted")
                }

                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { webOverlayTintIntensity },
                                set: { webOverlayTintIntensity = min(max($0, 0.0), 1.0) }
                            ),
                            in: 0.0...1.0
                        )
                        Text("\(Int(min(max(webOverlayTintIntensity, 0.0), 1.0) * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                } label: {
                    Label("Theme Tint", systemImage: "paintbrush.pointed")
                }
            }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Quick AI Section

    @ViewBuilder
    private var quickToolsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Quick Tools",
                systemImage: "briefcase",
                tint: .orange,
                description: "Global shortcut and dismissal behavior for the tools launcher."
            ) {
            Toggle(isOn: $enableQuickTools) {
                Label("Enable Quick Tools Hotkey", systemImage: "hammer")
            }
            .toggleStyle(.switch)

            if enableQuickTools {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .toggleQuickTools)
                } label: {
                    Label("Global Shortcut", systemImage: "command")
                }

                Toggle(isOn: $quickToolsClickOutsideCloses) {
                    Label("Click Outside Closes Quick Tools", systemImage: "cursorarrow.click")
                }
                .toggleStyle(.switch)
            }
            }

            if enableQuickTools {
                settingsCard(
                    "Quick Tools Appearance",
                    systemImage: "paintbrush",
                    tint: .yellow,
                    description: "Adjust the glass opacity and theme tint."
                ) {
                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { quickToolsBackgroundOpacity },
                                set: { quickToolsBackgroundOpacity = min(max($0, 0.05), 1.0) }
                            ),
                            in: 0.05...1.0
                        )
                        Text("\(Int(min(max(quickToolsBackgroundOpacity, 0.05), 1.0) * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                } label: {
                    Label("Glass Opacity", systemImage: "circle.dotted")
                }

                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { quickToolsTintIntensity },
                                set: { quickToolsTintIntensity = min(max($0, 0.0), 1.0) }
                            ),
                            in: 0.0...1.0
                        )
                        Text("\(Int(min(max(quickToolsTintIntensity, 0.0), 1.0) * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                } label: {
                    Label("Theme Tint", systemImage: "paintbrush.pointed")
                }
            }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private var quickAISection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Quick AI Settings",
                systemImage: "bolt.fill",
                tint: .blue,
                description: "Shortcut and dismissal behavior for Quick AI."
            ) {
            Toggle(isOn: $enableQuickAI) {
                Label("Enable Quick AI Hotkey", systemImage: "bolt.fill")
            }
            .toggleStyle(.switch)

            if enableQuickAI {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .toggleQuickAI)
                } label: {
                    Label("Global Shortcut", systemImage: "command")
                }

                Toggle(isOn: $quickAIClickOutsideCloses) {
                    Label("Click Outside Closes Quick AI", systemImage: "cursorarrow.click")
                }
                .toggleStyle(.switch)
            }
            }

            settingsCard(
                "Quick AI Appearance",
                systemImage: "window.shade.open",
                tint: .cyan,
                description: "Tune opacity, vibrancy, and tint across the Quick AI surfaces."
            ) {
            LabeledContent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { quickAIBackgroundOpacity },
                            set: { quickAIBackgroundOpacity = min(max($0, 0.05), 1.0) }
                        ),
                        in: 0.05...1.0
                    )
                    Text("\(Int(min(max(quickAIBackgroundOpacity, 0.05), 1.0) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } label: {
                Label("Background Opacity", systemImage: "circle.dotted")
            }

            LabeledContent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { quickAICommandBarVibrancy },
                            set: { quickAICommandBarVibrancy = min(max($0, 0.05), 1.0) }
                        ),
                        in: 0.05...1.0
                    )
                    Text("\(Int(min(max(quickAICommandBarVibrancy, 0.05), 1.0) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } label: {
                Label("Chat Bar Vibrancy", systemImage: "sparkle")
            }

            LabeledContent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { quickAIChatBarTintIntensity },
                            set: { quickAIChatBarTintIntensity = min(max($0, 0.0), 1.0) }
                        ),
                        in: 0.0...1.0
                    )
                    Text("\(Int(min(max(quickAIChatBarTintIntensity, 0.0), 1.0) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } label: {
                Label("Chat Bar Tint", systemImage: "paintbrush.pointed")
            }

            LabeledContent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { quickAITintIntensity },
                            set: { quickAITintIntensity = min(max($0, 0.0), 1.0) }
                        ),
                        in: 0.0...1.0
                    )
                    Text("\(Int(min(max(quickAITintIntensity, 0.0), 1.0) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } label: {
                Label("Glass Tint", systemImage: "rectangle.on.rectangle")
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    private func accounts(for provider: APIProviderDefinition) -> [ProviderAccount] {
        switch provider.accountType {
        case .gemini: return accountManager.geminiAccounts()
        case .chatgpt: return accountManager.chatGPTAccounts()
        case .claude: return accountManager.claudeAccounts()
        case .grok: return accountManager.grokAccounts()
        case .kimi: return accountManager.kimiAccounts()
        case .mistral: return accountManager.mistralAccounts()
        case .nvidia: return accountManager.nvidiaAccounts()
        case .customapi: return accountManager.customAPIAccounts()
        case .ollama, .copilot: return []
        }
    }

    private func addAccountLabel(for provider: APIProviderDefinition, count: Int) -> String {
        switch provider.accountType {
        case .customapi: return "Custom API \(count + 1)"
        default: return "\(provider.title) \(count + 1)"
        }
    }

    private func providerAccountDescription(for provider: APIProviderDefinition) -> String {
        switch provider.id {
        case "gemini": return "Google Gemini API keys with sparkle-style model management."
        case "chatgpt": return "OpenAI API keys with GPT presets and custom model IDs."
        case "claude": return "Anthropic Claude keys and curated model presets."
        case "grok": return "xAI Grok keys and fast preset selection."
        case "kimi": return "Moonshot Kimi keys and reasoning-focused presets."
        case "mistral": return "Mistral API keys with hosted model presets."
        case "nvidia": return "NVIDIA NIM API keys and catalog presets."
        case "customapi": return "Bring your own compatible API key and model IDs."
        default: return ""
        }
    }

    private func providerAccountsExist(_ provider: APIProviderDefinition) -> Bool {
        accounts(for: provider).contains {
            !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func resetAddAPIProviderDrafts(for provider: APIProviderDefinition? = nil) {
        draftAPIKey = ""
        draftAPIEndpoint = ""
        draftProviderCustomModel = ""
        let currentProvider = provider
            ?? addAPIProviderID.flatMap { APIProviderRegistry.provider(for: $0) }
        draftProviderPresetModel = currentProvider?.presetModels.first ?? ""
        draftModelChoiceMode = currentProvider?.presetModels.isEmpty == true ? "custom" : "preset"
    }

    private func apiKeyBinding(for account: ProviderAccount, provider: APIProviderDefinition)
        -> Binding<String>
    {
        Binding(
            get: { account.apiKey },
            set: { newKey in
                accountManager.updateAccount(id: account.id, apiKey: newKey)
                Task { await fetchModelsIfPossible(for: provider, account: account, apiKey: newKey) }
            }
        )
    }

    private func endpointBinding(for account: ProviderAccount) -> Binding<String> {
        Binding(
            get: { account.endpoint },
            set: { newValue in
                accountManager.updateAccount(id: account.id, endpoint: newValue)
            }
        )
    }

    @MainActor
    private func fetchModelsIfPossible(
        for provider: APIProviderDefinition,
        account: ProviderAccount,
        apiKey: String? = nil
    ) async {
        let key = (apiKey ?? account.apiKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard provider.fetchStrategy != .none else { return }

        fetchingProviders.insert(provider.id)
        defer { fetchingProviders.remove(provider.id) }

        do {
            let models = try await APIModelFetcher.shared.fetchModels(
                for: provider,
                apiKey: key,
                endpointOverride: account.endpoint
            )
            apiProviderModelStore.replaceFetchedModels(models, for: provider)
        } catch {
            // Keep presets/customs available even if fetch fails.
        }
    }

    private func initialModelForDraft(provider: APIProviderDefinition) -> String {
        if draftModelChoiceMode == "custom" {
            return draftProviderCustomModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return draftProviderPresetModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveAddedProvider(_ provider: APIProviderDefinition) {
        let key = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        let name = provider.title
        accountManager.addAccount(
            providerType: provider.accountType,
            displayName: name,
            apiKey: key,
            endpoint: draftAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let initialModel = initialModelForDraft(provider: provider)
        if !initialModel.isEmpty {
            if draftModelChoiceMode == "custom" {
                apiProviderModelStore.addCustomModel(initialModel, for: provider)
            } else {
                apiProviderModelStore.addPresetModel(initialModel, for: provider)
            }
            apiProviderModelStore.setSelectedModel(initialModel, for: provider)
        }

        if let account = accounts(for: provider).last {
            Task { await fetchModelsIfPossible(for: provider, account: account, apiKey: key) }
        }

        addAPIProviderID = nil
        resetAddAPIProviderDrafts()
    }

    @ViewBuilder
    private func accountRows(for provider: APIProviderDefinition) -> some View {
        let providerAccounts = accounts(for: provider)
        VStack(spacing: 12) {
            ForEach(providerAccounts) { account in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label(account.displayName, systemImage: "person.crop.circle")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button {
                            editingAccountName = account.displayName
                            editingAccountId = account.id
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if providerAccounts.count > 1 {
                            Button(role: .destructive) {
                                accountManager.removeAccount(id: account.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if editingAccountId == account.id {
                        HStack(spacing: 8) {
                            TextField("Name", text: $editingAccountName)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                accountManager.renameAccount(
                                    id: account.id, newName: editingAccountName)
                                editingAccountId = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    SecureField("API Key", text: apiKeyBinding(for: account, provider: provider))
                    .textFieldStyle(.roundedBorder)

                    if provider.accountType == .customapi {
                        TextField("Base URL", text: endpointBinding(for: account))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1)
                )
            }

            Button {
                addAPIProviderID = provider.id
                resetAddAPIProviderDrafts(for: provider)
            } label: {
                Label(providerAccounts.isEmpty ? "Add API Key" : "Add Account", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(provider.tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(provider.tint.opacity(0.2), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func modelPickerCard(for provider: APIProviderDefinition) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Preset and custom models live together under one provider.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    if !provider.presetModels.isEmpty {
                        Section("Presets") {
                            ForEach(provider.presetModels, id: \.self) { model in
                                Button(model) {
                                    apiProviderModelStore.addPresetModel(model, for: provider)
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Custom Model…") {
                        customModelProviderID = provider.id
                    }
                } label: {
                    Label("Add Model", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(provider.tint.opacity(0.14))
                )
            }

            Picker("Default Model", selection: Binding(
                get: { apiProviderModelStore.selectedModel(for: provider) },
                set: { apiProviderModelStore.setSelectedModel($0, for: provider) }
            )) {
                ForEach(apiProviderModelStore.enabledModels(for: provider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)

            let models = apiProviderModelStore.combinedModels(for: provider)
            let enabledModels = apiProviderModelStore.enabledModels(for: provider)
            if models.isEmpty {
                Text("No models added yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Label(
                        "\(enabledModels.count) enabled of \(models.count)",
                        systemImage: "checklist"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    if fetchingProviders.contains(provider.id) {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Button(expandedModelProviders.contains(provider.id) ? "Collapse" : "Expand") {
                        if expandedModelProviders.contains(provider.id) {
                            expandedModelProviders.remove(provider.id)
                        } else {
                            expandedModelProviders.insert(provider.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(provider.tint.opacity(0.12)))
                }

                if expandedModelProviders.contains(provider.id) {
                    HStack {
                        Button("Select All") {
                            apiProviderModelStore.selectAll(for: provider)
                        }
                        .buttonStyle(.plain)
                        Button("Unselect All") {
                            apiProviderModelStore.unselectAll(for: provider)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10)
                    {
                        ForEach(models, id: \.self) { model in
                            Button {
                                apiProviderModelStore.toggleEnabled(model, for: provider)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(
                                        systemName: enabledModels.contains(model)
                                            ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(
                                            enabledModels.contains(model)
                                                ? provider.tint : .secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model)
                                            .font(
                                                .system(
                                                    size: 12, weight: .medium,
                                                    design: .monospaced))
                                            .lineLimit(2)
                                        Text(
                                            apiProviderModelStore.isBuiltInPreset(model, for: provider)
                                                ? "Preset"
                                                : apiProviderModelStore.fetchedModels(for: provider)
                                                    .contains(model) ? "Fetched" : "Custom"
                                        )
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !apiProviderModelStore.isBuiltInPreset(model, for: provider)
                                        && !apiProviderModelStore.fetchedModels(for: provider)
                                            .contains(model)
                                    {
                                        Button(role: .destructive) {
                                            apiProviderModelStore.removeModel(model, for: provider)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(
                                            enabledModels.contains(model)
                                                ? provider.tint.opacity(0.12)
                                                : Color.white.opacity(0.5))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(
                                            enabledModels.contains(model)
                                                ? provider.tint.opacity(0.35)
                                                : Color.white.opacity(0.4), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func apiProviderCard(_ provider: APIProviderDefinition) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [provider.tint.opacity(0.95), provider.tint.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: provider.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(providerAccountDescription(for: provider))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            accountRows(for: provider)
            modelPickerCard(for: provider)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.74), provider.tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
        .task(id: accounts(for: provider).map(\.apiKey).joined(separator: "|")) {
            if let firstAccount = accounts(for: provider).first {
                await fetchModelsIfPossible(for: provider, account: firstAccount)
            }
        }
    }

    @ViewBuilder
    private var apisSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud APIs")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Configured providers only. Add a key, fetch models, then enable what you want.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(APIProviderRegistry.providers.filter { !providerAccountsExist($0) }) {
                        provider in
                        Button {
                            addAPIProviderID = provider.id
                            resetAddAPIProviderDrafts(for: provider)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: provider.icon)
                                Text(provider.title)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(provider.tint.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(APIProviderRegistry.providers.filter { providerAccountsExist($0) }) { provider in
                apiProviderCard(provider)
            }

            if APIProviderRegistry.providers.filter({ providerAccountsExist($0) }).isEmpty {
                Text("No API providers configured yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    @ViewBuilder
    private var cliSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CLI Providers")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Local and developer-adjacent providers live here now.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                copilotSection
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.74), Color.indigo.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 16) {
                ollamaSection
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.74), Color.green.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - AI Providers Section

    @ViewBuilder
    private var geminiSection: some View {
        let geminiAccts = accountManager.geminiAccounts()
        Section(header: Label("Gemini API", systemImage: "diamond")) {
            ForEach(geminiAccts) { (account: ProviderAccount) in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if editingAccountId == account.id {
                            TextField("Name", text: $editingAccountName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 150)
                            Button("Save") {
                                accountManager.renameAccount(
                                    id: account.id, newName: editingAccountName)
                                editingAccountId = nil
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Label(account.displayName, systemImage: "person.circle")
                                .font(.headline)
                            Spacer()
                            Button {
                                editingAccountName = account.displayName
                                editingAccountId = account.id
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            if geminiAccts.count > 1 {
                                Button(role: .destructive) {
                                    accountManager.removeAccount(id: account.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    SecureField(
                        "API Key",
                        text: Binding(
                            get: { account.apiKey },
                            set: { newKey in
                                accountManager.updateAccount(id: account.id, apiKey: newKey)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 4)
            }

            Picker(selection: $geminiModel) {
                ForEach(GeminiModelManager.shared.availableModels, id: \.self) { model in
                    Text(GeminiModelManager.shared.displayName(for: model)).tag(model)
                }
            } label: {
                Label("Default Model", systemImage: "cpu")
            }

            Button {
                accountManager.addAccount(
                    providerType: .gemini, displayName: "Gemini \(geminiAccts.count + 1)")
            } label: {
                Label("Add Gemini Account", systemImage: "plus.circle")
            }
        }

        Section(header: Label("Gemini Custom Models", systemImage: "sparkles")) {
            HStack {
                TextField(
                    "Add model (e.g. gemini-3.1-pro-preview)", text: $newCustomGeminiModelName
                )
                .textFieldStyle(.roundedBorder)
                Button("Add") {
                    geminiManager.addCustomModel(newCustomGeminiModelName)
                    newCustomGeminiModelName = ""
                }
            }

            ForEach(geminiManager.customModels, id: \.self) { model in
                HStack {
                    Text(model)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        geminiManager.removeCustomModel(model)
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

        Section(header: Label("Gemini Favorited Models", systemImage: "star.fill")) {
            if geminiManager.favoriteModels.isEmpty {
                Text("No favorite models")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(geminiManager.favoriteModels, id: \.self) { model in
                    HStack {
                        Text(model)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            geminiManager.toggleFavorite(model)
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
        }
    }

    @ViewBuilder
    private var ollamaSection: some View {
        let ollamaAccts = accountManager.ollamaAccounts()
        Section(header: Label("Ollama", systemImage: "server.rack")) {
            ForEach(ollamaAccts) { (account: ProviderAccount) in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if editingAccountId == account.id {
                            TextField("Name", text: $editingAccountName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 150)
                            Button("Save") {
                                accountManager.renameAccount(
                                    id: account.id, newName: editingAccountName)
                                editingAccountId = nil
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Label(account.displayName, systemImage: "person.circle")
                                .font(.headline)
                            Spacer()
                            Button {
                                editingAccountName = account.displayName
                                editingAccountId = account.id
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            if ollamaAccts.count > 1 {
                                Button(role: .destructive) {
                                    accountManager.removeAccount(id: account.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    TextField(
                        "Endpoint URL",
                        text: Binding(
                            get: { account.endpoint },
                            set: { newURL in
                                accountManager.updateAccount(id: account.id, endpoint: newURL)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 4)
            }

            Button {
                accountManager.addAccount(
                    providerType: .ollama, displayName: "Ollama \(ollamaAccts.count + 1)",
                    endpoint: "http://localhost:11434")
            } label: {
                Label("Add Ollama Account", systemImage: "plus.circle")
            }
        }

        Section(header: Label("Ollama Custom Models", systemImage: "cube")) {
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
                        .font(.system(.callout, design: .monospaced))
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

        Section(header: Label("Ollama Favorited Models", systemImage: "star.fill")) {
            if ollamaManager.favoriteModels.isEmpty {
                Text("No favorite models")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(ollamaManager.favoriteModels, id: \.self) { model in
                    HStack {
                        Text(model)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            ollamaManager.toggleFavorite(model)
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
        }
    }

    @ViewBuilder
    private var nvidiaSection: some View {
        let nvidiaAccts = accountManager.nvidiaAccounts()
        Section(header: Label("NVIDIA API", systemImage: "bolt.fill")) {
            ForEach(nvidiaAccts) { (account: ProviderAccount) in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if editingAccountId == account.id {
                            TextField("Name", text: $editingAccountName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 150)
                            Button("Save") {
                                accountManager.renameAccount(
                                    id: account.id, newName: editingAccountName)
                                editingAccountId = nil
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Label(account.displayName, systemImage: "person.circle")
                                .font(.headline)
                            Spacer()
                            Button {
                                editingAccountName = account.displayName
                                editingAccountId = account.id
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            if nvidiaAccts.count > 1 {
                                Button(role: .destructive) {
                                    accountManager.removeAccount(id: account.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    SecureField(
                        "API Key",
                        text: Binding(
                            get: { account.apiKey },
                            set: { newKey in
                                accountManager.updateAccount(id: account.id, apiKey: newKey)
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.vertical, 4)
            }

            Picker(selection: $selectedNvidiaModel) {
                ForEach(NvidiaModelManager.shared.sortedModels, id: \.self) { model in
                    Text(NvidiaModelManager.shared.displayName(for: model)).tag(model)
                }
            } label: {
                Label("Default Model", systemImage: "cpu")
            }

            Button {
                accountManager.addAccount(
                    providerType: .nvidia, displayName: "NVIDIA \(nvidiaAccts.count + 1)")
            } label: {
                Label("Add NVIDIA Account", systemImage: "plus.circle")
            }
        }

        Section(header: Label("NVIDIA Custom Models", systemImage: "bolt")) {
            HStack {
                TextField(
                    "Add model (e.g. meta/llama-3.1-405b-instruct)",
                    text: $newCustomNvidiaModelName
                )
                .textFieldStyle(.roundedBorder)
                Button("Add") {
                    nvidiaManager.addCustomModel(newCustomNvidiaModelName)
                    newCustomNvidiaModelName = ""
                }
            }

            ForEach(nvidiaManager.customModels, id: \.self) { model in
                HStack {
                    Text(model)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        nvidiaManager.removeCustomModel(model)
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

        Section(header: Label("NVIDIA Favorited Models", systemImage: "star.fill")) {
            if nvidiaManager.favoriteModels.isEmpty {
                Text("No favorite models")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(nvidiaManager.favoriteModels, id: \.self) { model in
                    HStack {
                        Text(model)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            nvidiaManager.toggleFavorite(model)
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
        }
    }

    @ViewBuilder
    private var copilotSection: some View {
        Section(
            header: Label("GitHub Copilot", systemImage: "chevron.left.forwardslash.chevron.right")
        ) {
            let copilotAccts = accountManager.copilotAccounts()

            // Show each authenticated account
            ForEach(copilotAccts) { (account: ProviderAccount) in
                let isAcctAuth = copilotService.isAccountAuthenticated(account.id)
                HStack {
                    if isAcctAuth {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        let ghUser = copilotService.accountAuthState[account.id]?.userName ?? ""
                        Text(ghUser.isEmpty ? "GitHub Copilot" : "GitHub Copilot (\(ghUser))")
                            .font(.headline)
                    } else {
                        Image(systemName: "xmark.circle")
                            .foregroundStyle(.secondary)
                        Text("GitHub Copilot")
                            .font(.headline)
                    }
                    Spacer()
                    if isAcctAuth {
                        Button("Sign Out") {
                            copilotService.signOut(accountId: account.id)
                        }
                        .foregroundStyle(.red)
                    } else if copilotService.isSigningIn
                        && copilotService.signingInAccountId == account.id
                    {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Sign In") {
                            copilotService.startSignIn(forAccountId: account.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if copilotAccts.count > 1 {
                        Button {
                            copilotService.signOut(accountId: account.id)
                            accountManager.removeAccount(id: account.id)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 4)
            }

            // Sign-in progress for new account (no specific account)
            if copilotService.isSigningIn, let code = copilotService.deviceCode {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for GitHub authorization...")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Enter code:")
                            .foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                    if let url = copilotService.verificationURL {
                        Link("Open GitHub to enter code", destination: url)
                    }
                }
            }

            // Add another account button
            if !copilotService.isSigningIn {
                Button {
                    let newAcct = ProviderAccount.copilotAccount(
                        name: "GitHub Account \(copilotAccts.count + 1)")
                    accountManager.addAccount(newAcct)
                    copilotService.startSignIn(forAccountId: newAcct.id)
                } label: {
                    Label("Add GitHub Account", systemImage: "plus.circle")
                }
                .controlSize(.small)
            }

            // Sign in prompt when no accounts exist
            if copilotAccts.isEmpty && !copilotService.isAuthenticated
                && !copilotService.isSigningIn
            {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in with your GitHub account to use Copilot models.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        copilotService.startSignIn()
                    } label: {
                        Label("Sign in with GitHub", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let error = copilotService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Custom Web Views Section

    @ViewBuilder
    private var customProviderSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Custom Web Views",
                systemImage: "macwindow",
                tint: .teal,
                description: "Add custom destinations for the Web View tool."
            ) {
            HStack {
                Text("Add web-based AI chats to the Web View tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showAddCustomWebView = true }) {
                    Label("Add Web View", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            let webViews = customWebViewsList()
            if webViews.isEmpty {
                Text("No custom web views added yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(webViews) { webView in
                    HStack {
                        Image(systemName: webView.icon ?? "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(webView.name.isEmpty ? "Untitled" : webView.name)
                                .font(.body)
                            Text(webView.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(action: { removeCustomWebView(id: webView.id) }) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .sheet(isPresented: $showAddCustomWebView) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Custom Web View")
                    .font(.headline)

                TextField("Name (e.g. My AI Chat)", text: $newWebViewName)
                TextField("URL (e.g. https://example.com)", text: $newWebViewURL)

                Picker("Icon", selection: $newWebViewIcon) {
                    ForEach(customWebIconOptions, id: \.self) { icon in
                        Label(customWebIconLabel(for: icon), systemImage: icon)
                            .tag(icon)
                    }
                }
                .pickerStyle(.menu)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        resetNewCustomWebViewForm()
                        showAddCustomWebView = false
                    }
                    Button("Add") {
                        addCustomWebView(
                            name: newWebViewName,
                            url: newWebViewURL,
                            icon: newWebViewIcon
                        )
                        resetNewCustomWebViewForm()
                        showAddCustomWebView = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
    }

    private func customWebViewsList() -> [CustomWebView] {
        guard let data = customWebViewsJSON.data(using: .utf8),
            let views = try? JSONDecoder().decode([CustomWebView].self, from: data)
        else { return [] }
        return views
    }

    private var customWebIconOptions: [String] {
        [
            "globe",
            "sparkles",
            "bubble.left.and.bubble.right",
            "brain.head.profile",
            "magnifyingglass",
            "bolt.horizontal",
            "link",
            "network",
        ]
    }

    private func customWebIconLabel(for icon: String) -> String {
        switch icon {
        case "globe": return "Globe"
        case "sparkles": return "Gemini"
        case "bubble.left.and.bubble.right": return "Chat"
        case "brain.head.profile": return "Claude"
        case "magnifyingglass": return "Search"
        case "bolt.horizontal": return "Grok"
        case "link": return "Link"
        case "network": return "Network"
        default: return "Icon"
        }
    }

    private func resetNewCustomWebViewForm() {
        newWebViewName = ""
        newWebViewURL = ""
        newWebViewIcon = "globe"
    }

    private func normalizedWebURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let withScheme = URL(string: trimmed),
            let scheme = withScheme.scheme,
            scheme == "http" || scheme == "https"
        {
            return withScheme
        }

        return URL(string: "https://\(trimmed)")
    }

    private func addCustomWebView(name: String, url: String, icon: String) {
        var views = customWebViewsList()
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedURL = normalizedWebURL(from: trimmedURL) else { return }
        let normalizedURLString = normalizedURL.absoluteString

        if views.contains(where: {
            ($0.url.caseInsensitiveCompare(normalizedURLString) == .orderedSame)
                || ($0.url.caseInsensitiveCompare(trimmedURL) == .orderedSame)
        }) {
            return
        }

        views.append(
            CustomWebView(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                url: normalizedURLString,
                icon: icon))
        if let data = try? JSONEncoder().encode(views),
            let json = String(data: data, encoding: .utf8)
        {
            customWebViewsJSON = json
        }
    }

    private func removeCustomWebView(id: UUID) {
        var views = customWebViewsList()
        views.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(views),
            let json = String(data: data, encoding: .utf8)
        {
            customWebViewsJSON = json
        }
    }

    // MARK: - System Prompt Section

    @ViewBuilder
    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "System Prompt",
                systemImage: "text.quote",
                tint: .yellow,
                description: "Global instructions applied across chats."
            ) {
            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        Color.gray.opacity(0.2), lineWidth: 1))
            Text("Instructions for how the AI should behave across all chats.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Autocomplete Sections

    @ViewBuilder
    private var autocompleteSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "AI Autocomplete",
                systemImage: "text.cursor",
                tint: .mint,
                description: "Enable autocomplete and control its shortcut."
            ) {
            Toggle(
                isOn: Binding(
                    get: { enableAutocomplete },
                    set: { newValue in
                        enableAutocomplete = newValue
                        if newValue {
                            AutocompleteManager.shared.setup()
                        } else {
                            AutocompleteManager.shared.stop()
                        }
                    }
                )
            ) {
                Label("Enable AI Autocomplete", systemImage: "sparkles")
            }
            .toggleStyle(.switch)

            if enableAutocomplete {
                LabeledContent {
                    KeyboardShortcuts.Recorder(for: .toggleAIAutocomplete)
                } label: {
                    Label("Toggle Shortcut", systemImage: "command")
                }
            }
            }

            if enableAutocomplete {
                settingsCard(
                    "Autocomplete Model",
                    systemImage: "cpu",
                    tint: .blue,
                    description: "Choose the backend and model used for completions."
                ) {
                Picker(selection: $autocompleteBackend) {
                    ForEach(AutocompleteService.Backend.allCases) { backend in
                        Text(backend.rawValue).tag(backend.rawValue)
                    }
                } label: {
                    Label("AI Backend", systemImage: "server.rack")
                }

                if autocompleteBackend != "Apple Intelligence" {
                    LabeledContent {
                        Picker("Model", selection: $autocompleteModel) {
                            if autocompleteModel.isEmpty {
                                Text("Select a model...").tag("")
                            }
                            if autocompleteBackend == "Ollama" {
                                ForEach(OllamaModelManager.shared.allModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            } else if autocompleteBackend == "Gemini" {
                                ForEach(GeminiModelManager.shared.availableModels, id: \.self) {
                                    model in
                                    Text(GeminiModelManager.shared.displayName(for: model)).tag(
                                        model)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 180)
                    } label: {
                        Label("Model Name", systemImage: "brain.head.profile")
                    }
                    Text("Select the model used for completions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }

                settingsCard(
                    "Completion Settings",
                    systemImage: "text.alignleft",
                    tint: .indigo,
                    description: "Control how long generated completions can be."
                ) {
                Picker(selection: $autocompleteCompletionLength) {
                    ForEach(
                        ["Short (~ 1 - 2 words)", "Medium (~ 2 - 4 words)", "Long (~ 5+ words)"],
                        id: \.self
                    ) { length in
                        Text(length).tag(length)
                    }
                } label: {
                    Label("Maximum Length", systemImage: "ruler")
                }
                Text("Controls how long generated completions can be.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                settingsCard(
                    "Autocomplete Behavior",
                    systemImage: "slider.horizontal.3",
                    tint: .purple,
                    description: "Delay, persona, and per-app exclusions."
                ) {
                LabeledContent {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(autocompleteDebounceMs) },
                                set: { autocompleteDebounceMs = Int($0) }
                            ),
                            in: 0...1500,
                            step: 50
                        )
                        Text("\(autocompleteDebounceMs)ms")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 55, alignment: .trailing)
                    }
                } label: {
                    Label("Prediction Delay", systemImage: "timer")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Custom Instructions", systemImage: "text.quote")
                    TextEditor(text: $autocompletePersona)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4).stroke(
                                Color.gray.opacity(0.2), lineWidth: 1))
                    Text("Additional instructions or persona for autocomplete to follow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Label("App Blocklist", systemImage: "xmark.app")

                    let blacklistedApps: [String] = {
                        guard let data = autocompleteBlacklist.data(using: .utf8),
                            let arr = try? JSONDecoder().decode([String].self, from: data)
                        else { return [] }
                        return arr
                    }()

                    if blacklistedApps.isEmpty {
                        Text("No apps blocked.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(blacklistedApps, id: \.self) { bundleId in
                                HStack {
                                    Text(bundleId)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    Button(action: {
                                        var apps = blacklistedApps
                                        apps.removeAll { $0 == bundleId }
                                        if let data = try? JSONEncoder().encode(apps),
                                            let json = String(data: data, encoding: .utf8)
                                        {
                                            autocompleteBlacklist = json
                                        }
                                    }) {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                    }

                    Button(action: {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType.application]
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")

                        if panel.runModal() == .OK, let url = panel.url {
                            if let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier
                            {
                                var apps = blacklistedApps
                                if !apps.contains(bundleId) {
                                    apps.append(bundleId)
                                    if let data = try? JSONEncoder().encode(apps),
                                        let json = String(data: data, encoding: .utf8)
                                    {
                                        autocompleteBlacklist = json
                                    }
                                }
                            }
                        }
                    }) {
                        Label("Add App...", systemImage: "plus.circle")
                    }
                    .padding(.top, 4)

                    Text("Disable autocomplete in specific apps by selecting them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                }

                settingsCard(
                    "Writing Memory",
                    systemImage: "brain",
                    tint: .orange,
                    description: "Store accepted suggestions temporarily to match your style."
                ) {
                Toggle(isOn: $autocompleteMemory) {
                    Label("Learn Writing Style", systemImage: "memorychip")
                }
                .toggleStyle(.switch)

                Text(
                    "Remembers accepted suggestions to match your style. Auto-expires after 7 days."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if autocompleteMemory {
                    HStack {
                        Label("\(WritingMemory.shared.count) samples", systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer()
                        Button(role: .destructive) {
                            WritingMemory.shared.clearAll()
                        } label: {
                            Label("Clear Memory", systemImage: "trash")
                        }
                    }
                }
            }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - File Downloads Section

    @ViewBuilder
    private var fileDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "File Downloads",
                systemImage: "arrow.down.doc",
                tint: .blue,
                description: "Choose where generated files are saved."
            ) {
            LabeledContent {
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
            } label: {
                Label("Save Path", systemImage: "folder")
            }
            Text(
                "Generated files will be instantly saved to this folder. Leave empty to disable."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Browser Automation Section

    @ViewBuilder
    private var browserAutomationSettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Browser Automation",
                systemImage: "play.desktopcomputer",
                tint: .orange,
                description: "Point Prism at a custom BrowserAutomation server checkout."
            ) {
            LabeledContent {
                HStack {
                    TextField("", text: $browserAutomationPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose the BrowserAutomation folder containing server.js"
                        if panel.runModal() == .OK {
                            browserAutomationPath = panel.url?.path ?? ""
                            BrowserAutomationManager.shared.setBrowserAutomationPath(
                                browserAutomationPath)
                        }
                    }
                    if !browserAutomationPath.isEmpty {
                        Button(action: {
                            browserAutomationPath = ""
                            BrowserAutomationManager.shared.setBrowserAutomationPath("")
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Label("Path", systemImage: "folder")
            }
            Text(
                "Set a custom path for the Browser Automation server files if you prefer to use your own clone."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Apple Shortcuts Section

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Apple Shortcuts",
                systemImage: "command",
                tint: .gray,
                description: "Names Prism uses to target your installed Shortcuts."
            ) {
            LabeledContent {
                TextField("", text: $shortcutPrivateCloud)
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("Private Cloud", systemImage: "cloud.fill")
            }
            LabeledContent {
                TextField("", text: $shortcutOnDevice)
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("On-Device", systemImage: "iphone")
            }
            LabeledContent {
                TextField("", text: $shortcutChatGPT)
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("ChatGPT", systemImage: "bubble.left.fill")
            }
            LabeledContent {
                TextField("", text: $shortcutImageGen)
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("Image Gen", systemImage: "photo.fill")
            }
            LabeledContent {
                TextField("", text: $shortcutImageGenChatGPT)
                    .textFieldStyle(.roundedBorder)
            } label: {
                Label("Image Gen (ChatGPT)", systemImage: "photo.badge.plus")
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    // MARK: - Data Section

    @ViewBuilder
    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                "Data & Privacy",
                systemImage: "externaldrive",
                tint: .red,
                description: "Local data controls and destructive cleanup actions."
            ) {
            Button(role: .destructive) {
                chatManager.deleteAllSessions()
            } label: {
                Label("Clear All Chat History", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 26)
    }

    @AppStorage("SelectedSettingsTab") private var selectedTab: SettingsTab = .general

    private var settingsTintStart: Color {
        (appTheme.colors.first ?? .blue).opacity(0.16)
    }

    private var settingsTintEnd: Color {
        (appTheme.colors.last ?? .green).opacity(0.1)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        _ title: String,
        systemImage: String,
        tint: Color,
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))

                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            content()
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.74), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 16, y: 8)
    }

    @ViewBuilder
    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.Category.allCases, id: \.rawValue) { category in
                    if !category.rawValue.isEmpty {
                        Text(category.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                    }

                    ForEach(SettingsTab.tabs(for: category)) { tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(
                                        selectedTab == tab ? .white : tab.iconColor
                                    )
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(
                                                selectedTab == tab
                                                    ? tab.iconColor
                                                    : tab.iconColor.opacity(0.15))
                                    )

                                Text(tab.rawValue)
                                    .font(
                                        .system(
                                            size: 13,
                                            weight: selectedTab == tab ? .semibold : .regular)
                                    )
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .padding(.vertical, 2)

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(
                                        selectedTab == tab
                                            ? Color(nsColor: .quaternaryLabelColor).opacity(0.2)
                                            : Color.clear
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .padding(.horizontal, 6)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 10)
        }
        .frame(width: 210)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.38),
                    Color.white.opacity(0.18),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    @ViewBuilder
    private var settingsContentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                contentForTab(selectedTab)
            }
            .safeAreaPadding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(
                isPresented: Binding(
                    get: { addAPIProviderID != nil },
                    set: { isPresented in
                        if !isPresented {
                            addAPIProviderID = nil
                            resetAddAPIProviderDrafts()
                        }
                    }
                )
            ) {
                if let providerID = addAPIProviderID,
                    let provider = APIProviderRegistry.provider(for: providerID)
                {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add \(provider.title)")
                            .font(.system(size: 18, weight: .bold, design: .rounded))

                        SecureField("API Key", text: $draftAPIKey)
                            .textFieldStyle(.roundedBorder)

                        if provider.accountType == .customapi {
                            TextField("Base URL", text: $draftAPIEndpoint)
                                .textFieldStyle(.roundedBorder)
                        }

                        Picker("Model", selection: $draftModelChoiceMode) {
                            if !provider.presetModels.isEmpty {
                                Text(provider.presetModeLabel).tag("preset")
                            }
                            Text("Custom Model").tag("custom")
                        }
                        .pickerStyle(.segmented)

                        if draftModelChoiceMode == "preset" && !provider.presetModels.isEmpty {
                            Picker("Preset", selection: $draftProviderPresetModel) {
                                ForEach(provider.presetModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            TextField(provider.customPlaceholder, text: $draftProviderCustomModel)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Spacer()
                            Button("Cancel") {
                                addAPIProviderID = nil
                                resetAddAPIProviderDrafts()
                            }
                            Button("Save") {
                                saveAddedProvider(provider)
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(18)
                    .frame(width: 320)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { customModelProviderID != nil },
                    set: { isPresented in
                        if !isPresented {
                            customModelProviderID = nil
                            draftCustomProviderModel = ""
                        }
                    }
                )
            ) {
                if let providerID = customModelProviderID,
                    let provider = APIProviderRegistry.provider(for: providerID)
                {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Add Custom Model")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(provider.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(provider.customPlaceholder, text: $draftCustomProviderModel)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Spacer()
                            Button("Cancel") {
                                customModelProviderID = nil
                                draftCustomProviderModel = ""
                            }
                            Button("Add") {
                                apiProviderModelStore.addCustomModel(
                                    draftCustomProviderModel, for: provider)
                                customModelProviderID = nil
                                draftCustomProviderModel = ""
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(18)
                    .frame(width: 300)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var settingsContainer: some View {
        HStack(spacing: 0) {
            settingsSidebar
            settingsContentPane
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
        .padding(EdgeInsets(top: 22, leading: 10, bottom: 10, trailing: 10))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            ZStack {
                LinearGradient(
                    colors: [settingsTintStart, settingsTintEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                settingsContainer
            }
        }
        .frame(width: 760, height: 760)
        .background(Color.clear)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(" ")

        .background(
            WindowAccessor { window in
                if let window = window {
                    if !window.titlebarAppearsTransparent {
                        window.titlebarAppearsTransparent = true
                    }
                    if window.titleVisibility != .hidden {
                        window.titleVisibility = .hidden
                    }
                    if !window.title.isEmpty {
                        window.title = ""
                    }
                    let sid = NSUserInterfaceItemIdentifier("PrismSettingsWindow")
                    if window.identifier != sid {
                        window.identifier = sid
                    }
                    if !window.styleMask.contains(.fullSizeContentView) {
                        window.styleMask.insert(.fullSizeContentView)
                    }

                    // Clear the default Settings toolbar to remove the white bar
                    window.toolbar = nil
                    window.toolbar?.isVisible = false

                    // Extra measures to ensure no white background
                    window.backgroundColor = .clear
                    window.isOpaque = false  // crucial for removing the opaque window background

                    // Show all traffic lights
                    if let closeBtn = window.standardWindowButton(.closeButton) {
                        if closeBtn.isHidden { closeBtn.isHidden = false }
                    }
                    if let minBtn = window.standardWindowButton(.miniaturizeButton) {
                        if minBtn.isHidden { minBtn.isHidden = false }
                    }
                    if let zoomBtn = window.standardWindowButton(.zoomButton) {
                        if zoomBtn.isHidden { zoomBtn.isHidden = false }
                    }

                    if window.titlebarSeparatorStyle != .none {
                        window.titlebarSeparatorStyle = .none
                    }
                }
            })
    }

    @ViewBuilder
    private func contentForTab(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            generalSection
        case .sidebarTools:
            sidebarToolsSection
        case .appearance:
            appearanceSection
        case .quickAI:
            quickAISection
        case .quickTools:
            quickToolsSection
        case .webOverlay:
            webOverlaySection
        case .apis:
            apisSection
        case .cli:
            cliSection
        case .customWebViews:
            customProviderSection
        case .systemPrompt:
            systemPromptSection
        case .autocomplete:
            autocompleteSections
        case .downloads:
            fileDownloadsSection
        case .browserAutomation:
            browserAutomationSettingsSection
        case .shortcuts:
            shortcutsSection
        case .updates:
            updatesSection
        case .dataPrivacy:
            dataSection
        }
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
    @State private var secondShimmer: CGFloat = -200
    @State private var prismGlowPulse: CGFloat = 0
    @State private var subtitleOpacity: Double = 0
    @State private var beamLength: CGFloat = 0
    @State private var rainbowBeamLength: CGFloat = 0
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let mainColor = colorScheme == .dark ? Color.white : Color.black
        let bgColor = colorScheme == .dark ? Color.black : Color.white

        ZStack {
            bgColor.ignoresSafeArea()

            // Multi-layered ambient background
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.blue.opacity(0.08), Color.clear],
                            center: .center, startRadius: 0, endRadius: 300
                        )
                    )
                    .frame(width: 600, height: 600)
                    .scaleEffect(backgroundPulse)
                    .opacity(stage >= 1 ? 0.9 : 0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.purple.opacity(0.06), Color.clear],
                            center: .center, startRadius: 0, endRadius: 250
                        )
                    )
                    .frame(width: 500, height: 500)
                    .offset(x: 80, y: -60)
                    .scaleEffect(backgroundPulse * 0.9)
                    .opacity(stage >= 2 ? 0.7 : 0)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.orange.opacity(0.04), Color.clear],
                            center: .center, startRadius: 0, endRadius: 200
                        )
                    )
                    .frame(width: 400, height: 400)
                    .offset(x: -60, y: 50)
                    .scaleEffect(backgroundPulse * 0.85)
                    .opacity(stage >= 2 ? 0.6 : 0)

                // Theme-tinted glow behind prism
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (appTheme.colors.first ?? .blue).opacity(0.06),
                                Color.clear,
                            ],
                            center: .center, startRadius: 0, endRadius: 150
                        )
                    )
                    .frame(width: 300, height: 300)
                    .scaleEffect(1.0 + prismGlowPulse * 0.15)
                    .opacity(stage >= 1 ? 1.0 : 0)
            }

            // Main animation container
            ZStack {
                // Orbiting particles (more, with rainbow colors and varied sizes)
                ForEach(0..<30, id: \.self) { i in
                    let angle = Double(i) * 12.0
                    let radius: CGFloat = 70 + CGFloat(i % 7) * 22
                    let delay = Double(i) * 0.04
                    let size = CGFloat(1 + i % 4)
                    Circle()
                        .fill(splashParticleColor(i))
                        .frame(width: size, height: size)
                        .offset(
                            x: cos(angle * .pi / 180 + particlePhase) * radius,
                            y: sin(angle * .pi / 180 + particlePhase) * radius
                        )
                        .opacity(stage >= 2 ? Double(0.15 + (Double(i % 6) * 0.1)) : 0)
                        .blur(radius: CGFloat(i % 3) * 0.8)
                        .animation(
                            .easeInOut(duration: 2.0 + Double(i % 4) * 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(delay),
                            value: particlePhase
                        )
                }

                // Light beam entering from left
                ZStack {
                    // Outer glow
                    Color.clear
                        .frame(width: 200, height: 12)
                        .overlay(
                            Rectangle()
                                .fill(mainColor.opacity(beamGlow * 0.12))
                                .frame(width: beamLength),
                            alignment: .leading
                        )
                        .blur(radius: 10)

                    // Mid glow
                    Color.clear
                        .frame(width: 200, height: 4)
                        .overlay(
                            Rectangle()
                                .fill(mainColor.opacity(beamGlow * 0.25))
                                .frame(width: beamLength),
                            alignment: .leading
                        )
                        .blur(radius: 4)

                    // Core beam
                    Color.clear
                        .frame(width: 200, height: 1.5)
                        .overlay(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [mainColor.opacity(0), mainColor.opacity(0.95)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: beamLength),
                            alignment: .leading
                        )
                }
                .offset(x: -120, y: -2)
                .rotationEffect(.degrees(12), anchor: .trailing)
                .opacity(stage >= 1 ? 1 : 0)

                // The Prism
                ZStack {
                    // Soft glow underneath
                    Triangle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.blue.opacity(0.2),
                                    Color.purple.opacity(0.08),
                                    Color.clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 80
                            )
                        )
                        .frame(width: 120, height: 110)
                        .blur(radius: 20)
                        .opacity(stage >= 1 ? 0.9 : 0)
                        .scaleEffect(1.0 + prismGlowPulse * 0.1)

                    // Glass body
                    Triangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(0.05),
                                    mainColor.opacity(0.015),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 100, height: 100)

                    // Edge stroke
                    Triangle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(0.8),
                                    mainColor.opacity(0.25),
                                    mainColor.opacity(0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 100, height: 100)

                    // Internal refraction line
                    Triangle()
                        .fill(Color.clear)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Path { path in
                                path.move(to: CGPoint(x: 50, y: 8))
                                path.addLine(to: CGPoint(x: 75, y: 92))
                            }
                            .stroke(mainColor.opacity(stage >= 1 ? 0.15 : 0), lineWidth: 0.8)
                        )

                    // Inner glow highlight
                    Triangle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    mainColor.opacity(stage >= 1 ? 0.5 : 0),
                                    mainColor.opacity(0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                        .frame(width: 78, height: 78)
                        .blur(radius: 1)

                    // Shimmer sweep
                    Triangle()
                        .fill(Color.clear)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            mainColor.opacity(0.18),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 35)
                                .offset(x: shimmerOffset)
                                .blur(radius: 2)
                        )
                        .clipShape(Triangle())

                    // Second shimmer (delayed)
                    Triangle()
                        .fill(Color.clear)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.clear,
                                            (appTheme.colors.first ?? .blue).opacity(0.1),
                                            Color.clear,
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: 25)
                                .offset(x: secondShimmer)
                                .blur(radius: 3)
                        )
                        .clipShape(Triangle())
                }
                .scaleEffect(prismScale)
                .opacity(prismOpacity)
                .rotation3DEffect(.degrees(prismRotation), axis: (x: 0, y: 1, z: 0))
                .shadow(color: mainColor.opacity(0.12), radius: 25)

                // Rainbow refracted beams
                ZStack {
                    ForEach(0..<7) { i in
                        let spreadAngle = Double(i) * 5.0 - 15.0

                        // Main beam
                        Color.clear
                            .frame(width: 250, height: 2.5, alignment: .leading)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.25)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                rainbowColor(i).opacity(0.95),
                                                rainbowColor(i).opacity(0.15),
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: rainbowBeamLength),
                                alignment: .leading
                            )
                            .offset(x: 115, y: 0)
                            .rotationEffect(
                                .degrees(spreadAngle * rainbowSpread),
                                anchor: .leading
                            )
                            .blur(radius: 3)

                        // Bloom glow
                        Color.clear
                            .frame(width: 250, height: 10, alignment: .leading)
                            .overlay(
                                Rectangle()
                                    .fill(rainbowColor(i).opacity(0.1))
                                    .frame(width: rainbowBeamLength),
                                alignment: .leading
                            )
                            .offset(x: 115, y: 0)
                            .rotationEffect(
                                .degrees(spreadAngle * rainbowSpread),
                                anchor: .leading
                            )
                            .blur(radius: 12)
                    }
                }

                // Text reveal
                VStack(spacing: 6) {
                    Text("Prism")
                        .font(.system(size: 48, weight: .thin, design: .serif))
                        .tracking(8)
                        .foregroundStyle(
                            LinearGradient(
                                colors: stage >= 3
                                    ? [.red, .orange, .yellow, .green, .cyan, .blue, .purple]
                                    : [mainColor, mainColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .opacity(textOpacity)
                        .offset(y: textOffset)
                        .shadow(color: stage >= 3 ? Color.blue.opacity(0.3) : .clear, radius: 8)

                    Text("AI, refracted.")
                        .font(.system(size: 14, weight: .light, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(mainColor.opacity(0.4))
                        .opacity(subtitleOpacity)
                        .offset(y: textOffset * 0.5)
                }
                .offset(y: 120)
            }
            .scaleEffect(stage == 4 ? 1.1 : 1.0)
            .opacity(stage == 4 ? 0 : 1)
        }
        .onAppear {
            // Prism appears with spring
            withAnimation(.spring(response: 0.9, dampingFraction: 0.65)) {
                prismScale = 1.0
                prismOpacity = 1.0
            }

            // Subtle 3D rotation
            withAnimation(.easeInOut(duration: 2.0).delay(0.2)) {
                prismRotation = 8
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeInOut(duration: 1.5)) {
                    prismRotation = 0
                }
            }

            // Stage 1: Beam enters
            withAnimation(.easeOut(duration: 1.0).delay(0.3)) {
                stage = 1
                beamGlow = 1.0
            }
            withAnimation(.easeOut(duration: 0.9).delay(0.3)) {
                beamLength = 200
            }

            // Background breathing
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                backgroundPulse = 1.2
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true).delay(0.5)) {
                prismGlowPulse = 1.0
            }

            // Shimmer sweeps
            withAnimation(.easeInOut(duration: 1.3).delay(0.5)) {
                shimmerOffset = 200
            }
            withAnimation(.easeInOut(duration: 1.0).delay(1.2)) {
                secondShimmer = 200
            }

            // Stage 2: Rainbow + particles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.8)) {
                    stage = 2
                }
                withAnimation(.easeOut(duration: 1.0)) {
                    rainbowSpread = 1.0
                }
                withAnimation(.easeOut(duration: 1.2)) {
                    rainbowBeamLength = 250
                }
                withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                    particlePhase = .pi * 2
                }
            }

            // Text appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.75)) {
                    textOffset = 0
                    textOpacity = 1.0
                }
            }

            // Subtitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                withAnimation(.easeOut(duration: 0.6)) {
                    subtitleOpacity = 1.0
                }
            }

            // Stage 3: Rainbow text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                withAnimation(.easeInOut(duration: 0.7)) {
                    stage = 3
                }
            }

            // Stage 4: Fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
                withAnimation(.easeInOut(duration: 0.8)) {
                    stage = 4
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) {
                onFinish()
            }
        }
    }

    func rainbowColor(_ i: Int) -> Color {
        let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]
        return colors[i % colors.count]
    }

    func splashParticleColor(_ i: Int) -> Color {
        let colors: [Color] = [
            .red.opacity(0.5), .orange.opacity(0.5), .yellow.opacity(0.5),
            .green.opacity(0.5), .cyan.opacity(0.5), .blue.opacity(0.5), .purple.opacity(0.5),
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

struct StringImageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct ImageGalleryView: View {
    @ObservedObject var chatManager: ChatManager
    @Binding var showImageGallery: Bool
    @ObservedObject private var imageGenStore = ImageGenerationStore.shared
    @State private var selectedImageForPreview: NSImage? = nil
    @State private var previewVisible: Bool = false
    @State private var previewSourceRect: CGRect = .zero
    @State private var imageFrames: [String: CGRect] = [:]

    var images: [(UUID, String, NSImage, String)] {
        var result: [(UUID, String, NSImage, String)] = []
        // Chat images
        for session in chatManager.sessions {
            for message in session.messages {
                if let versions = message.versions, !versions.isEmpty {
                    for (index, version) in versions.enumerated() {
                        if let imageData = version.imageData, let image = NSImage(data: imageData) {
                            result.append(
                                (
                                    session.id, "\(message.id.uuidString)-\(index)", image,
                                    version.content
                                ))
                        }
                    }
                } else if let image = message.image {
                    result.append((session.id, message.id.uuidString, image, message.content))
                }
            }
        }
        // Generated images from Image Generation tool
        for item in imageGenStore.items {
            if let img = imageGenStore.image(for: item.id) {
                result.append((item.id, item.id.uuidString, img, item.prompt))
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
                                            key: StringImageFramePreferenceKey.self,
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
        .onPreferenceChange(StringImageFramePreferenceKey.self) { frames in
            imageFrames.merge(frames) { _, new in new }
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.callback(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.callback(nsView.window)
        }
    }
}
