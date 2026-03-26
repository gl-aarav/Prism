import AppKit
import PDFKit
import SwiftUI

// MARK: - File analysis helpers

private struct AnalyzedFile: Identifiable {
    let id = UUID()
    let relativePath: String
    let fullURL: URL
    let fileSize: Int
    let fileExtension: String
    let isIncluded: Bool // whether content was included in the prompt
    let snippet: String? // first portion of file content
}

private struct FolderSnapshot {
    let promptContext: String
    let analyzedFiles: [AnalyzedFile]
    let scannedFileCount: Int
    let includedFileCount: Int
    let totalCharacters: Int
}

private enum FolderSnapshotBuilder {
    static func build(for folderURL: URL) -> FolderSnapshot {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isHiddenKey, .fileSizeKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles, .skipsPackageDescendants,
        ]
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: options
        )

        let maxVisiblePaths = 250
        let maxIncludedFiles = 80
        let maxPerFileCharacters = 12_000
        let maxTotalCharacters = 200_000
        let maxFileSizeBytes = 256_000
        let maxPDFFileSizeBytes = 10_000_000 // 10 MB for PDFs

        var analyzedFiles: [AnalyzedFile] = []
        var snippets: [String] = []
        var visiblePaths: [String] = []
        var scannedFileCount = 0
        var includedFileCount = 0
        var totalCharacters = 0

        while let next = enumerator?.nextObject() as? URL {
            guard
                let values = try? next.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }

            scannedFileCount += 1
            let relativePath = next.path.replacingOccurrences(of: folderURL.path + "/", with: "")
            let fileSize = values.fileSize ?? 0
            let ext = next.pathExtension.lowercased()

            if visiblePaths.count < maxVisiblePaths {
                visiblePaths.append(relativePath)
            }

            // Try to include the file content
            var included = false
            var snippetText: String? = nil

            let isPDF = ext == "pdf"
            let sizeLimit = isPDF ? maxPDFFileSizeBytes : maxFileSizeBytes

            if includedFileCount < maxIncludedFiles,
               totalCharacters < maxTotalCharacters,
               fileSize > 0, fileSize <= sizeLimit
            {
                // Try PDF extraction first, then plain text
                let rawText: String?
                if isPDF {
                    rawText = loadPDFText(from: next)
                } else {
                    rawText = loadText(from: next)
                }

                if let text = rawText {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let snippet = String(trimmed.prefix(maxPerFileCharacters))
                        totalCharacters += snippet.count
                        includedFileCount += 1
                        included = true
                        snippetText = snippet
                        snippets.append("[File: \(relativePath)]\n\(snippet)")
                    }
                }
            }

            if analyzedFiles.count < maxVisiblePaths {
                analyzedFiles.append(
                    AnalyzedFile(
                        relativePath: relativePath,
                        fullURL: next,
                        fileSize: fileSize,
                        fileExtension: ext,
                        isIncluded: included,
                        snippet: snippetText
                    )
                )
            }
        }

        let context = """
            Folder: \(folderURL.path)

            Files found: \(scannedFileCount)
            Files included with content: \(includedFileCount)

            File list:
            \(visiblePaths.map { "- \($0)" }.joined(separator: "\n"))

            Included file contents:
            \(snippets.joined(separator: "\n\n---\n\n"))
            """

        return FolderSnapshot(
            promptContext: context,
            analyzedFiles: analyzedFiles,
            scannedFileCount: scannedFileCount,
            includedFileCount: includedFileCount,
            totalCharacters: totalCharacters
        )
    }

    private static func loadText(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        if data.contains(0) { return nil }

        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = String(data: data, encoding: .ascii) {
            return string
        }
        if let string = String(data: data, encoding: .unicode) {
            return string
        }
        return nil
    }

    /// Extract text content from a PDF using PDFKit.
    private static func loadPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return nil }

        var pages: [String] = []
        // Extract text from each page, up to a reasonable limit
        let maxPages = min(pageCount, 200)
        for i in 0..<maxPages {
            if let page = document.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pages.append("[Page \(i + 1)]\n\(text)")
            }
        }

        if pages.isEmpty { return nil }

        var result = "PDF Document (\(pageCount) pages"
        if maxPages < pageCount {
            result += ", showing first \(maxPages)"
        }
        result += ")\n\n"
        result += pages.joined(separator: "\n\n")
        return result
    }
}

// MARK: - Main View

struct FolderContextView: View {
    @AppStorage("FolderAnalysisSelectedPath") private var selectedFolderPath: String = ""
    @AppStorage("FolderContextProvider") private var folderProvider: String = "Apple Foundation"
    @AppStorage("FolderContextModel") private var folderModel: String = ""
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("GeminiModel") private var geminiModel: String = "gemini-1.5-flash"
    @AppStorage("GeminiThinkingLevel") private var geminiThinkingLevel: String = "auto"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("SelectedOllamaModel") private var selectedOllamaModel: String = "llama3:8b"
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SelectedNvidiaModel") private var selectedNvidiaModel: String =
        "llama-3.1-70b-instruct"
    @AppStorage("SelectedCopilotModel") private var selectedCopilotModel: String = "gpt-4o"
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared
    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var copilotModelManager = GitHubCopilotModelManager.shared

    @State private var prompt: String = ""
    @State private var response: String = ""
    @State private var analyzedFiles: [AnalyzedFile] = []
    @State private var scannedFileCount: Int = 0
    @State private var includedFileCount: Int = 0
    @State private var totalCharacters: Int = 0
    @State private var isLoading: Bool = false
    @State private var isScanning: Bool = false
    @State private var selectedFileForPreview: AnalyzedFile? = nil
    @State private var filePreviewContent: String = ""
    @State private var fileSearchQuery: String = ""
    @State private var showFilesExpanded: Bool = false

    @AppStorage("FolderContextPreviewHeight") private var previewHeight: Double = 180
    @State private var previewDragInitialHeight: Double? = nil

    @Environment(\.colorScheme) private var colorScheme

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let nvidiaService = NvidiaService()
    private let appleFoundationService = AppleFoundationService()
    private let copilotService = GitHubCopilotService.shared

    private var themeColors: [Color] {
        let colors = appTheme.colors
        return colors.isEmpty ? [.blue, .purple] : colors
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    providerModelSection
                    promptSection
                    responseSection
                }
                .padding(20)
            }
            .frame(minWidth: 480)

            // File sidebar
            fileSidebar
                .frame(width: showFilesExpanded ? 320 : 0)
                .clipped()
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showFilesExpanded)
        }
        .onAppear {
            if !selectedFolderPath.isEmpty {
                showFilesExpanded = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: themeColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Folder Context")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Analyze folder contents with AI")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Toggle file sidebar
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showFilesExpanded.toggle()
                    }
                } label: {
                    Image(systemName: showFilesExpanded ? "sidebar.trailing" : "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
                .help(showFilesExpanded ? "Hide Files" : "Show Files")
            }

            // Folder path bar
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(themeColors.first ?? .blue)

                    if selectedFolderPath.isEmpty {
                        Text("No folder selected")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(selectedFolderPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    chooseFolder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedFolderPath.isEmpty ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text(selectedFolderPath.isEmpty ? "Choose" : "Change")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02))
            )

            // Stats bar
            if scannedFileCount > 0 {
                HStack(spacing: 16) {
                    statPill(icon: "doc.text", label: "\(scannedFileCount) scanned", color: .secondary)
                    statPill(icon: "checkmark.circle", label: "\(includedFileCount) included", color: .green)
                    statPill(
                        icon: "text.quote",
                        label: "\(formatCharacterCount(totalCharacters))",
                        color: .orange
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5),
                            colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Provider & Model Selection

    private var providerModelSection: some View {
        HStack(spacing: 10) {
            // Provider + Account selector
            Menu {
                // Apple Foundation
                Section("Apple Intelligence") {
                    Button(action: {
                        folderProvider = "Apple Foundation"
                        folderModel = "Apple Foundation"
                    }) {
                        Label("Apple Foundation", systemImage: "apple.logo")
                    }
                }

                // Gemini accounts
                let geminiAccounts = accountManager.geminiAccounts().filter { !$0.apiKey.isEmpty }
                if !geminiAccounts.isEmpty {
                    Section("Gemini API") {
                        ForEach(geminiAccounts) { account in
                            Menu(account.displayName) {
                                ForEach(GeminiModelManager.modelGroups, id: \.name) { group in
                                    Section(group.name) {
                                        ForEach(group.models, id: \.self) { model in
                                            Button(action: {
                                                folderProvider = "Gemini API|\(account.id.uuidString)"
                                                folderModel = model
                                            }) {
                                                HStack {
                                                    Text(geminiManager.displayName(for: model))
                                                    if folderModel == model && folderProvider.contains(account.id.uuidString) {
                                                        Spacer()
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Ollama accounts
                let ollamaAccounts = accountManager.ollamaAccounts()
                if !ollamaAccounts.isEmpty {
                    Section("Ollama") {
                        ForEach(ollamaAccounts) { account in
                            Menu(account.displayName) {
                                if !ollamaManager.favoriteModels.isEmpty {
                                    Section("Favorites") {
                                        ForEach(ollamaManager.favoriteModels, id: \.self) { model in
                                            Button(action: {
                                                folderProvider = "Ollama|\(account.id.uuidString)"
                                                folderModel = model
                                            }) {
                                                HStack {
                                                    Text(model)
                                                    if folderModel == model && folderProvider.contains(account.id.uuidString) {
                                                        Spacer()
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                let nonFavInstalled = ollamaManager.installedModels
                                    .filter { !ollamaManager.isFavorite($0) }
                                    .sorted()
                                if !nonFavInstalled.isEmpty {
                                    Section("Installed") {
                                        ForEach(nonFavInstalled, id: \.self) { model in
                                            Button(action: {
                                                folderProvider = "Ollama|\(account.id.uuidString)"
                                                folderModel = model
                                            }) {
                                                HStack {
                                                    Text(model)
                                                    if folderModel == model && folderProvider.contains(account.id.uuidString) {
                                                        Spacer()
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                let customNonInstalled = ollamaManager.customModels
                                    .filter { !ollamaManager.isFavorite($0) }
                                    .filter { !Set(ollamaManager.installedModels).contains($0) }
                                    .sorted()
                                if !customNonInstalled.isEmpty {
                                    Section("Custom") {
                                        ForEach(customNonInstalled, id: \.self) { model in
                                            Button(action: {
                                                folderProvider = "Ollama|\(account.id.uuidString)"
                                                folderModel = model
                                            }) {
                                                Text(model)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // NVIDIA accounts
                let nvidiaAccounts = accountManager.nvidiaAccounts().filter { !$0.apiKey.isEmpty }
                if !nvidiaAccounts.isEmpty {
                    Section("NVIDIA API") {
                        ForEach(nvidiaAccounts) { account in
                            Menu(account.displayName) {
                                ForEach(NvidiaModelManager.modelGroups, id: \.name) { group in
                                    Section(group.name) {
                                        ForEach(group.models, id: \.self) { model in
                                            Button(action: {
                                                folderProvider = "NVIDIA API|\(account.id.uuidString)"
                                                folderModel = model
                                            }) {
                                                HStack {
                                                    Text(nvidiaManager.displayName(for: model))
                                                    if folderModel == model && folderProvider.contains(account.id.uuidString) {
                                                        Spacer()
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // GitHub Copilot accounts
                if copilotService.isAuthenticated {
                    let copilotAccounts = accountManager.copilotAccounts()
                    Section("GitHub Copilot") {
                        ForEach(copilotAccounts) { account in
                            let ghUser = copilotService.accountAuthState[account.id]?.userName ?? ""
                            let label = ghUser.isEmpty ? account.displayName : "GitHub Copilot (\(ghUser))"
                            Menu(label) {
                                ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                    Button(action: {
                                        folderProvider = "GitHub Copilot|\(account.id.uuidString)"
                                        folderModel = model
                                    }) {
                                        HStack {
                                            Text(copilotModelManager.displayName(for: model))
                                            if folderModel == model && folderProvider.contains(account.id.uuidString) {
                                                Spacer()
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: providerIcon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(themeColors.first ?? .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(providerDisplayLabel)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(modelDisplayLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            Spacer()
        }
    }

    // MARK: - Prompt Section

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(themeColors.first ?? .blue)
                Text("Question")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }

            TextEditor(text: $prompt)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100, maxHeight: 200)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.02))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

            // Suggested prompts
            if prompt.isEmpty && !selectedFolderPath.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        suggestedPromptChip("Summarize the project structure")
                        suggestedPromptChip("What does this codebase do?")
                        suggestedPromptChip("Find potential bugs")
                        suggestedPromptChip("List all API endpoints")
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    askFolderQuestion()
                } label: {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(colorScheme == .dark ? .black : .white)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(isLoading ? "Analyzing…" : "Analyze")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(
                                AnyShapeStyle(
                                    isLoading || selectedFolderPath.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                        : AnyShapeStyle(LinearGradient(
                                            colors: themeColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ))
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading || selectedFolderPath.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if !response.isEmpty && !isLoading {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(response, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                            Text("Copy")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !response.isEmpty && !isLoading {
                    Button {
                        response = ""
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Clear")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5),
                            colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Response Section

    private var responseSection: some View {
        Group {
            if !response.isEmpty || isLoading {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(themeColors.last ?? .purple)
                        Text("Response")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                    }

                    if isLoading && response.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning folder and generating response…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    } else {
                        ScrollView {
                            MarkdownView(blocks: Message.parseMarkdown(response))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 160, maxHeight: 500)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.015))
                        )
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5),
                                    colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.03),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: response.isEmpty)
    }

    // MARK: - File Sidebar

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            // Sidebar header
            VStack(spacing: 10) {
                HStack {
                    Text("Files")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    if scannedFileCount > 0 {
                        Text("\(analyzedFiles.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                            )
                    }
                }

                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    TextField("Filter files…", text: $fileSearchQuery)
                        .font(.system(size: 12))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider().opacity(0.3)

            // File list
            if analyzedFiles.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No files indexed yet")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Choose a folder and analyze it to see files.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredFiles) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }

            // File preview pane
            if let file = selectedFileForPreview {
                ZStack {
                    Divider().opacity(0.3)
                    Color.clear
                        .frame(height: 14) // invisible grab area
                }
                .contentShape(Rectangle())
                .onHover { isHovering in
                    if isHovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if previewDragInitialHeight == nil {
                                previewDragInitialHeight = previewHeight
                            }
                            if let initial = previewDragInitialHeight {
                                let newHeight = initial - value.translation.height
                                previewHeight = max(100, min(600, newHeight))
                            }
                        }
                        .onEnded { _ in
                            previewDragInitialHeight = nil
                        }
                )
                .zIndex(1)

                filePreviewPane(file)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.5),
                            colorScheme == .dark ? Color.white.opacity(0.02) : Color.black.opacity(0.03),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
        .padding(.vertical, 20)
        .padding(.trailing, 20)
        .padding(.leading, 10)
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(_ file: AnalyzedFile) -> some View {
        let isSelected = selectedFileForPreview?.id == file.id
        Button {
            if isSelected {
                selectedFileForPreview = nil
                filePreviewContent = ""
            } else {
                selectedFileForPreview = file
                loadFilePreview(file)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: fileIcon(for: file.fileExtension))
                    .font(.system(size: 12))
                    .foregroundStyle(file.isIncluded ? (themeColors.first ?? .blue) : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(fileName(from: file.relativePath))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(fileDirectory(from: file.relativePath))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                Text(formatFileSize(file.fileSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                if file.isIncluded {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? (themeColors.first ?? .blue).opacity(colorScheme == .dark ? 0.15 : 0.08)
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Preview

    private func filePreviewPane(_ file: AnalyzedFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: fileIcon(for: file.fileExtension))
                    .font(.system(size: 11))
                    .foregroundStyle(themeColors.first ?? .blue)
                Text(fileName(from: file.relativePath))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()

                Button {
                    NSWorkspace.shared.selectFile(file.fullURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")

                Button {
                    selectedFileForPreview = nil
                    filePreviewContent = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                Text(filePreviewContent.isEmpty ? "Loading…" : filePreviewContent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: previewHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.03))
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Suggested prompt chip

    private func suggestedPromptChip(_ text: String) -> some View {
        Button {
            prompt = text
        } label: {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stat pill

    private func statPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Computed Properties

    private var filteredFiles: [AnalyzedFile] {
        if fileSearchQuery.isEmpty {
            return analyzedFiles
        }
        return analyzedFiles.filter {
            $0.relativePath.localizedCaseInsensitiveContains(fileSearchQuery)
        }
    }

    private var providerBase: String {
        folderProvider.split(separator: "|").first.map(String.init) ?? folderProvider
    }

    private var providerIcon: String {
        switch providerBase {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "chevron.left.forwardslash.chevron.right"
        default: return "cpu"
        }
    }

    private var providerDisplayLabel: String {
        if folderProvider.contains("|") {
            let parts = folderProvider.split(separator: "|")
            let base = parts.first.map(String.init) ?? folderProvider
            if let uuidStr = parts.last, let uuid = UUID(uuidString: String(uuidStr)) {
                if base == "GitHub Copilot",
                   let ghUser = copilotService.accountAuthState[uuid]?.userName,
                   !ghUser.isEmpty
                {
                    return "Copilot (\(ghUser))"
                }
                if let account = accountManager.accounts.first(where: { $0.id == uuid }) {
                    return account.displayName
                }
            }
        }
        return providerBase
    }

    private var modelDisplayLabel: String {
        if folderModel.isEmpty || folderModel == "Apple Foundation" {
            if providerBase == "Apple Foundation" { return "On-device" }
            return "Select model"
        }
        // Use display name for known providers
        switch providerBase {
        case "Gemini API":
            return geminiManager.displayName(for: folderModel)
        case "NVIDIA API":
            return nvidiaManager.displayName(for: folderModel)
        case "GitHub Copilot":
            return copilotModelManager.displayName(for: folderModel)
        default:
            return folderModel
        }
    }

    private var selectedAccount: ProviderAccount? {
        guard
            let uuidString = folderProvider.split(separator: "|").last.map(String.init),
            folderProvider.contains("|"),
            let uuid = UUID(uuidString: uuidString)
        else { return nil }
        return accountManager.accounts.first(where: { $0.id == uuid })
    }

    // MARK: - File Helpers

    private func fileIcon(for ext: String) -> String {
        switch ext {
        case "swift", "rs", "go", "java", "kt", "c", "cpp", "h", "m", "mm":
            return "chevron.left.forwardslash.chevron.right"
        case "py", "rb", "php", "js", "ts", "jsx", "tsx":
            return "curlybraces"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "md", "txt", "rtf", "csv":
            return "doc.text"
        case "html", "css", "scss", "less":
            return "globe"
        case "png", "jpg", "jpeg", "gif", "svg", "ico", "webp":
            return "photo"
        case "sh", "bash", "zsh", "fish":
            return "terminal"
        case "gitignore", "env", "dockerignore":
            return "gearshape"
        default:
            return "doc"
        }
    }

    private func fileName(from path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func fileDirectory(from path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func formatCharacterCount(_ count: Int) -> String {
        if count < 1000 { return "\(count) chars" }
        return "\(count / 1000)K chars"
    }

    private func loadFilePreview(_ file: AnalyzedFile) {
        // If we already have a snippet, use it immediately
        if let snippet = file.snippet, !snippet.isEmpty {
            filePreviewContent = snippet
            return
        }

        // Otherwise try to load from disk
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String

            if file.fileExtension == "pdf" {
                // Extract text from PDF
                if let document = PDFDocument(url: file.fullURL), document.pageCount > 0 {
                    var pages: [String] = []
                    let maxPages = min(document.pageCount, 50)
                    for i in 0..<maxPages {
                        if let page = document.page(at: i),
                           let text = page.string,
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            pages.append("[Page \(i + 1)]\n\(text)")
                        }
                    }
                    if pages.isEmpty {
                        result = "⚠️ PDF has no extractable text (may be image-based)"
                    } else {
                        let header = "PDF Document (\(document.pageCount) pages)\n\n"
                        result = String((header + pages.joined(separator: "\n\n")).prefix(12000))
                    }
                } else {
                    result = "⚠️ Unable to open PDF"
                }
            } else if let data = try? Data(contentsOf: file.fullURL, options: [.mappedIfSafe]),
               !data.contains(0),
               let text = String(data: data, encoding: .utf8)
            {
                result = String(text.prefix(8000))
            } else {
                result = "⚠️ Unable to preview this file (binary or unreadable)"
            }
            DispatchQueue.main.async {
                filePreviewContent = result
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            selectedFolderPath = url.path
            // Auto-scan when folder is chosen
            scanFolder()
            if !showFilesExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showFilesExpanded = true
                }
            }
        }
    }

    private func scanFolder() {
        guard !selectedFolderPath.isEmpty else { return }
        isScanning = true

        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                FolderSnapshotBuilder.build(for: URL(fileURLWithPath: selectedFolderPath))
            }.value

            await MainActor.run {
                analyzedFiles = snapshot.analyzedFiles
                scannedFileCount = snapshot.scannedFileCount
                includedFileCount = snapshot.includedFileCount
                totalCharacters = snapshot.totalCharacters
                isScanning = false
            }
        }
    }

    private func askFolderQuestion() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedFolderPath.isEmpty, !trimmedPrompt.isEmpty else { return }
        let folderPath = selectedFolderPath

        isLoading = true
        response = ""

        Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                FolderSnapshotBuilder.build(for: URL(fileURLWithPath: folderPath))
            }.value

            await MainActor.run {
                analyzedFiles = snapshot.analyzedFiles
                scannedFileCount = snapshot.scannedFileCount
                includedFileCount = snapshot.includedFileCount
                totalCharacters = snapshot.totalCharacters
                if !showFilesExpanded {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showFilesExpanded = true
                    }
                }
            }

            let systemPrompt = """
                You are analyzing a local folder snapshot selected by the user.
                Answer from the provided folder contents and paths.
                If the answer is incomplete because content was truncated or omitted, say so clearly.
                Use markdown formatting for your response including headers, code blocks, lists, and bold text where appropriate.
                """

            let combinedPrompt = """
                User question:
                \(trimmedPrompt)

                Folder snapshot:
                \(snapshot.promptContext)
                """

            let history = [Message(content: combinedPrompt, isUser: true)]

            do {
                let text = try await send(history: history, systemPrompt: systemPrompt)
                await MainActor.run {
                    response = text.isEmpty ? "No response returned." : text
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    response = "Error: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func send(history: [Message], systemPrompt: String) async throws -> String {
        switch providerBase {
        case "Apple Foundation":
            var text = ""
            for try await chunk in appleFoundationService.sendMessageStream(
                history: history,
                systemPrompt: systemPrompt
            ) {
                text += chunk
            }
            return text
        case "Gemini API":
            let apiKey = selectedAccount?.apiKey.isEmpty == false ? selectedAccount!.apiKey : geminiKey
            guard !apiKey.isEmpty else { throw NSError(domain: "FolderContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing Gemini API key"]) }
            let model = folderModel.isEmpty ? geminiModel : folderModel
            var text = ""
            let stream = geminiService.sendMessageStream(
                history: history,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                thinkingLevel: geminiThinkingLevel
            )
            for try await (chunk, _, _) in stream {
                text += chunk
            }
            return text
        case "Ollama":
            let endpoint = selectedAccount?.endpoint.isEmpty == false ? selectedAccount!.endpoint : ollamaURL
            let model = folderModel.isEmpty ? selectedOllamaModel : folderModel
            var text = ""
            for try await (chunk, _) in ollamaService.sendMessageStream(
                history: history,
                endpoint: endpoint,
                model: model,
                systemPrompt: systemPrompt,
                thinkingLevel: thinkingLevel,
                webSearchEnabled: false,
                webSearchService: nil
            ) {
                text += chunk
            }
            return text
        case "NVIDIA API":
            let apiKey = selectedAccount?.apiKey.isEmpty == false ? selectedAccount!.apiKey : nvidiaKey
            guard !apiKey.isEmpty else { throw NSError(domain: "FolderContext", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing NVIDIA API key"]) }
            let model = folderModel.isEmpty ? selectedNvidiaModel : folderModel
            var text = ""
            for try await (chunk, _) in nvidiaService.sendMessageStream(
                history: history,
                apiKey: apiKey,
                model: model,
                systemPrompt: systemPrompt,
                enableThinking: thinkingLevel == "high"
            ) {
                text += chunk
            }
            return text
        case "GitHub Copilot":
            let model = folderModel.isEmpty ? selectedCopilotModel : folderModel
            var text = ""
            for try await (chunk, _) in copilotService.sendMessageStream(
                history: history,
                model: model,
                systemPrompt: systemPrompt,
                accountId: selectedAccount?.id.uuidString
            ) {
                text += chunk
            }
            return text
        default:
            throw NSError(
                domain: "FolderContext",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Choose Apple Foundation, Gemini API, Ollama, NVIDIA API, or GitHub Copilot before using Folder Context."]
            )
        }
    }
}
