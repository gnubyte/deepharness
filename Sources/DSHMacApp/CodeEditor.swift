import SwiftUI
import AppKit
import DSHCore

// MARK: - Text view

/// A code editor backed by `NSTextView`: monospaced, line-numbered, syntax
/// highlighted, with tab-to-spaces and live external reload.
struct CodeEditorView: NSViewRepresentable {
    @Bindable var buffer: EditorBuffer
    var fontSize: Double
    var wraps: Bool
    var showsLineNumbers: Bool

    func makeCoordinator() -> Coordinator { Coordinator(buffer: buffer) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wraps
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        // Build the text system by hand: an NSTextView created with a zero
        // frame lays out into a zero-width container and draws nothing, so the
        // container and the frame are both given a real size up front.
        let contentSize = scrollView.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(
            frame: NSRect(origin: .zero, size: NSSize(width: max(contentSize.width, 400),
                                                      height: max(contentSize.height, 300))),
            textContainer: container
        )
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: LineNumberRuler.thickness + 6, height: 8)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        apply(to: textView, scrollView: scrollView, context: context, initial: true)

        if showsLineNumbers {
            // Order matters: the scroll view only insets its content view for
            // the ruler when it tiles, and it tiles off `hasVerticalRuler`.
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = LineNumberRuler(textView: textView)
            scrollView.rulersVisible = true
            scrollView.tile()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.buffer = buffer
        apply(to: textView, scrollView: scrollView, context: context, initial: false)
    }

    /// Without this the scroll view reports its *document's* size — thousands
    /// of points for a long file — and SwiftUI squeezes the tab bar and status
    /// bar to nothing trying to fit it. The editor takes whatever it is given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    private func apply(to textView: EditorTextView, scrollView: NSScrollView,
                       context: Context, initial: Bool) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let changedFile = context.coordinator.loadedID != buffer.id
        let reloaded = context.coordinator.loadedToken != buffer.reloadToken

        if initial || changedFile || reloaded || textView.string != buffer.text {
            // Only reset the text when it genuinely differs — typing must not
            // round-trip through here or the cursor jumps.
            if textView.string != buffer.text {
                let selection = textView.selectedRange()
                textView.string = buffer.text
                if !initial && !changedFile {
                    let clamped = NSRange(location: min(selection.location, (buffer.text as NSString).length),
                                          length: 0)
                    textView.setSelectedRange(clamped)
                }
            }
            context.coordinator.loadedID = buffer.id
            context.coordinator.loadedToken = buffer.reloadToken
            if changedFile || initial { Self.scrollToStart(scrollView) }
        }

        textView.font = font
        textView.language = buffer.language
        // The ruler overlays the scroll view's left edge rather than reserving
        // space, so the text is inset past it by hand.
        let leftInset = (showsLineNumbers ? LineNumberRuler.thickness : 0) + 6
        if abs(textView.textContainerInset.width - leftInset) > 0.5 {
            textView.textContainerInset = NSSize(width: leftInset, height: 8)
        }
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.textColor = .labelColor
        scrollView.hasHorizontalScroller = !wraps

        let width = scrollView.contentSize.width
        if wraps {
            // Wrapping: the container follows the view's width, and the view
            // follows the clip view.
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: width,
                                                           height: CGFloat.greatestFiniteMagnitude)
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
        } else {
            // Not wrapping: the container is unbounded and the view grows to
            // the longest line, which is what gives us horizontal scrolling.
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
            textView.sizeToFit()
            if textView.frame.width < width {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }
        }
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)

        if initial || changedFile {
            // The scroll view re-tiles once the ruler appears, which leaves the
            // document scrolled a gutter's width to the right. Reset after the
            // tiling has settled, not just before it.
            let box = scrollView
            DispatchQueue.main.async { Self.scrollToStart(box) }
        }
        if showsLineNumbers, scrollView.verticalRulerView == nil {
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = LineNumberRuler(textView: textView)
        }
        if scrollView.rulersVisible != showsLineNumbers {
            scrollView.rulersVisible = showsLineNumbers
            scrollView.tile()
        }
        (scrollView.verticalRulerView as? LineNumberRuler)?.font = font
        textView.rehighlightAll()
    }

    /// Put the document back at its top-left corner.
    static func scrollToStart(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.verticalRulerView?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var buffer: EditorBuffer
        weak var textView: EditorTextView?
        weak var scrollView: NSScrollView?
        var loadedID: String = ""
        var loadedToken = -1

        init(buffer: EditorBuffer) { self.buffer = buffer }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            buffer.text = textView.string
            textView.scheduleHighlight()
            scrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// `NSTextView` with syntax highlighting and editor-shaped key handling.
final class EditorTextView: NSTextView {
    var language: Language = .plain
    private var highlightWork: DispatchWorkItem?

    /// Soft tabs, because mixing them into an agent-edited file is a mess.
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    /// Keep the previous line's indentation on Return.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightVisible() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func rehighlightAll() {
        highlightVisible()
    }

    /// Colour what is on screen, plus a screenful either side so scrolling
    /// does not reveal uncoloured text.
    private func highlightVisible() {
        guard let storage = textStorage, let layoutManager, let container = textContainer else { return }
        guard !language.keywords.isEmpty || language.lineComment != nil || !language.quotes.isEmpty else {
            storage.setAttributes([.font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                   .foregroundColor: NSColor.labelColor],
                                  range: NSRange(location: 0, length: storage.length))
            return
        }
        let visible = visibleRect
        let padded = NSRect(x: visible.origin.x, y: max(0, visible.origin.y - visible.height),
                            width: visible.width, height: visible.height * 3)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: padded, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let range = charRange.length == 0
            ? NSRange(location: 0, length: min(storage.length, 20_000))
            : charRange
        SyntaxHighlighter.apply(to: storage, language: language, range: range,
                                font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleHighlight()
    }
}

/// Line-number gutter.
final class LineNumberRuler: NSRulerView {
    /// Gutter width. The editor insets its text by this much.
    static let thickness: CGFloat = 44

    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.thickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // AppKit does not clip subviews by default, and a ruler whose frame is
        // wider than its rule paints straight over the editor and the tab bar.
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // Paint only the gutter itself, never the area the text occupies.
        let gutter = rect.intersection(NSRect(x: 0, y: rect.minY,
                                              width: ruleThickness, height: rect.height))
        NSColor.textBackgroundColor.setFill()
        gutter.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: ruleThickness - 1, y: gutter.minY, width: 1, height: gutter.height).fill()

        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Count the lines above the visible range once, then walk forward.
        var lineNumber = 1
        if charRange.location > 0 {
            var index = 0
            while index < charRange.location {
                let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
                index = NSMaxRange(lineRange)
                if index <= charRange.location { lineNumber += 1 }
                if lineRange.length == 0 { break }
            }
        }

        let inset = textView.textContainerInset.height
        let originY = convert(NSPoint.zero, from: textView).y
        let currentLine = text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0))

        var index = charRange.location
        while index <= NSMaxRange(charRange), index <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: lineRange.location),
                effectiveRange: nil
            )
            let isCurrent = lineRange.location == currentLine.location
            let label = "\(lineNumber)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + originY + inset + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }
    }
}
