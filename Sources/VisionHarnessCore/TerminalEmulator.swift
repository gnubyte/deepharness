import Foundation

/// A cell colour: the palette default, one of the 256 indexed colours, or
/// 24-bit truecolor.
public enum TerminalColor: Equatable, Sendable {
    case standard
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellStyle: Equatable, Sendable {
    public var foreground: TerminalColor = .standard
    public var background: TerminalColor = .standard
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public static let normal = CellStyle()
}

public struct TerminalCell: Equatable, Sendable {
    public var character: Character = " "
    public var style: CellStyle = .normal
    /// Set on the cell after a double-width character, which draws nothing.
    public var isContinuation = false

    public static let blank = TerminalCell()
}

/// A VT100/xterm-subset screen.
///
/// It covers what a shell session, a build log, and a TUI-lite program (git
/// log, less, htop) actually emit: cursor motion, erase, insert/delete,
/// scroll regions, SGR colour including 256 and truecolor, the alternate
/// screen, and OSC titles. It is not a full terminal — no sixel, no mouse
/// reporting — and unknown sequences are skipped rather than printed.
public final class TerminalEmulator {
    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var grid: [[TerminalCell]]
    public private(set) var scrollback: [[TerminalCell]] = []

    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    public private(set) var cursorVisible = true
    public private(set) var title = ""

    /// Bumped on every change so the view knows to redraw.
    public private(set) var revision = 0
    /// Bytes the emulator wants to send back (device status reports).
    public var onReply: ((Data) -> Void)?
    /// The shell rang the bell.
    public var onBell: (() -> Void)?

    public var scrollbackLimit = 5_000

    private var style = CellStyle.normal
    private var savedCursor: (row: Int, col: Int, style: CellStyle)?
    private var scrollTop = 0
    private var scrollBottom: Int
    private var autoWrap = true
    /// Set once the cursor has printed in the last column, so the wrap happens
    /// on the *next* character (xterm's deferred-wrap behaviour).
    private var wrapPending = false
    private var usingAlternate = false
    private var savedPrimary: (grid: [[TerminalCell]], cursor: (Int, Int))?

    // Parser state
    private enum ParseState { case ground, escape, csi, osc, charset }
    private var state: ParseState = .ground
    private var parameterBuffer = ""
    private var oscBuffer = ""
    private var utf8Buffer: [UInt8] = []
    private var utf8Needed = 0

    public init(rows: Int = 24, cols: Int = 80) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.scrollBottom = self.rows - 1
        self.grid = Array(repeating: Array(repeating: TerminalCell.blank, count: self.cols), count: self.rows)
    }

    // MARK: - Feeding

    public func feed(_ data: Data) {
        for byte in data { consume(byte) }
        revision &+= 1
    }

    private func consume(_ byte: UInt8) {
        switch state {
        case .ground: ground(byte)
        case .escape: escape(byte)
        case .csi: csi(byte)
        case .osc: osc(byte)
        case .charset:
            state = .ground   // ESC ( X — character set selection, ignored
        }
    }

    // MARK: Ground

    private func ground(_ byte: UInt8) {
        // Mid-way through a multi-byte character?
        if utf8Needed > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Buffer.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 {
                    if let scalar = String(bytes: utf8Buffer, encoding: .utf8)?.first {
                        put(scalar)
                    }
                    utf8Buffer.removeAll(keepingCapacity: true)
                }
                return
            }
            // Invalid continuation: drop what we had and reprocess this byte.
            utf8Buffer.removeAll(keepingCapacity: true)
            utf8Needed = 0
        }

        switch byte {
        case 0x07: onBell?()
        case 0x08: backspace()
        case 0x09: tab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorCol = 0; wrapPending = false
        case 0x0E, 0x0F: break                     // shift out / in
        case 0x1B: state = .escape; parameterBuffer = ""
        case 0x00...0x06, 0x10...0x1A, 0x1C...0x1F: break
        case 0x20...0x7E: put(Character(UnicodeScalar(byte)))
        default:
            // Start of a multi-byte UTF-8 sequence.
            if byte & 0xE0 == 0xC0 { utf8Buffer = [byte]; utf8Needed = 1 }
            else if byte & 0xF0 == 0xE0 { utf8Buffer = [byte]; utf8Needed = 2 }
            else if byte & 0xF8 == 0xF0 { utf8Buffer = [byte]; utf8Needed = 3 }
        }
    }

    private func put(_ character: Character) {
        if wrapPending, autoWrap {
            cursorCol = 0
            lineFeed()
            wrapPending = false
        }
        guard cursorRow >= 0, cursorRow < rows else { return }
        if cursorCol >= cols {
            guard autoWrap else { return }
            cursorCol = 0
            lineFeed()
        }
        let width = character.terminalWidth
        if width == 2, cursorCol == cols - 1 {
            // A wide glyph will not fit: wrap it whole rather than splitting.
            grid[cursorRow][cursorCol] = TerminalCell(character: " ", style: style)
            cursorCol = 0
            lineFeed()
        }
        grid[cursorRow][cursorCol] = TerminalCell(character: character, style: style)
        cursorCol += 1
        if width == 2, cursorCol < cols {
            grid[cursorRow][cursorCol] = TerminalCell(character: " ", style: style, isContinuation: true)
            cursorCol += 1
        }
        if cursorCol >= cols {
            cursorCol = cols - 1
            wrapPending = true
        }
    }

    private func backspace() {
        wrapPending = false
        if cursorCol > 0 { cursorCol -= 1 }
    }

    private func tab() {
        wrapPending = false
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = min(next, cols - 1)
    }

    private func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        for _ in 0..<count {
            let line = grid[scrollTop]
            // Only the primary screen's history is worth keeping; the
            // alternate screen is a scratch surface by definition.
            if !usingAlternate, scrollTop == 0 {
                scrollback.append(line)
                if scrollback.count > scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - scrollbackLimit)
                }
            }
            grid.remove(at: scrollTop)
            grid.insert(Array(repeating: TerminalCell.blank, count: cols), at: scrollBottom)
        }
    }

    private func scrollDown(_ count: Int) {
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: TerminalCell.blank, count: cols), at: scrollTop)
        }
    }

    // MARK: Escape

    private func escape(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "["): state = .csi; parameterBuffer = ""
        case UInt8(ascii: "]"): state = .osc; oscBuffer = ""
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
            state = .charset
        case UInt8(ascii: "7"): savedCursor = (cursorRow, cursorCol, style); state = .ground
        case UInt8(ascii: "8"): restoreCursor(); state = .ground
        case UInt8(ascii: "M"): reverseIndex(); state = .ground
        case UInt8(ascii: "D"): lineFeed(); state = .ground
        case UInt8(ascii: "E"): cursorCol = 0; lineFeed(); state = .ground
        case UInt8(ascii: "c"): reset(); state = .ground
        default: state = .ground
        }
    }

    private func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = min(saved.row, rows - 1)
        cursorCol = min(saved.col, cols - 1)
        style = saved.style
    }

    // MARK: OSC

    private func osc(_ byte: UInt8) {
        // Terminated by BEL, or by ST (ESC \).
        if byte == 0x07 || byte == 0x9C {
            finishOSC()
            return
        }
        if byte == 0x1B { return }          // first half of ST
        if byte == UInt8(ascii: "\\"), oscBuffer.hasSuffix("\u{1B}") {
            finishOSC()
            return
        }
        if oscBuffer.count < 512, let scalar = UnicodeScalar(UInt32(byte)) {
            oscBuffer.append(Character(scalar))
        }
    }

    private func finishOSC() {
        let parts = oscBuffer.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, ["0", "1", "2"].contains(String(parts[0])) {
            title = String(parts[1])
        }
        oscBuffer = ""
        state = .ground
    }

    // MARK: CSI

    private func csi(_ byte: UInt8) {
        // Parameters and intermediates accumulate until a final byte arrives.
        if byte >= 0x30 && byte <= 0x3F || byte == 0x20 || byte == 0x21 {
            if parameterBuffer.count < 64, let scalar = UnicodeScalar(UInt32(byte)) {
                parameterBuffer.append(Character(scalar))
            }
            return
        }
        guard byte >= 0x40 && byte <= 0x7E else {
            state = .ground
            return
        }
        let isPrivate = parameterBuffer.hasPrefix("?")
        let body = isPrivate ? String(parameterBuffer.dropFirst()) : parameterBuffer
        let params = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func param(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < params.count, params[index] > 0 else { return fallback }
            return params[index]
        }

        switch Character(UnicodeScalar(byte)) {
        case "A": cursorRow = max(scrollTop, cursorRow - param(0)); wrapPending = false
        case "B": cursorRow = min(scrollBottom, cursorRow + param(0)); wrapPending = false
        case "C": cursorCol = min(cols - 1, cursorCol + param(0)); wrapPending = false
        case "D": cursorCol = max(0, cursorCol - param(0)); wrapPending = false
        case "E": cursorRow = min(scrollBottom, cursorRow + param(0)); cursorCol = 0
        case "F": cursorRow = max(scrollTop, cursorRow - param(0)); cursorCol = 0
        case "G", "`": cursorCol = clampCol(param(0) - 1); wrapPending = false
        case "d": cursorRow = clampRow(param(0) - 1); wrapPending = false
        case "H", "f":
            cursorRow = clampRow(param(0) - 1)
            cursorCol = clampCol(param(1) - 1)
            wrapPending = false
        case "J": eraseInDisplay(params.first ?? 0)
        case "K": eraseInLine(params.first ?? 0)
        case "L": insertLines(param(0))
        case "M": deleteLines(param(0))
        case "P": deleteCharacters(param(0))
        case "@": insertCharacters(param(0))
        case "X": eraseCharacters(param(0))
        case "S": scrollUp(param(0))
        case "T": scrollDown(param(0))
        case "m": applySGR(params.isEmpty ? [0] : params)
        case "r":
            let top = clampRow(param(0) - 1)
            let bottom = clampRow(params.count > 1 && params[1] > 0 ? params[1] - 1 : rows - 1)
            if top < bottom { scrollTop = top; scrollBottom = bottom }
            cursorRow = scrollTop
            cursorCol = 0
        case "h": setMode(params, enabled: true, isPrivate: isPrivate)
        case "l": setMode(params, enabled: false, isPrivate: isPrivate)
        case "s": savedCursor = (cursorRow, cursorCol, style)
        case "u": restoreCursor()
        case "n":
            if params.first == 6 {
                onReply?(Data("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R".utf8))
            } else if params.first == 5 {
                onReply?(Data("\u{1B}[0n".utf8))
            }
        case "c":
            onReply?(Data("\u{1B}[?1;2c".utf8))   // "I am a VT100 with AVO"
        default:
            break
        }
        state = .ground
        parameterBuffer = ""
    }

    private func clampRow(_ value: Int) -> Int { min(max(0, value), rows - 1) }
    private func clampCol(_ value: Int) -> Int { min(max(0, value), cols - 1) }

    private func setMode(_ params: [Int], enabled: Bool, isPrivate: Bool) {
        guard isPrivate else {
            return   // ANSI modes (IRM etc.) are not used by anything we target
        }
        for mode in params {
            switch mode {
            case 7: autoWrap = enabled
            case 25: cursorVisible = enabled
            case 47, 1047, 1049: setAlternateScreen(enabled, saveCursor: mode == 1049)
            default: break   // mouse reporting, bracketed paste, focus events
            }
        }
    }

    private func setAlternateScreen(_ on: Bool, saveCursor: Bool) {
        guard on != usingAlternate else { return }
        if on {
            if saveCursor { savedCursor = (cursorRow, cursorCol, style) }
            savedPrimary = (grid, (cursorRow, cursorCol))
            grid = Array(repeating: Array(repeating: TerminalCell.blank, count: cols), count: rows)
            cursorRow = 0
            cursorCol = 0
            usingAlternate = true
        } else {
            if let saved = savedPrimary {
                grid = saved.grid
                cursorRow = min(saved.cursor.0, rows - 1)
                cursorCol = min(saved.cursor.1, cols - 1)
            }
            savedPrimary = nil
            usingAlternate = false
            if saveCursor { restoreCursor() }
        }
        style = .normal
    }

    // MARK: Erase / insert / delete

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows {
                grid[row] = Array(repeating: blankCell(), count: cols)
            }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow {
                grid[row] = Array(repeating: blankCell(), count: cols)
            }
        case 2:
            grid = Array(repeating: Array(repeating: blankCell(), count: cols), count: rows)
        case 3:
            scrollback.removeAll()
        default: break
        }
    }

    private func eraseInLine(_ mode: Int) {
        guard cursorRow < rows else { return }
        switch mode {
        case 0: for col in cursorCol..<cols { grid[cursorRow][col] = blankCell() }
        case 1: for col in 0...min(cursorCol, cols - 1) { grid[cursorRow][col] = blankCell() }
        case 2: grid[cursorRow] = Array(repeating: blankCell(), count: cols)
        default: break
        }
    }

    private func eraseCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        for col in cursorCol..<min(cols, cursorCol + count) {
            grid[cursorRow][col] = blankCell()
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: blankCell(), count: cols), at: cursorRow)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<count {
            grid.remove(at: cursorRow)
            grid.insert(Array(repeating: blankCell(), count: cols), at: scrollBottom)
        }
    }

    private func insertCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        for _ in 0..<count {
            grid[cursorRow].insert(blankCell(), at: cursorCol)
            grid[cursorRow].removeLast()
        }
    }

    private func deleteCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        for _ in 0..<count {
            grid[cursorRow].remove(at: cursorCol)
            grid[cursorRow].append(blankCell())
        }
    }

    /// Erased cells keep the current background, which is what makes a
    /// coloured `clear` fill the screen rather than leave stripes.
    private func blankCell() -> TerminalCell {
        var cell = TerminalCell.blank
        cell.style.background = style.background
        return cell
    }

    // MARK: SGR

    private func applySGR(_ params: [Int]) {
        var index = 0
        while index < params.count {
            let code = params[index]
            switch code {
            case 0: style = .normal
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 39: style.foreground = .standard
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 49: style.background = .standard
            case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let (colour, consumed) = Self.extendedColour(params, from: index)
                if let colour {
                    if code == 38 { style.foreground = colour } else { style.background = colour }
                }
                index += consumed
            default: break
            }
            index += 1
        }
    }

    /// `38;5;n` (indexed) and `38;2;r;g;b` (truecolor).
    private static func extendedColour(_ params: [Int], from index: Int) -> (TerminalColor?, Int) {
        guard index + 1 < params.count else { return (nil, 0) }
        switch params[index + 1] {
        case 5:
            guard index + 2 < params.count else { return (nil, 1) }
            return (.indexed(UInt8(clamping: params[index + 2])), 2)
        case 2:
            guard index + 4 < params.count else { return (nil, 1) }
            return (.rgb(UInt8(clamping: params[index + 2]),
                         UInt8(clamping: params[index + 3]),
                         UInt8(clamping: params[index + 4])), 4)
        default:
            return (nil, 1)
        }
    }

    // MARK: - Geometry

    public func resize(rows newRows: Int, cols newCols: Int) {
        let newRows = max(1, newRows)
        let newCols = max(1, newCols)
        guard newRows != rows || newCols != cols else { return }

        var resized = grid.map { row -> [TerminalCell] in
            var row = row
            if row.count > newCols { row = Array(row.prefix(newCols)) }
            if row.count < newCols { row += Array(repeating: TerminalCell.blank, count: newCols - row.count) }
            return row
        }
        if resized.count > newRows {
            // Growing narrower or shorter pushes the top into scrollback so
            // output above the fold is not simply lost.
            let dropped = resized.count - newRows
            if !usingAlternate { scrollback.append(contentsOf: resized.prefix(dropped)) }
            resized.removeFirst(dropped)
            cursorRow = max(0, cursorRow - dropped)
        }
        if resized.count < newRows {
            resized += Array(repeating: Array(repeating: TerminalCell.blank, count: newCols),
                             count: newRows - resized.count)
        }
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }

        grid = resized
        rows = newRows
        cols = newCols
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = min(cursorRow, newRows - 1)
        cursorCol = min(cursorCol, newCols - 1)
        revision &+= 1
    }

    public func reset() {
        grid = Array(repeating: Array(repeating: TerminalCell.blank, count: cols), count: rows)
        scrollback.removeAll()
        cursorRow = 0
        cursorCol = 0
        style = .normal
        scrollTop = 0
        scrollBottom = rows - 1
        usingAlternate = false
        savedPrimary = nil
        cursorVisible = true
        autoWrap = true
        wrapPending = false
        revision &+= 1
    }

    /// Every line, history first — what the view draws and what "copy all"
    /// puts on the pasteboard.
    public var allLines: [[TerminalCell]] { scrollback + grid }

    public func plainText(_ line: [TerminalCell]) -> String {
        var text = ""
        for cell in line where !cell.isContinuation {
            text.append(cell.character)
        }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }
}

extension Character {
    /// Columns this glyph occupies. Emoji and CJK take two.
    public var terminalWidth: Int {
        guard let scalar = unicodeScalars.first else { return 1 }
        if unicodeScalars.count > 1, unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
            return 2
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
