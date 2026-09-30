import XCTest
@testable import DSHCore

/// The engine's side of the subagent fleet: what it hands the tools, how it runs several subagents in one
/// reply, and how a run that used its whole step budget still reports.
final class SubagentEngineTests: XCTestCase {
    private var root: FleetTestDirectory!

    override func setUp() {
        super.setUp()
        root = FleetTestDirectory("dsh-subagent-engine")
    }

    override func tearDown() {
        root.remove()
        super.tearDown()
    }

    private func engine(_ client: any LLMClient, tools: [any ToolExecutor], config: EngineConfig,
                        gate: @escaping @Sendable (String, String, String) async -> Bool = { _, _, _ in true },
                        vault: CredentialVault? = nil, fleet: AgentFleet? = nil, roster: AgentRoster? = nil,
                        agentTypes: AgentCatalog? = nil) -> Engine {
        Engine(client: client, registry: ToolRegistry(tools: tools), systemPrompt: "system", config: config,
               workspace: root.url, policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
               permissionGate: gate, vault: vault, fleet: fleet, roster: roster, agentTypes: agentTypes)
    }

    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ToolCall {
        ToolCall(id: id, name: name, arguments: arguments)
    }

    // MARK: - What the tools are handed

    func testToolsAreHandedTheFleetTheRosterTheTypesAndTheRunsOwnSettings() async throws {
        let capture = FleetCapturingTool()
        let fleet = AgentFleet()
        let roster = AgentRoster()
        let types = AgentCatalog(AgentDefinition.builtIn + [AgentDefinition(name: "docs", description: "Writes documentation")])
        var config = EngineConfig(model: "parent-model", temperature: 0.4, maxOutputTokens: 900, contextWindow: 12_345,
                                  thinking: .high, visionEnabled: false,
                                  retry: RetryPolicy(delay: { _ in 0 }, maxFailures: 3))
        config.depth = 0
        let client = ScriptedClient(turns: [.init(calls: [call("c1", "capture")]), .init(text: "done")])
        _ = try await engine(client, tools: [capture], config: config, fleet: fleet, roster: roster, agentTypes: types)
            .run(messages: [], userText: "go", sink: { _ in })

        let seen = try XCTUnwrap(capture.contexts.first)
        XCTAssertTrue(seen.fleet === fleet)
        XCTAssertTrue(seen.roster === roster)
        XCTAssertEqual(seen.agentTypes, types)
        XCTAssertEqual(seen.retry?.maxFailures, 3)
        XCTAssertEqual(seen.temperature, 0.4)
        XCTAssertEqual(seen.maxOutputTokens, 900)
        XCTAssertFalse(seen.visionEnabled)
        XCTAssertEqual(seen.contextWindow, 12_345)
        XCTAssertEqual(seen.thinking, .high)
        XCTAssertEqual(seen.model, "parent-model")
        XCTAssertEqual(seen.depth, 0)
    }

    func testAToolContextNeedsNoFleetToWork() throws {
        // The new fields all default, so every existing way of building a context still compiles and means what it did.
        let ctx = ToolContext(workspace: root.url, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root.url),
                              client: ScriptedClient(turns: []), registry: ToolRegistry(tools: []))
        XCTAssertNil(ctx.fleet)
        XCTAssertNil(ctx.roster)
        XCTAssertNil(ctx.agentTypes)
        XCTAssertNil(ctx.retry)
        XCTAssertTrue(ctx.visionEnabled)
        XCTAssertNil(ctx.temperature)
        XCTAssertNil(ctx.maxOutputTokens)
    }

    func testTheEnginesDepthReachesTheTools() async throws {
        let capture = FleetCapturingTool()
        var config = EngineConfig(model: "m")
        config.depth = 1
        let client = ScriptedClient(turns: [.init(calls: [call("c1", "capture")]), .init(text: "done")])
        _ = try await engine(client, tools: [capture], config: config).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(capture.contexts.first?.depth, 1)
    }

    func testASubagentsToolsRunOneLevelDown() async throws {
        let capture = FleetCapturingTool()
        let client = ScriptedClient(turns: [.init(calls: [call("c1", "capture")]), .init(text: "the report")])
        let ctx = fleetContext(client, root: root.url, registry: ToolRegistry(tools: [capture]))
        _ = await AgentTool().execute(args: #"{"description":"d","prompt":"p"}"#, in: ctx)
        XCTAssertEqual(capture.contexts.first?.depth, 1, "so a tool the subagent has cannot start subagents of its own")
    }

    // MARK: - The step budget and the wrap-up

    func testARunThatUsesItsWholeBudgetIsAskedForAReport() async throws {
        var config = EngineConfig(maxIterations: 2, model: "m")
        config.wrapUpAtLimit = true
        let client = ScriptedClient(turns: [.init(calls: [call("a", "echo", #"{"text":"1"}"#)]),
                                            .init(calls: [call("b", "echo", #"{"text":"2"}"#)]),
                                            .init(text: "Here is what I found.")])
        let events = FleetEvents()
        let result = try await engine(client, tools: [EchoTool()], config: config).run(messages: [], userText: "go", sink: events.sink)

        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(result.finalText, "Here is what I found.")
        XCTAssertEqual(result.lastReplyText, "Here is what I found.")
        XCTAssertTrue(result.hitIterationLimit)
        XCTAssertEqual(result.messages.last?.role, .assistant)
        XCTAssertEqual(result.messages.last?.content, "Here is what I found.")
        // The request for it names the tools still (the transcript has tool calls in it) and asks for no more of them.
        let ask = try XCTUnwrap(client.requests.dropFirst(2).first)
        XCTAssertFalse(ask.tools.isEmpty)
        XCTAssertEqual(ask.messages.last?.role, .user)
        XCTAssertEqual(ask.messages.last?.imageSource, "step limit")
        XCTAssertTrue(ask.messages.last?.content?.contains("Do not call any tools.") ?? false)
        XCTAssertTrue(events.all.contains("assistant wrap-up"))
        XCTAssertEqual(events.all.last, "finished run")
    }

    func testNoReportIsAskedForUnlessTheEngineWasToldTo() async throws {
        let config = EngineConfig(maxIterations: 2, model: "m")
        let client = ScriptedClient(turns: [.init(calls: [call("a", "echo", #"{"text":"1"}"#)]),
                                            .init(calls: [call("b", "echo", #"{"text":"2"}"#)]),
                                            .init(text: "never asked for")])
        let result = try await engine(client, tools: [EchoTool()], config: config).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(result.hitIterationLimit)
        XCTAssertEqual(result.finalText, "")
    }

    func testARunThatFinishesInTimeIsNotAskedForAnything() async throws {
        var config = EngineConfig(maxIterations: 3, model: "m")
        config.wrapUpAtLimit = true
        let client = ScriptedClient(turns: [.init(calls: [call("a", "echo", #"{"text":"1"}"#)]), .init(text: "all done")])
        let result = try await engine(client, tools: [EchoTool()], config: config).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertFalse(result.hitIterationLimit)
        XCTAssertEqual(result.finalText, "all done")
    }

    func testAWrapUpThatFailsLeavesTheRunWhatItWas() async throws {
        var config = EngineConfig(maxIterations: 1, model: "m")
        config.wrapUpAtLimit = true
        let client = FleetScriptedThenFailsClient(turns: [.init(text: "working on it", calls: [call("a", "echo", #"{"text":"1"}"#)])],
                                                  then: LLMError.http(401, "no key"))
        let result = try await engine(client, tools: [EchoTool()], config: config).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertTrue(result.hitIterationLimit)
        XCTAssertEqual(result.finalText, "working on it", "what the last real turn said is kept")
    }

    func testAWrapUpThatSaysNothingLeavesTheRunWhatItWas() async throws {
        var config = EngineConfig(maxIterations: 1, model: "m")
        config.wrapUpAtLimit = true
        let client = ScriptedClient(turns: [.init(text: "partial findings", calls: [call("a", "echo", #"{"text":"1"}"#)]), .init(text: "  ")])
        let result = try await engine(client, tools: [EchoTool()], config: config).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.lastReplyText, "partial findings")
        XCTAssertTrue(result.hitIterationLimit)
    }

    func testStoppingDuringTheWrapUpStopsTheRun() async throws {
        var config = EngineConfig(maxIterations: 1, model: "m")
        config.wrapUpAtLimit = true
        let blocking = FleetSwitchClient(first: .init(calls: [call("a", "echo", #"{"text":"1"}"#)]))
        let e = engine(blocking, tools: [EchoTool()], config: config)
        let running = FleetPending { try await e.run(messages: [], userText: "go", sink: { _ in }) }
        let waiting = await fleetEventually { blocking.hasBlocked }
        XCTAssertTrue(waiting, "the wrap-up request is the one that never answers")
        running.cancel()
        do {
            _ = try await running.value()
            XCTFail("expected the run to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testARunResultIsNotStalledUnlessTheEngineSaysSo() async throws {
        let client = ScriptedClient(turns: [.init(text: "hi")])
        let result = try await engine(client, tools: [], config: EngineConfig(model: "m")).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertFalse(result.stalled)
        XCTAssertTrue(RunResult(messages: [], usage: nil, deniedCount: 0, finalText: "x", stalled: true).stalled)
    }

    // MARK: - Foreground subagents get the long timeout

    func testDelegateGetsTheSameLongTimeoutAsAgent() async throws {
        // A tool call normally times out after `toolTimeout` (here one second). A subagent — or a batch of them — is a
        // whole task, so `agent` and `delegate` are given far longer; anything else still times out.
        let config = EngineConfig(maxIterations: 6, toolTimeout: 1, model: "m")
        let client = ScriptedClient(turns: [.init(calls: [call("d", "delegate")]),
                                            .init(calls: [call("a", "agent")]),
                                            .init(calls: [call("s", "slowpoke")]),
                                            .init(text: "done")])
        let result = try await engine(client, tools: [FleetSleepyTool("delegate", seconds: 1.25), FleetSleepyTool("agent", seconds: 1.25),
                                                      FleetSleepyTool("slowpoke", seconds: 1.25)],
                                      config: config).run(messages: [], userText: "go", sink: { _ in })
        let outputs = result.messages.filter { $0.role == .tool }.compactMap(\.content)
        guard outputs.count == 3 else { return XCTFail("expected three tool results, got \(outputs)") }
        XCTAssertTrue(outputs[0].hasPrefix("slept"), outputs[0])
        XCTAssertTrue(outputs[1].hasPrefix("slept"), outputs[1])
        XCTAssertEqual(outputs[2], "Error: tool timed out after 1s.")
    }

    // MARK: - The vault

    func testASubagentPromptKeepsItsVaultPlaceholders() async throws {
        // An empty vault turns a placeholder into a refusal for any tool that would get real values — so a call that goes
        // through with its placeholder intact is one the vault left alone, like `agent` (a prompt would carry the value to a
        // model) and now `delegate` (a batch of prompts).
        let vault = CredentialVault(directory: root.folder("vault"), store: MemoryBlobStore())
        let seen = SeenArgs()
        let record = FleetRecordingTool("delegate", seen)
        let recordAgent = FleetRecordingTool("agent", seen)
        let recordEcho = FleetRecordingTool("echo", seen)
        let calls = [call("d", "delegate", #"{"tasks":[{"prompt":"use {{vault:GITHUB_TOKEN}}"}]}"#),
                     call("a", "agent", #"{"description":"x","prompt":"use {{vault:GITHUB_TOKEN}}"}"#),
                     call("e", "echo", #"{"text":"{{vault:GITHUB_TOKEN}}"}"#)]
        let client = ScriptedClient(turns: [.init(calls: calls), .init(text: "done")])
        let result = try await engine(client, tools: [record, recordAgent, recordEcho], config: EngineConfig(model: "m"), vault: vault)
            .run(messages: [], userText: "go", sink: { _ in })

        let outputs = result.messages.filter { $0.role == .tool }.compactMap(\.content)
        guard outputs.count == 3 else { return XCTFail("expected three tool results, got \(outputs)") }
        XCTAssertFalse(outputs[0].contains("no credential named"), "delegate: \(outputs[0])")
        XCTAssertFalse(outputs[1].contains("no credential named"), "agent: \(outputs[1])")
        XCTAssertTrue(outputs[2].contains("no credential named GITHUB_TOKEN"), "an executing tool is refused: \(outputs[2])")
        XCTAssertEqual(seen.all.count, 2)
        XCTAssertTrue(seen.all.allSatisfy { $0.contains("{{vault:GITHUB_TOKEN}}") })
    }

    // MARK: - Several subagents in one reply

    func testSubagentsAskedForTogetherAreAnnouncedTogetherAndRecordedInOrder() async throws {
        let meeting = FleetMeeting(parties: 2)
        let client = ScriptedClient(turns: [.init(calls: [call("a1", "agent"), call("a2", "agent")]), .init(text: "both back")])
        let events = FleetEvents()
        let result = try await engine(client, tools: [FleetGateTool("agent", meeting: meeting)], config: EngineConfig(model: "m"))
            .run(messages: [], userText: "go", sink: events.sink)

        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.content), ["together", "together"])
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.toolCallID), ["a1", "a2"])
        XCTAssertEqual(events.all.filter { $0.hasPrefix("started") || $0.hasPrefix("finished a") },
                       ["started a1", "started a2", "finished a1", "finished a2"])
        XCTAssertEqual(result.finalText, "both back")
    }

    func testOtherCallsInTheSameReplyStillRunOneByOne() async throws {
        // Only subagents run side by side; a mixed batch keeps its order, so a call can rely on the one before it.
        let meeting = FleetMeeting(parties: 2)
        let client = ScriptedClient(turns: [.init(calls: [call("a1", "agent"), call("e1", "echo", #"{"text":"x"}"#), call("a2", "agent")]),
                                            .init(text: "done")])
        let events = FleetEvents()
        let result = try await engine(client, tools: [FleetGateTool("agent", meeting: meeting, patience: 0.2), EchoTool()],
                                      config: EngineConfig(model: "m")).run(messages: [], userText: "go", sink: events.sink)
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.content), ["alone", "echoed: x", "alone"])
        XCTAssertEqual(events.all.filter { $0.hasPrefix("started") || $0.hasPrefix("finished") && $0 != "finished run" },
                       ["started a1", "finished a1", "started e1", "finished e1", "started a2", "finished a2"])
    }

    func testASingleSubagentCallIsNotDeferred() async throws {
        let meeting = FleetMeeting(parties: 1)
        let client = ScriptedClient(turns: [.init(calls: [call("a1", "agent")]), .init(text: "done")])
        let events = FleetEvents()
        let result = try await engine(client, tools: [FleetGateTool("agent", meeting: meeting)], config: EngineConfig(model: "m"))
            .run(messages: [], userText: "go", sink: events.sink)
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.content), ["together"])
        XCTAssertEqual(events.all.filter { $0.hasSuffix("a1") }, ["started a1", "finished a1"])
    }

    func testSubagentCallsWithAVaultPlaceholderGoOneAtATime() async throws {
        let vault = CredentialVault(directory: root.folder("vault"), store: MemoryBlobStore())
        let meeting = FleetMeeting(parties: 2)
        let withPlaceholder = #"{"description":"x","prompt":"use {{vault:TOKEN}}"}"#
        let client = ScriptedClient(turns: [.init(calls: [call("a1", "agent", withPlaceholder), call("a2", "agent", withPlaceholder)]),
                                            .init(text: "done")])
        let events = FleetEvents()
        let result = try await engine(client, tools: [FleetGateTool("agent", meeting: meeting, patience: 0.2)],
                                      config: EngineConfig(model: "m"), vault: vault).run(messages: [], userText: "go", sink: events.sink)
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.content), ["alone", "alone"])
        XCTAssertEqual(events.all.filter { $0.hasPrefix("started") || $0.hasPrefix("finished a") },
                       ["started a1", "finished a1", "started a2", "finished a2"])
    }

    func testStoppingWhileSubagentsRunSideBySideStopsTheRun() async throws {
        let meeting = FleetMeeting(parties: 3)   // never met: the two calls wait for a third
        let client = ScriptedClient(turns: [.init(calls: [call("a1", "agent"), call("a2", "agent")]), .init(text: "done")])
        let e = engine(client, tools: [FleetGateTool("agent", meeting: meeting, patience: 30)], config: EngineConfig(model: "m"))
        let running = FleetPending { try await e.run(messages: [], userText: "go", sink: { _ in }) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(running.isDone)
        running.cancel()
        do {
            _ = try await running.value(within: 6)
            XCTFail("expected the run to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - The tool turn as the engine now runs it

    func testAnApprovedWriteOutsideTheWorkspaceStillRunsAndADeclinedOneDoesNot() async throws {
        // (The engine's own tests of this write real files, which not every sandbox allows; the tool here only records.)
        let outside = FleetTestDirectory("dsh-sibling")
        defer { outside.remove() }
        let arguments = "{\"file_path\":\"\(outside.url.appendingPathComponent("elsewhere.txt").path)\",\"content\":\"x\"}"

        let seen = SeenArgs()
        let approved = ScriptedClient(turns: [.init(calls: [call("w", "write_file", arguments)]), .init(text: "written")])
        let ok = try await engine(approved, tools: [FleetRecordingTool("write_file", seen)], config: EngineConfig(model: "m"))
            .run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(seen.all, [arguments], "asked, approved, run with the arguments as written")
        XCTAssertEqual(ok.deniedCount, 0)
        XCTAssertEqual(ok.messages.filter { $0.role == .tool }.compactMap(\.content), ["recorded"])

        let declined = ScriptedClient(turns: [.init(calls: [call("w", "write_file", arguments)]), .init(text: "understood")])
        let no = try await engine(declined, tools: [FleetRecordingTool("write_file", seen)], config: EngineConfig(model: "m"),
                                  gate: { _, _, _ in false }).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(seen.all.count, 1, "the declined call never ran")
        XCTAssertEqual(no.deniedCount, 1)
        XCTAssertTrue(no.messages.dropFirst(2).first?.content?.contains("Permission denied") ?? false)
    }

    func testAToolsFilesUsageAndTodosStillReachTheirDestinations() async throws {
        let seenTodos = FleetLog<Int>()
        let events = FleetEvents()
        let filesChanged = FleetCounter()
        let todo = call("t", "todo_write", #"{"todos":[{"content":"one","status":"pending"},{"content":"two","status":"completed"}]}"#)
        let client = ScriptedClient(turns: [.init(calls: [call("e", "echo", #"{"text":"x"}"#), todo]), .init(text: "done")])
        let e = Engine(client: client, registry: ToolRegistry(tools: [EchoTool(), TodoWriteTool()]), systemPrompt: "s",
                       config: EngineConfig(model: "m"), workspace: root.url,
                       policy: PermissionPolicy(preset: .workspaceWrite, workspaceRoot: root.url),
                       permissionGate: { _, _, _ in true }, onTodos: { seenTodos.append($0.count) })
        let sink = events.sink
        let result = try await e.run(messages: [], userText: "go", sink: { event in
            if case .filesChanged = event { filesChanged.bump() }
            sink(event)
        })
        XCTAssertEqual(seenTodos.all, [2])
        XCTAssertEqual(filesChanged.value, 1)
        XCTAssertEqual(events.all.filter { $0.hasPrefix("started") || $0.hasPrefix("finished ") && $0 != "finished run" },
                       ["started e", "finished e", "started t", "finished t"])
        XCTAssertEqual(result.messages.filter { $0.role == .tool }.compactMap(\.toolCallID), ["e", "t"])
    }

    // MARK: - Previews

    func testTheTimelineNamesAFanOutByItsSize() {
        let three = ToolCall(id: "1", name: "delegate", arguments: #"{"tasks":[{"prompt":"a"},{"prompt":"b"},{"prompt":"c"}]}"#)
        let one = ToolCall(id: "2", name: "delegate", arguments: #"{"tasks":[{"prompt":"a"}]}"#)
        let none = ToolCall(id: "3", name: "delegate", arguments: "{}")
        XCTAssertEqual(Engine.preview(of: three), "3 parallel tasks")
        XCTAssertEqual(Engine.preview(of: one), "1 parallel task")
        XCTAssertEqual(Engine.preview(of: none), "parallel tasks")
        XCTAssertEqual(Engine.preview(of: ToolCall(id: "4", name: "agent", arguments: #"{"description":"scan"}"#)), "scan")
    }
}

/// Records what it was called with, under a name of the test's choosing.
struct FleetRecordingTool: ToolExecutor {
    static let name = "record"
    static let spec = ToolSpec(name: "record", description: "", parameters: "{}")

    let toolName: String
    let seen: SeenArgs

    init(_ name: String, _ seen: SeenArgs) {
        toolName = name
        self.seen = seen
    }

    var name: String { toolName }
    var spec: ToolSpec { ToolSpec(name: toolName, description: "records", parameters: #"{"type":"object","properties":{}}"#) }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        seen.append(args.raw)
        return ToolResult(output: "recorded")
    }
}

/// Answers its first request as scripted; every later one waits for the task to be cancelled.
final class FleetSwitchClient: LLMClient, @unchecked Sendable {
    private let calls = FleetCounter()
    private let blocked = FleetCounter()
    private let first: ScriptedClient.Turn

    init(first: ScriptedClient.Turn) { self.first = first }

    var hasBlocked: Bool { blocked.value > 0 }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        calls.bump()
        let isFirst = calls.value == 1
        let turn = first
        if !isFirst { blocked.bump() }
        return AsyncThrowingStream { continuation in
            if isFirst {
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
                continuation.finish()
            } else {
                let task = Task {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
                    continuation.finish(throwing: CancellationError())
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func listModels() async throws -> [String] { [] }
}
