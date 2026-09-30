import XCTest
@testable import DSHCore

final class MultiAgentTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        root = FleetTestDirectory("dsh-multiagent")
    }

    override func tearDown() {
        root.remove()
        super.tearDown()
    }

    private func context(_ client: any LLMClient, fleet: AgentFleet? = nil, roster: AgentRoster? = nil, depth: Int = 0,
                         registry: ToolRegistry? = nil, catalog: AgentCatalog? = nil,
                         background: BackgroundAgents? = nil) -> ToolContext {
        fleetContext(client, root: root.url, fleet: fleet, roster: roster, catalog: catalog, registry: registry, depth: depth,
                     retry: fleetFastRetry, background: background)
    }

    private func status(_ fleet: AgentFleet, _ id: String) throws -> FleetStatus {
        try XCTUnwrap(fleet.snapshot().first { $0.id == id })
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Failover

    func testATaskMovesToAnotherServerWhenItsServerDies() async throws {
        let fleet = AgentFleet()
        let dead = FlakyClient(failures: Int.max, error: LLMError.connection("connection refused"), turns: [])
        fleet.configure([fleetServer("main", FleetReportsClient("report from main"), primary: true),
                         fleetServer("spark-2", dead)])
        let roster = AgentRoster()

        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet, roster: roster))

        XCTAssertTrue(result.output.contains("report from main"), result.output)
        XCTAssertTrue(result.output.contains("on main"), result.output)
        XCTAssertTrue(result.output.contains("after 1 server failure"), result.output)
        XCTAssertFalse(result.output.contains("failures"), result.output)
        XCTAssertEqual(dead.calls, 3, "the first try plus two quick retries")
        let spark = try status(fleet, "spark-2")
        XCTAssertEqual(spark.failed, 1)
        XCTAssertFalse(spark.healthy)
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(roster.all.count, 1)
        XCTAssertEqual(run.server, "main")
        XCTAssertEqual(run.status, .done)

        // The dead server is left alone for the next task.
        let again = await AgentTool().execute(args: #"{"description":"scan2","prompt":"p"}"#,
                                              in: context(ScriptedClient(turns: []), fleet: fleet, roster: roster))
        XCTAssertTrue(again.output.contains("on main"), again.output)
        XCTAssertFalse(again.output.contains("server failure"), again.output)
        XCTAssertEqual(dead.calls, 3)
    }

    func testARequestsOwnErrorDoesNotBounceBetweenServers() async throws {
        let fleet = AgentFleet()
        let picky = FlakyClient(failures: Int.max, error: LLMError.http(400, "bad key"), turns: [])
        fleet.configure([fleetServer("a", picky), fleetServer("b", FleetReportsClient("never"))])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' failed: "), result.output)
        XCTAssertTrue(result.output.contains("bad key"), result.output)
        XCTAssertTrue(try status(fleet, "a").healthy)
        XCTAssertEqual(picky.calls, 1)
    }

    func testWhenNoServerWorksTheFailureIsReported() async {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("a", FlakyClient(failures: Int.max, error: LLMError.connection("down"), turns: [])),
                         fleetServer("b", FlakyClient(failures: Int.max, error: LLMError.connection("down"), turns: []))])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' failed: "), result.output)
        XCTAssertTrue(result.output.contains("after 2 server failures"), result.output)
    }

    func testAFleetWithNoServerAtAllReportsThatToo() async {
        let roster = AgentRoster()
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: AgentFleet(), roster: roster))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' failed: No model server is configured."), result.output)
        XCTAssertEqual(roster.all.first?.status, .failed)
    }

    func testEveryServerUnreachableAtLeaseTimeIsReportedAsSuch() async {
        let fleet = AgentFleet()
        fleet.configure([fleetDeadServer("a"), fleetDeadServer("b")])
        let roster = AgentRoster()
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet, roster: roster))
        XCTAssertTrue(result.output.contains("No model server answered"), result.output)
        XCTAssertEqual(roster.all.first?.status, .failed)
        XCTAssertTrue(fleet.snapshot().allSatisfy { $0.inFlight == 0 })
    }

    func testALoneServerIsNotNamedInTheReport() async throws {
        // With nothing to choose between, "on spark" and a timing line would be noise.
        let fleet = AgentFleet()
        fleet.configure([fleetServer("only", FleetReportsClient("the report"), primary: true)])
        let roster = AgentRoster()
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet, roster: roster))
        XCTAssertEqual(result.output, "Subagent 'scan' finished.\n\nthe report")
        XCTAssertNil(try XCTUnwrap(roster.all.first).server)
        XCTAssertEqual(roster.all.count, 1)
    }

    func testASubagentUsesTheLeasedServersModelAndWindow() async {
        let client = FleetReportsClient("ok")
        let fleet = AgentFleet()
        fleet.configure([fleetServer("spark", client)])
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#,
                                      in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertEqual(client.requests.first?.model, "model-spark")
    }

    // MARK: - delegate

    func testDelegateSpreadsTasksAcrossServers() async throws {
        // Each server holds one task at a time and answers only once all three tasks are in flight — which can only
        // happen if the three tasks landed on three different servers.
        let meeting = FleetMeeting(parties: 3)
        let fleet = AgentFleet()
        fleet.configure([
            fleetServer("main", FleetRendezvousClient(meeting: meeting, name: "main"), primary: true, max: 1),
            fleetServer("spark-2", FleetRendezvousClient(meeting: meeting, name: "spark-2"), max: 1),
            fleetServer("spark-3", FleetRendezvousClient(meeting: meeting, name: "spark-3"), max: 1),
        ])
        let roster = AgentRoster()
        let arguments = """
        {"tasks":[{"description":"api layer","prompt":"audit the api","agent_type":"explore"},
                  {"description":"tests","prompt":"audit the tests","agent_type":"explore"},
                  {"description":"docs","prompt":"audit the docs","agent_type":"explore"}]}
        """
        let result = await DelegateTool().execute(args: JSONString(arguments),
                                                  in: context(ScriptedClient(turns: []), fleet: fleet, roster: roster))

        XCTAssertTrue(result.output.hasPrefix("Delegated 3 tasks: 3 finished, 0 failed."), result.output)
        XCTAssertTrue(result.output.contains("## 1. api layer — finished"), result.output)
        XCTAssertTrue(result.output.contains("## 3. docs — finished"), result.output)
        XCTAssertFalse(result.output.contains(": alone"), result.output)
        XCTAssertEqual(occurrences(of: ": together", in: result.output), 3, result.output)
        XCTAssertEqual(Set(roster.all.compactMap(\.server)), ["main", "spark-2", "spark-3"])
        XCTAssertTrue(roster.all.allSatisfy { $0.agentType == "explore" })
    }

    func testDelegateReportsFailuresNextToSuccesses() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("only", ScriptedClient(turns: [.init(text: "first report"), .init(text: "second report")]), max: 1)])
        let okContext = context(ScriptedClient(turns: []), fleet: fleet)
        let ok = try await fleetBounded {
            await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"do a"},{"description":"b","prompt":"do b"}]}"#,
                                         in: okContext)
        }
        XCTAssertTrue(ok.output.hasPrefix("Delegated 2 tasks: 2 finished, 0 failed."), ok.output)
        XCTAssertTrue(ok.output.contains("first report") && ok.output.contains("second report"), ok.output)

        let failing = AgentFleet()
        failing.configure([fleetServer("bad", FlakyClient(failures: Int.max, error: LLMError.http(401, "no key"), turns: []), max: 2)])
        let bad = await DelegateTool().execute(args: #"{"tasks":[{"description":"a","prompt":"do a"}]}"#,
                                               in: context(ScriptedClient(turns: []), fleet: failing))
        XCTAssertTrue(bad.output.hasPrefix("Delegated 1 task: 0 finished, 1 failed."), bad.output)
        XCTAssertTrue(bad.output.contains("no key"), bad.output)
        XCTAssertTrue(bad.output.contains("— failed"), bad.output)
    }

    func testDelegateReportsAreInTheOrderTheTasksWereGiven() async {
        // The first task is the slow one; its report still comes first.
        let result = await DelegateTool().execute(
            args: #"{"tasks":[{"description":"one","prompt":"slow"},{"description":"two","prompt":"2"},{"description":"three","prompt":"3"}]}"#,
            in: context(FleetSlowFirstClient()))
        let positions = ["## 1. one", "report for slow", "## 2. two", "report for 2", "## 3. three", "report for 3"]
            .map { result.output.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains { $0 == nil }, result.output)
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), result.output)
    }

    func testDelegateNamesUnnamedTasksByNumberAndTrimsPrompts() async {
        let client = FleetReportsClient("ok")
        let result = await DelegateTool().execute(args: #"{"tasks":[{"prompt":"  look around  "}]}"#, in: context(client))
        XCTAssertTrue(result.output.contains("## 1. task 1 — finished"), result.output)
        XCTAssertEqual(client.requests.first?.messages.first { $0.role == .user }?.content, "look around")
    }

    func testDelegateRunsSeriallyWhenAskedTo() async {
        let client = FleetConcurrencyClient()
        let arguments = #"{"tasks":[{"description":"a","prompt":"1"},{"description":"b","prompt":"2"},{"description":"c","prompt":"3"}],"max_parallel":1}"#
        _ = await DelegateTool().execute(args: JSONString(arguments), in: context(client))
        XCTAssertEqual(client.peak, 1)

        let wide = FleetConcurrencyClient()
        _ = await DelegateTool().execute(args: JSONString(arguments.replacingOccurrences(of: #""max_parallel":1"#, with: #""max_parallel":3"#)),
                                         in: context(wide))
        XCTAssertEqual(wide.peak, 3)
    }

    func testDelegateRunsSixAtOnceByDefaultAndNeverMoreThanAskedFor() async {
        let tasks = (1...8).map { #"{"description":"t\#($0)","prompt":"p"}"# }.joined(separator: ",")
        let defaulted = FleetConcurrencyClient()
        _ = await DelegateTool().execute(args: JSONString(#"{"tasks":[\#(tasks)]}"#), in: context(defaulted))
        XCTAssertEqual(defaulted.peak, 6)

        let clamped = FleetConcurrencyClient()
        _ = await DelegateTool().execute(args: JSONString(#"{"tasks":[\#(tasks)],"max_parallel":0}"#), in: context(clamped))
        XCTAssertEqual(clamped.peak, 1, "at least one at a time")
    }

    func testDelegateChecksItsArguments() async {
        let cases: [(String, String)] = [
            (#"{}"#, "Error: tasks must be a non-empty array"),
            (#"{"tasks":[]}"#, "Error: tasks must be a non-empty array"),
            (#"{"tasks":["nope"]}"#, "Error: task 1 is not an object."),
            (#"{"tasks":[{"description":"a"}]}"#, "Error: task 1 has no prompt."),
            (#"{"tasks":[{"description":"a","prompt":"   "}]}"#, "Error: task 1 has no prompt."),
            (#"{"tasks":[{"prompt":"ok"},{"prompt":"p","agent_type":"wizard"}]}"#, "Error: task 2 has an unknown agent_type 'wizard'"),
            (#"{"tasks":[{"prompt":"p","agent_type":"wizard"}]}"#, "Error: task 1 has an unknown agent_type 'wizard'"),
            (#"{"tasks":"not json"}"#, "Error: tasks must be a non-empty array"),
        ]
        for (arguments, expected) in cases {
            let client = ScriptedClient(turns: [])
            let result = await DelegateTool().execute(args: JSONString(arguments), in: context(client))
            XCTAssertTrue(result.output.hasPrefix(expected), "\(arguments) → \(result.output)")
            XCTAssertTrue(client.requests.isEmpty, arguments)
        }
    }

    func testDelegateHasALimitAndNoNesting() async {
        let many = (0..<13).map { #"{"description":"t\#($0)","prompt":"p"}"# }.joined(separator: ",")
        let over = await DelegateTool().execute(args: JSONString(#"{"tasks":[\#(many)]}"#), in: context(ScriptedClient(turns: [])))
        XCTAssertTrue(over.output.hasPrefix("Error: at most 12 tasks"), over.output)
        let nested = await DelegateTool().execute(args: #"{"tasks":[{"prompt":"p"}]}"#, in: context(ScriptedClient(turns: []), depth: 1))
        XCTAssertEqual(nested.output, "Error: nested subagents are not allowed (depth limit).")
    }

    func testDelegateAcceptsTasksSentAsAString() async throws {
        let client = FleetReportsClient("ok")
        let encoded = try JSONSerialization.data(withJSONObject: ["tasks": #"[{"description":"a","prompt":"p"}]"#])
        let result = await DelegateTool().execute(args: JSONString(String(decoding: encoded, as: UTF8.self)), in: context(client))
        XCTAssertTrue(result.output.hasPrefix("Delegated 1 task: 1 finished"), result.output)
    }

    func testDelegateStoppedMidwayStopsEveryTaskAndSaysSo() async throws {
        let blocking = FleetBlockingClient()
        let roster = AgentRoster()
        let ctx = context(blocking, roster: roster)
        let running = FleetPending {
            await DelegateTool().execute(args: #"{"tasks":[{"prompt":"1"},{"prompt":"2"}]}"#, in: ctx)
        }
        let started = await fleetEventually { roster.running.count == 2 }
        XCTAssertTrue(started)
        running.cancel()
        let result = try await running.value()
        XCTAssertEqual(result.output, "Error: cancelled by user.")
        XCTAssertEqual(roster.all.map(\.status), [.stopped, .stopped])
    }

    func testRegistryOffersDelegateOnlyAtTheTopLevel() {
        XCTAssertTrue(ToolRegistry.standard(depth: 0).names.contains(DelegateTool.name))
        XCTAssertFalse(ToolRegistry.standard(depth: 1).names.contains(DelegateTool.name))
        XCTAssertTrue(ToolRegistry.standard(depth: 0).names.contains(AgentTool.name))
        XCTAssertFalse(ToolRegistry.standard(depth: 1).names.contains(AgentTool.name))
        XCTAssertEqual(DelegateTool.name, "delegate")
    }

    // MARK: - Concurrent agent calls inside one engine turn

    private func engine(_ parent: any LLMClient, fleet: AgentFleet?, roster: AgentRoster?) -> Engine {
        Engine(client: parent, registry: ToolRegistry.standard(), systemPrompt: "system",
               config: EngineConfig(model: "parent", retry: fleetFastRetry),
               workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
               permissionGate: { _, _, _ in true }, fleet: fleet, roster: roster)
    }

    func testTwoAgentCallsInOneTurnRunOnTwoServersAtTheSameTime() async throws {
        let meeting = FleetMeeting(parties: 2)
        let fleet = AgentFleet()
        fleet.configure([fleetServer("spark-2", FleetRendezvousClient(meeting: meeting, name: "spark-2"), max: 1),
                         fleetServer("spark-3", FleetRendezvousClient(meeting: meeting, name: "spark-3"), max: 1)])
        let calls = [ToolCall(id: "a1", name: "agent", arguments: #"{"description":"left","prompt":"look left"}"#),
                     ToolCall(id: "a2", name: "agent", arguments: #"{"description":"right","prompt":"look right"}"#)]
        let parent = ScriptedClient(turns: [.init(calls: calls), .init(text: "all reported")])
        let roster = AgentRoster()

        let result = try await engine(parent, fleet: fleet, roster: roster).run(messages: [], userText: "check both", sink: { _ in })

        let tools = result.messages.filter { $0.role == .tool }
        XCTAssertEqual(tools.compactMap(\.toolCallID), ["a1", "a2"])
        XCTAssertTrue(tools.allSatisfy { ($0.content ?? "").contains(": together") }, "\(tools.map { $0.content ?? "" })")
        XCTAssertTrue(tools.contains { ($0.content ?? "").contains("spark-2: together") })
        XCTAssertTrue(tools.contains { ($0.content ?? "").contains("spark-3: together") })
        XCTAssertEqual(result.finalText, "all reported")
        XCTAssertEqual(roster.all.filter { $0.status == .done }.count, 2)
    }

    func testBackgroundAgentsUseTheFleetToo() async throws {
        let fleet = AgentFleet()
        fleet.configure([fleetServer("main", FleetReportsClient("never asked"), primary: true),
                         fleetServer("spark-2", FleetReportsClient("background report"), max: 1)])
        let pool = BackgroundAgents()
        let roster = AgentRoster()
        let ctx = context(ScriptedClient(turns: []), fleet: fleet, roster: roster, background: pool)
        let started = await AgentTool().execute(args: #"{"description":"bg","prompt":"p","run_in_background":true}"#, in: ctx)
        XCTAssertTrue(started.output.hasPrefix("Started background agent bg-1"), started.output)
        let job = await pool.wait("bg-1", timeout: 5)
        XCTAssertEqual(job?.status, .done)
        XCTAssertEqual(job?.report, "background report")
        let run = try XCTUnwrap(roster.all.first)
        XCTAssertEqual(roster.all.count, 1)
        XCTAssertTrue(run.isBackground)
        XCTAssertEqual(run.server, "spark-2")
    }

    func testStoppingABackgroundAgentFreesItsServerAndMarksItStopped() async throws {
        let fleet = AgentFleet()
        let blocking = FleetBlockingClient()
        fleet.configure([fleetServer("only", blocking, max: 1)])
        let pool = BackgroundAgents()
        let roster = AgentRoster()
        let ctx = context(ScriptedClient(turns: []), fleet: fleet, roster: roster, background: pool)
        _ = await AgentTool().execute(args: #"{"description":"bg","prompt":"p","run_in_background":true}"#, in: ctx)
        let busy = await fleetEventually { blocking.hasStarted && fleet.snapshot()[0].inFlight == 1 }
        XCTAssertTrue(busy)

        XCTAssertTrue(pool.stop("bg-1"))
        let freed = await fleetEventually { fleet.snapshot()[0].inFlight == 0 && roster.all.first?.status == .stopped }
        XCTAssertTrue(freed, "slot: \(fleet.snapshot()[0].inFlight), run: \(String(describing: roster.all.first?.status))")
        XCTAssertEqual(pool.job("bg-1")?.status, .stopped)
        XCTAssertEqual(fleet.snapshot()[0].completed, 0, "a stopped run is not counted as work")
        XCTAssertTrue(fleet.snapshot()[0].healthy)
    }

    // MARK: - Review fixes

    func testALoneServerIsWaitedOutNotGivenUpOn() async {
        // With nowhere else to go, a subagent waits for its server as long as the main agent would.
        let fleet = AgentFleet()
        let flaky = FlakyClient(failures: 6, error: LLMError.connection("restarting"), turns: [.init(text: "back again")])
        fleet.configure([fleetServer("only", flaky, primary: true)])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' finished."), result.output)
        XCTAssertTrue(result.output.contains("back again"), result.output)
        XCTAssertEqual(flaky.calls, 7)
    }

    func testALoneServerThatRefusesIsAskedOnceNotOverAndOver() async {
        // There is nowhere to fail over to, so "another attempt" would only be the same request again.
        let refuses = FleetRefusingClient(LLMError.http(401, "bad key"))
        let fleet = AgentFleet()
        fleet.configure([fleetServer("only", refuses, primary: true)])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.contains("failed"), result.output)
        XCTAssertEqual(refuses.asked, 1)
    }

    func testAServerFaultWithSeveralServersStillFailsOver() async {
        let refuses = FleetRefusingClient(LLMError.http(401, "bad key"))
        let healthy = FleetReportsClient("all done")
        let fleet = AgentFleet()
        fleet.configure([fleetServer("a", refuses), fleetServer("b", healthy)])
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.contains("all done"), result.output)
        XCTAssertEqual(refuses.asked, 1)
    }

    func testATaskFailsOverAtMostTwiceThenReportsTheFailure() async throws {
        let fleet = AgentFleet()
        let clients = (0..<4).map { _ in FleetRefusingClient(LLMError.http(503, "busy")) }
        fleet.configure(clients.enumerated().map { fleetServer("s\($0.offset)", $0.element) })
        let result = await AgentTool().execute(args: #"{"description":"scan","prompt":"p"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertTrue(result.output.hasPrefix("Subagent 'scan' failed: "), result.output)
        XCTAssertTrue(result.output.contains("after 2 server failures"), result.output)
        // A 503 is retried twice quickly on each server it lands on: three servers tried, none left over.
        XCTAssertEqual(clients.map(\.asked).reduce(0, +), 9)
        XCTAssertEqual(clients[3].asked, 0)
    }

    func testAFailoverAfterChangesTellsTheNextAttemptToLookFirst() async throws {
        let fleet = AgentFleet()
        let healthy = FleetReportsClient("all done")
        fleet.configure([fleetServer("a", FleetWritesThenDiesClient()), fleetServer("b", healthy)])
        let ctx = context(ScriptedClient(turns: []), fleet: fleet, registry: ToolRegistry(tools: [EchoTool()]))

        let result = await AgentTool().execute(args: #"{"description":"migrate","prompt":"add the migration"}"#, in: ctx)

        XCTAssertTrue(result.output.contains("all done"), result.output)
        let first = try XCTUnwrap(healthy.requests.first?.messages.first { $0.role == .user }?.content)
        XCTAssertTrue(first.hasPrefix("[Note: an earlier attempt"), first)
        XCTAssertTrue(first.contains("add the migration"), first)
    }

    func testAFailoverAfterOnlyReadingDoesNotWarnTheNextAttempt() async throws {
        // Reading changes nothing, so there is nothing for the next attempt to be careful about.
        let fleet = AgentFleet()
        let healthy = FleetReportsClient("all done")
        let reads = FleetScriptedThenDiesClient(firstTurn: ScriptedClient.Turn(calls: [ToolCall(id: "r1", name: "read_file", arguments: "{}")]))
        fleet.configure([fleetServer("a", reads), fleetServer("b", healthy)])
        let ctx = context(ScriptedClient(turns: []), fleet: fleet, registry: ToolRegistry(tools: [ReadOnlyEcho()]))
        let result = await AgentTool().execute(args: #"{"description":"look","prompt":"read it"}"#, in: ctx)
        XCTAssertTrue(result.output.contains("all done"), result.output)
        let first = try XCTUnwrap(healthy.requests.first?.messages.first { $0.role == .user }?.content)
        XCTAssertEqual(first, "read it")
    }

    func testADeniedCallIsNotAChange() async throws {
        // A write the gate refused never ran, so a failover after it needs no warning.
        let fleet = AgentFleet()
        let healthy = FleetReportsClient("all done")
        let dies = FleetScriptedThenDiesClient(firstTurn: ScriptedClient.Turn(calls: [
            ToolCall(id: "w1", name: "write_file", arguments: #"{"file_path":"/tmp/elsewhere/refused.txt","content":"x"}"#)]))
        fleet.configure([fleetServer("a", dies), fleetServer("b", healthy)])
        let base = context(ScriptedClient(turns: []), fleet: fleet)
        let ctx = ToolContext(workspace: base.workspace, policy: base.policy, client: base.client, registry: base.registry,
                              depth: 0, model: base.model, requestPermission: { _, _, _ in false },
                              fleet: fleet, retry: fleetFastRetry)
        _ = await AgentTool().execute(args: #"{"description":"write","prompt":"write a file"}"#, in: ctx)
        let first = try XCTUnwrap(healthy.requests.first?.messages.first { $0.role == .user }?.content)
        XCTAssertEqual(first, "write a file")
    }

    func testAFailoverBeforeAnyChangeReplaysTheTaskAsWritten() async throws {
        let fleet = AgentFleet()
        let healthy = FleetReportsClient("all done")
        fleet.configure([fleetServer("a", FlakyClient(failures: Int.max, error: LLMError.connection("down"), turns: [])),
                         fleetServer("b", healthy)])
        _ = await AgentTool().execute(args: #"{"description":"scan","prompt":"count the files"}"#,
                                      in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertEqual(healthy.requests.first?.messages.first { $0.role == .user }?.content, "count the files")
    }

    func testASubagentUsesTheLeasedRoutesOwnSettings() async {
        let client = FleetReportsClient("ok")
        let fleet = AgentFleet()
        fleet.configure([FleetServer(id: "x", label: "x", isPrimary: false, maxParallel: 1, resolve: {
            FleetTarget(client: client, model: "model-x", contextWindow: 8_000, temperature: 0.3, maxOutputTokens: 777)
        })])
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: context(ScriptedClient(turns: []), fleet: fleet))
        XCTAssertEqual(client.requests.first?.maxTokens, 777)
        XCTAssertEqual(client.requests.first?.temperature, 0.3)
    }

    func testASubagentInheritsTheParentsSettingsWhereTheRouteHasNone() async {
        let client = FleetReportsClient("ok")
        let ctx = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                              client: client, registry: ToolRegistry.standard(), model: "parent-model", contextWindow: 8_000,
                              thinking: .high, temperature: 0.7, maxOutputTokens: 1_234)
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: ctx)
        let request = client.requests.first
        XCTAssertEqual(request?.model, "parent-model")
        XCTAssertEqual(request?.temperature, 0.7)
        XCTAssertEqual(request?.maxTokens, 1_234)
        XCTAssertEqual(request?.thinking, .high)
    }

    func testDisallowedToolsAreRemovedFromASubagent() async {
        let careful = AgentDefinition(name: "careful", description: "no echo", disallowedTools: ["echo"])
        let catalog = AgentCatalog(AgentDefinition.builtIn + [careful])
        let client = FleetReportsClient("ok")
        let ctx = context(client, registry: ToolRegistry(tools: [EchoTool(), ReadFileTool()]), catalog: catalog)
        _ = await AgentTool(catalog: catalog).execute(args: #"{"description":"d","prompt":"p","agent_type":"careful"}"#, in: ctx)
        let offered = client.requests.first?.tools.map(\.name) ?? []
        XCTAssertFalse(offered.contains("echo"))
        XCTAssertTrue(offered.contains("read_file"))
    }

    func testAnAgentTypeCanPreferAServer() async {
        let fleet = AgentFleet()
        let spark2 = FleetReportsClient("from spark-2")
        let spark3 = FleetReportsClient("from spark-3")
        fleet.configure([fleetServer("main", FleetReportsClient("main"), primary: true), fleetServer("spark-2", spark2),
                         fleetServer("spark-3", spark3)])
        let catalog = AgentCatalog(AgentDefinition.builtIn + [AgentDefinition(name: "big", description: "d", server: "spark-3")])
        let result = await AgentTool().execute(args: #"{"description":"d","prompt":"p","agent_type":"big"}"#,
                                               in: context(ScriptedClient(turns: []), fleet: fleet, catalog: catalog))
        XCTAssertTrue(result.output.contains("from spark-3"), result.output)
        XCTAssertTrue(result.output.contains("big agent · on spark-3"), result.output)
        XCTAssertTrue(spark2.requests.isEmpty)
    }
}

/// A read-only tool under the name of a tool that reads, so running it is not a change.
private struct ReadOnlyEcho: ToolExecutor {
    static let name = "read_file"
    static let spec = ToolSpec(name: name, description: "reads", parameters: #"{"type":"object","properties":{}}"#)
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult { ToolResult(output: "contents") }
}

/// Answers its first request with a scripted turn (typically a tool call), then loses its connection.
private final class FleetScriptedThenDiesClient: LLMClient, @unchecked Sendable {
    private let calls = FleetCounter()
    private let firstTurn: ScriptedClient.Turn

    init(firstTurn: ScriptedClient.Turn) { self.firstTurn = firstTurn }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        calls.bump()
        let first = calls.value == 1
        let turn = firstTurn
        return AsyncThrowingStream { continuation in
            if first {
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
                continuation.finish()
            } else {
                continuation.finish(throwing: LLMError.connection("the server went away"))
            }
        }
    }

    func listModels() async throws -> [String] { ["m"] }
}
