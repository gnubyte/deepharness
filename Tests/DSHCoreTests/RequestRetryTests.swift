import XCTest
@testable import DSHCore

/// A client whose first `failures` calls throw `error` (after streaming
/// `partial` text, to mimic a stream cut off mid-reply), then answers.
final class FlakyClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresLeft: Int
    private let error: Error
    private let partial: String
    private var turns: [ScriptedClient.Turn]
    private(set) var calls = 0
    private(set) var models: [String] = []

    init(failures: Int, error: Error, partial: String = "", turns: [ScriptedClient.Turn]) {
        self.failuresLeft = failures
        self.error = error
        self.partial = partial
        self.turns = turns
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        calls += 1
        models.append(request.model)
        let fail = failuresLeft > 0
        if fail { failuresLeft -= 1 }
        let turn = fail ? nil : (turns.isEmpty ? ScriptedClient.Turn(text: "done") : turns.removeFirst())
        let error = self.error, partial = self.partial
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let turn {
                for chunk in turn.text.map(String.init) { continuation.yield(.text(chunk)) }
                continuation.yield(.done(calls: turn.calls, finish: "stop", usage: turn.usage))
                continuation.finish()
            } else {
                if !partial.isEmpty { continuation.yield(.text(partial)) }
                continuation.finish(throwing: error)
            }
        }
    }

    func listModels() async throws -> [String] { ["flaky"] }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EngineEvent] = []
    var events: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return storage }
    var sink: @Sendable (EngineEvent) -> Void { { [self] e in lock.lock(); storage.append(e); lock.unlock() } }

    var retries: [(Int, String)] {
        events.compactMap { if case .retrying(let a, _, let r) = $0 { return (a, r) } else { return nil } }
    }
    var recovered: [Int] {
        events.compactMap { if case .recovered(let n) = $0 { return n } else { return nil } }
    }
    /// Text as the UI would show it: deltas since the last retry.
    var visibleText: String {
        var text = ""
        for e in events {
            switch e {
            case .textDelta(let d): text += d
            case .retrying: text = ""
            default: break
            }
        }
        return text
    }
}

final class RequestRetryTests: XCTestCase {

    private let instant = RetryPolicy(delay: { _ in 0 })

    private func engine(_ client: any LLMClient, retry: RetryPolicy? = nil,
                        registry: ToolRegistry = ToolRegistry(tools: [EchoTool()]),
                        reroute: (@Sendable () async -> (client: any LLMClient, model: String)?)? = nil) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        return Engine(client: client, registry: registry, systemPrompt: "system",
                      config: .init(maxIterations: 5, toolTimeout: 5, model: "m1", retry: retry ?? instant),
                      workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                      permissionGate: { _, _, _ in true }, reroute: reroute)
    }

    // MARK: Classification

    func testTransientFailuresRetryUntilAvailable() {
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .networkConnectionLost,
                                    .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
                                    .badServerResponse, .secureConnectionFailed] {
            XCTAssertEqual(RequestRetry.disposition(for: URLError(code)), .untilAvailable, "\(code)")
        }
        for status in [408, 429, 502, 503, 504] {
            XCTAssertEqual(RequestRetry.disposition(for: LLMError.http(status, "")), .untilAvailable, "\(status)")
        }
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.sse("cut off")), .untilAvailable)
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.connection("refused")), .untilAvailable)
        // Mid-swap: the old model id is gone until the route re-resolves.
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.http(404, #"{"message":"The model `qwen` does not exist."}"#)),
                       .untilAvailable)
        XCTAssertEqual(RequestRetry.disposition(for: NSError(domain: NSPOSIXErrorDomain, code: 61)), .untilAvailable)
        XCTAssertEqual(RequestRetry.disposition(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
                       .untilAvailable)
    }

    func testPermanentFailuresSurfaceImmediately() {
        XCTAssertEqual(RequestRetry.disposition(for: CancellationError()), .fail)
        XCTAssertEqual(RequestRetry.disposition(for: URLError(.cancelled)), .fail)
        XCTAssertEqual(RequestRetry.disposition(for: URLError(.badURL)), .fail)
        XCTAssertEqual(RequestRetry.disposition(for: URLError(.serverCertificateUntrusted)), .fail)
        for status in [400, 401, 403, 404, 422] {
            XCTAssertEqual(RequestRetry.disposition(for: LLMError.http(status, "nope")), .fail, "\(status)")
        }
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.noModel), .fail)
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.overflow(limit: 10, detail: "")), .fail)
        // A 500 is retried, but not forever.
        XCTAssertEqual(RequestRetry.disposition(for: LLMError.http(500, "boom")), .limited(RequestRetry.serverErrorRetries))
        XCTAssertFalse(RetryPolicy.standard.shouldRetry(LLMError.http(500, ""), attempt: RequestRetry.serverErrorRetries + 1))
        XCTAssertTrue(RetryPolicy.standard.shouldRetry(URLError(.timedOut), attempt: 10_000))
        XCTAssertFalse(RetryPolicy.off.shouldRetry(URLError(.timedOut), attempt: 1))
    }

    func testBackoffGrowsThenHoldsAtThirtySeconds() {
        XCTAssertEqual((1...7).map(RequestRetry.backoff(attempt:)), [2, 4, 8, 16, 30, 30, 30])
    }

    func testReasonsAreShortAndPlain() {
        XCTAssertEqual(RequestRetry.reason(for: URLError(.timedOut)), "the request timed out")
        XCTAssertEqual(RequestRetry.reason(for: URLError(.cannotConnectToHost)), "the server refused the connection")
        XCTAssertEqual(RequestRetry.reason(for: LLMError.http(503, "")), "HTTP 503")
        XCTAssertTrue(RequestRetry.reason(for: LLMError.http(502, String(repeating: "x", count: 500))).count < 100)
    }

    // MARK: Engine

    func testTimeoutsAreRetriedUntilTheModelAnswers() async throws {
        let client = FlakyClient(failures: 3, error: URLError(.timedOut), partial: "Hel",
                                 turns: [.init(text: "Hello")])
        let events = EventLog()
        let result = try await engine(client).run(messages: [], userText: "hi", sink: events.sink)
        XCTAssertEqual(result.finalText, "Hello")
        XCTAssertEqual(client.calls, 4)
        XCTAssertEqual(events.retries.map(\.0), [1, 2, 3])
        XCTAssertEqual(events.retries.first?.1, "the request timed out")
        XCTAssertEqual(events.recovered, [3])
        // The cut-off partial "Hel"s are void: no duplicated text reaches the UI or the transcript.
        XCTAssertEqual(events.visibleText, "Hello")
        XCTAssertEqual(result.messages.filter { $0.role == .assistant }.map(\.content), ["Hello"])
    }

    func testPermanentErrorIsNotRetried() async {
        let client = FlakyClient(failures: 1, error: LLMError.http(401, "bad key"), turns: [])
        let events = EventLog()
        do {
            _ = try await engine(client).run(messages: [], userText: "hi", sink: events.sink)
            XCTFail("expected the 401 to surface")
        } catch {
            XCTAssertEqual(client.calls, 1)
            XCTAssertTrue(events.retries.isEmpty)
        }
    }

    func testRetryingCanBeTurnedOff() async {
        let client = FlakyClient(failures: 1, error: URLError(.timedOut), turns: [])
        do {
            _ = try await engine(client, retry: .off).run(messages: [], userText: "hi", sink: { _ in })
            XCTFail("expected the timeout to surface")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testStopDuringTheWaitEndsTheRunPromptly() async {
        let client = FlakyClient(failures: 1_000, error: URLError(.cannotConnectToHost), turns: [])
        let slow = RetryPolicy(delay: { _ in 30 })
        let eng = engine(client, retry: slow)
        let task = Task { try await eng.run(messages: [], userText: "hi", sink: { _ in }) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
        XCTAssertEqual(client.calls, 1)
    }

    func testRetryFollowsARerouteToTheNewModel() async throws {
        let first = FlakyClient(failures: 10, error: LLMError.http(404, "model m1 does not exist"), turns: [])
        let second = ScriptedClient(turns: [.init(text: "served by m2")])
        let result = try await engine(first, reroute: { (second, "m2") })
            .run(messages: [], userText: "hi", sink: { _ in })
        XCTAssertEqual(result.finalText, "served by m2")
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.requests.first?.model, "m2")
    }

    func testToolWorkBeforeAFailureIsSalvaged() async {
        // Round 1: a tool call runs. Round 2: the server returns a permanent error.
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"hi"}"#)
        let client = ScriptedThenFailing(turns: [.init(calls: [call])], error: LLMError.http(400, "bad request"))
        let progress = RunProgress()
        do {
            _ = try await engine(client).run(messages: [.user("earlier"), .assistant("ok")], userText: "go",
                                             progress: progress, sink: { _ in })
            XCTFail("expected the 400")
        } catch {}
        let kept = try? XCTUnwrap(progress.salvaged)
        XCTAssertEqual(kept?.map(\.role), [.user, .assistant, .user, .assistant, .tool])
        XCTAssertEqual(kept?.last?.content, "echoed: hi")
    }

    func testNothingIsSalvagedWhenTheRunNeverGotGoing() async {
        let client = FlakyClient(failures: 1, error: LLMError.http(400, "bad"), turns: [])
        let progress = RunProgress()
        _ = try? await engine(client).run(messages: [.user("a"), .assistant("b")], userText: "c",
                                          progress: progress, sink: { _ in })
        XCTAssertNil(progress.salvaged)
    }

    func testDanglingToolCallsAreClosed() {
        let calls = [ToolCall(id: "a", name: "echo", arguments: "{}"), ToolCall(id: "b", name: "echo", arguments: "{}")]
        let messages: [LLMMessage] = [.user("x"), .assistant("", calls: calls), .toolResult(id: "a", name: "echo", output: "ok")]
        let closed = Engine.closingDanglingToolCalls(messages)
        XCTAssertEqual(closed.count, 4)
        XCTAssertEqual(closed.last?.toolCallID, "b")
        XCTAssertTrue(closed.last?.content?.contains("interrupted") ?? false)
        // Already complete: untouched.
        XCTAssertEqual(Engine.closingDanglingToolCalls(closed), closed)
        XCTAssertEqual(Engine.closingDanglingToolCalls([.user("x"), .assistant("hi")]).count, 2)
    }

    func testLastReplyTextSurvivesAnEmptyFinalMessage() async throws {
        // The model declares completion alongside a final tool call, then ends
        // with an empty message: the goal loop must still see the verdict.
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"x"}"#)
        let client = ScriptedClient(turns: [.init(text: "All done.\nGOAL_COMPLETE", calls: [call]), .init(text: "")])
        let result = try await engine(client).run(messages: [], userText: "go", sink: { _ in })
        XCTAssertEqual(result.finalText, "")
        XCTAssertEqual(GoalProtocol.status(of: result.lastReplyText), .complete)
    }
}


extension RequestRetryTests {
    func testWorkAfterAnInRunCompactionIsStillSalvaged() async {
        // A long transcript compacts in-run to something shorter than where it
        // started; the tool round after it must survive a later failure.
        let call = ToolCall(id: "c1", name: "echo", arguments: #"{"text":"after"}"#)
        let client = ScriptedThenFailing(turns: [.init(calls: [call])], error: LLMError.http(400, "bad"))
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let big = (0..<40).flatMap { i -> [LLMMessage] in [.user(String(repeating: "u\(i) ", count: 200)), .assistant("a\(i)")] }
        let engine = Engine(client: client, registry: ToolRegistry(tools: [EchoTool()]), systemPrompt: "s",
                            config: .init(maxIterations: 5, toolTimeout: 5, model: "m", contextWindow: 2_000,
                                          retry: RetryPolicy(delay: { _ in 0 })),
                            workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                            permissionGate: { _, _, _ in true },
                            compaction: { _, messages in [.system("summary")] + messages.suffix(1) })
        let progress = RunProgress()
        _ = try? await engine.run(messages: big, userText: "go", progress: progress, sink: { _ in })
        let kept = progress.salvaged
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.last?.content, "echoed: after")
        XCTAssertEqual(kept?.first?.content, "summary")
    }

    func testServerErrorAllowanceIsSeparateFromOutageRetries() async throws {
        // 12 outage failures, then a 500, then success: the 500 is still retried.
        let counter = Counter()
        let client = CallbackClient { n in
            if n <= 12 { return .failure(URLError(.cannotConnectToHost)) }
            if n == 13 { return .failure(LLMError.http(500, "oops")) }
            return .success("ok")
        }
        _ = counter
        let result = try await engine(client).run(messages: [], userText: "hi", sink: { _ in })
        XCTAssertEqual(result.finalText, "ok")
    }

    func testStopWhileAPermissionQuestionIsOpenIsNotARefusal() async {
        let call = ToolCall(id: "c1", name: "run_shell_command", arguments: #"{"command":"rm -rf /tmp/x"}"#)
        let client = ScriptedClient(turns: [.init(calls: [call])])
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let engine = Engine(client: client, registry: ToolRegistry.standard(), systemPrompt: "s",
                            config: .init(model: "m"), workspace: root,
                            policy: PermissionPolicy(preset: .plan, workspaceRoot: root),
                            permissionGate: { _, _, _ in
                                try? await Task.sleep(nanoseconds: 5_000_000_000)
                                return false
                            })
        let progress = RunProgress()
        let task = Task { try await engine.run(messages: [], userText: "go", progress: progress, sink: { _ in }) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = try? await task.value
        let kept = progress.salvaged ?? []
        XCTAssertFalse(kept.contains { ($0.content ?? "").contains("Permission denied") })
        XCTAssertTrue(kept.last?.content?.contains("interrupted") ?? false)
    }
}

/// Answers each call from a closure (1-based call number).
final class CallbackClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private let answer: @Sendable (Int) -> Result<String, Error>
    init(_ answer: @escaping @Sendable (Int) -> Result<String, Error>) { self.answer = answer }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock(); n += 1; let k = n; lock.unlock()
        let result = answer(k)
        return AsyncThrowingStream { c in
            switch result {
            case .success(let text):
                c.yield(.text(text)); c.yield(.done(calls: [], finish: "stop", usage: nil)); c.finish()
            case .failure(let e):
                c.finish(throwing: e)
            }
        }
    }
    func listModels() async throws -> [String] { [] }
}
/// Plays scripted turns, then fails every later call with `error`.
final class ScriptedThenFailing: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [ScriptedClient.Turn]
    private let error: Error
    init(turns: [ScriptedClient.Turn], error: Error) { self.turns = turns; self.error = error }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        let turn = turns.isEmpty ? nil : turns.removeFirst()
        lock.unlock()
        let error = self.error
        return AsyncThrowingStream { c in
            if let turn {
                for ch in turn.text.map(String.init) { c.yield(.text(ch)) }
                c.yield(.done(calls: turn.calls, finish: "stop", usage: nil))
                c.finish()
            } else {
                c.finish(throwing: error)
            }
        }
    }
    func listModels() async throws -> [String] { [] }
}
