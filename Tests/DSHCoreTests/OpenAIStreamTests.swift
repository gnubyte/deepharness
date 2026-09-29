import XCTest
@testable import DSHCore

/// A fake model server behind URLSession: every request a test client makes
/// is answered by `handler` (status + SSE body, or a transport error).
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var error: URLError.Code? = nil
        var contentType = "text/event-stream"
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _paths: [String] = []
    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); _paths = []; lock.unlock()
        self.handler = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._paths.append(request.url?.path ?? ""); Self.lock.unlock()
        let reply = Self.handler?(request) ?? Reply(status: 500, body: "no handler")
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// An SSE body streaming `text` as a few deltas, then finish + [DONE].
    static func sse(_ text: String, finish: Bool = true, done: Bool = true) -> String {
        var out = ""
        for piece in text.chunked(3) {
            let json = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": piece]]]])
            out += "data: \(String(decoding: json, as: UTF8.self))\n\n"
        }
        if finish { out += #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n" }
        if done { out += "data: [DONE]\n\n" }
        return out
    }
}

private extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count == n { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

final class OpenAIStreamTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OpenAIClient.protocolClassesForTesting = [StubServer.self]
    }

    override func tearDown() {
        OpenAIClient.protocolClassesForTesting = nil
        StubServer.handler = nil
        super.tearDown()
    }

    private func client() -> OpenAIClient {
        OpenAIClient(profile: .init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "m"))
    }

    private func request() -> LLMRequest {
        LLMRequest(systemPrompt: "s", messages: [.user("hi")], tools: [], model: "m")
    }

    private func collect(_ client: OpenAIClient) async throws -> String {
        var text = ""
        for try await event in client.stream(request()) {
            if case .text(let d) = event { text += d }
        }
        return text
    }

    func testCompleteStreamIsReturned() async throws {
        StubServer.reset { _ in .init(body: StubServer.sse("Hello there")) }
        let text = try await collect(client())
        XCTAssertEqual(text, "Hello there")
    }

    func testStreamCutOffMidReplyIsAnError() async {
        // The server went away mid-reply: no finish_reason, no [DONE].
        StubServer.reset { _ in .init(body: StubServer.sse("Hel", finish: false, done: false)) }
        do {
            _ = try await collect(client())
            XCTFail("a truncated stream must not pass as a short answer")
        } catch {
            guard case LLMError.sse = error else { return XCTFail("\(error)") }
            XCTAssertEqual(RequestRetry.disposition(for: error), .untilAvailable)
        }
    }

    func testMidStreamErrorPayloadSurfaces() async {
        let body = StubServer.sse("par", finish: false, done: false)
            + #"data: {"object":"error","message":"Internal worker died","type":"InternalServerError","code":503}"# + "\n\n"
        StubServer.reset { _ in .init(body: body) }
        do {
            _ = try await collect(client())
            XCTFail("expected the mid-stream error")
        } catch {
            guard case LLMError.http(let code, let message) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 503)
            XCTAssertTrue(message.contains("worker died"))
        }
    }

    func testPlainJSONReplyIsAccepted() async throws {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"plain answer"},"finish_reason":"stop"}]}"#
        StubServer.reset { _ in .init(body: body, contentType: "application/json") }
        var text = ""
        var finished = false
        for try await event in client().stream(request()) {
            if case .text(let d) = event { text += d }
            if case .done = event { finished = true }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(text, "plain answer")
    }

    func testServerDownThenUpIsRetriedEndToEnd() async throws {
        // 1st: gateway error (nginx in front of a restarting server).
        // 2nd: timeout. 3rd: the model answers.
        let counter = Counter()
        StubServer.reset { req in
            guard req.url?.path.hasSuffix("chat/completions") == true else { return .init(status: 404) }
            switch counter.next() {
            case 1: return .init(status: 502, body: "<html>Bad Gateway</html>")
            case 2: return .init(error: .timedOut)
            default: return .init(body: StubServer.sse("back online"))
            }
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let engine = Engine(client: client(), registry: ToolRegistry(tools: []), systemPrompt: "s",
                            config: .init(model: "m", retry: RetryPolicy(delay: { _ in 0 })),
                            workspace: root, policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                            permissionGate: { _, _, _ in true })
        let result = try await engine.run(messages: [], userText: "hi", sink: { _ in })
        XCTAssertEqual(result.finalText, "back online")
        XCTAssertEqual(counter.value, 3)
    }

    func testStreamErrorShapes() {
        XCTAssertEqual(OpenAIClient.streamError(in: ["error": ["message": "x", "code": 400]])?.code, 400)
        XCTAssertEqual(OpenAIClient.streamError(in: ["error": ["message": "x", "code": "429"]])?.code, 429)
        XCTAssertEqual(OpenAIClient.streamError(in: ["error": "plain"])?.message, "plain")
        XCTAssertEqual(OpenAIClient.streamError(in: ["object": "error", "message": "m"])?.code, 500)
        XCTAssertNil(OpenAIClient.streamError(in: ["choices": []]))
    }
}


extension OpenAIStreamTests {
    func testFinishReasonErrorIsAFailureNotAReply() async {
        let body = #"data: {"choices":[{"delta":{"content":"par"}}]}"# + "\n\n"
            + #"data: {"error":{"message":"provider failed","code":502},"choices":[{"delta":{},"finish_reason":"error"}]}"# + "\n\n"
        StubServer.reset { _ in .init(body: body) }
        do {
            _ = try await collect(client())
            XCTFail("expected an error")
        } catch {
            guard case LLMError.http(let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 502)
        }
    }

    func testANonModelReplyIsNotRetriedForever() async {
        StubServer.reset { _ in .init(body: "<html>Welcome to nginx</html>", contentType: "text/html") }
        do {
            _ = try await collect(client())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(RequestRetry.disposition(for: error), .fail, "\(error)")
        }
    }

    func testSGLangOverflowWordingIsRecognised() {
        XCTAssertEqual(OpenAIClient.overflowLimit(in: "The input (270000 tokens) is longer than the model's context length (262144 tokens)."), 262_144)
        XCTAssertEqual(OpenAIClient.overflowLimit(in: "Requested token count exceeds the model's maximum context length of 131072 tokens"), 131_072)
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
