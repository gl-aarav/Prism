import SwiftUI
import UniformTypeIdentifiers

// MARK: - Comparison Slot Model

struct ComparisonSlot: Identifiable {
    let id = UUID()
    var provider: String  // "Gemini API", "Ollama", "Apple Foundation", etc.
    var model: String  // specific model name
    var response: String = ""
    var isLoading: Bool = false
    var error: String?
    var thinkingContent: String?
    var elapsedTime: TimeInterval?
    var thinkingLevel: String = "auto"
    var webSearchEnabled: Bool = false
}

// MARK: - Comparison State Manager (singleton to persist across view lifecycle)

class ComparisonStateManager: ObservableObject {
    static let shared = ComparisonStateManager()

    @Published var slots: [ComparisonSlot]
    @Published var synthesizedResponse: String = ""
    @Published var synthesizedThinking: String = ""
    @Published var showSynthesizePanel: Bool = false

    private init() {
        if let savedData = UserDefaults.standard.array(forKey: "ComparisonSlots")
            as? [[String: String]],
            savedData.count >= 2
        {
            slots = savedData.map {
                ComparisonSlot(
                    provider: $0["provider"] ?? "Gemini API",
                    model: $0["model"] ?? "gemini-2.5-flash",
                    thinkingLevel: $0["thinkingLevel"] ?? "auto",
                    webSearchEnabled: $0["webSearchEnabled"] == "true"
                )
            }
        } else {
            slots = [
                ComparisonSlot(provider: "Gemini API", model: "gemini-2.5-flash"),
                ComparisonSlot(provider: "Ollama", model: "llama3.3"),
            ]
        }
    }

    func saveSlotConfigurations() {
        let data = slots.map {
            [
                "provider": $0.provider,
                "model": $0.model,
                "thinkingLevel": $0.thinkingLevel,
                "webSearchEnabled": $0.webSearchEnabled ? "true" : "false",
            ]
        }
        UserDefaults.standard.set(data, forKey: "ComparisonSlots")
    }
}

// MARK: - Model Comparison View

struct ModelComparisonView: View {
    @AppStorage("GeminiKey") private var geminiKey: String = ""
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://localhost:11434"
    @AppStorage("NvidiaKey") private var nvidiaKey: String = ""
    @AppStorage("SystemPrompt") private var systemPrompt: String = ""
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @AppStorage("ShortcutChatGPT") private var shortcutChatGPT: String = "Ask ChatGPT"
    @AppStorage("ShortcutPrivateCloud") private var shortcutPrivateCloud: String = "Ask AI Private"

    @ObservedObject private var ollamaManager = OllamaModelManager.shared
    @ObservedObject private var geminiManager = GeminiModelManager.shared
    @ObservedObject private var nvidiaManager = NvidiaModelManager.shared
    @ObservedObject private var apiProviderModelStore = APIProviderModelStore.shared
    @ObservedObject private var copilotService = GitHubCopilotService.shared
    @ObservedObject private var copilotModelManager = GitHubCopilotModelManager.shared
    @ObservedObject private var accountManager = AccountManager.shared
    @ObservedObject private var state = ComparisonStateManager.shared

    @AppStorage("ComparePrompt") private var prompt: String = ""
    @State private var isComparing: Bool = false
    @State private var currentTasks: [UUID: Task<Void, Never>] = [:]
    @State private var isInputFocused: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedAttachments: [Attachment] = []
    @StateObject private var pasteMonitor = PasteMonitor()

    // Synthesize state
    @State private var isSynthesizing: Bool = false
    @State private var synthesizeProvider: String = "Gemini API"
    @State private var synthesizeModel: String = "gemini-2.5-flash"
    @AppStorage("ThinkingLevel") private var thinkingLevel: String = "medium"
    @State private var synthesizeTask: Task<Void, Never>?
    @State private var isSynthesizeProviderMenuOpen: Bool = false

    // Ollama comparison options
    @AppStorage("OllamaAPIKey") private var ollamaAPIKey: String = ""
    @State private var compareWebSearchEnabled: Bool = false
    @State private var compareThinkingLevel: String = "medium"

    // Synthesize options
    @State private var synthesizeThinkingLevel: String = "medium"
    @State private var synthesizeWebSearchEnabled: Bool = false

    private let geminiService = GeminiService()
    private let ollamaService = OllamaService()
    private let appleFoundationService = AppleFoundationService()
    private let nvidiaService = NvidiaService()
    private let shortcutService = ShortcutService()
    private let webSearchService = WebSearchService()

    // Convenience accessor for slots
    private var slots: [ComparisonSlot] {
        state.slots
    }

    private func saveSlots() {
        state.saveSlotConfigurations()
    }

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

    private func providerBase(_ provider: String) -> String {
        provider.split(separator: "|").first.map(String.init) ?? provider
    }

    private func accountIdentifier(from provider: String) -> UUID? {
        guard
            provider.contains("|"),
            let uuidStr = provider.split(separator: "|").last.map(String.init)
        else { return nil }
        return UUID(uuidString: uuidStr)
    }

    private func account(for provider: String) -> ProviderAccount? {
        guard let id = accountIdentifier(from: provider) else { return nil }
        return accountManager.accounts.first(where: { $0.id == id })
    }

    private func providerDisplayName(_ provider: String) -> String {
        guard provider.contains("|") else { return providerBase(provider) }
        let base = providerBase(provider)
        if let id = accountIdentifier(from: provider),
            base == "GitHub Copilot",
            let ghUser = copilotService.accountAuthState[id]?.userName,
            !ghUser.isEmpty
        {
            return "GitHub Copilot (\(ghUser))"
        }
        return account(for: provider)?.displayName ?? base
    }

    private func modelDisplayName(provider: String, model: String) -> String {
        switch providerBase(provider) {
        case "Gemini API":
            return geminiManager.displayName(for: model)
        case "NVIDIA API":
            return nvidiaManager.displayName(for: model)
        case "GitHub Copilot":
            return copilotModelManager.displayName(for: model)
        default:
            return model
        }
    }

    private func resolvedGeminiAPIKey(for provider: String) -> String {
        account(for: provider)?.apiKey ?? geminiKey
    }

    private func resolvedNvidiaAPIKey(for provider: String) -> String {
        account(for: provider)?.apiKey ?? nvidiaKey
    }

    private func resolvedOllamaEndpoint(for provider: String) -> String {
        guard let account = account(for: provider) else { return ollamaURL }
        return account.endpoint.isEmpty ? ollamaURL : account.endpoint
    }

    private func resolvedCopilotAccountID(for provider: String) -> String? {
        accountIdentifier(from: provider)?.uuidString
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let slotId = slot.id
                    ComparisonCard(
                        slot: slot,
                        index: index,
                        appTheme: appTheme,
                        onRemove: slots.count > 2
                            ? {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    removeSlot(at: idx)
                                }
                            } : nil,
                        onChangeProvider: { provider, model in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].provider = provider
                                state.slots[idx].model = model
                                saveSlots()
                            }
                        },
                        onChangeThinkingLevel: { level in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].thinkingLevel = level
                                saveSlots()
                            }
                        },
                        onChangeWebSearch: { enabled in
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].webSearchEnabled = enabled
                                saveSlots()
                            }
                        },
                        ollamaManager: ollamaManager,
                        geminiManager: geminiManager,
                        nvidiaManager: nvidiaManager,
                        copilotModelManager: copilotModelManager,
                        hasOllamaAPIKey: !ollamaAPIKey.isEmpty,
                        hasNvidiaKey: !nvidiaKey.isEmpty,
                        hasCopilotAuth: copilotService.isAuthenticated,
                        shortcutChatGPT: shortcutChatGPT,
                        shortcutPrivateCloud: shortcutPrivateCloud
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Synthesize button
                if slots.filter({ !$0.response.isEmpty && !$0.isLoading }).count >= 2 {
                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            state.showSynthesizePanel.toggle()
                            if !state.showSynthesizePanel {
                                synthesizeTask?.cancel()
                                synthesizeTask = nil
                                isSynthesizing = false
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 15, weight: .semibold))
                            Text(
                                state.showSynthesizePanel
                                    ? "Hide Synthesis" : "Synthesize All Responses"
                            )
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(
                            LinearGradient(
                                colors: appTheme.colors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Combine all responses into one using AI")
                    .padding(.top, 8)
                }

                // Inline synthesis panel
                if state.showSynthesizePanel {
                    synthesizeInlinePanel
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)).combined(
                                    with: .scale(scale: 0.95, anchor: .top)),
                                removal: .opacity.combined(
                                    with: .scale(scale: 0.95, anchor: .top))
                            ))
                }
            }
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            headerBar
        }
        .safeAreaInset(edge: .bottom) {
            comparisonInputBar
        }
        .background(Color.clear)
        .onDisappear {
            // Cancel all running tasks to prevent freeze when switching views
            for (_, task) in currentTasks {
                task.cancel()
            }
            currentTasks.removeAll()
            synthesizeTask?.cancel()
            synthesizeTask = nil
            for i in state.slots.indices {
                state.slots[i].isLoading = false
            }
            isComparing = false
            isSynthesizing = false
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Spacer()

            // Slot count indicator
            HStack(spacing: 5) {
                Text("\(slots.count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.8))
                Text("/")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("10")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            // Add model button
            if slots.count < 10 {
                Button(action: addSlot) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add Model")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.primary.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
            }

            // Clear all
            if slots.contains(where: { !$0.response.isEmpty }) {
                Button(action: clearAll) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .help("Clear all responses")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.clear)
    }

    // MARK: - Input Bar

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

    private var comparisonInputBar: some View {
        VStack(spacing: 0) {
            imagePreview

            HStack(spacing: 10) {
                // Left action button
                Button(action: selectAttachment) {
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

                // Prompt field
                ZStack(alignment: .leading) {
                    if prompt.isEmpty && !isInputFocused {
                        Text("Enter a prompt to compare models...")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }
                    NativeTextInput(
                        text: $prompt,
                        isFocused: $isInputFocused,
                        font: .systemFont(ofSize: 15),
                        textColor: colorScheme == .dark ? .white : .black,
                        maxLines: 5,
                        onCommit: {
                            startComparison()
                        }
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: isInputFocused) { _, newValue in
                        if newValue {
                            pasteMonitor.start()
                        } else {
                            pasteMonitor.stop()
                        }
                    }
                }

                // Send/Stop Button — Liquid Glass orb
                Button(action: {
                    if isComparing {
                        stopComparison()
                    } else {
                        startComparison()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: isComparing
                                        ? [.red.opacity(0.8), .red.opacity(0.5)]
                                        : (prompt.isEmpty && selectedAttachments.isEmpty)
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

                        Image(systemName: isComparing ? "stop.fill" : "arrow.up")
                            .font(.system(size: isComparing ? 12 : 14, weight: .bold))
                            .foregroundStyle(
                                isComparing
                                    ? Color.white
                                    : (colorScheme == .dark ? Color.black : Color.white)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled((prompt.isEmpty && selectedAttachments.isEmpty) && !isComparing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Liquid Glass container
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(isInputFocused ? 0.5 : 0.3)
                    : Color.black.opacity(isInputFocused ? 0.12 : 0.06),
                radius: isInputFocused ? 30 : 16,
                x: 0,
                y: isInputFocused ? 12 : 6
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isInputFocused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.clear)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handlePaste(providers)
            return true
        }
        .onAppear {
            setupMonitor()
        }
    }

    // MARK: - Inline Synthesis Panel

    private var synthesizeInlinePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Panel header with provider picker
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: appTheme.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Menu {
                    Button(action: {
                        synthesizeProvider = "Apple Foundation"
                        synthesizeModel = "Apple Foundation"
                    }) {
                        Label("Apple Foundation", systemImage: "apple.logo")
                    }
                    Divider()
                    let geminiAccounts = accountManager.geminiAccounts().filter {
                        !$0.apiKey.isEmpty
                    }
                    if !geminiAccounts.isEmpty {
                        Menu("Gemini API") {
                            ForEach(geminiAccounts) { account in
                                Menu(account.displayName) {
                                    ForEach(geminiDropdownModels, id: \.self) { model in
                                        Button(action: {
                                            synthesizeProvider =
                                                "Gemini API|\(account.id.uuidString)"
                                            synthesizeModel = model
                                        }) {
                                            if synthesizeProvider.contains(account.id.uuidString)
                                                && synthesizeModel == model
                                            {
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
                    } else {
                        Menu("Gemini API") {
                            ForEach(geminiDropdownModels, id: \.self) { model in
                                Button(action: {
                                    synthesizeProvider = "Gemini API"
                                    synthesizeModel = model
                                }) {
                                    if providerBase(synthesizeProvider) == "Gemini API"
                                        && synthesizeModel == model
                                    {
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
                    let ollamaAccounts = accountManager.ollamaAccounts()
                    if !ollamaAccounts.isEmpty {
                        Menu("Ollama") {
                            ForEach(ollamaAccounts) { account in
                                Menu(account.displayName) {
                                    ForEach(ollamaManager.allModels, id: \.self) { model in
                                        Button(action: {
                                            synthesizeProvider = "Ollama|\(account.id.uuidString)"
                                            synthesizeModel = model
                                        }) {
                                            if synthesizeProvider.contains(account.id.uuidString)
                                                && synthesizeModel == model
                                            {
                                                Label(ModelNameFormatter.format(name: model), systemImage: "checkmark")
                                            } else {
                                                Text(ModelNameFormatter.format(name: model))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        Menu("Ollama") {
                            ForEach(ollamaManager.allModels, id: \.self) { model in
                                Button(action: {
                                    synthesizeProvider = "Ollama"
                                    synthesizeModel = model
                                }) {
                                    if providerBase(synthesizeProvider) == "Ollama"
                                        && synthesizeModel == model
                                    {
                                        Label(ModelNameFormatter.format(name: model), systemImage: "checkmark")
                                    } else {
                                        Text(ModelNameFormatter.format(name: model))
                                    }
                                }
                            }
                        }
                    }
                    let nvidiaAccounts = accountManager.nvidiaAccounts().filter {
                        !$0.apiKey.isEmpty
                    }
                    if !nvidiaAccounts.isEmpty {
                        Menu("NVIDIA API") {
                            ForEach(nvidiaAccounts) { account in
                                Menu(account.displayName) {
                                    ForEach(nvidiaDropdownModels, id: \.self) { model in
                                        Button(action: {
                                            synthesizeProvider =
                                                "NVIDIA API|\(account.id.uuidString)"
                                            synthesizeModel = model
                                        }) {
                                            if synthesizeProvider.contains(account.id.uuidString)
                                                && synthesizeModel == model
                                            {
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
                        }
                    } else if !nvidiaKey.isEmpty {
                        Menu("NVIDIA API") {
                            ForEach(nvidiaDropdownModels, id: \.self) { model in
                                Button(action: {
                                    synthesizeProvider = "NVIDIA API"
                                    synthesizeModel = model
                                }) {
                                    if providerBase(synthesizeProvider) == "NVIDIA API"
                                        && synthesizeModel == model
                                    {
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
                    if copilotService.isAuthenticated {
                        let copilotAccounts = accountManager.copilotAccounts()
                        if !copilotAccounts.isEmpty {
                            Menu("GitHub Copilot") {
                                ForEach(copilotAccounts) { account in
                                    let ghUser =
                                        copilotService.accountAuthState[account.id]?.userName ?? ""
                                    let label =
                                        ghUser.isEmpty
                                        ? account.displayName
                                        : "GitHub Copilot (\(ghUser))"
                                    Menu(label) {
                                        ForEach(copilotModelManager.chatModels, id: \.self) {
                                            model in
                                            Button(action: {
                                                synthesizeProvider =
                                                    "GitHub Copilot|\(account.id.uuidString)"
                                                synthesizeModel = model
                                            }) {
                                                if synthesizeProvider.contains(
                                                    account.id.uuidString)
                                                    && synthesizeModel == model
                                                {
                                                    Label(
                                                        copilotModelManager.displayName(for: model),
                                                        systemImage: "checkmark")
                                                } else {
                                                    Text(
                                                        copilotModelManager.displayName(for: model))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            Menu("GitHub Copilot") {
                                ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                    Button(action: {
                                        synthesizeProvider = "GitHub Copilot"
                                        synthesizeModel = model
                                    }) {
                                        if providerBase(synthesizeProvider) == "GitHub Copilot"
                                            && synthesizeModel == model
                                        {
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
                    Divider()
                    Section("Shortcuts") {
                        Button(action: {
                            synthesizeProvider = "ChatGPT"
                            synthesizeModel = "ChatGPT"
                        }) {
                            if synthesizeProvider == "ChatGPT" {
                                Label("ChatGPT", systemImage: "checkmark")
                            } else {
                                Label("ChatGPT", systemImage: "message")
                            }
                        }
                        Button(action: {
                            synthesizeProvider = "Private Cloud"
                            synthesizeModel = "Private Cloud"
                        }) {
                            if synthesizeProvider == "Private Cloud" {
                                Label("Private Cloud", systemImage: "checkmark")
                            } else {
                                Label("Private Cloud", systemImage: "lock.icloud")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: synthesizeProviderIcon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(
                            "\(providerDisplayName(synthesizeProvider)) — \(modelDisplayName(provider: synthesizeProvider, model: synthesizeModel))"
                        )
                        .font(.system(size: 12, weight: .medium))
                        Image(
                            systemName: isSynthesizeProviderMenuOpen ? "chevron.up" : "chevron.down"
                        )
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .focusable(false)
                .focusEffectDisabled()
                .fixedSize()
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isSynthesizeProviderMenuOpen.toggle()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isSynthesizeProviderMenuOpen = false
                            }
                        }
                    })

                Spacer()

                if !isSynthesizing && state.synthesizedResponse.isEmpty {
                    Button(action: startSynthesis) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Generate")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
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
                } else if isSynthesizing {
                    Button(action: {
                        synthesizeTask?.cancel()
                        synthesizeTask = nil
                        isSynthesizing = false
                    }) {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Stop")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Has response - show copy/retry
                    HStack(spacing: 8) {
                        Button(action: {
                            state.synthesizedResponse = ""
                            state.synthesizedThinking = ""
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10))
                                Text("Retry")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                state.synthesizedResponse, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("Copy")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Synthesize options bar (thinking + web search)
            if providerBase(synthesizeProvider) == "Ollama"
                || providerBase(synthesizeProvider) == "NVIDIA API"
            {
                HStack(spacing: 10) {
                    // Thinking level
                    if synthesizeHasThinkingCapability {
                        Menu {
                            Button("Low") { synthesizeThinkingLevel = "low" }
                            Button("Medium") { synthesizeThinkingLevel = "medium" }
                            Button("High") { synthesizeThinkingLevel = "high" }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Thinking: \(synthesizeThinkingLevel.capitalized)")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .fixedSize()
                    }

                    // Web search toggle
                    if providerBase(synthesizeProvider) == "Ollama" {
                        Button(action: { synthesizeWebSearchEnabled.toggle() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11, weight: .medium))
                                Text(
                                    synthesizeWebSearchEnabled
                                        ? "Web Search: On" : "Web Search: Off"
                                )
                                .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(
                                synthesizeWebSearchEnabled ? Color.blue : Color.secondary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Response content
            if state.synthesizedResponse.isEmpty && !isSynthesizing {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.2))
                        Text("Select a model and tap Generate")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                    .padding(.vertical, 24)
                    Spacer()
                }
            } else {
                Divider().opacity(0.2).padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !state.synthesizedThinking.isEmpty {
                            DisclosureGroup {
                                Text(state.synthesizedThinking)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "brain")
                                        .font(.system(size: 11))
                                    Text("Thinking")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.purple)
                            }
                            .padding(.bottom, 4)
                        }

                        MarkdownView(blocks: Message.parseMarkdown(state.synthesizedResponse))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(maxHeight: 350)

                if !state.synthesizedResponse.isEmpty && !isSynthesizing {
                    HStack {
                        Text(
                            "Synthesized by \(providerDisplayName(synthesizeProvider)) — \(modelDisplayName(provider: synthesizeProvider, model: synthesizeModel))"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var synthesizeProviderIcon: String {
        switch providerBase(synthesizeProvider) {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "person.crop.circle"
        case "ChatGPT": return "message"
        case "Private Cloud": return "lock.icloud"
        default: return "cpu"
        }
    }

    /// Whether any slot is an Ollama provider
    private var hasOllamaSlot: Bool {
        slots.contains(where: { providerBase($0.provider) == "Ollama" })
    }

    /// Whether any Ollama slot has a thinking-capable model (deepseek, gpt-oss, r1)
    private var hasThinkingCapableOllamaSlot: Bool {
        slots.contains(where: { slot in
            guard providerBase(slot.provider) == "Ollama" else { return false }
            let lower = slot.model.lowercased()
            return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
        })
    }

    /// Whether the synthesize model has thinking capability
    private var synthesizeHasThinkingCapability: Bool {
        if providerBase(synthesizeProvider) == "Ollama" {
            let lower = synthesizeModel.lowercased()
            return lower.contains("deepseek") || lower.contains("gpt-oss") || lower.contains("r1")
        } else if providerBase(synthesizeProvider) == "NVIDIA API" {
            let lower = synthesizeModel.lowercased()
            return lower.contains("deepseek") || lower.contains("glm")
        }
        return false
    }

    /// Compute the effective thinking level for a given provider/model.
    private func effectiveThinkingLevel(provider: String, model: String) -> String {
        return effectiveThinkingLevel(provider: provider, model: model, level: compareThinkingLevel)
    }

    private func effectiveThinkingLevel(provider: String, model: String, level: String) -> String {
        let base = providerBase(provider)
        if base == "Gemini API" {
            let lower = model.lowercased()
            if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-2.5") {
                return level  // auto, low, medium, high
            }
            return "none"
        } else if base == "Ollama" {
            let lower = model.lowercased()
            if lower.contains("gpt-oss") {
                return level  // low, medium, high from setting
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return level == "high" ? "true" : "false"
            }
            return "false"
        } else if base == "NVIDIA API" {
            let lower = model.lowercased()
            if lower.contains("deepseek") || lower.contains("glm") {
                return level == "high" ? "true" : "false"
            }
            return "none"
        }
        return "none"
    }

    private func startSynthesis() {
        let completedSlots = slots.filter { !$0.response.isEmpty && !$0.isLoading }
        guard completedSlots.count >= 2 else { return }

        state.synthesizedResponse = ""
        state.synthesizedThinking = ""
        isSynthesizing = true

        // Build the synthesis prompt
        var synthesisPrompt =
            "You are an expert at synthesizing information. Below are responses from multiple AI models to the same prompt. Combine them into one comprehensive, well-structured response that takes the best parts of each. Do not mention the models by name or that there were multiple responses — just produce the best possible unified answer.\n\n"
        synthesisPrompt += "Original prompt: \(prompt)\n\n"
        for (i, slot) in completedSlots.enumerated() {
            synthesisPrompt +=
                "--- Response \(i + 1) (\(providerDisplayName(slot.provider)) / \(modelDisplayName(provider: slot.provider, model: slot.model))) ---\n\(slot.response)\n\n"
        }

        let userMsg = Message(content: synthesisPrompt, isUser: true)
        let history = [userMsg]
        let synthThinking = effectiveThinkingLevel(
            provider: synthesizeProvider, model: synthesizeModel, level: synthesizeThinkingLevel)

        synthesizeTask = Task {
            do {
                let synthBaseProvider = providerBase(synthesizeProvider)
                // Web search augmentation for Ollama synthesis
                var synthSystemPrompt = ""
                if synthBaseProvider == "Ollama" && synthesizeWebSearchEnabled {
                    do {
                        let searchResults = try await webSearchService.search(
                            query: prompt)
                        let searchContext = webSearchService.buildSearchContext(
                            results: searchResults)
                        if !searchContext.isEmpty {
                            synthSystemPrompt = searchContext
                        }
                    } catch {
                        print("Synthesize web search failed: \(error.localizedDescription)")
                    }
                }

                switch synthBaseProvider {
                case "Gemini API":
                    let apiKey = resolvedGeminiAPIKey(for: synthesizeProvider)
                    guard !apiKey.isEmpty else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: No Gemini API key set."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    for try await (chunk, _, _) in geminiService.sendMessageStream(
                        history: history, apiKey: apiKey, model: synthesizeModel,
                        systemPrompt: "",
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { state.synthesizedResponse = content }
                    }

                case "Ollama":
                    var full = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()
                    for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                        history: history,
                        endpoint: resolvedOllamaEndpoint(for: synthesizeProvider),
                        model: synthesizeModel,
                        systemPrompt: synthSystemPrompt,
                        thinkingLevel: synthThinking
                    ) {
                        full += chunk
                        if let t = thinkChunk { fullThinking += t }

                        // Throttle UI updates to avoid blocking the stream
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            let thinking = fullThinking
                            await MainActor.run {
                                state.synthesizedResponse = content
                                if !thinking.isEmpty {
                                    state.synthesizedThinking = thinking
                                }
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    // Flush final content
                    let finalSynthContent = full
                    let finalSynthThinking = fullThinking
                    await MainActor.run {
                        state.synthesizedResponse = finalSynthContent
                        if !finalSynthThinking.isEmpty {
                            state.synthesizedThinking = finalSynthThinking
                        }
                    }

                case "Apple Foundation":
                    var full = ""
                    for try await chunk in appleFoundationService.sendMessageStream(
                        history: history, systemPrompt: ""
                    ) {
                        full += chunk
                        let content = full
                        await MainActor.run { state.synthesizedResponse = content }
                    }

                case "NVIDIA API":
                    let apiKey = resolvedNvidiaAPIKey(for: synthesizeProvider)
                    guard !apiKey.isEmpty else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: No NVIDIA API key set."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    var fullThinking = ""
                    var lastUpdateTime = Date()
                    let nvidiaEnableThinking = synthThinking == "true"
                    for try await (chunk, thinkChunk) in nvidiaService.sendMessageStream(
                        history: history, apiKey: apiKey, model: synthesizeModel,
                        systemPrompt: "",
                        enableThinking: nvidiaEnableThinking
                    ) {
                        full += chunk
                        if let t = thinkChunk { fullThinking += t }
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            let thinking = fullThinking
                            await MainActor.run {
                                state.synthesizedResponse = content
                                if !thinking.isEmpty {
                                    state.synthesizedThinking = thinking
                                }
                            }
                            lastUpdateTime = Date()
                        }
                    }
                    let finalNvidiaContent = full
                    let finalNvidiaThinking = fullThinking
                    await MainActor.run {
                        state.synthesizedResponse = finalNvidiaContent
                        if !finalNvidiaThinking.isEmpty {
                            state.synthesizedThinking = finalNvidiaThinking
                        }
                    }

                case "GitHub Copilot":
                    guard copilotService.isAuthenticated else {
                        await MainActor.run {
                            state.synthesizedResponse = "Error: GitHub Copilot not authenticated."
                            isSynthesizing = false
                        }
                        return
                    }
                    var full = ""
                    var lastUpdateTime = Date()
                    for try await (chunk, _) in GitHubCopilotService.shared.sendMessageStream(
                        history: history,
                        model: synthesizeModel,
                        systemPrompt: "",
                        accountId: resolvedCopilotAccountID(for: synthesizeProvider)
                    ) {
                        full += chunk
                        if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                            let content = full
                            await MainActor.run { state.synthesizedResponse = content }
                            lastUpdateTime = Date()
                        }
                    }
                    let finalCopilotContent = full
                    await MainActor.run { state.synthesizedResponse = finalCopilotContent }

                case "ChatGPT":
                    let result = try await shortcutService.runShortcut(
                        name: shortcutChatGPT, input: synthesisPrompt, image: nil)
                    await MainActor.run { state.synthesizedResponse = result.0 }

                case "Private Cloud":
                    let result = try await shortcutService.runShortcut(
                        name: shortcutPrivateCloud, input: synthesisPrompt, image: nil)
                    await MainActor.run { state.synthesizedResponse = result.0 }

                default:
                    await MainActor.run {
                        state.synthesizedResponse = "Error: Provider not supported."
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        if state.synthesizedResponse.isEmpty {
                            state.synthesizedResponse = "Error: \(error.localizedDescription)"
                        }
                    }
                }
            }
            await MainActor.run {
                isSynthesizing = false
            }
        }
    }

    // MARK: - Actions

    private func addSlot() {
        guard slots.count < 10 else { return }
        // Cycle through default providers
        let defaults: [(String, String)] = [
            ("Gemini API", "gemini-2.5-flash"),
            ("Ollama", "llama3.3"),
            ("Apple Foundation", "Apple Foundation"),
            ("Gemini API", "gemini-2.5-pro"),
            ("NVIDIA API", "meta/llama-3.3-70b-instruct"),
            ("GitHub Copilot", "gpt-4o"),
            ("Gemini API", "gemini-2.5-flash-lite"),
            ("Ollama", "deepseek-r1"),
            ("ChatGPT", "ChatGPT"),
        ]
        let newDefault = defaults[slots.count % defaults.count]
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            state.slots.append(ComparisonSlot(provider: newDefault.0, model: newDefault.1))
        }
        saveSlots()
    }

    private func removeSlot(at index: Int) {
        guard slots.count > 2, index < slots.count else { return }
        let slotId = state.slots[index].id
        currentTasks[slotId]?.cancel()
        currentTasks.removeValue(forKey: slotId)
        let _ = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            state.slots.remove(at: index)
        }
        saveSlots()
    }

    private func clearAll() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        withAnimation {
            for i in state.slots.indices {
                state.slots[i].response = ""
                state.slots[i].error = nil
                state.slots[i].isLoading = false
                state.slots[i].thinkingContent = nil
                state.slots[i].elapsedTime = nil
            }
        }
        isComparing = false
    }

    private func stopComparison() {
        for (_, task) in currentTasks {
            task.cancel()
        }
        currentTasks.removeAll()
        for i in state.slots.indices {
            state.slots[i].isLoading = false
        }
        isComparing = false
    }

    private func startComparison() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !selectedAttachments.isEmpty else { return }

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
        let currentAttachments = selectedAttachments
        selectedAttachments = []

        // For text attachments, append file contents to the input text
        var augmentedInput = trimmed
        for attachment in currentAttachments where attachment.type == .text {
            if let text = String(data: attachment.data, encoding: .utf8) {
                let name = attachment.fileName ?? "file"
                augmentedInput += "\n\n--- Contents of \(name) ---\n\(text)\n--- End of \(name) ---"
            }
        }

        // Clear the input field
        prompt = ""

        isComparing = true
        // Reset all slots
        for i in state.slots.indices {
            state.slots[i].response = ""
            state.slots[i].error = nil
            state.slots[i].isLoading = true
            state.slots[i].thinkingContent = nil
            state.slots[i].elapsedTime = nil
        }

        // Build a minimal history with just the user message
        let userMsg = Message(
            content: augmentedInput,
            attachments: msgAttachments.isEmpty ? nil : msgAttachments,
            isUser: true)
        let history = [userMsg]
        let comparisonImage = msgAttachments.first { $0.type == "image" }.flatMap {
            NSImage(data: $0.data)
        }

        // Launch parallel tasks for each slot
        for i in state.slots.indices {
            let slotId = state.slots[i].id
            let provider = state.slots[i].provider
            let model = state.slots[i].model
            let slotThinkingLevel = state.slots[i].thinkingLevel
            let slotWebSearch = state.slots[i].webSearchEnabled

            let task = Task {
                let startTime = Date()
                do {
                    let baseProvider = providerBase(provider)
                    switch baseProvider {
                    case "Gemini API":
                        let apiKey = resolvedGeminiAPIKey(for: provider)
                        guard !apiKey.isEmpty else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "No Gemini API key set"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var fullThinking = ""
                        let geminiThinking = effectiveThinkingLevel(
                            provider: provider, model: model, level: slotThinkingLevel)
                        var lastGeminiUpdateTime = Date()
                        for try await (chunk, thinkChunk, _) in geminiService.sendMessageStream(
                            history: history, apiKey: apiKey, model: model,
                            systemPrompt: systemPrompt, thinkingLevel: geminiThinking
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            if Date().timeIntervalSince(lastGeminiUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastGeminiUpdateTime = Date()
                            }
                        }
                        let elapsed = Date().timeIntervalSince(startTime)
                        let finalGeminiContent = fullContent
                        let finalGeminiThinking = fullThinking
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalGeminiContent
                                if !finalGeminiThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalGeminiThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Ollama":
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()
                        let ollamaThinking = effectiveThinkingLevel(
                            provider: provider, model: model, level: slotThinkingLevel)

                        // Web search augmentation for Ollama
                        var ollamaSystemPrompt = systemPrompt
                        if slotWebSearch {
                            do {
                                let searchResults = try await webSearchService.search(
                                    query: trimmed)
                                let searchContext = webSearchService.buildSearchContext(
                                    results: searchResults)
                                if !searchContext.isEmpty {
                                    ollamaSystemPrompt = systemPrompt + searchContext
                                }
                            } catch {
                                print("Compare web search failed: \(error.localizedDescription)")
                            }
                        }

                        for try await (chunk, thinkChunk) in ollamaService.sendMessageStream(
                            history: history,
                            endpoint: resolvedOllamaEndpoint(for: provider),
                            model: model,
                            systemPrompt: ollamaSystemPrompt, thinkingLevel: ollamaThinking
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            // Throttle UI updates to avoid blocking the stream on every token
                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        // Flush final content
                        let finalContent = fullContent
                        let finalThinking = fullThinking
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalContent
                                if !finalThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Apple Foundation":
                        var fullContent = ""
                        for try await chunk in appleFoundationService.sendMessageStream(
                            history: history, systemPrompt: systemPrompt
                        ) {
                            fullContent += chunk
                            let content = fullContent
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].response = content
                                }
                            }
                        }
                        let afElapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = afElapsed
                            }
                        }

                    case "NVIDIA API":
                        let apiKey = resolvedNvidiaAPIKey(for: provider)
                        guard !apiKey.isEmpty else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "No NVIDIA API key set"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var fullThinking = ""
                        var lastUpdateTime = Date()
                        let nvidiaThinking = effectiveThinkingLevel(
                            provider: provider, model: model, level: slotThinkingLevel)
                        for try await (chunk, thinkChunk) in nvidiaService.sendMessageStream(
                            history: history, apiKey: apiKey, model: model,
                            systemPrompt: systemPrompt,
                            enableThinking: nvidiaThinking == "true"
                        ) {
                            fullContent += chunk
                            if let t = thinkChunk { fullThinking += t }

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                let thinking = fullThinking
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                        if !thinking.isEmpty {
                                            state.slots[idx].thinkingContent = thinking
                                        }
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let nvidiaElapsed = Date().timeIntervalSince(startTime)
                        let finalNvidiaContent = fullContent
                        let finalNvidiaThinking = fullThinking
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalNvidiaContent
                                if !finalNvidiaThinking.isEmpty {
                                    state.slots[idx].thinkingContent = finalNvidiaThinking
                                }
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = nvidiaElapsed
                            }
                        }

                    case "GitHub Copilot":
                        guard copilotService.isAuthenticated else {
                            await MainActor.run {
                                if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                    state.slots[idx].error = "GitHub Copilot not authenticated"
                                    state.slots[idx].isLoading = false
                                }
                            }
                            return
                        }
                        var fullContent = ""
                        var lastUpdateTime = Date()
                        for try await (chunk, _) in GitHubCopilotService.shared.sendMessageStream(
                            history: history,
                            model: model,
                            systemPrompt: systemPrompt,
                            accountId: resolvedCopilotAccountID(for: provider)
                        ) {
                            fullContent += chunk

                            if Date().timeIntervalSince(lastUpdateTime) > 0.05 {
                                let content = fullContent
                                await MainActor.run {
                                    if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                        state.slots[idx].response = content
                                    }
                                }
                                lastUpdateTime = Date()
                            }
                        }
                        let copilotElapsed = Date().timeIntervalSince(startTime)
                        let finalCopilotContent = fullContent
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = finalCopilotContent
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = copilotElapsed
                            }
                        }

                    case "ChatGPT":
                        let shortcutName = self.shortcutChatGPT
                        let result = try await shortcutService.runShortcut(
                            name: shortcutName, input: augmentedInput, image: comparisonImage)
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = result.0
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    case "Private Cloud":
                        let shortcutName = self.shortcutPrivateCloud
                        let result = try await shortcutService.runShortcut(
                            name: shortcutName, input: augmentedInput, image: comparisonImage)
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].response = result.0
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }

                    default:
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].error =
                                    "Provider '\(provider)' not supported for comparison"
                                state.slots[idx].isLoading = false
                            }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        let elapsed = Date().timeIntervalSince(startTime)
                        await MainActor.run {
                            if let idx = slots.firstIndex(where: { $0.id == slotId }) {
                                state.slots[idx].error = error.localizedDescription
                                state.slots[idx].isLoading = false
                                state.slots[idx].elapsedTime = elapsed
                            }
                        }
                    }
                }

                // Check if all done
                await MainActor.run {
                    if !slots.contains(where: { $0.isLoading }) {
                        isComparing = false
                    }
                }
            }

            currentTasks[slotId] = task
        }
    }

    private func selectAttachment() {
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
                    if let data = try? Data(contentsOf: url) {
                        selectedAttachments.append(
                            Attachment(type: .text, data: data, fileName: url.lastPathComponent))
                    }
                }
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

                        let imageExtensions = [
                            "png", "jpg", "jpeg", "tiff", "gif", "bmp", "webp", "heic",
                        ]
                        if imageExtensions.contains(url.pathExtension.lowercased()) {
                            if let data = try? Data(contentsOf: url) {
                                DispatchQueue.main.async {
                                    self.selectedAttachments.append(
                                        Attachment(type: .image, data: data))
                                }
                                return
                            }
                        }

                        if let data = try? Data(contentsOf: url) {
                            DispatchQueue.main.async {
                                self.selectedAttachments.append(
                                    Attachment(
                                        type: .text, data: data, fileName: url.lastPathComponent))
                            }
                        }
                    }
                }
            }
        }
    }

    private func setupMonitor() {
        pasteMonitor.onPaste = { attachments in
            DispatchQueue.main.async {
                self.selectedAttachments.append(contentsOf: attachments)
            }
        }
        if isInputFocused {
            pasteMonitor.start()
        }
    }
}

// MARK: - Comparison Card

struct ComparisonCard: View {
    let slot: ComparisonSlot
    let index: Int
    let appTheme: AppTheme
    var onRemove: (() -> Void)?
    var onChangeProvider: (String, String) -> Void
    var onChangeThinkingLevel: (String) -> Void
    var onChangeWebSearch: (Bool) -> Void

    @ObservedObject var ollamaManager: OllamaModelManager
    @ObservedObject var geminiManager: GeminiModelManager
    @ObservedObject var nvidiaManager: NvidiaModelManager
    @ObservedObject var apiProviderModelStore = APIProviderModelStore.shared
    @ObservedObject var copilotModelManager: GitHubCopilotModelManager
    @ObservedObject var accountManager = AccountManager.shared
    @ObservedObject var copilotService = GitHubCopilotService.shared
    var hasOllamaAPIKey: Bool = false
    var hasNvidiaKey: Bool = false
    var hasCopilotAuth: Bool = false
    var shortcutChatGPT: String = "Ask ChatGPT"
    var shortcutPrivateCloud: String = "Ask AI Private"
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovered: Bool = false
    @State private var showCopied: Bool = false
    @State private var isProviderMenuOpen: Bool = false

    private var accentColor: Color {
        let palette: [Color] = [.blue, .purple, .orange, .green]
        return palette[index % palette.count]
    }

    private var slotProviderBase: String {
        slot.provider.split(separator: "|").first.map(String.init) ?? slot.provider
    }

    private var slotAccountID: UUID? {
        guard
            slot.provider.contains("|"),
            let uuidStr = slot.provider.split(separator: "|").last.map(String.init)
        else { return nil }
        return UUID(uuidString: uuidStr)
    }

    private var slotProviderDisplayName: String {
        if let id = slotAccountID,
            slotProviderBase == "GitHub Copilot",
            let ghUser = copilotService.accountAuthState[id]?.userName,
            !ghUser.isEmpty
        {
            return "GitHub Copilot (\(ghUser))"
        }
        if let id = slotAccountID,
            let account = accountManager.accounts.first(where: { $0.id == id })
        {
            return account.displayName
        }
        return slotProviderBase
    }

    private var providerIcon: String {
        switch slotProviderBase {
        case "Apple Foundation": return "apple.logo"
        case "Gemini API": return "sparkles"
        case "Ollama": return "laptopcomputer"
        case "NVIDIA API": return "bolt.fill"
        case "GitHub Copilot": return "person.crop.circle"
        case "ChatGPT": return "message"
        case "Private Cloud": return "lock.icloud"
        default: return "cpu"
        }
    }

    /// Determine the thinking mode for this slot's provider/model
    private var slotThinkingMode: ThinkingMode {
        let lower = slot.model.lowercased()
        if slotProviderBase == "Gemini API" {
            if lower.hasPrefix("gemini-3-pro") {
                return .geminiPro
            } else if lower.hasPrefix("gemini-3") || lower.hasPrefix("gemini-2.5") {
                return .geminiFlash
            }
        } else if slotProviderBase == "Ollama" {
            if lower.contains("gpt-oss") {
                return .threeState
            } else if lower.contains("deepseek") || lower.contains("r1") {
                return .binary
            }
        } else if slotProviderBase == "NVIDIA API" {
            if lower.contains("deepseek") || lower.contains("glm") {
                return .binary
            }
        }
        return .none
    }

    /// Whether this slot can show web search toggle
    private var slotCanWebSearch: Bool {
        slotProviderBase == "Ollama"
    }

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

    private var slotModelDisplayName: String {
        switch slotProviderBase {
        case "Gemini API":
            return geminiManager.displayName(for: slot.model)
        case "NVIDIA API":
            return nvidiaManager.displayName(for: slot.model)
        case "GitHub Copilot":
            return copilotModelManager.displayName(for: slot.model)
        default:
            return slot.model
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header separated into pills
            HStack(spacing: 8) {
                // Provider/Model pill
                modelHeaderPill

                Spacer()

                // Status/Actions pill (with X)
                actionPill
            }
            .padding(.horizontal, 4)

            // Card Body
            VStack(alignment: .leading, spacing: 0) {
                cardBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .shadow(
                color: Color.black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 16 : 8,
                x: 0,
                y: 4
            )
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Separated Headers

    private var modelHeaderPill: some View {
        HStack(spacing: 10) {
            // Provider icon with accent
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: providerIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor)
            }

            // Provider & Model selector
            VStack(alignment: .leading, spacing: 2) {
                providerMenu
                modelLabel
            }

            // Thinking & web search controls
            if slotThinkingMode != .none || slotCanWebSearch {
                Divider()
                    .frame(height: 20)
                    .opacity(0.5)

                HStack(spacing: 6) {
                    if slotThinkingMode != .none {
                        Menu {
                            if slotThinkingMode == .binary {
                                Button {
                                    onChangeThinkingLevel("high")
                                } label: {
                                    if slot.thinkingLevel == "high" {
                                        Label("Reasoning: On", systemImage: "checkmark")
                                    } else {
                                        Text("Reasoning: On")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("low")
                                } label: {
                                    if slot.thinkingLevel != "high" {
                                        Label("Reasoning: Off", systemImage: "checkmark")
                                    } else {
                                        Text("Reasoning: Off")
                                    }
                                }
                            } else if slotThinkingMode == .geminiPro {
                                Button {
                                    onChangeThinkingLevel("auto")
                                } label: {
                                    if slot.thinkingLevel == "auto" {
                                        Label("Auto", systemImage: "checkmark")
                                    } else {
                                        Text("Auto")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("low")
                                } label: {
                                    if slot.thinkingLevel == "low" {
                                        Label("Low", systemImage: "checkmark")
                                    } else {
                                        Text("Low")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("high")
                                } label: {
                                    if slot.thinkingLevel == "high" {
                                        Label("High", systemImage: "checkmark")
                                    } else {
                                        Text("High")
                                    }
                                }
                            } else if slotThinkingMode == .geminiFlash {
                                Button {
                                    onChangeThinkingLevel("auto")
                                } label: {
                                    if slot.thinkingLevel == "auto" {
                                        Label("Auto", systemImage: "checkmark")
                                    } else {
                                        Text("Auto")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("low")
                                } label: {
                                    if slot.thinkingLevel == "low" {
                                        Label("Low", systemImage: "checkmark")
                                    } else {
                                        Text("Low")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("medium")
                                } label: {
                                    if slot.thinkingLevel == "medium" {
                                        Label("Medium", systemImage: "checkmark")
                                    } else {
                                        Text("Medium")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("high")
                                } label: {
                                    if slot.thinkingLevel == "high" {
                                        Label("High", systemImage: "checkmark")
                                    } else {
                                        Text("High")
                                    }
                                }
                            } else {
                                // threeState (Ollama gpt-oss)
                                Button {
                                    onChangeThinkingLevel("low")
                                } label: {
                                    if slot.thinkingLevel == "low" {
                                        Label("Low", systemImage: "checkmark")
                                    } else {
                                        Text("Low")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("medium")
                                } label: {
                                    if slot.thinkingLevel == "medium" {
                                        Label("Medium", systemImage: "checkmark")
                                    } else {
                                        Text("Medium")
                                    }
                                }
                                Button {
                                    onChangeThinkingLevel("high")
                                } label: {
                                    if slot.thinkingLevel == "high" {
                                        Label("High", systemImage: "checkmark")
                                    } else {
                                        Text("High")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "brain")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accentColor.opacity(0.8))
                                .padding(5)
                                .glassEffect(.regular, in: .circle)
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.plain)
                        .focusable(false)
                        .focusEffectDisabled()
                        .fixedSize()
                        .help("Reasoning: \(slot.thinkingLevel.capitalized)")
                    }

                    if slotCanWebSearch {
                        Button(action: { onChangeWebSearch(!slot.webSearchEnabled) }) {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(
                                    slot.webSearchEnabled
                                        ? Color.blue : Color.secondary.opacity(0.6)
                                )
                                .padding(5)
                                .glassEffect(.regular, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help(slot.webSearchEnabled ? "Web Search: On" : "Web Search: Off")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var actionPill: some View {
        HStack(spacing: 8) {
            if slot.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .padding(.leading, 8)
            } else if let elapsed = slot.elapsedTime {
                Text(String(format: "%.1fs", elapsed))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }

            if let onRemove = onRemove {
                if slot.isLoading || slot.elapsedTime != nil {
                    Divider()
                        .frame(height: 14)
                        .opacity(0.5)
                }
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Provider Menu

    private var providerMenu: some View {
        Menu {
            Button(action: { onChangeProvider("Apple Foundation", "Apple Foundation") }) {
                Label("Apple Foundation", systemImage: "apple.logo")
            }
            Divider()
            let geminiAccounts = accountManager.geminiAccounts().filter { !$0.apiKey.isEmpty }
            if !geminiAccounts.isEmpty {
                Menu("Gemini API") {
                    ForEach(geminiAccounts) { account in
                        Menu(account.displayName) {
                            ForEach(geminiDropdownModels, id: \.self) { model in
                                Button(action: {
                                    onChangeProvider("Gemini API|\(account.id.uuidString)", model)
                                }) {
                                    if slot.provider.contains(account.id.uuidString)
                                        && slot.model == model
                                    {
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
            } else {
                Menu("Gemini API") {
                    ForEach(geminiDropdownModels, id: \.self) { model in
                        Button(action: { onChangeProvider("Gemini API", model) }) {
                            if slotProviderBase == "Gemini API" && slot.model == model {
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

            let ollamaAccounts = accountManager.ollamaAccounts()
            if !ollamaAccounts.isEmpty {
                Menu("Ollama") {
                    ForEach(ollamaAccounts) { account in
                        Menu(account.displayName) {
                            ForEach(ollamaManager.allModels, id: \.self) { model in
                                Button(action: {
                                    onChangeProvider("Ollama|\(account.id.uuidString)", model)
                                }) {
                                    if slot.provider.contains(account.id.uuidString)
                                        && slot.model == model
                                    {
                                        Label(ModelNameFormatter.format(name: model), systemImage: "checkmark")
                                    } else {
                                        Text(ModelNameFormatter.format(name: model))
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Menu("Ollama") {
                    ForEach(ollamaManager.allModels, id: \.self) { model in
                        Button(action: { onChangeProvider("Ollama", model) }) {
                            if slotProviderBase == "Ollama" && slot.model == model {
                                Label(ModelNameFormatter.format(name: model), systemImage: "checkmark")
                            } else {
                                Text(ModelNameFormatter.format(name: model))
                            }
                        }
                    }
                }
            }

            let nvidiaAccounts = accountManager.nvidiaAccounts().filter { !$0.apiKey.isEmpty }
            if !nvidiaAccounts.isEmpty {
                Menu("NVIDIA API") {
                    ForEach(nvidiaAccounts) { account in
                        Menu(account.displayName) {
                            ForEach(nvidiaDropdownModels, id: \.self) { model in
                                Button(action: {
                                    onChangeProvider("NVIDIA API|\(account.id.uuidString)", model)
                                }) {
                                    if slot.provider.contains(account.id.uuidString)
                                        && slot.model == model
                                    {
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
                }
            } else if hasNvidiaKey {
                Menu("NVIDIA API") {
                    ForEach(nvidiaDropdownModels, id: \.self) { model in
                        Button(action: { onChangeProvider("NVIDIA API", model) }) {
                            if slotProviderBase == "NVIDIA API" && slot.model == model {
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

            if hasCopilotAuth {
                let copilotAccounts = accountManager.copilotAccounts()
                if !copilotAccounts.isEmpty {
                    Menu("GitHub Copilot") {
                        ForEach(copilotAccounts) { account in
                            let ghUser = copilotService.accountAuthState[account.id]?.userName ?? ""
                            let label =
                                ghUser.isEmpty
                                ? account.displayName
                                : "GitHub Copilot (\(ghUser))"
                            Menu(label) {
                                ForEach(copilotModelManager.chatModels, id: \.self) { model in
                                    Button(action: {
                                        onChangeProvider(
                                            "GitHub Copilot|\(account.id.uuidString)", model)
                                    }) {
                                        if slot.provider.contains(account.id.uuidString)
                                            && slot.model == model
                                        {
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
                } else {
                    Menu("GitHub Copilot") {
                        ForEach(copilotModelManager.chatModels, id: \.self) { model in
                            Button(action: { onChangeProvider("GitHub Copilot", model) }) {
                                if slotProviderBase == "GitHub Copilot" && slot.model == model {
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
            Divider()
            Section("Shortcuts") {
                Button(action: { onChangeProvider("ChatGPT", "ChatGPT") }) {
                    if slotProviderBase == "ChatGPT" {
                        Label("ChatGPT", systemImage: "checkmark")
                    } else {
                        Label("ChatGPT", systemImage: "message")
                    }
                }
                Button(action: { onChangeProvider("Private Cloud", "Private Cloud") }) {
                    if slotProviderBase == "Private Cloud" {
                        Label("Private Cloud", systemImage: "checkmark")
                    } else {
                        Label("Private Cloud", systemImage: "lock.icloud")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(slotProviderDisplayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                Image(systemName: isProviderMenuOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .fixedSize()
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
    }

    // MARK: - Model Label

    private var modelLabel: some View {
        Text(slotModelDisplayName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Card Body

    @ViewBuilder
    private var cardBody: some View {
        if let error = slot.error {
            // Error state
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else if slot.response.isEmpty && !slot.isLoading {
            // Empty / waiting state
            VStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary.opacity(0.3))
                Text("Response will appear here")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else if slot.isLoading && slot.response.isEmpty {
            // Loading pulse
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(accentColor.opacity(0.6))
                            .frame(width: 8, height: 8)
                            .scaleEffect(slot.isLoading ? 1.0 : 0.5)
                            .animation(
                                .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.15),
                                value: slot.isLoading
                            )
                    }
                }
                Text("Generating...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(16)
        } else {
            // Response content
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let thinking = slot.thinkingContent, !thinking.isEmpty {
                        DisclosureGroup {
                            Text(thinking)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineSpacing(3)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11))
                                Text("Thinking")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.purple)
                        }
                        .padding(.bottom, 4)
                    }

                    MarkdownView(blocks: Message.parseMarkdown(slot.response))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
            .frame(minHeight: 120, maxHeight: 400)

            // Copy button + small model warning
            VStack(spacing: 6) {
                // Model disclaimer for all providers
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange.opacity(0.7))
                    Text("Information could be inaccurate")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

                HStack {
                    Spacer()
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(slot.response, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(showCopied ? "Copied" : "Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(showCopied ? Color.green : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .animation(.easeInOut(duration: 0.2), value: showCopied)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 10)
        }
    }
}
