import XCTest
@testable import DSHCore

/// A subagent task marked `sensitive` runs only on a private server — and the main agent is told which servers are
/// private.
final class SensitiveDelegationTests: XCTestCase {
    private var dir: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        dir = FleetTestDirectory("dsh-sensitive")
    }

    override func tearDown() {
        dir.remove()
        super.tearDown()
    }

    private func server(_ id: String, primary: Bool = false, max: Int = 2, private isPrivate: Bool) -> FleetServer {
        FleetServer(id: id, label: id, isPrimary: primary, maxParallel: max, isPrivate: isPrivate) {
            FleetTarget(client: FleetReportsClient("report from \(id)"), model: "model-" + id, contextWindow: 8_000)
        }
    }

    // MARK: The fleet

    func testASensitiveTaskGoesToAPrivateWorkerEvenWhenAnotherIsFreer() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("primary", primary: true, private: false), server("kimi", max: 4, private: false),
                         server("spark-2", max: 1, private: true)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark-2")
        // An ordinary task still goes where there is room.
        let ordinary = try await fleet.acquire()
        XCTAssertEqual(ordinary.label, "kimi")
        lease.release()
        ordinary.release()
    }

    func testWithoutAPrivateWorkerItRunsOnAPrivatePrimaryThatMayTakeSubagents() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("spark", primary: true, private: true), server("kimi", private: false)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark")
        lease.release()
    }

    func testOtherwiseTheModelIsToldToDoItItself() async {
        let notAllowed = AgentFleet()
        notAllowed.usePrimaryWhenWorkersBusy = false
        notAllowed.configure([server("spark", primary: true, private: true), server("kimi", private: false)])
        let notPrivate = AgentFleet()
        notPrivate.configure([server("openai", primary: true, private: false), server("kimi", private: false)])
        for fleet in [notAllowed, notPrivate] {
            do {
                _ = try await fleet.acquire(sensitive: true)
                XCTFail("nothing private may take it")
            } catch let error as FleetUnavailableError {
                XCTAssertEqual(error.message, "No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again.")
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    func testAPrivateServerOnItsOwnTakesSensitiveTasks() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("spark", primary: true, private: true)])
        let lease = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(lease.label, "spark", "with no workers at all, the one server is the subagent server")
        lease.release()
    }

    func testABusyPrivateWorkerIsWaitedForOrOverflowsToAPrivatePrimary() async throws {
        let fleet = AgentFleet()
        fleet.usePrimaryWhenWorkersBusy = false
        fleet.configure([server("primary", primary: true, private: true), server("kimi", private: false),
                         server("spark-2", max: 1, private: true)])
        let held = try await fleet.acquire(sensitive: true)
        let waiting = FleetPending { try await fleet.acquire(sensitive: true) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(waiting.isDone, "it waits for the private worker rather than going to kimi")
        held.release()
        let lease = try await waiting.value()
        XCTAssertEqual(lease.label, "spark-2")
        // With the primary allowed, the overflow goes there instead of waiting.
        fleet.usePrimaryWhenWorkersBusy = true
        let overflow = try await fleet.acquire(sensitive: true)
        XCTAssertEqual(overflow.label, "primary")
        lease.release()
        overflow.release()
    }

    // MARK: The tools

    func testTheAgentToolSaysWhenNothingPrivateCanTakeIt() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("openai", primary: true, private: false), server("kimi", private: false)])
        let context = fleetContext(FleetReportsClient("parent"), root: dir.url, fleet: fleet, retry: fleetFastRetry)
        let result = await AgentTool().execute(args: #"{"description":"payroll","prompt":"p","sensitive":true}"#, in: context)
        XCTAssertTrue(result.output.contains("No private server is free for a sensitive task. Do it yourself, or rewrite it without the sensitive details and try again."),
                      result.output)
        // Without the flag it runs.
        let ordinary = await AgentTool().execute(args: #"{"description":"docs","prompt":"p"}"#, in: context)
        XCTAssertTrue(ordinary.output.contains("finished"), ordinary.output)
    }

    func testDelegateMarksTasksOneByOneOrAllAtOnce() async throws {
        let fleet = AgentFleet()
        fleet.configure([server("openai", primary: true, private: false), server("spark-2", private: true), server("kimi", private: false)])
        let context = fleetContext(FleetReportsClient("parent"), root: dir.url, fleet: fleet, retry: fleetFastRetry)
        let result = await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"p","sensitive":true},{"description":"b","prompt":"p"}]}"#,
                                                  in: context)
        XCTAssertTrue(result.output.contains("2 finished"), result.output)
        XCTAssertTrue(result.output.contains("## 1. a — finished (on spark-2"), result.output)
    }

    func testTheModelIsToldWhichServersArePrivate() throws {
        let servers = [SubagentServers.Entry(name: "Spark 2", isPrivate: true), SubagentServers.Entry(name: "Kimi Code", isPrivate: false)]
        let note = try XCTUnwrap(SubagentServers.note(servers))
        XCTAssertTrue(note.hasPrefix("Subagent servers: Spark 2 (private), Kimi Code (not private). "))
        XCTAssertTrue(note.contains("Servers that aren't private must not receive sensitive data. Describe their tasks in general terms — no names, credentials, personal or client details; the app also masks what it detects."))
        XCTAssertNil(SubagentServers.note([]))
        XCTAssertFalse(SubagentServers.note([servers[0]])!.contains("must not receive"))

        let registry = ToolRegistry.standard(agents: nil, servers: servers)
        for spec in registry.specs {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(spec.parameters.utf8)), spec.name)
        }
        for name in ["agent", "delegate"] {
            let spec = try XCTUnwrap(registry.specs.first { $0.name == name })
            XCTAssertTrue(spec.description.contains("Subagent servers: Spark 2 (private), Kimi Code (not private)"), name)
            XCTAssertTrue(spec.parameters.contains(#""sensitive":{"type":"boolean","description":"Set true when the task needs sensitive data (personal data, credentials, client details). It then runs only on a private server."#), name)
        }
    }
}
