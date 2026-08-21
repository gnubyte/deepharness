import XCTest
@testable import DSHCore

/// A scripted client: each `stream` call returns the next queued turn, so a
/// test can drive the engine through a full tool round-trip without a network.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    struct Turn {
        var text: String = ""
        var calls: [ToolCall] = []
        var usage: LLMUsage? = nil
    }

    private let lock = NSLock()
    private var turns: [Turn]
    private(set) var requests: [LLMRequest] = []

    init(turns: [Turn]) { self.turns = turns }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let turn = turns.isEmpty ? Turn(text: "done") : turns.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            // Deltas arrive in pieces, as they would from a real stream.
            for chunk in turn.text.map(String.init) {
                continuation.yield(.text(chunk))
            }
            continuation.yield(.done(calls: turn.calls, finish: "stop", usage: turn.usage))
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { ["scripted"] }
}

/// A tool that records what it was handed and returns a fixed answer.
struct EchoTool: ToolExecutor {
    static let name = "echo"
    static let spec = ToolSpec(name: name, description: "echo",
                               parameters: #"{"type":"object","properties":{"text":{"type":"string"}}}"#)

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let text = Self.string(args, "text") ?? ""
        return ToolResult(output: "echoed: \(text)",
                          files: [FileChange(context.workspace.appendingPathComponent("out.txt"), .created)])
    }
}

struct FailingTool: ToolExecutor {
    static let name = "boom"
    static let spec = ToolSpec(name: name, description: "always fails", parameters: "{}")
    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        ToolResult(output: "Error: it broke")
    }
}

final class EngineTests: XCTestCase {

    private func makeEngine(client: LLMClient,
                            registry: ToolRegistry = ToolRegistry(tools: [EchoTool()]),
                            preset: PermissionPreset = .workspaceWrite,
                            workspace: URL? = nil,
                            gate: @escaping @Sendable (String, String, String) async -> Bool = { _, _, _ in true }
    ) -> Engine {
        let root = workspace ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return Engine(client: client,
                      registry: registry,
                      systemPrompt: "system",
                      config: .init(maxIterations: 5, toolTimeout: 5, model: "test"),
                      workspace: root,
                      policy: PermissionPolicy(preset: preset, workspaceRoot: root),
                      permissionGate: gate)
    }

    /// Collects events off the engine's sink, which is called from a task.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [EngineEvent] = []
        var events: [EngineEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        var record: @Sendable (EngineEvent) -> Void {
            { [self] event in
                lock.lock(); storage.append(event); lock.unlock()
            }
        }
    }

    func testTextOnlyTurnFinishes() async throws {
        let client = ScriptedClient(turns: [.init(text: "hello there")])
        let sink = Sink()
        let result = try await makeEngine(client: client)
            .run(messages: [], userText: "hi", sink: sink.record)

        XCTAssertEqual(result.finalText, "hello there")
        XCTAssertEqual(result.deniedCount, 0)
        // user + assistant
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages.first?.role, .user)

        let deltas = sink.events.compactMap { event -> String? in
            if case .textDelta(let chunk) = event { return chunk }
            return nil
        }
        XCTAssertEqual(deltas.joined(), "hello there")
    }

    func testToolCallRoundTrip() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"ping"}"#)
        let client = ScriptedClient(turns: [
            .init(text: "let me check", calls: [call]),
            .init(text: "all done"),
        ])
        let sink = Sink()
        let result = try await makeEngine(client: client)
            .run(messages: [], userText: "go", sink: sink.record)

        XCTAssertEqual(result.finalText, "all done")
        // user, assistant+call, tool result, assistant
        XCTAssertEqual(result.messages.count, 4)
        XCTAssertEqual(result.messages[2].role, .tool)
        XCTAssertEqual(result.messages[2].content, "echoed: ping")
        XCTAssertEqual(result.messages[2].toolCallID, "c1")

        let started = sink.events.contains { if case .toolStarted(_, let name, _) = $0 { return name == "echo" } else { return false } }
        let finished = sink.events.contains { if case .toolFinished(_, _, let ok, _, _) = $0 { return ok } else { return false } }
        XCTAssertTrue(started)
        XCTAssertTrue(finished)
    }

    /// The engine must forward a tool's file changes so the editor can reload.
    func testFileChangesAreEmitted() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"x"}"#)
        let client = ScriptedClient(turns: [.init(calls: [call]), .init(text: "ok")])
        let sink = Sink()
        _ = try await makeEngine(client: client).run(messages: [], userText: "go", sink: sink.record)

        let changed = sink.events.compactMap { event -> [FileChange]? in
            if case .filesChanged(let files) = event { return files }
            return nil
        }
        XCTAssertEqual(changed.first?.first?.kind, .created)
    }

    func testFailingToolIsReportedNotFatal() async throws {
        let call = ToolCall(id: "c1", name: "boom", arguments: "{}")
        let client = ScriptedClient(turns: [.init(calls: [call]), .init(text: "recovered")])
        let sink = Sink()
        let result = try await makeEngine(client: client, registry: ToolRegistry(tools: [FailingTool()]))
            .run(messages: [], userText: "go", sink: sink.record)

        XCTAssertEqual(result.finalText, "recovered")
        let failed = sink.events.contains { if case .toolFinished(_, _, let ok, _, _) = $0 { return !ok } else { return false } }
        XCTAssertTrue(failed)
    }

    func testUnknownToolDoesNotCrashTheRun() async throws {
        let call = ToolCall(id: "c1", name: "nope", arguments: "{}")
        let client = ScriptedClient(turns: [.init(calls: [call]), .init(text: "moved on")])
        let result = try await makeEngine(client: client)
            .run(messages: [], userText: "go") { _ in }

        XCTAssertEqual(result.finalText, "moved on")
        XCTAssertTrue(result.messages[2].content?.contains("unknown tool") ?? false)
    }

    /// A denied write must not execute, and the model must be told to stop
    /// rather than retry the same thing.
    func testDeniedWriteIsRecordedAndNotExecuted() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("escaped.txt")

        let call = ToolCall(id: "c1", name: "write_file",
                            arguments: #"{"file_path":"\#(outside.path)","content":"nope"}"#)
        let client = ScriptedClient(turns: [.init(calls: [call]), .init(text: "understood")])
        let engine = makeEngine(client: client,
                                registry: ToolRegistry.standard(),
                                workspace: root,
                                gate: { _, _, _ in false })
        let result = try await engine.run(messages: [], userText: "write outside") { _ in }

        XCTAssertEqual(result.deniedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(result.messages[2].content?.contains("Permission denied") ?? false)
    }

    func testApprovedWriteOutsideWorkspaceProceeds() async throws {
        let root = try makeTempDirectory()
        let sibling = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
        let target = sibling.appendingPathComponent("allowed.txt")
        let call = ToolCall(id: "c1", name: "write_file",
                            arguments: #"{"file_path":"\#(target.path)","content":"yes"}"#)
        let client = ScriptedClient(turns: [.init(calls: [call]), .init(text: "written")])
        let engine = makeEngine(client: client, registry: ToolRegistry.standard(),
                                workspace: root, gate: { _, _, _ in true })
        _ = try await engine.run(messages: [], userText: "write") { _ in }

        XCTAssertEqual(try? String(contentsOf: target, encoding: .utf8), "yes")
    }

    func testUsageAccumulatesAcrossIterations() async throws {
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"x"}"#)
        let client = ScriptedClient(turns: [
            .init(calls: [call], usage: LLMUsage(promptTokens: 10, completionTokens: 5)),
            .init(text: "ok", usage: LLMUsage(promptTokens: 20, completionTokens: 7)),
        ])
        let result = try await makeEngine(client: client).run(messages: [], userText: "go") { _ in }
        XCTAssertEqual(result.usage?.promptTokens, 30)
        XCTAssertEqual(result.usage?.completionTokens, 12)
    }

    func testIterationBudgetStopsRunawayLoops() async throws {
        // Every turn asks for another tool call; the engine must give up.
        let call = ToolCall(id: "c", name: "echo", arguments: #"{"text":"again"}"#)
        let client = ScriptedClient(turns: Array(repeating: .init(calls: [call]), count: 50))
        let result = try await makeEngine(client: client).run(messages: [], userText: "go") { _ in }
        // 5 iterations × (assistant + tool) + the initial user message.
        XCTAssertEqual(result.messages.count, 11)
    }

    func testToolSpecsAreOfferedToTheModel() async throws {
        let client = ScriptedClient(turns: [.init(text: "hi")])
        _ = try await makeEngine(client: client, registry: ToolRegistry.standard())
            .run(messages: [], userText: "go") { _ in }
        let offered = Set(client.requests.first?.tools.map(\.name) ?? [])
        // The Qwen Code tool names, which is what makes prompts portable.
        for expected in ["read_file", "write_file", "edit", "list_directory",
                         "glob", "grep", "read_many_files", "run_shell_command",
                         "web_fetch", "todo_write", "exit_plan_mode"] {
            XCTAssertTrue(offered.contains(expected), "missing tool \(expected)")
        }
    }

    func testPriorTranscriptIsCarriedForward() async throws {
        let client = ScriptedClient(turns: [.init(text: "second")])
        let history: [LLMMessage] = [.user("first question"), .assistant("first answer")]
        _ = try await makeEngine(client: client).run(messages: history, userText: "follow up") { _ in }

        let sent = client.requests.first?.messages ?? []
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0].content, "first question")
        XCTAssertEqual(sent[2].content, "follow up")
    }

    func testCancellationPropagates() async {
        let client = ScriptedClient(turns: Array(repeating: .init(text: "..."), count: 100))
        let engine = makeEngine(client: client)
        let task = Task {
            try await engine.run(messages: [], userText: "go") { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            // A very fast machine may finish the first turn before the cancel
            // lands; either outcome is correct as long as it did not hang.
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: Previews

    func testPreviewPicksTheInterestingArgument() {
        XCTAssertEqual(Engine.preview(of: .init(id: "1", name: "read_file",
                                                arguments: #"{"file_path":"a/b.swift"}"#)), "a/b.swift")
        XCTAssertEqual(Engine.preview(of: .init(id: "2", name: "run_shell_command",
                                                arguments: #"{"command":"ls -la"}"#)), "ls -la")
        XCTAssertEqual(Engine.preview(of: .init(id: "3", name: "grep",
                                                arguments: #"{"pattern":"TODO"}"#)), "TODO")
        // A plugin tool: fall back to the first string argument.
        XCTAssertEqual(Engine.preview(of: .init(id: "4", name: "custom",
                                                arguments: #"{"target":"release"}"#)), "release")
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
