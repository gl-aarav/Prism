import AppKit
import Combine
import SwiftUI

/// Core orchestrator for the AI autocomplete feature.
/// Ties together CursorTracker, AutocompleteService, KeyboardEventTap,
/// TextInjector, and the suggestion overlay.
class AutocompleteManager: ObservableObject {
    static let shared = AutocompleteManager()

    // MARK: - Published State

    /// The current suggestion text (nil when no suggestion is available).
    @Published var suggestion: String? = nil

    /// Dynamic font size based on the cursor height of the host app.
    @Published var suggestionFontSize: CGFloat = 13.0

    /// Whether a prediction is currently in-flight.
    @Published var isLoading: Bool = false

    /// Whether AI autocomplete is globally enabled.
    @Published var isEnabled: Bool = false

    // MARK: - Settings (backed by UserDefaults)

    @AppStorage("EnableAIAutocomplete") var enableAutocomplete: Bool = false
    @AppStorage("AIAutocompleteBackend") var backendRaw: String = "Ollama"
    @AppStorage("AIAutocompleteModel") var aiAutocompleteModel: String = ""
    @AppStorage("AIAutocompleteDebounceMs") var debounceMs: Int = 500
    @AppStorage("AIAutocompleteCustomInstruction") var customInstruction: String = ""
    @AppStorage("AIAutocompleteBlacklist") var blacklistJSON: String = "[]"
    @AppStorage("AIAutocompleteCompletionLength") var completionLength: String =
        "Medium (~ 2 - 4 words)"

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var debounceTimer: DispatchWorkItem?
    private var currentTask: Task<Void, Never>?
    private var overlayPanel: SuggestionOverlayPanel?
    private var lastTextBeforeCursor: String = ""
    private var isAcceptingPartialWord: Bool = false

    /// Live-read backend from UserDefaults so settings changes take effect immediately.
    var backend: AutocompleteService.Backend {
        let raw = UserDefaults.standard.string(forKey: "AIAutocompleteBackend") ?? "Ollama"
        return AutocompleteService.Backend(rawValue: raw) ?? .ollama
    }

    /// Live-read model from UserDefaults so settings changes take effect immediately.
    var currentModel: String {
        UserDefaults.standard.string(forKey: "AIAutocompleteModel") ?? ""
    }

    /// Live-read custom instruction so settings changes take effect immediately.
    var currentCustomInstruction: String {
        UserDefaults.standard.string(forKey: "AIAutocompleteCustomInstruction") ?? ""
    }

    var blacklistedApps: [String] {
        get {
            let json = UserDefaults.standard.string(forKey: "AIAutocompleteBlacklist") ?? "[]"
            guard let data = json.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
                let json = String(data: data, encoding: .utf8)
            {
                UserDefaults.standard.set(json, forKey: "AIAutocompleteBlacklist")
            }
        }
    }

    private init() {}

    // MARK: - Setup

    func setup() {
        guard enableAutocomplete else { return }

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
        // Swapped bindings: Tab accepts next word, Right Arrow accepts full text
        tap.onTab = { [weak self] in self?.acceptNextWord() }
        tap.onRightArrow = { [weak self] in self?.acceptFull() }
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
                guard let self = self else { return }
                // Use effectiveCursorFrame so Chromium/Electron apps get mouse fallback
                self.updateOverlayPosition(frame != .zero ? frame : self.effectiveCursorFrame())
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
        // If we just injected a partial word, don't cancel the existing suggestion.
        // But do update the last tracked text so the next user keystroke triggers properly.
        if isAcceptingPartialWord {
            lastTextBeforeCursor = newText
            return
        }

        // Check if the user is "typing through" the current suggestion.
        // If the new text is just the old text + the prefix of the current suggestion,
        // we can simply keep the suggestion and chop off the typed part.
        if let currentSuggestion = suggestion {
            if newText.hasPrefix(lastTextBeforeCursor) {
                let addedText = String(newText.dropFirst(lastTextBeforeCursor.count))
                if !addedText.isEmpty, currentSuggestion.hasPrefix(addedText) {
                    // User typed exactly what was suggested!
                    // Shorten the suggestion and DO NOT trigger a new prediction.
                    lastTextBeforeCursor = newText
                    let remaining = String(currentSuggestion.dropFirst(addedText.count))

                    if remaining.isEmpty {
                        suggestion = nil
                    } else {
                        suggestion = remaining
                    }
                    return
                }
            }
        }

        // Cancel any pending prediction
        cancelPrediction()

        // Clear current suggestion when text changes and didn't match the type-through
        suggestion = nil

        // Don't predict if text is too short or empty
        guard !newText.isEmpty, newText.count >= 3 else { return }

        // Don't predict if text hasn't actually changed
        guard newText != lastTextBeforeCursor else { return }
        lastTextBeforeCursor = newText

        // Check if the focused app is blacklisted by user or hardcoded (browsers with extensions)
        let hardcodedBlacklist = [
            "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser",
        ]
        if let bundleId = CursorTracker.shared.focusedAppBundleId,
            blacklistedApps.contains(bundleId) || hardcodedBlacklist.contains(bundleId)
        {
            return
        }

        // Don't predict if cursor is not in a text field
        guard CursorTracker.shared.isTextFieldFocused else { return }

        // Live-read debounce from UserDefaults
        let currentDebounce = UserDefaults.standard.integer(forKey: "AIAutocompleteDebounceMs")
        let delay = max(0, currentDebounce)

        // Debounce: wait before triggering prediction
        if delay == 0 {
            triggerPrediction(context: newText)
        } else {
            let workItem = DispatchWorkItem { [weak self] in
                self?.triggerPrediction(context: newText)
            }
            debounceTimer = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delay),
                execute: workItem
            )
        }
    }

    // MARK: - Prediction

    private func triggerPrediction(context: String) {
        isLoading = true

        // Read settings live from UserDefaults for each prediction
        let liveBackend = backend
        let liveModel = currentModel
        let liveInstruction = currentCustomInstruction
        let liveLength = completionLength

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            var accumulated = ""
            do {
                let stream = AutocompleteService.shared.generateCompletion(
                    context: context,
                    backend: liveBackend,
                    model: liveModel,
                    customInstruction: liveInstruction,
                    length: liveLength
                )

                for try await chunk in stream {
                    guard !Task.isCancelled else { return }
                    accumulated += chunk

                    // Post-process: strip any echoed context from the LLM response
                    var cleaned = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)

                    // If the model echoed back the end of the context, strip it
                    let contextSuffix = String(context.suffix(50)).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !contextSuffix.isEmpty, cleaned.hasPrefix(contextSuffix) {
                        cleaned = String(cleaned.dropFirst(contextSuffix.count))
                            .trimmingCharacters(in: .whitespaces)
                    }

                    if !cleaned.isEmpty {
                        // Ensure single-line rendering for the UI by replacing newlines with spaces
                        let singleLine = cleaned.replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: "")
                        let completionText = singleLine
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
        if UserDefaults.standard.bool(forKey: "AIAutocompleteMemoryEnabled") {
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
        let remaining = String(trimmed.dropFirst(firstWord.count)).trimmingCharacters(
            in: .whitespaces)
        let insertText = remaining.isEmpty ? firstWord : firstWord + " "

        isAcceptingPartialWord = true
        TextInjector.shared.insertText(insertText)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isAcceptingPartialWord = false
        }

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
        overlayPanel = SuggestionOverlayPanel()
    }

    private func showOverlay(_ text: String) {
        guard let panel = overlayPanel else { return }

        let cursorFrame = effectiveCursorFrame()
        let x = cursorFrame.maxX - 8
        let screenMaxX =
            NSScreen.main?.visibleFrame.maxX ?? NSScreen.screens.first?.frame.maxX ?? 1920
        let availableWidth = max(100.0, screenMaxX - x - 24)

        // Update the SwiftUI view
        panel.update(text: text, fontSize: suggestionFontSize, maxWidth: availableWidth)

        // Give SwiftUI time to layout, then reposition using the intrinsic size
        panel.hostingView.layout()
        updateOverlayPosition(cursorFrame)

        if !panel.isVisible {
            // Use orderFrontRegardless so the panel shows even when another app is active
            // (which is always the case during autocomplete in other apps)
            panel.orderFrontRegardless()
        }
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
    }

    /// Returns the cursor frame from the accessibility API, or falls back to
    /// the mouse pointer location when the AX API fails (common in Chromium/Electron).
    private func effectiveCursorFrame() -> NSRect {
        let frame = CursorTracker.shared.cursorFrame
        if frame != .zero { return frame }

        // Fallback: use the current mouse location as an approximation.
        // Chromium/Electron apps often don't expose kAXBoundsForRangeParameterizedAttribute,
        // so the cursor frame stays at .zero. The mouse is usually near the text cursor.
        let mouseLocation = NSEvent.mouseLocation  // AppKit coordinates (bottom-left origin)
        // Convert to AX/CG coordinates (top-left origin) to match what CursorTracker provides
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 1080
        let axY = primaryScreenHeight - mouseLocation.y
        return NSRect(x: mouseLocation.x, y: axY, width: 1, height: 20)
    }

    private func updateOverlayPosition(_ cursorFrame: NSRect) {
        guard let panel = overlayPanel, cursorFrame != .zero else { return }

        // Find the screen that actually contains the cursor
        let targetScreen =
            NSScreen.screens.first { screen in
                screen.frame.contains(cursorFrame)
            } ?? NSScreen.main ?? NSScreen.screens[0]

        // Use the specific screen's frame for coordinate mapping
        let x = cursorFrame.maxX - 8
        let availableWidth = max(100.0, targetScreen.visibleFrame.maxX - x - 24)

        // Calculate dynamic font size based on cursor height
        let calculatedFontSize = max(11, min(cursorFrame.height * 0.75, 24))
        if self.suggestionFontSize != calculatedFontSize {
            self.suggestionFontSize = calculatedFontSize
            if let text = suggestion {
                panel.update(text: text, fontSize: calculatedFontSize, maxWidth: availableWidth)
                panel.hostingView.layout()
            }
        }

        // Get the new fitting size of the liquid glass pill
        let fittingSize = panel.hostingView.fittingSize
        let panelWidth = min(fittingSize.width, availableWidth)
        let panelHeight = fittingSize.height

        // The top of the cursor in AppKit coordinates (using the target screen's height)
        // Since CGEvent coordinates are global top-left, we must adjust Y relative to the screen
        let topAppKitY = targetScreen.frame.maxY - cursorFrame.minY

        // The panel's y coordinate specifies its bottom edge.
        let y = topAppKitY - panelHeight + 12

        // Ensure the text is constrained horizontally and vertically on the target screen
        let clampedX = min(
            max(x, targetScreen.visibleFrame.minX + 4),
            targetScreen.visibleFrame.maxX - panelWidth - 4)
        let clampedY = max(
            min(y, targetScreen.visibleFrame.maxY - panelHeight - 4),
            targetScreen.visibleFrame.minY + 4)

        panel.setFrame(
            NSRect(x: clampedX, y: clampedY, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    // MARK: - Toggle

    func toggle() {
        if isEnabled {
            stop()
            enableAutocomplete = false
        } else {
            enableAutocomplete = true
            setup()
        }
    }
}
