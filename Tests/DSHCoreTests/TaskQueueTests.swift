import XCTest
@testable import DSHCore

final class TaskQueueTests: XCTestCase {
    func testAddOrderingAndPositions() {
        var q = TaskQueue()
        let a = q.add("A")
        _ = q.add("B")
        let c = q.add("C")
        let front = q.add("D", atFront: true)

        XCTAssertEqual(q.tasks.map(\.title), ["D", "A", "B", "C"])
        XCTAssertEqual(q.position(of: front.id), 1)
        XCTAssertEqual(q.position(of: a.id), 2)
        XCTAssertEqual(q.nextTask?.id, front.id)
        // entered-logs record the position it was added at
        XCTAssertEqual(front.log.last?.text, "Entered the queue at #1")
        XCTAssertEqual(c.log.last?.text, "Entered the queue at #3")
    }

    func testMoveKeepsFinishedTasksOutOfTheWay() {
        var q = TaskQueue()
        let a = q.add("A")
        _ = q.add("B")
        let c = q.add("C")
        q.start(a.id)
        q.finish(a.id, status: .complete)

        // Move C to the front: finished A must not block the renumbering.
        q.move(id: c.id, before: a.id)
        XCTAssertEqual(q.tasks.map(\.title), ["C", "A", "B"])
        XCTAssertEqual(q.position(of: c.id), 1)

        // Move B one up (before finished A) → B lands right after A's slot.
        q.move(id: q.tasks[2].id, by: -1)
        XCTAssertEqual(q.tasks.map(\.title), ["C", "B", "A"])
        XCTAssertEqual(q.position(of: q.tasks[1].id), 2)
    }

    func testRemoveRunningTaskMarksItSkipped() {
        var q = TaskQueue()
        let a = q.add("A")
        _ = q.add("B")
        q.start(a.id)
        q.remove(id: a.id)

        // Running task is kept as a record, marked skipped.
        XCTAssertEqual(q.tasks.count, 2)
        XCTAssertEqual(q.task(a.id)?.status, .skipped)
        XCTAssertEqual(q.task(a.id)?.log.last?.kind, .skipped)

        // A queued task really disappears.
        let b = q.tasks.first { $0.title == "B" }!
        q.remove(id: b.id)
        XCTAssertTrue(q.tasks.allSatisfy { $0.status == .skipped })
    }

    func testUpdateKeepsStatusAndLogs() {
        var q = TaskQueue()
        let a = q.add("Old title", details: "d1")
        q.update(id: a.id, title: "New title", details: "d2")
        XCTAssertEqual(q.task(a.id)?.title, "New title")
        XCTAssertEqual(q.task(a.id)?.details, "d2")
        XCTAssertEqual(q.task(a.id)?.status, .queued)
        XCTAssertEqual(q.task(a.id)?.log.last?.kind, .note)
    }

    func testStatsAndTokensPerSecond() {
        var q = TaskQueue()
        let a = q.add("A")
        _ = q.add("B")
        q.start(a.id)
        q.recordRound(a.id, round: 3, prompt: 900, completion: 100)
        q.finish(a.id, status: .complete, sessionID: "s1")

        let s = q.stats()
        XCTAssertEqual(s.completed, 1)
        XCTAssertEqual(s.queued, 1)
        XCTAssertEqual(s.promptTokens, 900)
        XCTAssertEqual(s.completionTokens, 100)
        XCTAssertGreaterThanOrEqual(s.totalDuration, 0)

        let t = q.task(a.id)!
        XCTAssertEqual(t.totalTokens, 1000)
        // avg rate ≈ 1000 / (a few ms) → huge but positive
        XCTAssertGreaterThanOrEqual(t.avgTokensPerSecond ?? 0, 100)

        // Drain the queue → finished flag.
        let b = q.nextTask!
        q.start(b.id)
        q.finish(b.id, status: .complete)
        XCTAssertTrue(q.stats().finished)
        XCTAssertFalse(q.hasRunning)
    }

    func testFinishLogCarriesRoundsAndRate() {
        var q = TaskQueue()
        let a = q.add("A")
        q.start(a.id)
        q.recordRound(a.id, round: 2, prompt: 100, completion: 100)
        q.finish(a.id, status: .complete)
        let line = q.task(a.id)!.log.last!
        XCTAssertEqual(line.kind, .complete)
        XCTAssertTrue(line.text.contains("2 rounds"), line.text)
        XCTAssertTrue(line.text.contains("tokens/s avg"), line.text)
    }

    func testBlockedAndFailedReasons() {
        var q = TaskQueue()
        let a = q.add("A")
        let b = q.add("B")
        q.start(a.id)
        q.finish(a.id, status: .blocked, reason: "missing API key")
        q.start(b.id)
        q.finish(b.id, status: .failed, reason: "server 500")
        XCTAssertEqual(q.task(a.id)!.log.last?.kind, .blocked)
        XCTAssertTrue(q.task(a.id)!.log.last!.text.contains("missing API key"))
        XCTAssertEqual(q.task(b.id)!.log.last?.kind, .failed)
    }

    func testPersistenceRoundTrip() throws {
        var q = TaskQueue()
        let a = q.add("A", details: "do a")
        _ = q.add("B")
        q.start(a.id)
        q.recordRound(a.id, round: 4, prompt: 50, completion: 60)
        q.finish(a.id, status: .complete, sessionID: "s")
        q.move(id: q.tasks[1].id, before: a.id)

        let data = try JSONEncoder().encode(q)
        let decoded = try JSONDecoder().decode(TaskQueue.self, from: data)
        XCTAssertEqual(decoded, q)
        XCTAssertEqual(decoded.tasks.map(\.title), ["B", "A"])
        XCTAssertEqual(decoded.task(a.id)?.rounds, 4)
        XCTAssertEqual(decoded.task(a.id)?.sessionID, "s")
    }

    func testBlockedTaskCanBeRetried() {
        var q = TaskQueue()
        let a = q.add("A")
        let b = q.add("B")
        q.start(a.id)
        q.finish(a.id, status: .blocked, reason: "needs you")
        // Retry: start must accept a blocked task and reset its stats.
        q.start(a.id)
        XCTAssertEqual(q.task(a.id)?.status, .running)
        XCTAssertEqual(q.task(a.id)?.rounds, 0)
        q.recordRound(a.id, round: 1, prompt: 5, completion: 5)
        q.finish(a.id, status: .complete)
        XCTAssertEqual(q.task(a.id)?.rounds, 1)
        XCTAssertEqual(q.task(a.id)?.promptTokens, 5)
        _ = b
    }

    func testRequeueMovesBlockedToFrontOfQueuedRegion() {
        var q = TaskQueue()
        let a = q.add("A")
        _ = q.add("B")
        _ = q.add("C")
        q.start(a.id)
        q.finish(a.id, status: .failed, reason: "boom")
        q.requeue(a.id, toFront: true)
        XCTAssertEqual(q.task(a.id)?.status, .queued)
        // A is now position #1 of the queued region.
        XCTAssertEqual(q.nextTask?.id, a.id)
        XCTAssertEqual(q.position(of: a.id), 1)
    }

    func testRequeueIgnoresRunningTask() {
        var q = TaskQueue()
        let a = q.add("A")
        q.start(a.id)
        q.requeue(a.id)   // no-op while running
        XCTAssertEqual(q.task(a.id)?.status, .running)
    }

    func testMarkStoppedOnlyFromRunning() {
        var q = TaskQueue()
        let a = q.add("A")
        q.markStopped(a.id)   // not running → no-op
        XCTAssertEqual(q.task(a.id)?.status, .queued)
        q.start(a.id)
        q.markStopped(a.id)
        XCTAssertEqual(q.task(a.id)?.status, .queued)
        XCTAssertEqual(q.task(a.id)?.log.last?.kind, .note)
    }

    func testGoalTextFoldsTitleAndDetails() {
        var q = TaskQueue()
        let t = q.add("Short title", details: "Full instructions here.")
        XCTAssertTrue(t.goalText.hasPrefix("Short title"))
        XCTAssertTrue(t.goalText.contains("Full instructions here."))
        // No details → title only.
        let bare = q.add("Just a title")
        XCTAssertEqual(bare.goalText, "Just a title")
    }

    func testGlobalLogIsTimeOrdered() {
        var q = TaskQueue()
        let a = q.add("A")
        q.start(a.id)
        q.recordRound(a.id, round: 1, prompt: 10, completion: 10)
        q.finish(a.id, status: .complete)
        let lines = q.allLogLines
        XCTAssertEqual(lines.count, q.tasks.flatMap(\.log).count)
        for pair in zip(lines, lines.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.at, pair.1.at)
        }
        XCTAssertEqual(lines.first?.kind, .entered)
        XCTAssertEqual(lines.last?.kind, .complete)
    }

    func testDurationFormatting() {
        XCTAssertEqual(59.4.formattedDuration, "59s")
        XCTAssertEqual(125.0.formattedDuration, "2m 5s")
        XCTAssertEqual(120.0.formattedDuration, "2m")
        XCTAssertEqual(3723.0.formattedDuration, "1h 2m")
        XCTAssertEqual(7200.0.formattedDuration, "2h")
    }
}
