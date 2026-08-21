import SwiftUI
import AppKit
import DSHCore

/// One integrated-terminal tab: a shell on a pty, plus the screen it draws to.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID().uuidString
    let cwd: URL
    var title: String
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?

    @ObservationIgnored let emulator = TerminalEmulator()
    @ObservationIgnored private let pty = PTY()
    /// The view sets this to learn about new output without SwiftUI diffing
    /// a 24×80 grid on every keystroke.
    @ObservationIgnored var onUpdate: (() -> Void)?

    private var started = false

    init(cwd: URL, title: String? = nil) {
        self.cwd = cwd
        self.title = title ?? cwd.lastPathComponent
        emulator.onReply = { [weak self] data in
            Task { @MainActor in self?.pty.write(data) }
        }
        emulator.onBell = { NSSound.beep() }
    }

    /// Launch the shell. Safe to call repeatedly; only the first one runs.
    func start(cols: Int, rows: Int, shell: String? = nil) {
        guard !started else { return }
        started = true
        emulator.resize(rows: rows, cols: cols)

        pty.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.emulator.feed(data)
                if !self.emulator.title.isEmpty { self.title = self.emulator.title }
                self.onUpdate?()
            }
        }
        pty.onExit = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.exitStatus = status
                self.emulator.feed(Data("\r\n[process exited with status \(status)]\r\n".utf8))
                self.onUpdate?()
            }
        }

        let launched = pty.start(shell: shell ?? PTY.defaultShell,
                                 arguments: ["-l"],
                                 cwd: cwd,
                                 cols: UInt16(cols), rows: UInt16(rows))
        isRunning = launched
        if !launched {
            emulator.feed(Data("Could not start a shell.\r\n".utf8))
            onUpdate?()
        }
    }

    func send(_ data: Data) { pty.write(data) }
    func send(_ text: String) { pty.write(text) }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != emulator.cols || rows != emulator.rows else { return }
        emulator.resize(rows: rows, cols: cols)
        pty.resize(cols: UInt16(cols), rows: UInt16(rows))
        onUpdate?()
    }

    func clear() {
        emulator.reset()
        send("\u{0C}")   // ^L so the shell redraws its prompt
        onUpdate?()
    }

    func terminate() {
        pty.terminate()
        isRunning = false
    }

    /// Everything on screen and in history, as text.
    var transcript: String {
        emulator.allLines.map { emulator.plainText($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - SwiftUI wrapper

struct TerminalScreen: NSViewRepresentable {
    let session: TerminalSession
    var fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let view = TerminalNSView(session: session, fontSize: fontSize)
        scrollView.documentView = view
        view.scrollView = scrollView
        session.onUpdate = { [weak view] in view?.contentChanged() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let view = scrollView.documentView as? TerminalNSView else { return }
        view.updateFontSize(fontSize)
    }

    /// Same reason as the editor: the document grows with scrollback, and the
    /// panel must not grow with it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 200)
    }
}

/// Draws the emulator's grid and turns key presses into pty bytes.
final class TerminalNSView: NSView {
    private let session: TerminalSession
    weak var scrollView: NSScrollView?

    private var font: NSFont
    private var cellSize: NSSize = .zero
    private var lastRevision = -1
    /// Stops the auto-scroll when the user has deliberately scrolled back.
    private var pinnedToBottom = true
    /// Selection, as (line, column) into `allLines`.
    private var selectionAnchor: (line: Int, column: Int)?
    private var selectionHead: (line: Int, column: Int)?
    private var redrawScheduled = false

    init(session: TerminalSession, fontSize: Double) {
        self.session = session
        self.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: .zero)
        measureCell()
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    func updateFontSize(_ size: Double) {
        guard abs(font.pointSize - size) > 0.1 else { return }
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        measureCell()
        reflow()
        needsDisplay = true
    }

    private func measureCell() {
        let sample = "M" as NSString
        let bounding = sample.size(withAttributes: [.font: font])
        // Advance width from the font itself, so every cell lines up exactly.
        let advance = font.advancement(forGlyph: font.glyph(withName: "M")).width
        cellSize = NSSize(width: max(advance, bounding.width).rounded(.up),
                          height: (font.ascender - font.descender + font.leading).rounded(.up) + 1)
    }

    // MARK: Layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reflow()
        startShellIfNeeded()
        window?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reflow()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        reflow()
    }

    private func startShellIfNeeded() {
        guard let scrollView else { return }
        let (cols, rows) = gridSize(in: scrollView.contentSize)
        session.start(cols: cols, rows: rows)
        contentChanged()
    }

    private func gridSize(in size: NSSize) -> (cols: Int, rows: Int) {
        guard cellSize.width > 0, cellSize.height > 0 else { return (80, 24) }
        let cols = max(20, Int((size.width - 12) / cellSize.width))
        let rows = max(4, Int(size.height / cellSize.height))
        return (cols, rows)
    }

    /// Match the emulator's geometry to the view, then resize the document to
    /// fit history plus screen.
    private func reflow() {
        guard let scrollView else { return }
        let (cols, rows) = gridSize(in: scrollView.contentSize)
        session.resize(cols: cols, rows: rows)
        resizeDocument()
    }

    private func resizeDocument() {
        guard let scrollView else { return }
        let lines = session.emulator.allLines.count
        let height = max(scrollView.contentSize.height, CGFloat(lines) * cellSize.height + 6)
        let width = scrollView.contentSize.width
        if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    /// Called from the session when new output lands. Redraws are coalesced to
    /// one per runloop turn so a `cat` of a large file does not melt the CPU.
    func contentChanged() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.resizeDocument()
            if self.pinnedToBottom { self.scrollToBottom() }
            self.needsDisplay = true
        }
    }

    private func scrollToBottom() {
        guard let scrollView else { return }
        let maxY = max(0, frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func scrolled(_ notification: Notification) {
        guard let scrollView,
              (notification.object as? NSClipView) === scrollView.contentView else { return }
        let maxY = max(0, frame.height - scrollView.contentSize.height)
        pinnedToBottom = scrollView.contentView.bounds.origin.y >= maxY - cellSize.height
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let lines = session.emulator.allLines
        guard !lines.isEmpty, cellSize.height > 0 else { return }

        let firstLine = max(0, Int(dirtyRect.minY / cellSize.height))
        let lastLine = min(lines.count - 1, Int(dirtyRect.maxY / cellSize.height) + 1)
        guard firstLine <= lastLine else { return }

        let defaultForeground = NSColor.textColor
        let defaultBackground = NSColor.textBackgroundColor
        let selection = normalizedSelection()

        for lineIndex in firstLine...lastLine {
            let row = lines[lineIndex]
            let y = CGFloat(lineIndex) * cellSize.height

            // Runs of identical style draw as one string — far fewer draw
            // calls than one per cell.
            var column = 0
            while column < row.count {
                let cell = row[column]
                if cell.isContinuation { column += 1; continue }
                var end = column + 1
                while end < row.count,
                      !row[end].isContinuation,
                      row[end].style == cell.style,
                      isSelected(line: lineIndex, column: end, selection) == isSelected(line: lineIndex, column: column, selection) {
                    end += 1
                }
                let text = String(row[column..<end].filter { !$0.isContinuation }.map(\.character))
                let selected = isSelected(line: lineIndex, column: column, selection)
                draw(text: text, at: NSPoint(x: 6 + CGFloat(column) * cellSize.width, y: y),
                     style: cell.style, selected: selected,
                     defaultForeground: defaultForeground, defaultBackground: defaultBackground,
                     width: CGFloat(end - column) * cellSize.width)
                column = end
            }
        }

        drawCursor(lineOffset: session.emulator.scrollback.count)
    }

    private func draw(text: String, at origin: NSPoint, style: CellStyle, selected: Bool,
                      defaultForeground: NSColor, defaultBackground: NSColor, width: CGFloat) {
        var foreground = TerminalPalette.resolve(style.foreground, fallback: defaultForeground)
        var background = TerminalPalette.resolve(style.background, fallback: defaultBackground)
        if style.inverse { swap(&foreground, &background) }
        if style.dim { foreground = foreground.withAlphaComponent(0.6) }
        if selected {
            background = NSColor.selectedTextBackgroundColor
            foreground = NSColor.selectedTextColor
        }

        if background != defaultBackground {
            background.setFill()
            NSRect(x: origin.x, y: origin.y, width: width, height: cellSize.height).fill()
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || style.underline || style.strikethrough else {
            return
        }

        var drawFont = font
        if style.bold {
            drawFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if style.italic {
            drawFont = NSFontManager.shared.convert(drawFont, toHaveTrait: .italicFontMask)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: drawFont,
            .foregroundColor: foreground,
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        (text as NSString).draw(at: NSPoint(x: origin.x, y: origin.y), withAttributes: attributes)
    }

    private func drawCursor(lineOffset: Int) {
        guard session.emulator.cursorVisible, session.isRunning,
              window?.firstResponder === self else { return }
        let line = lineOffset + session.emulator.cursorRow
        let rect = NSRect(x: 6 + CGFloat(session.emulator.cursorCol) * cellSize.width,
                          y: CGFloat(line) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        NSColor.textColor.withAlphaComponent(0.65).setFill()
        rect.fill(using: .difference)
    }

    // MARK: Selection

    private func position(at point: NSPoint) -> (line: Int, column: Int) {
        let line = max(0, Int(point.y / cellSize.height))
        let column = max(0, Int((point.x - 6) / cellSize.width + 0.5))
        return (line, column)
    }

    private func normalizedSelection() -> (start: (line: Int, column: Int), end: (line: Int, column: Int))? {
        guard let anchor = selectionAnchor, let head = selectionHead else { return nil }
        if anchor.line < head.line || (anchor.line == head.line && anchor.column <= head.column) {
            return (anchor, head)
        }
        return (head, anchor)
    }

    private func isSelected(line: Int, column: Int,
                            _ selection: (start: (line: Int, column: Int), end: (line: Int, column: Int))?) -> Bool {
        guard let selection else { return false }
        if line < selection.start.line || line > selection.end.line { return false }
        if line == selection.start.line, column < selection.start.column { return false }
        if line == selection.end.line, column >= selection.end.column { return false }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        selectionAnchor = position(at: point)
        selectionHead = selectionAnchor
        if event.clickCount == 2 { selectWord(at: selectionAnchor!) }
        if event.clickCount >= 3 { selectLine(at: selectionAnchor!) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectionHead = position(at: point)
        autoscroll(with: event)
        needsDisplay = true
    }

    private func selectWord(at position: (line: Int, column: Int)) {
        let lines = session.emulator.allLines
        guard position.line < lines.count else { return }
        let row = lines[position.line]
        guard position.column < row.count else { return }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || "._-/~".contains($0) }
        guard isWord(row[position.column].character) else { return }
        var start = position.column
        var end = position.column
        while start > 0, isWord(row[start - 1].character) { start -= 1 }
        while end < row.count, isWord(row[end].character) { end += 1 }
        selectionAnchor = (position.line, start)
        selectionHead = (position.line, end)
    }

    private func selectLine(at position: (line: Int, column: Int)) {
        let lines = session.emulator.allLines
        guard position.line < lines.count else { return }
        selectionAnchor = (position.line, 0)
        selectionHead = (position.line, lines[position.line].count)
    }

    var selectedText: String? {
        guard let selection = normalizedSelection() else { return nil }
        let lines = session.emulator.allLines
        var parts: [String] = []
        for lineIndex in selection.start.line...selection.end.line where lineIndex < lines.count {
            let row = lines[lineIndex]
            let from = lineIndex == selection.start.line ? selection.start.column : 0
            let to = lineIndex == selection.end.line ? selection.end.column : row.count
            guard from < to, from < row.count else { parts.append(""); continue }
            let slice = row[from..<min(to, row.count)]
            var text = String(slice.filter { !$0.isContinuation }.map(\.character))
            while text.hasSuffix(" ") { text.removeLast() }
            parts.append(text)
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session.send(text)
    }

    override func selectAll(_ sender: Any?) {
        let lines = session.emulator.allLines
        guard let last = lines.last else { return }
        selectionAnchor = (0, 0)
        selectionHead = (lines.count - 1, last.count)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Let ⌘-shortcuts (copy, paste, close tab) reach the responder chain.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        guard let bytes = Self.encode(event) else { return }
        selectionAnchor = nil
        selectionHead = nil
        pinnedToBottom = true
        session.send(bytes)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch event.charactersIgnoringModifiers {
        case "c" where selectedText != nil: copy(nil); return true
        case "v": paste(nil); return true
        case "a": selectAll(nil); return true
        case "k": session.clear(); return true
        default: return false
        }
    }

    /// Map a key event to the bytes a terminal would send.
    static func encode(_ event: NSEvent) -> Data? {
        let flags = event.modifierFlags

        // Normal (not application) cursor keys: we never send DECCKM, so the
        // shell always gets the CSI forms.
        if let special = event.specialKey {
            switch special {
            case .upArrow: return Data("\u{1B}[A".utf8)
            case .downArrow: return Data("\u{1B}[B".utf8)
            case .rightArrow: return Data("\u{1B}[C".utf8)
            case .leftArrow: return Data("\u{1B}[D".utf8)
            case .home: return Data("\u{1B}[H".utf8)
            case .end: return Data("\u{1B}[F".utf8)
            case .pageUp: return Data("\u{1B}[5~".utf8)
            case .pageDown: return Data("\u{1B}[6~".utf8)
            case .delete: return Data([0x7F])           // Backspace
            case .deleteForward: return Data("\u{1B}[3~".utf8)
            case .carriageReturn, .enter: return Data([0x0D])
            case .tab: return Data([0x09])
            case .backTab: return Data("\u{1B}[Z".utf8)
            case .f1: return Data("\u{1B}OP".utf8)
            case .f2: return Data("\u{1B}OQ".utf8)
            case .f3: return Data("\u{1B}OR".utf8)
            case .f4: return Data("\u{1B}OS".utf8)
            case .f5: return Data("\u{1B}[15~".utf8)
            case .f6: return Data("\u{1B}[17~".utf8)
            case .f7: return Data("\u{1B}[18~".utf8)
            case .f8: return Data("\u{1B}[19~".utf8)
            case .f9: return Data("\u{1B}[20~".utf8)
            case .f10: return Data("\u{1B}[21~".utf8)
            case .f11: return Data("\u{1B}[23~".utf8)
            case .f12: return Data("\u{1B}[24~".utf8)
            default: break
            }
        }
        if event.keyCode == 53 { return Data([0x1B]) }   // Escape

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }

        if flags.contains(.control) {
            guard let scalar = characters.unicodeScalars.first else { return nil }
            let value = scalar.value
            // ^A…^Z, plus the punctuation controls.
            if value >= 97 && value <= 122 { return Data([UInt8(value - 96)]) }
            if value >= 65 && value <= 90 { return Data([UInt8(value - 64)]) }
            switch scalar {
            case "@", " ": return Data([0x00])
            case "[": return Data([0x1B])
            case "\\": return Data([0x1C])
            case "]": return Data([0x1D])
            case "^": return Data([0x1E])
            case "_", "/": return Data([0x1F])
            case "?": return Data([0x7F])
            default: return nil
            }
        }

        // Option sends the ESC-prefixed form, which is what shells expect for
        // word motion (⌥←/⌥→ arrive as specialKey above).
        if flags.contains(.option), let typed = event.characters, !typed.isEmpty {
            return Data("\u{1B}\(characters)".utf8)
        }
        guard let typed = event.characters, !typed.isEmpty else { return nil }
        return Data(typed.utf8)
    }
}
