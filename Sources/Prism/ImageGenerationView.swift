import SwiftUI

// MARK: - Persistent Image Store

struct GeneratedImageItem: Identifiable, Codable {
    let id: UUID
    let prompt: String
    let style: String
    var responseText: String?
    var error: String?
    var timestamp: Date
}

class ImageGenerationStore: ObservableObject {
    static let shared = ImageGenerationStore()

    @Published var items: [GeneratedImageItem] = []

    private let saveDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Prism")
            .appendingPathComponent("GeneratedImages")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var metadataPath: URL { saveDir.appendingPathComponent("metadata.json") }

    init() {
        loadItems()
    }

    func addItem(_ item: GeneratedImageItem, image: NSImage?) {
        items.insert(item, at: 0)
        if let image = image {
            saveImageData(image, for: item.id)
        }
        saveMetadata()
    }

    func updateItem(id: UUID, responseText: String?, image: NSImage?, error: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let text = responseText {
            items[idx].responseText = text
        }
        if let err = error {
            items[idx].error = err
        }
        if let image = image {
            saveImageData(image, for: id)
        }
        saveMetadata()
    }

    func image(for id: UUID) -> NSImage? {
        let path = saveDir.appendingPathComponent("\(id.uuidString).png")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return NSImage(data: data)
    }

    func clearAll() {
        for item in items {
            let path = saveDir.appendingPathComponent("\(item.id.uuidString).png")
            try? FileManager.default.removeItem(at: path)
        }
        items.removeAll()
        saveMetadata()
    }

    /// All generated images for the gallery view: (itemId, NSImage, prompt)
    var allImages: [(UUID, NSImage, String)] {
        var result: [(UUID, NSImage, String)] = []
        for item in items {
            if let img = image(for: item.id) {
                result.append((item.id, img, item.prompt))
            }
        }
        return result
    }

    private func saveImageData(_ image: NSImage, for id: UUID) {
        let path = saveDir.appendingPathComponent("\(id.uuidString).png")
        if let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: path)
        }
    }

    private func saveMetadata() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: metadataPath)
        }
    }

    private func loadItems() {
        guard let data = try? Data(contentsOf: metadataPath),
            let loaded = try? JSONDecoder().decode([GeneratedImageItem].self, from: data)
        else { return }
        items = loaded
    }
}

// MARK: - Image Generation View

struct ImageGenerationView: View {
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String =
        "Generate Image ChatGPT"
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var store = ImageGenerationStore.shared

    @State private var prompt: String = ""
    @State private var selectedStyle: String = "Animation"
    @State private var isGenerating: Bool = false
    @State private var currentTask: Task<Void, Never>? = nil
    @State private var showResetConfirmation: Bool = false
    @State private var loadingItemId: UUID? = nil
    @State private var imageCache: [UUID: NSImage] = [:]
    @FocusState private var isInputFocused: Bool

    private let shortcutService = ShortcutService()

    private let styles: [(section: String, items: [(label: String, value: String)])] = [
        (
            "Apple Intelligence",
            [
                ("Animation", "Animation"),
                ("Illustration", "Illustration"),
                ("Sketch", "Sketch"),
            ]
        ),
        (
            "ChatGPT",
            [
                ("ChatGPT (Default)", "ChatGPT"),
                ("Oil Painting", "Oil Painting (ChatGPT)"),
                ("Watercolor", "Watercolor (ChatGPT)"),
                ("Vector", "Vector (ChatGPT)"),
                ("Anime", "Anime (ChatGPT)"),
                ("Print", "Print (ChatGPT)"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .background(.ultraThinMaterial)

            // Content area — no background, parent provides it
            VStack(spacing: 0) {
                if store.items.isEmpty && !isGenerating {
                    emptyState
                } else {
                    messagesView
                }

                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Clear All Images", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                currentTask?.cancel()
                currentTask = nil
                isGenerating = false
                loadingItemId = nil
                imageCache.removeAll()
                store.clearAll()
            }
        } message: {
            Text("This will permanently delete all generated images. This cannot be undone.")
        }
        .onAppear {
            loadCachedImages()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "paintbrush.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: appTheme.colors.isEmpty ? [.orange, .pink] : appTheme.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Image Generation")
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Spacer()

            // Style indicator
            HStack(spacing: 4) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 10))
                Text(selectedStyle)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))

            if !store.items.isEmpty {
                Button(action: { showResetConfirmation = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let colors = appTheme.colors
        let startColor = colors.first ?? .orange
        let endColor = colors.last ?? .pink

        return VStack(spacing: 24) {
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
                    .frame(width: 120, height: 120)
                    .blur(radius: 20)

                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [startColor, endColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: startColor.opacity(0.3), radius: 10, x: 0, y: 5)
            }

            VStack(spacing: 8) {
                Text("Create Images")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [startColor, endColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("Describe what you'd like and pick a style")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    // MARK: - Messages (Chat-like)

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    ForEach(store.items.reversed()) { item in
                        VStack(spacing: 12) {
                            // User prompt bubble
                            HStack {
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(item.prompt)
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(
                                            LinearGradient(
                                                colors: appTheme.colors.isEmpty
                                                    ? [.blue, .blue.opacity(0.8)]
                                                    : appTheme.colors,
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        )

                                    Text(item.style)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                            }

                            // AI response bubble
                            HStack {
                                VStack(alignment: .leading, spacing: 8) {
                                    if loadingItemId == item.id {
                                        GeneratingImagePlaceholder()
                                    } else if let img = imageCache[item.id] {
                                        Image(nsImage: img)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(maxWidth: 400, maxHeight: 400)
                                            .clipShape(
                                                RoundedRectangle(
                                                    cornerRadius: 12, style: .continuous)
                                            )
                                            .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                                            .contextMenu {
                                                Button("Copy Image") {
                                                    let pb = NSPasteboard.general
                                                    pb.clearContents()
                                                    pb.writeObjects([img])
                                                }
                                                Button("Save to Downloads") {
                                                    saveImage(img, prompt: item.prompt)
                                                }
                                            }

                                        if let text = item.responseText, !text.isEmpty {
                                            Text(text)
                                                .font(.system(size: 13))
                                                .foregroundColor(.primary)
                                                .textSelection(.enabled)
                                        }
                                    } else if let error = item.error {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.orange)
                                            Text(error)
                                                .font(.system(size: 12))
                                                .foregroundColor(.red)
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                    }
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.06)
                                                : Color.black.opacity(0.04))
                                )

                                Spacer(minLength: 40)
                            }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onChange(of: store.items.count) { _, _ in
                if let first = store.items.first {
                    withAnimation {
                        proxy.scrollTo(first.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Bar (matches main chat window)

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Style picker button
                Menu {
                    ForEach(styles, id: \.section) { section in
                        Section(section.section) {
                            ForEach(section.items, id: \.value) { item in
                                Button(action: { selectedStyle = item.value }) {
                                    if selectedStyle == item.value {
                                        Label(item.label, systemImage: "checkmark")
                                    } else {
                                        Text(item.label)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
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
                .help("Style: \(selectedStyle)")

                // Text field — matching main chat input style
                ZStack(alignment: .leading) {
                    if prompt.isEmpty && !isInputFocused {
                        Text("Describe the image to generate...")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.6))
                            .allowsHitTesting(false)
                            .padding(.leading, 4)
                    }

                    TextField("", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($isInputFocused)
                        .onSubmit { generate() }
                }

                // Send/Stop button
                Button(action: isGenerating ? stopGeneration : generate) {
                    Image(
                        systemName: isGenerating ? "stop.fill" : "arrow.up.circle.fill"
                    )
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        isGenerating
                            ? AnyShapeStyle(Color.red)
                            : (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AnyShapeStyle(Color.secondary.opacity(0.4))
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: appTheme.colors.isEmpty
                                            ? [.blue, .green]
                                            : appTheme.colors,
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )))
                    )
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !isGenerating)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.15 : 0.6),
                                        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08),
                        radius: 12, x: 0, y: 4)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func generate() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let style = selectedStyle
        let promptText = trimmed
        prompt = ""

        let itemId = UUID()
        let item = GeneratedImageItem(
            id: itemId, prompt: promptText, style: style,
            responseText: nil, error: nil, timestamp: Date())
        store.addItem(item, image: nil)

        loadingItemId = itemId
        isGenerating = true

        currentTask = Task {
            do {
                let targetShortcut =
                    (style == "ChatGPT") ? shortcutImageGenChatGPT : shortcutImageGen

                let result = try await shortcutService.runShortcut(
                    name: targetShortcut, input: promptText, style: style, image: nil)

                await MainActor.run {
                    let text = result.0.isEmpty ? nil : result.0
                    store.updateItem(id: itemId, responseText: text, image: result.1, error: nil)
                    if let img = result.1 {
                        imageCache[itemId] = img
                    }
                    loadingItemId = nil
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    store.updateItem(
                        id: itemId, responseText: nil, image: nil,
                        error: error.localizedDescription)
                    loadingItemId = nil
                    isGenerating = false
                }
            }
        }
    }

    private func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
        if let id = loadingItemId {
            store.updateItem(id: id, responseText: nil, image: nil, error: "Cancelled")
            loadingItemId = nil
        }
    }

    private func loadCachedImages() {
        for item in store.items {
            if imageCache[item.id] == nil {
                if let img = store.image(for: item.id) {
                    imageCache[item.id] = img
                }
            }
        }
    }

    private func saveImage(_ image: NSImage, prompt: String) {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
        let sanitized = prompt.prefix(40).replacingOccurrences(
            of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
        let filename = "Prism_\(sanitized)_\(Int(Date().timeIntervalSince1970)).png"
        let fileURL = downloadsURL.appendingPathComponent(filename)

        if let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            try? png.write(to: fileURL)
        }
    }
}
