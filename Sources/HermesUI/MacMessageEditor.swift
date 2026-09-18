#if os(macOS)
import AppKit
import SwiftUI

/// Plain native composition with hidden scrollers and a layout-measured height.
/// Supply focus callbacks when the containing view owns a SwiftUI FocusState.
struct MacMessageEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: Bool?
    var onFocusChange: @MainActor (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(text: Binding<String>, isFocused: Bool? = nil,
         onFocusChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        _text = text
        self.isFocused = isFocused
        self.onFocusChange = onFocusChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MessageScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0

        let editor = MessageTextView(frame: .zero, textContainer: container)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.font = .systemFont(ofSize: T.bodySize)
        editor.textColor = NSColor(T.ink)
        editor.insertionPointColor = NSColor(T.ink)
        editor.textContainerInset = NSSize(width: 4, height: 2)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 36)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.usesFontPanel = false
        editor.usesRuler = false
        editor.setAccessibilityLabel("Message Hermes")
        editor.string = text
        editor.delegate = context.coordinator

        let scroll = MessageScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = editor
        let coordinator = context.coordinator
        coordinator.scroll = scroll
        editor.focusChanged = { [weak coordinator] focused in coordinator?.reportFocus(focused) }
        editor.windowChanged = { [weak coordinator] in coordinator?.synchronizeFocus() }
        return scroll
    }

    func updateNSView(_ scroll: MessageScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = scroll.editor else { return }
        editor.isEditable = isEnabled
        editor.isSelectable = true
        if editor.string != text {
            // SwiftUI echoes of user edits take the no-op path. A send/restore or
            // conversation switch replaces the draft without retaining its undo.
            let ranges = editor.selectedRanges
            editor.string = text
            editor.undoManager?.removeAllActions()
            let length = (text as NSString).length
            editor.selectedRanges = ranges.map { value in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            editor.scrollRangeToVisible(editor.selectedRange())
            scroll.invalidateIntrinsicContentSize()
        }
        coordinator.synchronizeFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.measuredHeight(for: width))
    }

    static func dismantleNSView(_ scroll: MessageScrollView, coordinator: Coordinator) {
        scroll.editor?.delegate = nil
        scroll.editor?.focusChanged = nil
        scroll.editor?.windowChanged = nil
        coordinator.scroll = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacMessageEditor
        weak var scroll: MessageScrollView?
        private var applyingFocus = false

        init(_ parent: MacMessageEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? {
            view.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = scroll?.editor else { return }
            if parent.text != editor.string { parent.text = editor.string }
            scroll?.invalidateIntrinsicContentSize()
        }

        func reportFocus(_ focused: Bool) {
            guard !applyingFocus, parent.isFocused != focused else { return }
            parent.onFocusChange(focused)
        }

        func synchronizeFocus() {
            guard let desired = parent.isFocused, let editor = scroll?.editor,
                  let window = editor.window else { return }
            let focused = window.firstResponder === editor
            guard desired != focused else { return }
            applyingFocus = true
            defer { applyingFocus = false }
            if desired, editor.isEditable { window.makeFirstResponder(editor) }
            else if focused { window.makeFirstResponder(nil) }
        }
    }
}

@MainActor final class MessageScrollView: NSScrollView {
    var editor: MessageTextView? { documentView as? MessageTextView }
    private var preferredHeight: CGFloat = 36

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let editor, let container = editor.textContainer, let layout = editor.layoutManager else { return 36 }
        editor.setFrameSize(NSSize(width: width, height: max(editor.frame.height, 36)))
        container.containerSize = NSSize(width: max(1, width - editor.textContainerInset.width * 2),
                                         height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: editor.font ?? .systemFont(ofSize: T.bodySize))
        let contentHeight = max(lineHeight, layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let documentHeight = max(36, ceil(contentHeight + editor.textContainerInset.height * 2))
        editor.setFrameSize(NSSize(width: width, height: documentHeight))
        preferredHeight = min(140, documentHeight)
        return preferredHeight
    }
}

@MainActor final class MessageTextView: NSTextView {
    var focusChanged: ((Bool) -> Void)?
    var windowChanged: (() -> Void)?
    private let editingUndoManager = UndoManager()
    override var undoManager: UndoManager? { editingUndoManager }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?()
    }
}
#endif
