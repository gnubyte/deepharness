import XCTest
@testable import DSHCore

final class QueueLogTests: XCTestCase {
    private func makeTask() -> QueueTask {
        var t = QueueTask(title: "Fix the login crash", details: "repro then patch", status: .complete)
        t.startedAt = .now
        t.rounds = 3
        t.promptTokens = 40_000
        t.completionTokens = 6_000
        t.finishedAt = .now
        t.appendLog(.complete, "Complete after 3 rounds, 42s · 1142 tokens/s avg.")
        return t
    }

    func testReportIsReadableAndComplete() {
        var q = TaskQueue()
        _ = q.add("B")
        let a = makeTask()
        q.appendTask(a)

        let text = QueueLog.report(q)
        XCTAssertTrue(text.contains("Fix the login crash"), text)
        XCTAssertTrue(text.contains("queued"), text)
        XCTAssertTrue(text.contains("3 rounds"), text)
        XCTAssertTrue(text.contains("tokens/s avg"), text)
        XCTAssertTrue(text.contains("46,000 tokens"), text)
        // header stats line
        XCTAssertTrue(text.contains("2 tasks — 1 complete, 1 queued"), text)
        // emoji marks
        XCTAssertTrue(text.contains("✅"), text)
        XCTAssertTrue(text.contains("•"), text)
    }

    func testRunningTaskShowsElapsed() {
        var q = TaskQueue()
        let t = q.add("Live")
        q.start(t.id)
        let text = QueueLog.report(q)
        XCTAssertTrue(text.contains("▶️"), text)
        XCTAssertTrue(text.contains("running"), text)
    }

    func testEmptyReport() {
        XCTAssertTrue(QueueLog.report(TaskQueue()).contains("empty"))
    }

    func testWhenRelativeBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(QueueLog.when(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(QueueLog.when(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(QueueLog.when(now.addingTimeInterval(-3600), now: now), "1h ago")
        XCTAssertEqual(QueueLog.when(now.addingTimeInterval(-90_000), now: now), "yesterday")
        XCTAssertEqual(QueueLog.when(now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        let old = QueueLog.when(now.addingTimeInterval(-30 * 86_400), now: now)
        XCTAssertFalse(old.contains("ago"), old) // falls back to an absolute stamp
    }

    func testStatusMarks() {
        XCTAssertEqual(QueueLog.statusMark(.complete), "✅")
        XCTAssertEqual(QueueLog.statusMark(.running), "▶️")
        XCTAssertEqual(QueueLog.statusMark(.blocked), "⏸")
        XCTAssertEqual(QueueLog.statusMark(.failed), "✖")
        XCTAssertEqual(QueueLog.statusMark(.skipped), "↦")
    }
}
