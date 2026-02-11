import AppKit
import SwiftUI

/// High-performance multi-line text input using native NSTextView.
/// Avoids the layout thrashing and performance degradation of
/// SwiftUI's TextField(axis: .vertical) with large amounts of text.
struct NativeTextInput: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>? = nil
    var font: NSFont = .systemFont(ofSize: 15)
    var textColor: NSColor = .labelColor
    var maxLines: Int = 10
    var onCommit: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onArrowUp: (() -> Bool)? = nil
    var onArrowDown: (() -> Bool)? = nil
    var onTab: (() -> Bool)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Called when user pastes non-text content (files, images, PDFs).
    /// Return true if handled, false to fall back to default paste.
    var onPasteNonText: ((NSPasteboard) -> Bool)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> _NTIScrollView {
        let textView = _NTITextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text

        let scrollView = _NTIScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let lineHeight = computeLineHeight(font: font)
        scrollView.maxContentHeight = lineHeight * CGFloat(maxLines)
        scrollView.minContentHeight = lineHeight

        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: _NTIScrollView, context: Context) {
        guard let textView = scrollView.documentView as? _NTITextView else { return }
        context.coordinator.parent = self

        // Sync text from SwiftUI → NSTextView (only if not currently editing)
        if textView.string != text && !context.coordinator.isEditing {
            textView.string = text
            scrollView.invalidateIntrinsicContentSize()
        }

        // Update style
        if textView.font != font {
            textView.font = font
            let lineHeight = computeLineHeight(font: font)
            scrollView.maxContentHeight = lineHeight * CGFloat(maxLines)
            scrollView.minContentHeight = lineHeight
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }

        // Handle programmatic focus changes
        if let focusBinding = isFocused {
            if focusBinding.wrappedValue {
                if textView.window != nil && textView.window?.firstResponder !== textView {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func computeLineHeight(font: NSFont) -> CGFloat {
        let layoutManager = NSLayoutManager()
        return layoutManager.defaultLineHeight(for: font) + 4 // +4 for textContainerInset
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextInput
        var isEditing = false
        weak var scrollView: _NTIScrollView?
        weak var textView: _NTITextView?

        init(_ parent: NativeTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = textView.string
            isEditing = false
            scrollView?.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = false
            parent.onFocusChange?(false)
        }

        // Event handling (called from _NTITextView)
        func handleCommit() { parent.onCommit?() }
        func handleEscape() { parent.onEscape?() }
        func handleArrowUp() -> Bool { parent.onArrowUp?() ?? false }
        func handleArrowDown() -> Bool { parent.onArrowDown?() ?? false }
        func handleTab() -> Bool { parent.onTab?() ?? false }
        func handlePasteNonText(_ pasteboard: NSPasteboard) -> Bool {
            parent.onPasteNonText?(pasteboard) ?? false
        }
    }
}

// MARK: - NSTextView subclass for key event handling

class _NTITextView: NSTextView {
    weak var coordinator: NativeTextInput.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:  // Return
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event)
            } else {
                coordinator?.handleCommit()
            }
        case 53:  // Escape
            coordinator?.handleEscape()
        case 126:  // Up Arrow
            if coordinator?.handleArrowUp() != true {
                super.keyDown(with: event)
            }
        case 125:  // Down Arrow
            if coordinator?.handleArrowDown() != true {
                super.keyDown(with: event)
            }
        case 48:  // Tab
            if coordinator?.handleTab() != true {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        // Check if caller wants to handle non-text paste (images, files, PDFs)
        if let coordinator = coordinator {
            let pb = NSPasteboard.general
            let hasNonText =
                pb.canReadItem(withDataConformingToTypes: ["public.image"])
                || pb.canReadItem(withDataConformingToTypes: ["public.file-url"])
                || pb.canReadItem(withDataConformingToTypes: ["com.adobe.pdf"])
            if hasNonText && coordinator.handlePasteNonText(pb) {
                return
            }
        }
        super.paste(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            coordinator?.parent.isFocused?.wrappedValue = true
            coordinator?.parent.onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            coordinator?.parent.isFocused?.wrappedValue = false
            coordinator?.parent.onFocusChange?(false)
        }
        return result
    }
}

// MARK: - Auto-sizing scroll view

class _NTIScrollView: NSScrollView {
    var maxContentHeight: CGFloat = 200
    var minContentHeight: CGFloat = 22

    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return NSSize(width: NSView.noIntrinsicMetric, height: minContentHeight)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = usedRect.height + textView.textContainerInset.height * 2
        let height = min(max(contentHeight, minContentHeight), maxContentHeight)

        // Enable scrolling only when content exceeds max
        hasVerticalScroller = contentHeight > maxContentHeight

        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}
