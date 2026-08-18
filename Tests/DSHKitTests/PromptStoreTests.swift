import XCTest
@testable import DSHKit

final class PromptStoreTests: XCTestCase {
    private var directory: URL!
    private var store: PromptStore!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-prompt-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PromptStore(url: directory.appendingPathComponent("prompts.db"))
    }

    override func tearDown() async throws {
        await store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordsAndReadsBackPerSession() async throws {
        try await store.record(sessionId: "s1", sessionTitle: "One", cwd: "/p", text: "first", attachmentCount: 0, mode: "queue")
        try await store.record(sessionId: "s1", sessionTitle: "One", cwd: "/p", text: "second", attachmentCount: 2, mode: "steer")
        try await store.record(sessionId: "s2", sessionTitle: "Two", cwd: "/q", text: "elsewhere", attachmentCount: 0, mode: "queue")

        let s1 = try await store.prompts(sessionId: "s1")
        let total = try await store.count()
        XCTAssertEqual(s1.count, 2)
        XCTAssertEqual(Set(s1.map(\.text)), ["first", "second"])
        XCTAssertEqual(total, 3)

        let steered = s1.first { $0.isSteer }
        XCTAssertEqual(steered?.text, "second")
        XCTAssertEqual(steered?.attachmentCount, 2)
    }

    func testNewestFirstOrdering() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.record(sessionId: "s", sessionTitle: nil, cwd: nil, text: "older", attachmentCount: 0, mode: "queue", at: base)
        try await store.record(sessionId: "s", sessionTitle: nil, cwd: nil, text: "newer", attachmentCount: 0, mode: "queue", at: base.addingTimeInterval(60))

        let rows = try await store.prompts(sessionId: "s")
        XCTAssertEqual(rows.map(\.text), ["newer", "older"])
    }

    func testSearchAcrossSessions() async throws {
        try await store.record(sessionId: "a", sessionTitle: nil, cwd: nil, text: "refactor the parser", attachmentCount: 0, mode: "queue")
        try await store.record(sessionId: "b", sessionTitle: nil, cwd: nil, text: "write the README", attachmentCount: 0, mode: "queue")

        let hits = try await store.search("parser")
        let misses = try await store.search("nothing here")
        XCTAssertEqual(hits.map(\.text), ["refactor the parser"])
        XCTAssertTrue(misses.isEmpty)
    }

    /// LIKE wildcards in the query must match literally, not as patterns.
    func testSearchEscapesWildcards() async throws {
        try await store.record(sessionId: "a", sessionTitle: nil, cwd: nil, text: "literal % percent", attachmentCount: 0, mode: "queue")
        try await store.record(sessionId: "a", sessionTitle: nil, cwd: nil, text: "no wildcard here", attachmentCount: 0, mode: "queue")

        let percent = try await store.search("%")
        let underscore = try await store.search("_")
        XCTAssertEqual(percent.count, 1, "a bare % must not match every row")
        XCTAssertEqual(underscore.count, 0, "_ must not match any single character")
    }

    func testTitleBackfill() async throws {
        try await store.record(sessionId: "s", sessionTitle: nil, cwd: nil, text: "hi", attachmentCount: 0, mode: "queue")
        try await store.updateTitle(sessionId: "s", title: "Named Later")
        let rows = try await store.prompts(sessionId: "s")
        XCTAssertEqual(rows.first?.sessionTitle, "Named Later")
    }

    func testDeleteSessionLeavesOthers() async throws {
        try await store.record(sessionId: "a", sessionTitle: nil, cwd: nil, text: "keep", attachmentCount: 0, mode: "queue")
        try await store.record(sessionId: "b", sessionTitle: nil, cwd: nil, text: "drop", attachmentCount: 0, mode: "queue")
        try await store.deleteSession("b")
        let remaining = try await store.count()
        let recent = try await store.recent()
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(recent.first?.text, "keep")
    }

    /// The whole point of a local store: it outlives the process that wrote it.
    func testDataSurvivesReopen() async throws {
        let path = directory.appendingPathComponent("persist.db")
        let first = try PromptStore(url: path)
        try await first.record(sessionId: "s", sessionTitle: nil, cwd: nil, text: "durable", attachmentCount: 0, mode: "queue")
        await first.close()

        let second = try PromptStore(url: path)
        let reread = try await second.prompts(sessionId: "s")
        XCTAssertEqual(reread.map(\.text), ["durable"])
        await second.close()
    }
}
