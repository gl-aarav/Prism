import SwiftUI

struct ImageGenerationView: View {
    @AppStorage("ShortcutImageGen") private var shortcutImageGen: String = "Generate Image"
    @AppStorage("ShortcutImageGenChatGPT") private var shortcutImageGenChatGPT: String =
        "Generate Image ChatGPT"
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default
    @Environment(\.colorScheme) private var colorScheme

    @State private var prompt: String = ""
    @State private var selectedStyle: String = "Animation"
    @State private var isGenerating: Bool = false
    @State private var generatedImages: [GeneratedImage] = []
    @State private var selectedAttachment: NSImage? = nil
    @State private var errorMessage: String? = nil
    @State private var currentTask: Task<Void, Never>? = nil
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
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintbrush.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: appTheme.colors.isEmpty ? [.orange, .pink] : appTheme.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Image Generation")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Spacer()

            if !generatedImages.isEmpty {
                Button(action: clearAll) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            if generatedImages.isEmpty && !isGenerating {
                emptyState
            } else {
                galleryView
            }
            Spacer(minLength: 0)
            inputArea
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.artframe")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange.opacity(0.6), .pink.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Generate Images")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
            Text("Describe what you'd like to create and pick a style.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Gallery

    private var galleryView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(generatedImages) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        // Prompt label
                        HStack(spacing: 6) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(item.prompt)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Text(item.style)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(Color.orange.opacity(0.12))
                                )
                        }

                        if item.isLoading {
                            GeneratingImagePlaceholder()
                        } else if let image = item.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 400, maxHeight: 400)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                                .contextMenu {
                                    Button("Copy Image") {
                                        let pb = NSPasteboard.general
                                        pb.clearContents()
                                        pb.writeObjects([image])
                                    }
                                    Button("Save to Downloads") {
                                        saveImage(image, prompt: item.prompt)
                                    }
                                }
                        }

                        if let text = item.responseText, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                        }

                        if let error = item.error {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03))
                    )
                }
            }
            .padding(20)
        }
    }

    // MARK: - Input Area

    private var inputArea: some View {
        VStack(spacing: 10) {
            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Spacer()
                    Button("Dismiss") { errorMessage = nil }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                // Style picker
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.orange, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                        )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .help("Style: \(selectedStyle)")

                // Text field
                TextField("Describe the image to generate...", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isInputFocused)
                    .onSubmit { generate() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
                    )

                // Generate button
                Button(action: isGenerating ? stopGeneration : generate) {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            isGenerating
                                ? AnyShapeStyle(Color.red)
                                : AnyShapeStyle(
                                    LinearGradient(
                                        colors: [.orange, .pink],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                        )
                }
                .buttonStyle(.plain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
                .help(isGenerating ? "Stop" : "Generate")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func generate() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let style = selectedStyle
        let promptText = trimmed
        prompt = ""
        errorMessage = nil

        let itemId = UUID()
        var item = GeneratedImage(id: itemId, prompt: promptText, style: style)
        item.isLoading = true
        generatedImages.append(item)
        isGenerating = true

        currentTask = Task {
            do {
                let targetShortcut =
                    (style == "ChatGPT") ? shortcutImageGenChatGPT : shortcutImageGen

                let result = try await shortcutService.runShortcut(
                    name: targetShortcut, input: promptText, style: style, image: selectedAttachment)

                await MainActor.run {
                    if let idx = generatedImages.firstIndex(where: { $0.id == itemId }) {
                        generatedImages[idx].responseText = result.0.isEmpty ? nil : result.0
                        generatedImages[idx].image = result.1
                        generatedImages[idx].isLoading = false
                    }
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    if let idx = generatedImages.firstIndex(where: { $0.id == itemId }) {
                        generatedImages[idx].error = error.localizedDescription
                        generatedImages[idx].isLoading = false
                    }
                    isGenerating = false
                }
            }
        }
    }

    private func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
        // Mark any loading items as cancelled
        for i in generatedImages.indices where generatedImages[i].isLoading {
            generatedImages[i].isLoading = false
            generatedImages[i].error = "Cancelled"
        }
    }

    private func clearAll() {
        currentTask?.cancel()
        currentTask = nil
        isGenerating = false
        generatedImages.removeAll()
    }

    private func saveImage(_ image: NSImage, prompt: String) {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
        let sanitized = prompt.prefix(40).replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: "", options: .regularExpression)
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

// MARK: - Generated Image Model

struct GeneratedImage: Identifiable {
    let id: UUID
    let prompt: String
    let style: String
    var image: NSImage? = nil
    var responseText: String? = nil
    var error: String? = nil
    var isLoading: Bool = false
}
