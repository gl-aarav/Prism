import AppKit
import Combine
import SwiftUI

/// Core orchestrator for the Cotypist autocomplete feature.
/// Ties together CursorTracker, AutocompleteService, KeyboardEventTap,
/// TextInjector, and the suggestion overlay.
class AutocompleteManager: ObservableObject {
    static let shared = AutocompleteManager()

    // MARK: - Published State

    /// The current suggestion text (nil when no suggestion is available).
    @Published var suggestion: String? = nil

    /// Whether a prediction is currently in-flight.
    @Published var isLoading: Bool = false

    /// Whether Cotypist is globally enabled.
    @Published var isEnabled: Bool = false

    // MARK: - Settings (backed by UserDefaults)

    @AppStorage("EnableCotypist") var enableCotypist: Bool = false
    @AppStorage("CotypistBackend") var backendRaw: String = "Ollama"
    @AppStorage("CotypistModel") var cotypistModel: String = ""
    @AppStorage("CotypistDebounceMs") var debounceMs: Int = 500
    @AppStorage("CotypistCustomInstruction") var customInstruction: String = ""
    @AppStorage("CotypistBlacklist") var blacklistJSON: String = "[]"

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var overlayPanel: SuggestionOverlayPanel?
    private var lastTextBeforeCursor: String = ""

    /// Live-read backend from UserDefaults so settings changes take effect immediately.
    var backend: AutocompleteService.Backend {
        let raw = UserDefaults.standard.string(forKey: "CotypistBackend") ?? "Ollama"
        return AutocompleteService.Backend(rawValue: raw) ?? .ollama
    }

    /// Live-read model from UserDefaults so settings changes take effect immediately.
    var currentModel: String {
        UserDefaults.standard.string(forKey: "CotypistModel") ?? ""
    }

    /// Live-read custom instruction so settings changes take effect immediately.
    var currentCustomInstruction: String {
        UserDefaults.standard.string(forKey: "CotypistCustomInstruction") ?? ""
    }

    var blacklistedApps: [String] {
        get {
            let json = UserDefaults.standard.string(forKey: "CotypistBlacklist") ?? "[]"
            guard let data = json.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            {
                UserDefaults.standard.set(json, forKey: "CotypistBlacklist")
            }
        }
    }

    private init() {}

    // MARK: - Setup

    func setup() {
        guard enableCotypist else { return }

        // Check accessibility permission
        guard AccessibilityHelper.shared.checkAccessibilityPermission(prompt: true) else {
            print("[AutocompleteManager] Accessibility permission not granted.")
            return
        }

        start()
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true

        // Start cursor tracking
        CursorTracker.shared.start()

        // Install keyboard event tap
        let tap = KeyboardEventTap.shared
        tap.isSuggestionVisible = { [weak self] in
            self?.suggestion != nil
        }
        tap.onTab = { [weak self] in self?.acceptFull() }
        tap.onRightArrow = { [weak self] in self?.acceptNextWord() }
        tap.install()

        // Create overlay panel
        setupOverlay()

        // Observe text changes from the cursor tracker
        CursorTracker.shared.$textBeforeCursor
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.handleTextChange(newText)
            }
            .store(in: &cancellables)

        // Observe cursor position changes to reposition overlay
        CursorTracker.shared.$cursorFrame
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.updateOverlayPosition(frame)
            }
            .store(in: &cancellables)

        // Observe suggestion changes to show/hide overlay
        $suggestion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestion in
                if let suggestion = suggestion, !suggestion.isEmpty {
                    self?.showOverlay(suggestion)
                } else {
                    self?.hideOverlay()
                }
            }
            .store(in: &cancellables)

        print("[AutocompleteManager] Started.")
    }

    func stop() {
        isEnabled = false
        CursorTracker.shared.stop()
        KeyboardEventTap.shared.uninstall()
        cancellables.removeAll()
        cancelPrediction()
        hideOverlay()
        print("[AutocompleteManager] Stopped.")
    }

    // MARK: - Text Change Handling

    private func handleTextChange(_ newText: String) {
        // Cancel any pending prediction
        cancelPrediction()

        // Clear current suggestion when text changes
        suggestion = nil

        // Don't predict if text is too short or empty
        guard !newText.isEmpty, newText.count >= 3 else { return }

        // Don't predict if text hasn't actually changed
        guard newText != lastTextBeforeCursor else { return }
        lastTextBeforeCursor = newText

        // Check if the focused app is blacklisted
        if let bundleId = CursorTracker.shared.focusedAppBundleId,
            blacklistedApps.contains(bundleId)
        {
            return
        }

        // Don't predict if cursor is not in a text field
        guard CursorTracker.shared.isTextFieldFocused else { return }

        // Live-read debounce from UserDefaults
        let currentDebounce = UserDefaults.standard.integer(forKey: "CotypistDebounceMs")
        let delay = currentDebounce > 0 ? currentDebounce : 500

        // Debounce: wait before triggering prediction
        let workItem = DispatchWorkItem { [weak self] in
            self?.triggerPrediction(context: newText)
        }
        debounceTimer = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delay),
            execute: workItem
        )
    }

    // MARK: - Prediction

    private func triggerPrediction(context: String) {
        isLoading = true

        // Read settings live from UserDefaults for each prediction
        let liveBackend = backend
        let liveModel = currentModel
        let liveInstruction = currentCustomInstruction

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            var accumulated = ""
            do {
                let stream = AutocompleteService.shared.generateCompletion(
                    context: context,
                    backend: liveBackend,
                    model: liveModel,
                    customInstruction: liveInstruction
                )

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    accumulated += chunk

                    // Post-process: strip any echoed context from the LLM response
                    var cleaned = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)

                    // If the model echoed back the end of the context, strip it
                    let contextSuffix = String(context.suffix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !contextSuffix.isEmpty, cleaned.hasPrefix(contextSuffix) {
                        cleaned = String(cleaned.dropFirst(contextSuffix.count))
                            .trimmingCharacters(in: .whitespaces)
                    }

                    if !cleaned.isEmpty {
                        let completionText = cleaned
                        await MainActor.run {
                            self.suggestion = completionText
                        }
                    }
                }

                let finalAccumulated = accumulated
                await MainActor.run {
                    self.isLoading = false
                    if finalAccumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.suggestion = nil
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isLoading = false
                        self.suggestion = nil
                    }
                    print("[AutocompleteManager] Prediction error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelPrediction() {
        debounceTimer?.cancel()
        debounceTimer = nil
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
    }

    // MARK: - Acceptance Controls

    /// Accept the full suggestion (Tab key).
    func acceptFull() {
        guard let text = suggestion, !text.isEmpty else { return }
        
        // Record in writing memory if enabled
        if UserDefaults.standard.bool(forKey: "CotypistMemoryEnabled") {
            WritingMemory.shared.record(
                context: lastTextBeforeCursor,
                accepted: text,
                appBundleId: CursorTracker.shared.focusedAppBundleId
            )
        }
        
        TextInjector.shared.insertText(text)
        suggestion = nil
        lastTextBeforeCursor = ""  // Reset so next text change triggers prediction
    }

    /// Accept only the next word from the suggestion (Right Arrow key).
    func acceptNextWord() {
        guard let text = suggestion, !text.isEmpty else { return }

        // Find the next word boundary
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let components = trimmed.components(separatedBy: .whitespaces)
        guard let firstWord = components.first, !firstWord.isEmpty else { return }

        // Insert the first word (with a trailing space if more words follow)
        let remaining = String(trimmed.dropFirst(firstWord.count)).trimmingCharacters(in: .whitespaces)
        let insertText = remaining.isEmpty ? firstWord : firstWord + " "
        TextInjector.shared.insertText(insertText)

        // Update the suggestion to remove the accepted word
        if remaining.isEmpty {
            suggestion = nil
        } else {
            suggestion = remaining
        }
    }

    /// Dismiss the current suggestion.
    func dismiss() {
        suggestion = nil
        cancelPrediction()
    }

    // MARK: - Overlay Management

    private func setupOverlay() {
        let panel = SuggestionOverlayPanel()
        panel.contentView = NSHostingView(
            rootView: SuggestionOverlayView()
                .environmentObject(self)
        )
        overlayPanel = panel
    }

    private func showOverlay(_ text: String) {
        guard let panel = overlayPanel else { return }

        // Size the panel to fit the inline text
        let font = NSFont.systemFont(ofSize: 13)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: 600, height: 30),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        let width = min(textSize.width + 8, 600)
        let height: CGFloat = 22

        let currentFrame = panel.frame
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: width,
            height: height
        )
        panel.setFrame(newFrame, display: true)

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }

    private func updateOverlayPosition(_ cursorFrame: NSRect) {
        guard let panel = overlayPanel, cursorFrame != .zero else { return }

        // cursorFrame is in AX/CG coordinates: origin at TOP-LEFT of primary display.
        // NSPanel uses AppKit coordinates: origin at BOTTOM-LEFT of primary display.
        // We need to convert Y.

        // Find the screen that contains the cursor
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080

        // Convert AX Y (top-left origin) to AppKit Y (bottom-left origin)
        // AX: y = distance from TOP of primary screen
        // AppKit: y = distance from BOTTOM of primary screen
        // AX bottom of cursor = cursorFrame.origin.y + cursorFrame.height
        // AppKit bottom of cursor = primaryScreenHeight - (cursorFrame.origin.y + cursorFrame.height)
        let appKitCursorBottom = primaryScreenHeight - cursorFrame.origin.y - cursorFrame.height
        let cursorHeight = max(cursorFrame.height, 16)  // At least 16px line height

        // Position inline: right after the cursor, aligned to the cursor baseline
        let x = cursorFrame.maxX + 2  // 2px after cursor
        // Align panel bottom with cursor bottom, offset up to center vertically
        let y = appKitCursorBottom + (cursorHeight - panel.frame.height) / 2

        // Ensure it stays on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let clampedX = min(x, screenFrame.maxX - panel.frame.width)
            panel.setFrameOrigin(NSPoint(x: clampedX, y: y))
        } else {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - Toggle

    func toggle() {
        if isEnabled {
            stop()
            enableCotypist = false
        } else {
            enableCotypist = true
            setup()
        }
    }
}
