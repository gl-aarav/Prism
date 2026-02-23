import AppKit
import Combine

/// Polls the Accessibility API at a regular interval to track
/// the cursor position and surrounding text context in the
/// currently focused text field of any application.
class CursorTracker: ObservableObject {
    static let shared = CursorTracker()

    /// Screen-space frame of the insertion point (cursor caret).
    @Published var cursorFrame: NSRect = .zero

    /// The full text content of the focused text field.
    @Published var currentText: String = ""

    /// The text before the cursor (context for autocomplete).
    @Published var textBeforeCursor: String = ""

    /// The cursor position (character index) within currentText.
    @Published var cursorPosition: Int = 0

    /// Whether a text input element is currently focused.
    @Published var isTextFieldFocused: Bool = false

    /// Bundle identifier of the app that currently has focus.
    @Published var focusedAppBundleId: String? = nil

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.prism.cursorTracker", qos: .userInteractive)
    private var isRunning = false

    /// The polling interval in milliseconds.
    var pollIntervalMs: Int = 100

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(pollIntervalMs),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { [weak self] in
            self?.isTextFieldFocused = false
            self?.currentText = ""
            self?.textBeforeCursor = ""
            self?.cursorFrame = .zero
        }
    }

    func pause() {
        timer?.suspend()
    }

    func resume() {
        timer?.resume()
    }

    // MARK: - Polling

    private func poll() {
        let helper = AccessibilityHelper.shared

        // Get frontmost app
        let bundleId = helper.getFrontmostAppBundleIdentifier()

        // Get the focused element
        guard let element = helper.getFocusedElement() else {
            updateState(focused: false, bundleId: bundleId)
            return
        }

        // Check if it's a text input element
        let role = helper.getRole(element)
        let isStandardText =
            role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
            || role == "AXSearchField"
        // Electron/Chromium apps expose text inputs as AXWebArea or AXGroup
        let isWebText =
            (role == "AXWebArea" || role == "AXGroup") && helper.isElementEditable(element)
        let isText = isStandardText || isWebText

        guard isText, helper.isElementEditable(element) else {
            updateState(focused: false, bundleId: bundleId)
            return
        }

        // Read text content
        let text = helper.getTextFromElement(element) ?? ""

        // Read cursor position
        let range = helper.getSelectedRange(element)
        let position = range?.location ?? text.count

        // Only get insertion point frame if we have text
        let frame = helper.getInsertionPointFrame(element)

        // Extract text before cursor
        let safePosition = min(position, text.count)
        let beforeCursor: String
        if safePosition > 0 {
            let startIndex = text.startIndex
            let endIndex =
                text.index(startIndex, offsetBy: safePosition, limitedBy: text.endIndex)
                ?? text.endIndex
            beforeCursor = String(text[startIndex..<endIndex])
        } else {
            beforeCursor = ""
        }

        // Update published properties on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTextFieldFocused = true
            self.focusedAppBundleId = bundleId
            self.currentText = text
            self.cursorPosition = safePosition
            self.textBeforeCursor = beforeCursor
            if let frame = frame {
                self.cursorFrame = frame
            }
        }
    }

    private func updateState(focused: Bool, bundleId: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isTextFieldFocused = focused
            self.focusedAppBundleId = bundleId
            if !focused {
                self.currentText = ""
                self.textBeforeCursor = ""
                self.cursorFrame = .zero
            }
        }
    }
}
