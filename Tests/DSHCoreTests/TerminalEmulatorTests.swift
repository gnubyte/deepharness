import XCTest
@testable import DSHCore

/// The emulator is the piece with the most state, so it gets the most tests.
final class TerminalEmulatorTests: XCTestCase {

    private func makeEmulator(rows: Int = 6, cols: Int = 20) -> TerminalEmulator {
        TerminalEmulator(rows: rows, cols: cols)
    }

    private func line(_ emulator: TerminalEmulator, _ index: Int) -> String {
        emulator.plainText(emulator.grid[index])
    }

    private func feed(_ emulator: TerminalEmulator, _ text: String) {
        emulator.feed(Data(text.utf8))
    }

    // MARK: Printing

    func testPrintsPlainText() {
        let emulator = makeEmulator()
        feed(emulator, "hello")
        XCTAssertEqual(line(emulator, 0), "hello")
        XCTAssertEqual(emulator.cursorCol, 5)
    }

    func testCarriageReturnAndLineFeed() {
        let emulator = makeEmulator()
        feed(emulator, "one\r\ntwo")
        XCTAssertEqual(line(emulator, 0), "one")
        XCTAssertEqual(line(emulator, 1), "two")
        XCTAssertEqual(emulator.cursorRow, 1)
    }

    func testCarriageReturnOverwritesInPlace() {
        let emulator = makeEmulator()
        feed(emulator, "abcdef\rXY")
        XCTAssertEqual(line(emulator, 0), "XYcdef")
    }

    func testBackspaceMovesWithoutErasing() {
        let emulator = makeEmulator()
        feed(emulator, "abc\u{08}\u{08}Z")
        XCTAssertEqual(line(emulator, 0), "aZc")
    }

    func testWrapsAtRightMargin() {
        let emulator = makeEmulator(rows: 4, cols: 5)
        feed(emulator, "abcdefgh")
        XCTAssertEqual(line(emulator, 0), "abcde")
        XCTAssertEqual(line(emulator, 1), "fgh")
    }

    /// xterm defers the wrap until the *next* character, so a line that ends
    /// exactly at the margin must not eat a blank row.
    func testDeferredWrapDoesNotInsertBlankLine() {
        let emulator = makeEmulator(rows: 4, cols: 5)
        feed(emulator, "abcde\r\nxy")
        XCTAssertEqual(line(emulator, 0), "abcde")
        XCTAssertEqual(line(emulator, 1), "xy")
    }

    func testTabStops() {
        let emulator = makeEmulator(rows: 2, cols: 30)
        feed(emulator, "a\tb\tc")
        XCTAssertEqual(line(emulator, 0), "a       b       c")
    }

    func testUTF8AcrossChunkBoundary() {
        let emulator = makeEmulator()
        let bytes = Array("héllo".utf8)
        // Split mid-character: 'é' is two bytes.
        emulator.feed(Data(bytes[0..<2]))
        emulator.feed(Data(bytes[2...]))
        XCTAssertEqual(line(emulator, 0), "héllo")
    }

    // MARK: Cursor motion

    func testCursorPositionAbsolute() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[3;5Hx")
        XCTAssertEqual(emulator.cursorRow, 2)
        XCTAssertEqual(line(emulator, 2), "    x")
    }

    func testCursorRelativeMoves() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[2B\u{1B}[3Cx")
        XCTAssertEqual(emulator.cursorRow, 2)
        XCTAssertEqual(line(emulator, 2), "   x")
    }

    func testCursorMovesClampToScreen() {
        let emulator = makeEmulator(rows: 4, cols: 10)
        feed(emulator, "\u{1B}[99B\u{1B}[99C")
        XCTAssertEqual(emulator.cursorRow, 3)
        XCTAssertEqual(emulator.cursorCol, 9)
    }

    func testSaveAndRestoreCursor() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[2;3H\u{1B}7\u{1B}[5;9H\u{1B}8x")
        XCTAssertEqual(emulator.cursorRow, 1)
        XCTAssertEqual(line(emulator, 1), "  x")
    }

    // MARK: Erase

    func testEraseToEndOfLine() {
        let emulator = makeEmulator()
        feed(emulator, "abcdef\u{1B}[3G\u{1B}[K")
        XCTAssertEqual(line(emulator, 0), "ab")
    }

    func testEraseWholeDisplay() {
        let emulator = makeEmulator()
        feed(emulator, "one\r\ntwo\u{1B}[2J")
        XCTAssertEqual(line(emulator, 0), "")
        XCTAssertEqual(line(emulator, 1), "")
    }

    func testEraseBelowLeavesEarlierLines() {
        let emulator = makeEmulator()
        feed(emulator, "one\r\ntwo\r\nthree\u{1B}[2;1H\u{1B}[J")
        XCTAssertEqual(line(emulator, 0), "one")
        XCTAssertEqual(line(emulator, 1), "")
        XCTAssertEqual(line(emulator, 2), "")
    }

    func testDeleteAndInsertCharacters() {
        let emulator = makeEmulator()
        feed(emulator, "abcdef\u{1B}[1G\u{1B}[2P")
        XCTAssertEqual(line(emulator, 0), "cdef")
        feed(emulator, "\u{1B}[1G\u{1B}[2@")
        XCTAssertEqual(line(emulator, 0), "  cdef")
    }

    func testInsertAndDeleteLines() {
        let emulator = makeEmulator(rows: 4, cols: 10)
        feed(emulator, "a\r\nb\r\nc\u{1B}[1;1H\u{1B}[L")
        XCTAssertEqual(line(emulator, 0), "")
        XCTAssertEqual(line(emulator, 1), "a")
        feed(emulator, "\u{1B}[1;1H\u{1B}[M")
        XCTAssertEqual(line(emulator, 0), "a")
    }

    // MARK: Scrolling

    func testScrollPushesIntoScrollback() {
        let emulator = makeEmulator(rows: 3, cols: 10)
        feed(emulator, "1\r\n2\r\n3\r\n4")
        XCTAssertEqual(emulator.scrollback.count, 1)
        XCTAssertEqual(emulator.plainText(emulator.scrollback[0]), "1")
        XCTAssertEqual(line(emulator, 2), "4")
    }

    func testScrollRegionKeepsOutsideLines() {
        let emulator = makeEmulator(rows: 5, cols: 10)
        feed(emulator, "top\r\na\r\nb\r\nc\r\nbottom")
        // Confine scrolling to rows 2–4, then force a scroll inside it.
        feed(emulator, "\u{1B}[2;4r\u{1B}[4;1H\r\nnew")
        XCTAssertEqual(line(emulator, 0), "top")
        XCTAssertEqual(line(emulator, 4), "bottom")
        XCTAssertEqual(line(emulator, 3), "new")
    }

    func testReverseIndexScrollsDown() {
        let emulator = makeEmulator(rows: 3, cols: 10)
        feed(emulator, "a\r\nb\u{1B}[1;1H\u{1B}M")
        XCTAssertEqual(line(emulator, 0), "")
        XCTAssertEqual(line(emulator, 1), "a")
    }

    func testScrollbackIsCapped() {
        let emulator = makeEmulator(rows: 2, cols: 10)
        emulator.scrollbackLimit = 5
        for index in 0..<40 { feed(emulator, "\(index)\r\n") }
        XCTAssertLessThanOrEqual(emulator.scrollback.count, 5)
    }

    // MARK: SGR

    func testBasicColourAndReset() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[31mred\u{1B}[0mplain")
        XCTAssertEqual(emulator.grid[0][0].style.foreground, .indexed(1))
        XCTAssertEqual(emulator.grid[0][3].style.foreground, .standard)
    }

    func testBrightColoursAndBackground() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[92;44mx")
        XCTAssertEqual(emulator.grid[0][0].style.foreground, .indexed(10))
        XCTAssertEqual(emulator.grid[0][0].style.background, .indexed(4))
    }

    func test256ColourAndTruecolor() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[38;5;123mA\u{1B}[38;2;10;20;30mB")
        XCTAssertEqual(emulator.grid[0][0].style.foreground, .indexed(123))
        XCTAssertEqual(emulator.grid[0][1].style.foreground, .rgb(10, 20, 30))
    }

    func testAttributesToggleIndependently() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[1;4mA\u{1B}[24mB")
        XCTAssertTrue(emulator.grid[0][0].style.bold)
        XCTAssertTrue(emulator.grid[0][0].style.underline)
        XCTAssertTrue(emulator.grid[0][1].style.bold)
        XCTAssertFalse(emulator.grid[0][1].style.underline)
    }

    // MARK: Modes

    func testAlternateScreenRoundTrips() {
        let emulator = makeEmulator()
        feed(emulator, "primary")
        feed(emulator, "\u{1B}[?1049h")
        XCTAssertEqual(line(emulator, 0), "")
        feed(emulator, "alt")
        XCTAssertEqual(line(emulator, 0), "alt")
        feed(emulator, "\u{1B}[?1049l")
        XCTAssertEqual(line(emulator, 0), "primary")
    }

    func testAlternateScreenDoesNotPolluteScrollback() {
        let emulator = makeEmulator(rows: 2, cols: 10)
        feed(emulator, "\u{1B}[?1049h")
        for index in 0..<10 { feed(emulator, "\(index)\r\n") }
        XCTAssertTrue(emulator.scrollback.isEmpty)
    }

    func testCursorVisibilityMode() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}[?25l")
        XCTAssertFalse(emulator.cursorVisible)
        feed(emulator, "\u{1B}[?25h")
        XCTAssertTrue(emulator.cursorVisible)
    }

    // MARK: OSC and replies

    func testOSCTitleWithBEL() {
        let emulator = makeEmulator()
        feed(emulator, "\u{1B}]0;my title\u{07}rest")
        XCTAssertEqual(emulator.title, "my title")
        XCTAssertEqual(line(emulator, 0), "rest")
    }

    func testDeviceStatusReportAnswersCursorPosition() {
        let emulator = makeEmulator()
        var replies: [String] = []
        emulator.onReply = { replies.append(String(decoding: $0, as: UTF8.self)) }
        feed(emulator, "\u{1B}[3;7H\u{1B}[6n")
        XCTAssertEqual(replies, ["\u{1B}[3;7R"])
    }

    func testUnknownSequenceIsSwallowedNotPrinted() {
        let emulator = makeEmulator()
        feed(emulator, "a\u{1B}[?2004hb")
        XCTAssertEqual(line(emulator, 0), "ab")
    }

    // MARK: Resize

    func testResizeKeepsContentAndClampsCursor() {
        let emulator = makeEmulator(rows: 4, cols: 20)
        feed(emulator, "hello\r\nworld")
        emulator.resize(rows: 2, cols: 10)
        XCTAssertEqual(emulator.rows, 2)
        XCTAssertEqual(emulator.cols, 10)
        XCTAssertLessThan(emulator.cursorRow, 2)
        XCTAssertTrue(emulator.allLines.contains { emulator.plainText($0) == "hello" })
    }

    func testResizeToWiderPadsRows() {
        let emulator = makeEmulator(rows: 2, cols: 5)
        feed(emulator, "abc")
        emulator.resize(rows: 3, cols: 12)
        XCTAssertEqual(emulator.grid[0].count, 12)
        XCTAssertEqual(line(emulator, 0), "abc")
    }

    // MARK: Wide characters

    func testWideCharacterOccupiesTwoCells() {
        let emulator = makeEmulator(rows: 2, cols: 10)
        feed(emulator, "漢字")
        XCTAssertEqual(emulator.cursorCol, 4)
        XCTAssertTrue(emulator.grid[0][1].isContinuation)
        XCTAssertEqual(line(emulator, 0), "漢字")
    }
}
