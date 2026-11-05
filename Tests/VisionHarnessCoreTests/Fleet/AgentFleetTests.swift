import XCTest
@testable import VisionHarnessCore

final class AgentFleetTests: XCTestCase {

    private func server(_ id: String, primary: Bool = false, max: Int = 2) -> FleetServer {
        fleetServer(id, FleetReportsClient(id), primary: primary, max: max)
    }

    private func status(_ fleet: AgentFleet, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> FleetStatus {
        guard let found = fleet.snapshot().first(where: { $0.id == id }) else {
            XCTFail("no server \(id) in the snapshot", file: file, line: line)
            return FleetStatus(id: id, label: id, isPrimary: false, inFlight: -1, maxParallel: 0, healthy: false, completed: 0, failed: 0)
        }
        return found
    }

    func testASingleServerIsAConcurrencyLimit() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("spark-1", primary: true, max: 2)])
        let a = try await fleet.acquire(preferred: nil)
        let b = try await fleet.acquire(preferred: nil)
        let third = FleetPending { try await fleet.acquire(preferred: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(third.isDone)
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 2)

        a.release()
        let lease = try await third.value()
        XCTAssertEqual(lease.label, "spark-1")
        b.release()
        lease.release()
        let after = fleet.snapshot()[0]
        XCTAssertEqual(after.inFlight, 0)
        XCTAssertEqual(after.completed, 3)
    }

    func testWorkersTakeSubagentsBeforeThePrimary() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("primary", primary: true), server("worker-a", max: 1), server("worker-b", max: 1)])
        let first = try await fleet.acquire(preferred: nil)
        let second = try await fleet.acquire(preferred: nil)
        XCTAssertEqual([first.label, second.label].sorted(), ["worker-a", "worker-b"])
        // Both workers full: the primary takes the overflow.
        let third = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(third.label, "primary")
    }

    func testThePrimaryCanBeKeptFreeForTheMainAgent() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("primary", primary: true), server("worker", max: 1)])
        let held = try await fleet.acquire(preferred: nil)
        let waiting = FleetPending { try await fleet.acquire(preferred: nil) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(waiting.isDone, "must not spill onto the primary")
        held.release()
        let lease = try await waiting.value()
        XCTAssertEqual(lease.label, "worker")
    }

    func testTheLeastLoadedWorkerIsChosen() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 4), server("b", max: 4)])
        var leases: [FleetLease] = []
        for _ in 0..<6 { leases.append(try await fleet.acquire(preferred: nil)) }
        XCTAssertEqual(leases.filter { $0.label == "a" }.count, 3)
        XCTAssertEqual(leases.filter { $0.label == "b" }.count, 3)
    }

    func testLoadIsJudgedByShareOfCapacityNotByHeadCount() async throws {
        // Two of four slots busy is as full as one of two: after the first three leases (2 + 1) the fourth goes to the
        // roomier server again. Counting heads would have put it on the small one (2 + 2).
        let fleet = AgentFleet()
        fleet.configure([server("big", max: 4), server("small", max: 2)])
        var leases: [FleetLease] = []
        for _ in 0..<4 { leases.append(try await fleet.acquire(preferred: nil)) }
        XCTAssertEqual(leases.map(\.label), ["big", "small", "big", "big"])
    }

    func testAPreferredServerIsUsedWhenItHasRoom() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("spark-1", primary: true), server("spark-2"), server("spark-3")])
        let first = try await fleet.acquire(preferred: "SPARK-3")
        XCTAssertEqual(first.label, "spark-3")
        // A preference is not a demand: when that server is full, others serve.
        let second = try await fleet.acquire(preferred: "spark-3")
        XCTAssertEqual(second.label, "spark-3")
        let third = try await fleet.acquire(preferred: "spark-3")
        XCTAssertNotEqual(third.label, "spark-3")
    }

    func testAPreferenceMatchesTheIdAsWellAsTheLabel() async throws {
        let fleet = AgentFleet()
        let named = FleetServer(id: "route-7f3a", label: "Spark 2", isPrimary: false, maxParallel: 2, resolve: {
            FleetTarget(client: FleetReportsClient("x"), model: "m")
        })
        fleet.configure([server("other"), named])
        let byLabel = try await fleet.acquire(preferred: "spark 2")
        XCTAssertEqual(byLabel.server.id, "route-7f3a")
        let byId = try await fleet.acquire(preferred: "7f3a")
        XCTAssertEqual(byId.server.id, "route-7f3a")
        // Nothing matches: the usual order applies.
        let none = try await fleet.acquire(preferred: "orion")
        XCTAssertEqual(none.server.id, "other")
    }

    func testAPreferredServerThatJustFailedIsNotUsed() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a"), server("b")])
        let failing = try await fleet.acquire(preferred: "a")
        failing.fail(LLMError.connection("refused"))
        failing.release()
        let next = try await fleet.acquire(preferred: "a")
        XCTAssertEqual(next.label, "b")
    }

    func testAFailedServerIsAvoidedThenForgiven() async throws {
        let clock = FleetTestClock()
        let fleet = AgentFleet(now: { clock.now })
        fleet.unhealthyFor = 60
        fleet.configure([server("primary", primary: true), server("flaky", max: 4)])
        let lease = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(lease.label, "flaky")
        lease.fail(LLMError.connection("refused"))
        lease.release()

        let down = status(fleet, "flaky")
        XCTAssertFalse(down.healthy)
        XCTAssertEqual(down.unhealthyUntil, clock.now.addingTimeInterval(60))
        let elsewhere = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(elsewhere.label, "primary")

        clock.advance(seconds: 61)
        XCTAssertTrue(status(fleet, "flaky").healthy)
        XCTAssertNil(status(fleet, "flaky").unhealthyUntil)
        let back = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(back.label, "flaky")
    }

    func testAServerThatWorkedAgainIsTrustedAtOnce() async throws {
        let clock = FleetTestClock()
        let fleet = AgentFleet(now: { clock.now })
        fleet.configure([server("a", max: 1)])
        let bad = try await fleet.acquire(preferred: nil)
        bad.fail(LLMError.http(503, "busy"))
        bad.release()
        XCTAssertFalse(status(fleet, "a").healthy)
        // When every server is down the fleet tries them anyway; one that then does real work is forgiven.
        let good = try await fleet.acquire(preferred: nil)
        good.release()
        XCTAssertTrue(status(fleet, "a").healthy)
    }

    func testARequestsOwnFaultDoesNotBlacklistAServer() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("only", max: 4)])
        let lease = try await fleet.acquire(preferred: nil)
        lease.fail(LLMError.http(400, "bad request"))   // the request was wrong, not the server
        lease.release()
        XCTAssertTrue(fleet.snapshot()[0].healthy)
        XCTAssertEqual(fleet.snapshot()[0].failed, 1)
    }

    func testAnUnreachableServerIsSkippedAtLeaseTime() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetDeadServer("dead"), server("alive")])
        let lease = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(lease.label, "alive")
        XCTAssertEqual(status(fleet, "dead").inFlight, 0, "its slot was given back")
        XCTAssertFalse(status(fleet, "dead").healthy)
        XCTAssertEqual(status(fleet, "dead").failed, 1)
    }

    func testAServerThatAnswersNoModelListCountsAsDown() async throws {
        // The host resolves a worker by asking what it serves; a server that names no model isn't answering, and says so
        // with a connection error. The fleet then treats it like any other dead server.
        let fleet = AgentFleet()
        fleet.configure([fleetDeadServer("silent", error: LLMError.connection("http://spark-2:8002/v1 didn't answer")),
                         server("alive")])
        let lease = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(lease.label, "alive")
        XCTAssertFalse(status(fleet, "silent").healthy)
        let again = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(again.label, "alive", "and it is left alone for the next task")
    }

    func testWhenEveryServerIsDownTheyAreTriedAnyway() async throws {
        let clock = FleetTestClock()
        let fleet = AgentFleet(now: { clock.now })
        fleet.configure([server("a", max: 1), server("b", max: 1)])
        for id in ["a", "b"] {
            let lease = try await fleet.acquire(preferred: id)
            lease.fail(LLMError.connection("down"))
            lease.release()
        }
        XCTAssertTrue(fleet.snapshot().allSatisfy { !$0.healthy })
        // "Skipped for a minute" gives way to "better than nothing".
        let lease = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(lease.label, "a")
    }

    func testWhenNoServerAnswersTheErrorSaysSo() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetDeadServer("dead", error: LLMError.connection("refused"))])
        do {
            _ = try await fleet.acquire(preferred: nil)
            XCTFail("expected FleetUnavailableError")
        } catch let error as FleetUnavailableError {
            XCTAssertTrue(error.message.contains("No model server answered"), error.message)
            XCTAssertTrue(error.message.contains("refused"), "it carries the last server's own error: \(error.message)")
            XCTAssertEqual(error.errorDescription, error.message)
            XCTAssertNotNil(error.underlying)
        }
        do {
            _ = try await AgentFleet().acquire(preferred: nil)
            XCTFail("expected FleetUnavailableError")
        } catch let error as FleetUnavailableError {
            XCTAssertEqual(error.message, "No model server is configured.")
        }
    }

    func testWaitingIsCancellable() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("only", max: 1)])
        let held = try await fleet.acquire(preferred: nil)
        let waiting = FleetPending { try await fleet.acquire(preferred: nil) }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(waiting.isDone)
        waiting.cancel()
        do {
            _ = try await waiting.value()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 1, "only the lease that was already held")
        held.release()
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 0)
    }

    func testACancelledLeaseInTheMiddleOfResolvingGivesTheSlotBackWithoutCounting() async throws {
        let fleet = AgentFleet()
        let slow = fleetServer("slow", FleetReportsClient("x"), max: 1, resolve: {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            throw CancellationError()
        })
        fleet.configure([slow])
        let acquiring = FleetPending { try await fleet.acquire(preferred: nil) }
        let leased = await fleetEventually { fleet.snapshot()[0].inFlight == 1 }
        XCTAssertTrue(leased, "the slot is held while the server is being asked")
        acquiring.cancel()
        do {
            _ = try await acquiring.value()
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let after = fleet.snapshot()[0]
        XCTAssertEqual(after.inFlight, 0)
        XCTAssertEqual(after.completed, 0)
        XCTAssertEqual(after.failed, 0)
        XCTAssertTrue(after.healthy, "being stopped is not the server's fault")
    }

    func testReconfiguringKeepsWorkInFlightAndWakesWaiters() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 1)])
        let held = try await fleet.acquire(preferred: nil)
        let waiting = FleetPending { try await fleet.acquire(preferred: nil) }
        try await Task.sleep(nanoseconds: 30_000_000)
        fleet.configure([server("a", max: 1), server("b", max: 1)])   // a second Spark was added
        let lease = try await waiting.value()
        XCTAssertEqual(lease.label, "b")
        XCTAssertEqual(status(fleet, "a").inFlight, 1)
        held.release()
    }

    func testARemovedServerKeepsItsLeaseUntilItIsReleased() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a"), server("b")])
        let lease = try await fleet.acquire(preferred: "a")
        fleet.configure([server("b")])
        XCTAssertEqual(fleet.snapshot().map(\.id), ["b"])
        XCTAssertEqual(fleet.servers.map(\.id), ["b"])
        lease.release()   // must not trip over the forgotten server
        XCTAssertEqual(fleet.snapshot().map(\.inFlight), [0])
    }

    func testTheServersAndWhetherThereAreWorkers() {
        let fleet = AgentFleet()
        XCTAssertFalse(fleet.hasWorkers)
        fleet.configure([server("main", primary: true)])
        XCTAssertFalse(fleet.hasWorkers)
        fleet.configure([server("main", primary: true), server("spark-2")])
        XCTAssertTrue(fleet.hasWorkers)
        XCTAssertEqual(fleet.servers.map(\.label), ["main", "spark-2"])
        XCTAssertEqual(fleet.snapshot().map(\.isPrimary), [true, false])
    }

    func testChangedFiresWhenLeasesMove() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a")])
        let fired = FleetCounter()
        fleet.onChange = { fired.bump() }
        let lease = try await fleet.acquire(preferred: nil)
        lease.release()
        XCTAssertGreaterThanOrEqual(fired.value, 2)   // granted, then released
    }

    func testAListenerThatLooksAtTheFleetCannotDeadlockItOrLoseASlot() async throws {
        // (A C# listener could throw; a Swift one can't. What can go wrong is a listener that comes back into the
        // fleet while it is being told — which must work, not deadlock on the fleet's own lock.)
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 1)])
        let seen = FleetLog<Int>()
        fleet.onChange = { [unowned fleet] in seen.append(fleet.snapshot()[0].inFlight) }
        let acquiring = FleetPending { try await fleet.acquire(preferred: nil) }
        let lease = try await acquiring.value()
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 1)
        lease.release()
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 0)
        // Told after the state was settled: 1 slot in use when it was granted, none when it was given back.
        XCTAssertEqual(seen.all, [1, 0])
    }

    func testEachStepOfALeaseTellsTheListener() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 1)])
        let heard = FleetCounter()
        fleet.onChange = { heard.bump() }
        let lease = try await fleet.acquire(preferred: nil)
        lease.fail(LLMError.connection("down"))
        lease.release()
        XCTAssertGreaterThanOrEqual(heard.value, 3)   // granted, failed, released
    }

    func testServerFaultClassification() {
        XCTAssertTrue(AgentFleet.isServerFault(URLError(.cannotConnectToHost)))
        XCTAssertTrue(AgentFleet.isServerFault(URLError(.timedOut)))
        XCTAssertTrue(AgentFleet.isServerFault(URLError(.networkConnectionLost)))
        XCTAssertFalse(AgentFleet.isServerFault(URLError(.badURL)))
        XCTAssertFalse(AgentFleet.isServerFault(URLError(.cancelled)))
        struct Unrelated: Error {}
        XCTAssertFalse(AgentFleet.isServerFault(Unrelated()))
        XCTAssertFalse(AgentFleet.isServerFault(CancellationError()))
    }

    func testLLMErrorsAreClassifiedByKindAndStatus() {
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.connection("x")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.sse("cut off")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(503, "busy")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(429, "slow down")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(500, "oom")))
        // Credentials one server rejects may be fine on another.
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(401, "no")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(403, "no")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.rejected(status: 401, message: "sign in", body: "", permanent: true)))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.rejected(status: 403, message: "denied", body: "", permanent: true)))
        // A server mid-swap says the model isn't there (or is still loading): the retry policy waits that
        // out, so it is the server's.
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(404, "The model `qwen` does not exist")))
        XCTAssertTrue(AgentFleet.isServerFault(LLMError.http(400, "model is loading, try again")))
        // The request's own faults follow it wherever it goes.
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.http(400, "bad")))
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.http(422, "unprocessable")))
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.rejected(status: 404, message: "no such model", body: "", permanent: true)))
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.noModel))
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.overflow(limit: 8_000, detail: "too long")))
        XCTAssertFalse(AgentFleet.isServerFault(LLMError.unsupported("x")))
        XCTAssertFalse(AgentFleet.isServerFault(CancellationError()))
    }

    func testAWaiterIsWokenWhenABlacklistedServerRecovers() async throws {
        let fleet = AgentFleet()
        fleet.unhealthyFor = 0.3
        fleet.configure([server("a", max: 1), server("b", max: 1)])
        let a = try await fleet.acquire(preferred: "a")
        a.fail(URLError(.cannotConnectToHost))
        a.release()   // a is out of rotation for 300 ms
        let b = try await fleet.acquire(preferred: "b")   // and b is busy
        let waiting = FleetPending { try await fleet.acquire(preferred: nil) }

        // Nothing releases b, yet the waiter must not sit there for ever: a comes back by itself.
        let lease = try await waiting.value(within: 5)
        XCTAssertEqual(lease.label, "a")
        lease.release()
        b.release()
    }

    func testAStoppedLeaseIsNotCountedAsWork() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 1)])
        let lease = try await fleet.acquire(preferred: nil)
        lease.abandon()
        lease.release()
        let after = fleet.snapshot()[0]
        XCTAssertEqual(after.inFlight, 0)
        XCTAssertEqual(after.completed, 0)
    }

    func testAStoppedLeaseDoesNotForgiveAServerThatFailed() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 2)])
        let bad = try await fleet.acquire(preferred: nil)
        let stopped = try await fleet.acquire(preferred: nil)
        bad.fail(LLMError.connection("down"))
        bad.release()
        stopped.abandon()
        stopped.release()
        XCTAssertFalse(fleet.snapshot()[0].healthy, "being stopped is not evidence the server recovered")
    }

    func testReleasingTwiceGivesTheSlotBackOnce() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 2)])
        let one = try await fleet.acquire(preferred: nil)
        let two = try await fleet.acquire(preferred: nil)
        one.release()
        one.release()
        one.abandon()
        one.release()
        let after = fleet.snapshot()[0]
        XCTAssertEqual(after.inFlight, 1, "the other lease still holds its slot")
        XCTAssertEqual(after.completed, 1)
        two.release()
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 0)
    }

    func testAFailureIsCountedOnceNotAsWorkToo() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("a")])
        let lease = try await fleet.acquire(preferred: nil)
        lease.fail(LLMError.http(503, "busy"))
        lease.release()
        let after = fleet.snapshot()[0]
        XCTAssertEqual(after.failed, 1)
        XCTAssertEqual(after.completed, 0)
    }

    func testTheLeaseCarriesTheResolvedTarget() async throws {
        let fleet = AgentFleet()
        let client = FleetReportsClient("x")
        fleet.configure([FleetServer(id: "s", label: "S", isPrimary: false, maxParallel: 1, resolve: {
            FleetTarget(client: client, model: "qwen-live", contextWindow: 262_144, vision: false, temperature: 0.2, maxOutputTokens: 4_096)
        })])
        let lease = try await fleet.acquire(preferred: nil)
        XCTAssertEqual(lease.target.model, "qwen-live")
        XCTAssertEqual(lease.target.contextWindow, 262_144)
        XCTAssertEqual(lease.target.vision, false)
        XCTAssertEqual(lease.target.temperature, 0.2)
        XCTAssertEqual(lease.target.maxOutputTokens, 4_096)
        XCTAssertEqual(lease.server.id, "s")
        XCTAssertEqual(lease.label, "S")
    }

    func testServersAreResolvedWhenLeasedNotWhenConfigured() async throws {
        // A Spark may have swapped models since the route was configured.
        let fleet = AgentFleet()
        let asked = FleetCounter()
        fleet.configure([fleetServer("s", FleetReportsClient("x"), resolve: {
            asked.bump()
            return FleetTarget(client: FleetReportsClient("x"), model: "live-\(asked.value)")
        })])
        XCTAssertEqual(asked.value, 0)
        let first = try await fleet.acquire(preferred: nil)
        first.release()
        let second = try await fleet.acquire(preferred: nil)
        XCTAssertEqual([first.target.model, second.target.model], ["live-1", "live-2"])
    }

    func testCancellingTasksAtAnyPointNeverLeaksASlot() async throws {
        // Tasks stopped while waiting for a slot, while the server is being asked, or while holding one: whichever it
        // was, the slot is back at the end — and none of it counted as work that was not done.
        let fleet = AgentFleet()
        fleet.configure([server("a", max: 2), fleetServer("b", FleetReportsClient("b"), max: 1, resolve: {
            try await Task.sleep(nanoseconds: 3_000_000)
            return FleetTarget(client: FleetReportsClient("b"), model: "m")
        })])
        let held = FleetCounter()
        try await fleetBounded {
            var tasks: [Task<Void, Never>] = []
            for index in 0..<60 {
                tasks.append(Task {
                    do {
                        let lease = try await fleet.acquire(preferred: index % 7 == 0 ? "b" : nil)
                        held.bump()
                        do { try await Task.sleep(nanoseconds: UInt64(index % 5) * 2_000_000) } catch { lease.abandon() }
                        lease.release()
                    } catch {
                        // stopped before it got a slot
                    }
                })
                if index % 3 == 0 { tasks[index].cancel() }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            for index in stride(from: 1, to: 60, by: 4) { tasks[index].cancel() }
            for task in tasks { await task.value }
        }
        XCTAssertTrue(fleet.snapshot().allSatisfy { $0.inFlight == 0 }, "\(fleet.snapshot())")
        XCTAssertGreaterThan(held.value, 0)
        XCTAssertLessThanOrEqual(fleet.snapshot().map(\.completed).reduce(0, +), held.value)
        // …and the fleet still works.
        let lease = try await fleetBounded { try await fleet.acquire(preferred: nil) }
        lease.release()
    }

    func testManyTasksShareFewSlots() async throws {
        // Twenty tasks on a server with two slots: never more than two at once, all of them served.
        let fleet = AgentFleet()
        fleet.configure([server("only", max: 2)])
        let served = FleetCounter()
        let busiest = FleetLog<Int>()
        try await fleetBounded {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        let lease = try await fleet.acquire(preferred: nil)
                        busiest.append(fleet.snapshot()[0].inFlight)
                        try await Task.sleep(nanoseconds: 5_000_000)
                        served.bump()
                        lease.release()
                    }
                }
                try await group.waitForAll()
            }
        }
        XCTAssertEqual(served.value, 20)
        XCTAssertLessThanOrEqual(busiest.all.max() ?? 0, 2)
        XCTAssertEqual(fleet.snapshot()[0].completed, 20)
        XCTAssertEqual(fleet.snapshot()[0].inFlight, 0)
    }
}
