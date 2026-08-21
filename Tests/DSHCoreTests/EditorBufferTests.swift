import XCTest
@testable import DSHCore

/// "See files edit in real time" is this class's job: a buffer must follow the
/// agent's writes silently when it is clean, and never throw away unsaved work
/// when it is not.
@MainActor
final class EditorBufferTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-buf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ text: String, to name: String = "main.swift") throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadsFileAndDetectsLanguage() throws {
        let url = try write("let x = 1\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        XCTAssertEqual(buffer.text, "let x = 1\n")
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(buffer.language.name, "Swift")
        XCTAssertEqual(buffer.name, "main.swift")
    }

    func testEditingMarksDirtyAndSavingClearsIt() throws {
        let url = try write("one\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        buffer.text = "two\n"
        XCTAssertTrue(buffer.isDirty)

        try buffer.save()
        XCTAssertFalse(buffer.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two\n")
    }

    /// The agent rewrites a file the user has open but has not touched: the
    /// editor should just show the new contents.
    func testCleanBufferFollowsExternalWriteSilently() throws {
        let url = try write("before\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        let token = buffer.reloadToken

        try "after\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.externalChangeDetected()

        XCTAssertEqual(buffer.text, "after\n")
        XCTAssertFalse(buffer.diskConflict)
        XCTAssertFalse(buffer.isDirty)
        XCTAssertGreaterThan(buffer.reloadToken, token, "the text view must be told to reload")
    }

    /// Same write, but the user has unsaved edits: their work must survive and
    /// a conflict must be raised instead.
    func testDirtyBufferRaisesConflictInsteadOfLosingWork() throws {
        let url = try write("before\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        buffer.text = "my unsaved edit\n"

        try "the agent's version\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.externalChangeDetected()

        XCTAssertTrue(buffer.diskConflict)
        XCTAssertEqual(buffer.text, "my unsaved edit\n", "unsaved work must not be overwritten")
    }

    func testReloadFromDiskDiscardsLocalEdits() throws {
        let url = try write("before\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        buffer.text = "mine\n"
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.externalChangeDetected()

        buffer.reloadFromDisk()
        XCTAssertEqual(buffer.text, "theirs\n")
        XCTAssertFalse(buffer.diskConflict)
        XCTAssertFalse(buffer.isDirty)
    }

    /// "Keep Mine" clears the warning but leaves the buffer dirty against the
    /// new file, so the next save is still an explicit overwrite.
    func testKeepMineLeavesTheBufferDirty() throws {
        let url = try write("before\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        buffer.text = "mine\n"
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.externalChangeDetected()

        buffer.keepMine()
        XCTAssertFalse(buffer.diskConflict)
        XCTAssertTrue(buffer.isDirty)
        XCTAssertEqual(buffer.text, "mine\n")

        try buffer.save()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")
    }

    /// A write that lands identical to the buffer (the agent reformatted to
    /// what was already there) must not flag a conflict.
    func testIdenticalExternalWriteIsNotAConflict() throws {
        let url = try write("same\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        buffer.text = "same\n"
        try "same\n".write(to: url, atomically: true, encoding: .utf8)
        buffer.externalChangeDetected()

        XCTAssertFalse(buffer.diskConflict)
        XCTAssertFalse(buffer.isDirty)
    }

    func testMissingFileYieldsNoBuffer() {
        XCTAssertNil(EditorBuffer(url: root.appendingPathComponent("nope.txt")))
    }

    func testBinaryFileYieldsNoBuffer() throws {
        let url = root.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01, 0xC0]).write(to: url)
        XCTAssertNil(EditorBuffer(url: url), "invalid UTF-8 must not open as text")
    }

    func testDeletedFileLeavesTheBufferIntact() throws {
        let url = try write("content\n")
        let buffer = try XCTUnwrap(EditorBuffer(url: url))
        try FileManager.default.removeItem(at: url)
        buffer.externalChangeDetected()
        XCTAssertEqual(buffer.text, "content\n", "a delete must not blank the editor")
    }
}

// MARK: - Language detection

final class LanguageTests: XCTestCase {
    private func language(_ name: String) -> Language {
        Language.detect(for: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testDetectsByExtension() {
        XCTAssertEqual(language("a.swift").name, "Swift")
        XCTAssertEqual(language("a.json").name, "JSON")
        XCTAssertEqual(language("a.yml").name, "YAML")
        XCTAssertEqual(language("a.sql").name, "SQL")
        XCTAssertEqual(language("a.sh").name, "Shell")
    }

    func testDetectsExtensionlessConventions() {
        XCTAssertEqual(language("Makefile").name, "Shell")
        XCTAssertEqual(language("Dockerfile").name, "Shell")
    }

    func testUnknownFallsBackToPlain() {
        XCTAssertEqual(language("notes.xyz").name, "Text")
        XCTAssertTrue(language("notes.xyz").keywords.isEmpty)
    }

    func testSwiftVocabularyIsPresent() {
        let swift = Language.swift
        XCTAssertTrue(swift.keywords.contains("guard"))
        XCTAssertTrue(swift.keywords.contains("actor"))
        XCTAssertEqual(swift.lineComment, "//")
        XCTAssertEqual(swift.blockComment?.open, "/*")
    }

    func testJavaScriptGetsItsOwnKeywords() {
        let js = Language.detect(for: URL(fileURLWithPath: "/tmp/a.ts"))
        XCTAssertTrue(js.keywords.contains("interface"))
        XCTAssertTrue(js.keywords.contains("await"))
    }
}
