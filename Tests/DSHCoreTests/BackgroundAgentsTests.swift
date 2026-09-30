import XCTest
@testable import DSHCore

/// Answers main-agent and subagent requests from separate scripts (a
/// subagent's system prompt starts "You are a focused subagent").
final class RoleScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var main: [ScriptedClient.Turn]
    private let sub: @Sendable (String) -> String
    private(set) var mainRequests: [LLMRequest] = []

    init(main: [ScriptedClient.Turn], sub: @escaping @Sendable (String) -> String) {
        self.main = main
        self.sub = sub
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let isSub = request.systemPrompt.hasPrefix("You are a focused subagent")
        let turn: ScriptedClient.Turn = lock.withLock {
            if isSub {
                let task = request.messages.first(where: { $0.role == .user })?.content ?? ""
                return .init(text: sub(task))
            }
            mainRequests.append(request)
            return main.isEmpty ? .init(text: "done") : main.removeFirst()
        }
        return AsyncThrowingStream { c in
            for ch in turn.text.map(String.init) { c.yield(.text(ch)) }
            c.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
            c.finish()
        }
    }
    func listModels() async throws -> [String] { [] }
}

final class BackgroundAgentsTests: XCTestCase {

    func testPoolLifecycle() async {
        let pool = BackgroundAgents(maxConcurrent: 2)
        let changes = SeenArgs()
        pool.onChange = { changes.append("\($0.id):\($0.status.rawValue)") }
        guard case .success(let fast) = pool.launch(description: "fast", work: { (true, "fast report") }) else {
            return XCTFail("launch failed")
        }
        guard case .success(let slow) = pool.launch(description: "slow", work: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return (true, "slow report")
        }) else { return XCTFail("launch failed") }
        let finished = await pool.wait(fast.id, timeout: 5)
        XCTAssertEqual(finished?.status, .done)
        XCTAssertEqual(finished?.report, "fast report")
        // Only two at once.
        guard case .success(let third) = pool.launch(description: "third", work: {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return (true, "")
        }) else {
            return XCTFail("a slot freed up when fast finished")
        }
        if case .success = pool.launch(description: "fourth", work: { try? await Task.sleep(nanoseconds: 5_000_000_000); return (true, "") }) {
            XCTFail("over the limit")
        }
        // Waiting on a running job times out quickly.
        let stillRunning = await pool.wait(slow.id, timeout: 0.2)
        XCTAssertEqual(stillRunning?.status, .running)
        XCTAssertTrue(pool.stop(slow.id))
        pool.stop(third.id)
        XCTAssertEqual(pool.job(slow.id)?.status, .stopped)
        // Finished (not stopped) jobs are reported once.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let unreported = pool.takeUnreported().map(\.id)
        XCTAssertTrue(unreported.contains(fast.id))
        XCTAssertFalse(unreported.contains(slow.id))
        XCTAssertTrue(pool.takeUnreported().isEmpty)
        XCTAssertTrue(changes.all.contains("\(fast.id):done"))
        XCTAssertTrue(BackgroundAgents.notice(for: [finished!]).contains("fast report"))
    }

    private func engine(_ client: any LLMClient, pool: BackgroundAgents) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let registry = ToolRegistry(tools: [AgentTool(), EchoTool()] + ToolRegistry.backgroundAgentTools())
        return Engine(client: client, registry: registry, systemPrompt: "main", config: .init(maxIterations: 8, model: "m"),
                      workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                      permissionGate: { _, _, _ in true }, backgroundAgents: pool)
    }

    func testLaunchInBackgroundThenCollectTheReport() async throws {
        let launch = ToolCall(id: "1", name: "agent",
                              arguments: #"{"description":"scan","prompt":"find TODOs","run_in_background":true}"#)
        let status = ToolCall(id: "2", name: "agent_status", arguments: #"{"id":"bg-1","wait_seconds":10}"#)
        let client = RoleScriptedClient(main: [.init(calls: [launch]), .init(calls: [status]), .init(text: "All collected.")],
                                        sub: { task in "found 3 TODOs for: \(task)" })
        let pool = BackgroundAgents()
        let result = try await engine(client, pool: pool).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.finalText, "All collected.")
        let toolResults = result.messages.filter { $0.role == .tool }.compactMap(\.content)
        XCTAssertTrue(toolResults[0].hasPrefix("Started background agent bg-1"), toolResults[0])
        XCTAssertTrue(toolResults[1].contains("found 3 TODOs for: find TODOs"), toolResults[1])
        XCTAssertEqual(pool.job("bg-1")?.status, .done)
        // Read via agent_status: not announced again.
        XCTAssertTrue(pool.takeUnreported().isEmpty)
    }

    func testFinishedAgentsAreAnnouncedAutomatically() async throws {
        let pool = BackgroundAgents()
        _ = pool.launch(description: "tests", work: { (true, "12 tests pass") })
        _ = await pool.wait("bg-1", timeout: 5)
        let client = RoleScriptedClient(main: [.init(text: "noted")], sub: { _ in "" })
        _ = try await engine(client, pool: pool).run(messages: [], userText: "what's up?", sink: { _ in })
        let sent = client.mainRequests.first?.messages.last?.content ?? ""
        XCTAssertTrue(sent.hasPrefix("what's up?"))
        XCTAssertTrue(sent.contains("[Automatic message: a background agent finished"))
        XCTAssertTrue(sent.contains("12 tests pass"))
    }

    func testBackgroundNeedsAPoolAndSubagentsCantNest() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let out = await AgentTool().execute(args: #"{"description":"x","prompt":"y","run_in_background":true}"#, in: ctx).output
        XCTAssertTrue(out.hasPrefix("Error: background subagents aren't available"))
        let status = await AgentStatusTool().execute(args: "{}", in: ctx).output
        XCTAssertTrue(status.hasPrefix("Error"))
        let nestedCtx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                                    client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []), depth: 1)
        let nested = await AgentTool().execute(args: #"{"description":"x","prompt":"y"}"#, in: nestedCtx).output
        XCTAssertTrue(nested.contains("nested subagents"), nested)
    }

    func testSubagentsDoNotGetTheAgentOrQueueTools() {
        let registry = ToolRegistry(tools: [AgentTool(), DelegateTool(), EchoTool()] + ToolRegistry.backgroundAgentTools()
                                    + [QueueAddTool(add: { _, _, _, _ in "" })])
        let sub = registry.removing(AgentTool.name, DelegateTool.name, AgentStatusTool.name, AgentStopTool.name, QueueAddTool.name)
        XCTAssertEqual(sub.names, ["echo"])
        XCTAssertEqual(registry.removing(["echo", "agent"]).names, ["delegate", "agent_status", "agent_stop", "queue_task"])
        XCTAssertEqual(registry.only(["agent_stop", "echo", "nothing"]).names, ["echo", "agent_stop"], "the registry's own order")
    }

    // MARK: - The pool

    private struct Kaput: LocalizedError {
        var errorDescription: String? { "kaput" }
    }

    func testAFailingOrThrowingJobIsReportedAsFailed() async {
        let pool = BackgroundAgents()
        guard case .success(let a) = pool.launch(description: "a", work: { (false, "the server said no") }),
              case .success(let b) = pool.launch(description: "b", work: { throw Kaput() }) else {
            return XCTFail("launch failed")
        }
        let first = await pool.wait(a.id, timeout: 5)
        XCTAssertEqual(first?.status, .failed)
        XCTAssertEqual(first?.report, "the server said no")
        let second = await pool.wait(b.id, timeout: 5)
        XCTAssertEqual(second?.status, .failed)
        XCTAssertEqual(second?.report, "kaput")
        // A failure is announced to the main agent like a success.
        XCTAssertEqual(Set(pool.takeUnreported().map(\.id)), [a.id, b.id])
    }

    func testReportsThatNeverReachedTheModelCanBeAnnouncedAgain() async {
        let pool = BackgroundAgents()
        guard case .success(let done) = pool.launch(description: "done", work: { (true, "report") }),
              case .success(let stopped) = pool.launch(description: "stopped", work: {
                  while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                  return (true, "")
              }) else { return XCTFail("launch failed") }
        _ = await pool.wait(done.id, timeout: 5)
        pool.stop(stopped.id)
        let taken = pool.takeUnreported()
        XCTAssertEqual(taken.map(\.id), [done.id])
        XCTAssertFalse(pool.hasUnreported)

        // The request that carried them failed: they come back — but a stopped job is never announced, and nothing twice.
        pool.requeue(taken + [pool.job(stopped.id)!])
        pool.requeue(taken)
        XCTAssertTrue(pool.hasUnreported)
        XCTAssertEqual(pool.takeUnreported().map(\.id), [done.id])
        XCTAssertFalse(pool.hasUnreported)
    }

    func testARunningJobIsNotRequeued() async {
        let pool = BackgroundAgents()
        guard case .success(let running) = pool.launch(description: "long", work: {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (true, "")
        }) else { return XCTFail("launch failed") }
        pool.requeue([running])
        XCTAssertFalse(pool.hasUnreported)
        pool.requeue([BackgroundAgents.Job(id: "bg-99", description: "unknown", startedAt: .now, status: .done)])
        XCTAssertFalse(pool.hasUnreported)
        pool.stopAll()
    }

    func testAListenerThatLooksAtThePoolCannotLeaveAJobStuck() async {
        // (A C# listener could throw; a Swift one can't. What it can do is look at the pool — even ask it for more — while
        // it is told, which must neither deadlock nor lose the slot.)
        let pool = BackgroundAgents(maxConcurrent: 1)
        let heard = SeenArgs()
        pool.onChange = { [unowned pool] job in
            _ = pool.all
            _ = pool.running
            heard.append("\(job.id):\(job.status.rawValue)")
        }
        guard case .success(let job) = pool.launch(description: "first", work: { (true, "report") }) else {
            return XCTFail("launch failed")
        }
        let finished = await pool.wait(job.id, timeout: 5)
        XCTAssertEqual(finished?.status, .done)
        let told = await fleetEventually { heard.all.contains("\(job.id):done") }
        XCTAssertTrue(told)
        // The one slot was given back: another can start.
        guard case .success = pool.launch(description: "second", work: { (true, "again") }) else {
            return XCTFail("the slot was not given back")
        }
    }

    func testAJobIsAnnouncedStartedBeforeItIsAnnouncedFinished() async {
        // A job that ends the moment it starts must not be seen finishing first — the UI would then show it running for ever.
        // A listener that is slow to hear "started" gives the job every chance to finish first; a hundred quick rounds
        // check the same thing without the help.
        for round in 0..<105 {
            let slow = round < 5
            let pool = BackgroundAgents()
            let heard = SeenArgs()
            pool.onChange = { job in
                if slow && job.status == .running { Thread.sleep(forTimeInterval: 0.04) }
                heard.append(job.status.rawValue)
            }
            guard case .success = pool.launch(description: "instant", work: { (true, "ok") }) else {
                return XCTFail("launch failed")
            }
            let settled = await fleetEventually(1) { heard.all.count == 2 }
            guard settled, heard.all == ["running", "done"] else {
                return XCTFail("round \(round): announced \(heard.all), expected [running, done]")
            }
        }
    }

    func testARefusedLaunchDoesNotUseUpAnId() async {
        let pool = BackgroundAgents(maxConcurrent: 1)
        guard case .success(let first) = pool.launch(description: "long", work: {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (true, "")
        }) else { return XCTFail("launch failed") }
        XCTAssertEqual(first.id, "bg-1")
        guard case .failure(let refused) = pool.launch(description: "one too many", work: { (true, "") }) else {
            return XCTFail("over the limit")
        }
        XCTAssertEqual(refused, .tooMany(1))
        XCTAssertEqual(refused.errorDescription, "1 background agents are already running — wait for one (agent_status with wait_seconds) or stop one first.")
        pool.stop(first.id)
        guard case .success(let next) = pool.launch(description: "next", work: { (true, "") }) else {
            return XCTFail("launch failed")
        }
        XCTAssertEqual(next.id, "bg-2", "the refused launch took no id")
    }

    func testStoppingRightAfterLaunchCancelsTheWork() async {
        let pool = BackgroundAgents()
        let sawCancel = FleetCounter()
        guard case .success(let job) = pool.launch(description: "long", work: {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            sawCancel.bump()
            return (true, "finished anyway")
        }) else { return XCTFail("launch failed") }
        XCTAssertTrue(pool.stop(job.id))
        let cancelled = await fleetEventually { sawCancel.value == 1 }
        XCTAssertTrue(cancelled, "the work must be told to stop, not left running")
        XCTAssertEqual(pool.job(job.id)?.status, .stopped)
        XCTAssertEqual(pool.job(job.id)?.report, "Stopped before it finished.", "a stopped job keeps the words it was stopped with")
        XCTAssertFalse(pool.stop(job.id))
        XCTAssertTrue(pool.takeUnreported().isEmpty, "a stopped job is never announced")
    }

    func testLaunchingAndStoppingFromManyTasksLeavesNothingRunning() async throws {
        let pool = BackgroundAgents(maxConcurrent: 500)
        let told = FleetLog<String>()
        pool.onChange = { told.append("\($0.id):\($0.status.rawValue)") }
        try await fleetBounded {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<200 {
                    group.addTask {
                        guard case .success(let job) = pool.launch(description: "long", work: {
                            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                            return (true, "")
                        }) else { return }
                        if Int.random(in: 0..<2) == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
                        pool.stop(job.id)
                    }
                }
            }
        }
        XCTAssertEqual(pool.all.count, 200)
        XCTAssertTrue(pool.running.isEmpty)
        XCTAssertTrue(pool.all.allSatisfy { $0.status == .stopped })
        XCTAssertFalse(pool.hasUnreported)
        XCTAssertEqual(Set(pool.all.map(\.id)).count, 200)
        // Every job was announced once as started and once as stopped, the start first.
        let events = told.all
        XCTAssertEqual(events.count, 400)
        for job in pool.all {
            let mine = events.filter { $0.hasPrefix(job.id + ":") }
            XCTAssertEqual(mine, [job.id + ":running", job.id + ":stopped"])
        }
    }

    func testAgentStatusListsJobsAndAnswersForOne() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let pool = BackgroundAgents()
        let ctx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []), backgroundAgents: pool)
        let none = await AgentStatusTool().execute(args: "{}", in: ctx).output
        XCTAssertEqual(none, "No background agents have been started in this chat.")

        guard case .success(let done) = pool.launch(description: "quick", work: { (true, "first line\nsecond line") }),
              case .success(let long) = pool.launch(description: "long", work: {
                  while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
                  return (true, "")
              }) else { return XCTFail("launch failed") }
        _ = await pool.wait(done.id, timeout: 5)

        let list = await AgentStatusTool().execute(args: "{}", in: ctx).output
        XCTAssertTrue(list.hasPrefix("Background agents:\n- bg-1 “quick”: done, "), list)
        XCTAssertTrue(list.contains(" — first line"), list)
        XCTAssertFalse(list.contains("second line"), list)
        XCTAssertTrue(list.contains("- bg-2 “long”: running, "), list)

        let one = await AgentStatusTool().execute(args: #"{"id":" bg-1 "}"#, in: ctx).output
        XCTAssertTrue(one.hasPrefix("bg-1 “quick” done after "), one)
        XCTAssertTrue(one.hasSuffix("first line\nsecond line"), one)
        XCTAssertFalse(pool.hasUnreported, "reading it counts as announcing it")

        let running = await AgentStatusTool().execute(args: #"{"id":"bg-2"}"#, in: ctx).output
        XCTAssertTrue(running.hasPrefix("bg-2 “long” is still running ("), running)
        let unknown = await AgentStatusTool().execute(args: #"{"id":"bg-9"}"#, in: ctx).output
        XCTAssertEqual(unknown, "Error: no background agent bg-9. agent_status without an id lists them.")

        let stop = await AgentStopTool().execute(args: #"{"id":" bg-2 "}"#, in: ctx).output
        XCTAssertEqual(stop, "Stopped bg-2.")
        let again = await AgentStopTool().execute(args: #"{"id":"bg-2"}"#, in: ctx).output
        XCTAssertEqual(again, "Error: bg-2 isn't a running background agent.")
        _ = long
    }

    func testQueueTaskToolPassesItsArguments() async {
        let seen = SeenArgs()
        let tool = QueueAddTool(add: { title, details, front, start in
            seen.append("\(title)|\(details)|\(front)|\(start)")
            return "queued"
        })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let ctx = ToolContext(workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        let out = await tool.execute(args: #"{"title":" Write tests ","details":"for the parser","start":true}"#, in: ctx).output
        XCTAssertEqual(out, "queued")
        XCTAssertEqual(seen.all, ["Write tests|for the parser|false|true"])
        let missing = await tool.execute(args: #"{"details":"x"}"#, in: ctx).output
        XCTAssertTrue(missing.hasPrefix("Error"))
    }
}
